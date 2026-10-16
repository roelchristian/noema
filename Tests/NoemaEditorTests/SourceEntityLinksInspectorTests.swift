import Foundation
import Synchronization
import Testing
@testable import VaultCore
@testable import noema

private final class LinkReadCounter: Sendable {
    let reads = Mutex(0)
    func reset() { reads.withLock { $0 = 0 } }
    var count: Int { reads.withLock { $0 } }
}
private struct LinkReadProbe: VaultContentStore {
    let base: any VaultContentStore
    let counter: LinkReadCounter
    func read(at path: String) throws -> Data {
        if path.contains("/original.") { counter.reads.withLock { $0 += 1 } }
        return try base.read(at: path)
    }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try base.changeToken(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

struct SourceEntityLinksPresentationTests {
    @Test func entitySourceRowsRejectCachedSelectionBeforeReloadStarts() {
        let revision = BlockStoreRevision(token: Data("fixture".utf8)), session = UUID()
        let old = KnowledgeEntitySnapshot(entity: .init(typeKey: "person", label: "Old selection"), revision: revision)
        let next = KnowledgeEntitySnapshot(entity: .init(typeKey: "person", label: "Next selection"), revision: revision)
        let snapshot = SourceEntityLinksSnapshot(associations: [], sources: [], entities: [old, next],
            vaultRevision: revision, sessionID: session, offset: 0)
        #expect(SourceEntityLinksPresentation.canDisplayEntitySources(snapshot, entityID: old.entity.id,
            requestedEntityID: old.entity.id, requestedSessionID: session, sessionID: session, isLocked: false))
        // Even if the next entity happens to occur in the old result, ownership must match.
        #expect(!SourceEntityLinksPresentation.canDisplayEntitySources(snapshot, entityID: next.entity.id,
            requestedEntityID: old.entity.id, requestedSessionID: session, sessionID: session, isLocked: false))
        #expect(!SourceEntityLinksPresentation.canDisplayEntitySources(snapshot, entityID: old.entity.id,
            requestedEntityID: old.entity.id, requestedSessionID: session, sessionID: UUID(), isLocked: false))
        #expect(!SourceEntityLinksPresentation.canDisplayEntitySources(snapshot, entityID: old.entity.id,
            requestedEntityID: old.entity.id, requestedSessionID: session, sessionID: session, isLocked: true))
        let preview = SourceEntityLinksSnapshot(associations: [], sources: [], entities: [old],
            vaultRevision: revision, sessionID: nil, offset: 0)
        #expect(SourceEntityLinksPresentation.canDisplayEntitySources(preview, entityID: old.entity.id,
            requestedEntityID: old.entity.id, requestedSessionID: nil, sessionID: nil, isLocked: false))
        #expect(!SourceEntityLinksPresentation.canDisplayEntitySources(preview, entityID: old.entity.id,
            requestedEntityID: nil, requestedSessionID: nil, sessionID: nil, isLocked: false))
    }
    @Test func rolesFilterOnlyExistingTypesAndMetadataNeverImpliesAvailability() throws {
        let revision = BlockStoreRevision(token: Data("fixture".utf8))
        let entities = KnowledgeEntityType.initial.map { KnowledgeEntitySnapshot(entity: .init(typeKey: $0.key, label: $0.key), revision: revision) }
        let deleted = KnowledgeEntitySnapshot(entity: .init(typeKey: "creativeWork", label: "Deleted", lifecycle: .tombstoned), revision: revision)
        let unsupported = KnowledgeEntitySnapshot(entity: .init(typeKey: "book", label: "Unsupported"), revision: revision)
        #expect(SourceEntityLinksPresentation.eligibleEntities(entities + [deleted, unsupported], role: .aboutEntity) == entities)
        #expect(SourceEntityLinksPresentation.eligibleEntities(entities + [deleted], role: .representsWork).map(\.entity.typeKey) == ["creativeWork"])
        #expect(SourceEntityLinksPresentation.roleLabel(.aboutEntity) != SourceEntityLinksPresentation.roleLabel(.representsWork))
        let metadata = SourceMetadata(id: UUID(), title: "Evidence", capturedAt: "2026-10-16", originalFilename: "evidence.txt", originURL: nil,
            sha256: String(repeating: "a", count: 64), storedFilename: "original.txt")
        let source = try CanonicalSource(metadata: metadata)
        let live = CanonicalSourceSnapshot(source: source, revision: revision, trashed: false, trashedAt: nil)
        let trash = CanonicalSourceSnapshot(source: source, revision: revision, trashed: true, trashedAt: Date())
        #expect(SourceEntityLinksPresentation.sourceTitle(live) == "Evidence")
        #expect(SourceEntityLinksPresentation.sourceStatus(live, availability: nil) == "Original not verified")
        #expect(SourceEntityLinksPresentation.sourceStatus(live, availability: "Offline").contains("Offline"))
        #expect(SourceEntityLinksPresentation.sourceStatus(trash, availability: "Available").contains("Trash"))
        #expect(SourceEntityLinksPresentation.sourceStatus(trash, availability: nil) == "Source in Trash · Original not verified")
        #expect(SourceEntityLinksPresentation.sourceStatus(trash, availability: "Offline") == "Source in Trash · Last check: Offline")
        let unavailable = CanonicalSource(id: source.id, ownership: .unavailable, metadata: source.metadata)
        let unavailableTrash = CanonicalSourceSnapshot(source: unavailable, revision: revision, trashed: true, trashedAt: Date())
        #expect(SourceEntityLinksPresentation.sourceStatus(unavailableTrash, availability: "Available") == "Source in Trash · Original unavailable")
    }
}

