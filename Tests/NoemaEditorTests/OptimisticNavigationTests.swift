import Foundation
import Testing
import VaultCore
@testable import noema

private enum NavigationFixtureError: Error { case saveFailure }

@MainActor private final class NavigationSaveBarrier {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

extension VaultUIIntegrationTests {
    @Suite(.serialized) @MainActor struct OptimisticNavigationTests {
        private func fixture() async throws -> (URL, URL, FileVaultRepository, AppModel, NoteRecord, NoteRecord) {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("optimistic-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let first = try await repository.create(title: "First", body: "Original")
            let second = try await repository.create(title: "Second", body: "Destination")
            let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            try #require(model.isVaultAvailable)
            model.select(first.id)
            return (base, root, repository, model, first, second)
        }
        private func entered(_ barrier: NavigationSaveBarrier) async throws {
            for _ in 0..<200 {
                if barrier.entered { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(barrier.entered)
        }

        @Test func busySaveAllowsImmediateNavigationAndRebasesOnlyItsOwnSuccessor() async throws {
            let (base, _, repository, model, first, second) = try await fixture()
            defer { try? FileManager.default.removeItem(at: base) }
            let barrier = NavigationSaveBarrier(); defer { barrier.release() }
            var waits = 0
            model.pageSavePreparation = { waits += 1; if waits == 1 { await barrier.wait() } }
            model.body = "First captured revision"; model.select(second.id)
            #expect(model.selectedID == second.id && model.body == second.body)
            try await entered(barrier)
            model.select(first.id)
            #expect(model.body == "First captured revision")
            model.body = "Latest captured revision"; model.lccInput = "QA76"
            model.select(second.id)
            #expect(model.body == second.body)
            barrier.release()
            #expect(await model.flushPendingEdits())
            let saved = try #require(try await repository.scan().notes.first { $0.id == first.id })
            #expect(BlockDocumentCodec.markdownBody(saved.body) == "Latest captured revision")
            #expect(saved.lcc == "QA76")
            #expect(model.pageSaveFailures.isEmpty)
            #expect(model.currentNote?.id == second.id && model.body == second.body)
            #expect(await model.closeVault())
        }

        @Test func structuredDraftRetainsBlockIdentityAndMetadataAcrossDelayedSaveAndRevisit() async throws {
            let (base, _, repository, model, first, second) = try await fixture()
            defer { try? FileManager.default.removeItem(at: base) }
            let barrier = NavigationSaveBarrier(); defer { barrier.release() }
            var waits = 0
            model.pageSavePreparation = { waits += 1; if waits == 1 { await barrier.wait() } }
            var document = model.editorDocument
            let blockID = try #require(document.blocks.first?.id)
            document.blocks[0].runs = [RichRun("Structured captured draft")]
            document.blocks[0].metadata.extra["future-property"] = "Preserved"
            document.setAISummary("Preserved summary")
            model.editorDocument = document
            model.select(second.id)
            try await entered(barrier)
            model.select(first.id)
            #expect(model.editorDocument == document)
            #expect(model.editorDocument.withoutAISummary.blocks.first?.id == blockID)
            let blockIndex = try #require(model.editorDocument.blocks.firstIndex { $0.id == blockID })
            model.editorDocument.blocks[blockIndex].runs = [RichRun("Structured successor draft")]
            let successor = model.editorDocument
            model.select(second.id)
            barrier.release()
            #expect(await model.flushPendingEdits())
            let saved = try await repository.sqliteBlockStore.loadPage(pageID: first.id)
            #expect(saved.snapshot.document.withoutAISummary.blocks.first?.id == blockID)
            #expect(saved.snapshot.document.withoutAISummary.blocks.first?.metadata.extra["future-property"] == "Preserved")
            #expect(saved.snapshot.document.aiSummary == successor.aiSummary)
            #expect(saved.snapshot.document.withoutAISummary.blocks.first?.text == "Structured successor draft")
            #expect(model.pageSaveFailures.isEmpty)
            #expect(await model.closeVault())
        }

        @Test(arguments: [true, false]) func lifecycleDrainsBackgroundSaveBeforeRetiringSession(lock: Bool) async throws {
            let (base, root, repository, model, first, second) = try await fixture()
            defer { try? FileManager.default.removeItem(at: base) }
            let barrier = NavigationSaveBarrier(); defer { barrier.release() }
            model.pageSavePreparation = { await barrier.wait() }
            model.body = "Durable before retirement"; model.select(second.id)
            try await entered(barrier)
            let retirement = Task { lock ? await model.lockVault() : await model.closeVault() }
            await Task.yield()
            #expect(model.isVaultAvailable)
            barrier.release()
            #expect(await retirement.value)
            let saved = try #require(try await repository.scan().notes.first { $0.id == first.id })
            #expect(BlockDocumentCodec.markdownBody(saved.body) == "Durable before retirement")
            if lock {
                #expect(await model.unlockVault(using: root))
                #expect(await model.closeVault())
            }
        }

        @Test func externalRevisionStillConflictsAndReloadShowsDiskWhileRetainingDraft() async throws {
            let (base, _, repository, model, first, second) = try await fixture()
            defer { try? FileManager.default.removeItem(at: base) }
            let barrier = NavigationSaveBarrier(); defer { barrier.release() }
            model.pageSavePreparation = { await barrier.wait() }
            model.body = "Local draft"; model.select(second.id)
            try await entered(barrier)
            _ = try await repository.save(note: first, title: first.title, body: "External update", tags: first.tags)
            barrier.release(); model.pageSavePreparation = nil
            #expect(!(await model.flushPendingEdits()))
            #expect(model.pageSaveFailures[first.id] != nil)
            model.select(first.id)
            #expect(model.body == "Local draft")
            model.reloadDiskVersion()
            for _ in 0..<200 {
                if BlockDocumentCodec.markdownBody(model.body) == "External update" { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(BlockDocumentCodec.markdownBody(model.body) == "External update")
            #expect(model.recoveredDrafts.contains { $0.id == first.id && BlockDocumentCodec.markdownBody($0.contentBody) == "Local draft" })
            #expect(await model.closeVault())
        }

        @Test func failureBeforeRecoveryPublicationRemainsRecoverableAcrossForcedClose() async throws {
            let (base, root, _, model, first, second) = try await fixture()
            defer { try? FileManager.default.removeItem(at: base) }
            model.pageSavePreparation = { throw NavigationFixtureError.saveFailure }
            model.body = "Memory draft"; model.select(second.id)
            #expect(!(await model.flushPendingEdits()))
            #expect(model.recoveredDrafts.contains { $0.id == first.id && BlockDocumentCodec.markdownBody($0.contentBody) == "Memory draft" })
            #expect(await model.closeVault(force: true))
            model.pageSavePreparation = nil
            await model.open(root, create: false)
            #expect(model.recoveredDrafts.contains { $0.id == first.id && BlockDocumentCodec.markdownBody($0.contentBody) == "Memory draft" })
            #expect(await model.closeVault())
        }
    }
}