extension VaultUIIntegrationTests {
    @MainActor struct SourceEntityLinksInspectorTests {
        @Test func linksNavigateBothDirectionsWithoutEagerOriginalReadsAndUnlinkFromEitherSide() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("source-links-ui-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let source = try await repository.importSource(data: Data("Preserved evidence".utf8), filename: "evidence.txt", title: "Evidence", originURL: nil)
            let store = repository.sqliteBlockStore
            let work = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let before = try await store.sourceSnapshot(id: source.id)
            let counter = LinkReadCounter()
            let provider = VaultStorageProvider { root in LinkReadProbe(base: try VaultStorageProvider.plaintext.makeStore(root: root), counter: counter) }
            let model = AppModel(storageProvider: provider)
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            await model.refresh()
            counter.reset()
            let empty = try await model.loadSourceEntityLinks(sourceID: source.id)
            await #expect(throws: (any Error).self) {
                try await model.linkSourceEntity(sourceID: source.id, entity: work, role: .representsWork, snapshot: empty, isCurrent: { false })
            }
            try await model.linkSourceEntity(sourceID: source.id, entity: work, role: .representsWork, snapshot: empty, isCurrent: { true })
            let sourceLinks = try await model.loadSourceEntityLinks(sourceID: source.id)
            let entityLinks = try await model.loadEntitySourceLinks(entityID: work.entity.id)
            #expect(sourceLinks.associations == entityLinks.associations)
            #expect(entityLinks.sources.first == before)
            #expect(sourceLinks.entities.first == work)
            #expect(counter.count == 0)
            let association = try #require(entityLinks.associations.first)
            try await model.unlinkSourceEntity(association, snapshot: entityLinks, isCurrent: { true })
            #expect(try await model.loadSourceEntityLinks(sourceID: source.id).associations.isEmpty)
            let refreshed = try await model.loadSourceEntityLinks(sourceID: source.id)
            try await model.linkSourceEntity(sourceID: source.id, entity: work, role: .aboutEntity, snapshot: refreshed, isCurrent: { true })
            let linked = try await model.loadSourceEntityLinks(sourceID: source.id)
            try await model.unlinkSourceEntity(#require(linked.associations.first), snapshot: linked, isCurrent: { true })
            #expect(try await model.loadEntitySourceLinks(entityID: work.entity.id).associations.isEmpty)
            #expect(try await store.sourceSnapshot(id: source.id) == before)
            #expect(try await store.loadEntity(id: work.entity.id) == work)
            #expect(counter.count == 0)
            // Navigation intentionally uses the existing reader, which verifies original bytes.
            let navigation = try await model.loadEntitySourceLinks(entityID: work.entity.id)
            let sourceNavigation = SourceEntityLinksSnapshot(associations: [], sources: [before], entities: [work],
                vaultRevision: navigation.vaultRevision, sessionID: navigation.sessionID, offset: 0)
            model.openAssociatedSource(source.id, snapshot: sourceNavigation, isCurrent: { false })
            #expect(!SourceReader.openReaderIDs.contains(source.id))
            model.openAssociatedSource(source.id, snapshot: sourceNavigation, isCurrent: { true })
            for _ in 0..<150 {
                if SourceReader.openReaderIDs.contains(source.id) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(SourceReader.openReaderIDs.contains(source.id))
            #expect(counter.count > 0)
            #expect(await model.closeVault(force: true))
            #expect(!SourceReader.openReaderIDs.contains(source.id))
            try await store.close()
        }

        @Test func delayedLinksRejectSourceTrashWithoutCollectionRevisionChangeAndStillAllowExplicitUnlink() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("source-links-trash-race-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let source = try await repository.importSource(data: Data("Evidence".utf8), filename: "e.txt", title: "Evidence", originURL: nil)
            let store = repository.sqliteBlockStore
            let entity = try await store.createEntity(.init(typeKey: "person", label: "Person"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            _ = try await store.linkSource(source.id, to: entity.entity.id, role: .aboutEntity,
                expectedSource: store.sourceSnapshot(id: source.id).revision, expectedEntity: entity.revision,
                expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State"); model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let entered = AsyncStream.makeStream(of: Void.self), release = AsyncStream.makeStream(of: Void.self)
            model.sourceEntityLinksDidLoad = {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            let pending = Task { try await model.loadEntitySourceLinks(entityID: entity.entity.id) }
            var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
            _ = try await store.setSourceTrashed(id: source.id, expected: store.sourceSnapshot(id: source.id).revision, trashed: true)
            model.sourceEntityLinksDidLoad = nil
            release.continuation.yield(()); release.continuation.finish()
            await #expect(throws: KnowledgeStoreError.staleRevision) { try await pending.value }
            let retained = try await model.loadEntitySourceLinks(entityID: entity.entity.id)
            #expect(retained.sources.first?.trashed == true)
            try await model.unlinkSourceEntity(#require(retained.associations.first), snapshot: retained, isCurrent: { true })
            #expect(try await store.sourcesForEntity(id: entity.entity.id).isEmpty)
            #expect(await model.closeVault(force: true)); try await store.close()
        }

        @Test func delayedResultsAndMutationsRejectVaultSwitch() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("source-links-session-race-\(UUID())")
            let root = base.appendingPathComponent("Vault"), otherRoot = base.appendingPathComponent("Other")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let other = try await openCanonicalAppFixture(root: otherRoot, create: true)
            let source = try await repository.importSource(data: Data("Evidence".utf8), filename: "e.txt", title: "Evidence", originURL: nil)
            let store = repository.sqliteBlockStore
            let entity = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State"); model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let captured = try await model.loadSourceEntityLinks(sourceID: source.id)
            let entered = AsyncStream.makeStream(of: Void.self), release = AsyncStream.makeStream(of: Void.self)
            model.sourceEntityLinksDidLoad = {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            let pending = Task { try await model.loadSourceEntityLinks(sourceID: source.id) }
            var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
            #expect(await model.closeVault(force: true))
            model.sourceEntityLinksDidLoad = nil
            await model.open(otherRoot, create: false)
            release.continuation.yield(()); release.continuation.finish()
            await #expect(throws: (any Error).self) { try await pending.value }
            await #expect(throws: (any Error).self) {
                try await model.linkSourceEntity(sourceID: source.id, entity: entity, role: .representsWork, snapshot: captured, isCurrent: { true })
            }
            model.openAssociatedSource(source.id, snapshot: captured, isCurrent: { true })
            #expect(!SourceReader.openReaderIDs.contains(source.id))
            #expect(try await store.associationsForSource(id: source.id).isEmpty)
            #expect(await model.closeVault(force: true))
            try await store.close(); try await other.sqliteBlockStore.close()
        }
    }
}
