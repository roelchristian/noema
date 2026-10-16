import Foundation
import Testing
@testable import VaultCore
@testable import noema

@Suite("Entity properties inspector")
struct EntityPropertiesInspectorTests {
    @Test func scalarInputsPreserveFalseZeroEmptyAndDateGranularity() throws {
        #expect(try EntityPropertyInput.value(kind: .text, text: "", boolean: false) == .text(""))
        #expect(try EntityPropertyInput.value(kind: .number, text: "0", boolean: false) == .number(0))
        #expect(try EntityPropertyInput.value(kind: .boolean, text: "", boolean: false) == .boolean(false))
        #expect(try EntityPropertyInput.value(kind: .date, text: "2024", boolean: false) == .date(.init(year: 2024)))
        #expect(try EntityPropertyInput.value(kind: .date, text: "2024-02", boolean: false) == .date(.init(year: 2024, month: 2)))
        #expect(try EntityPropertyInput.value(kind: .date, text: "2024-02-29", boolean: false) == .date(.init(year: 2024, month: 2, day: 29)))
        #expect(try EntityPropertyInput.value(kind: .url, text: "https://example.org/work", boolean: false) == .url("https://example.org/work"))
    }

    @Test func invalidScalarInputCannotReachCanonicalSave() {
        for number in ["", "nan", "inf", "1e999", "abc"] {
            #expect(throws: (any Error).self) { try EntityPropertyInput.value(kind: .number, text: number, boolean: false) }
        }
        for date in ["2023-02-29", "2024-13", "2024-00", "2024-01-32", "2024-02-", "2024-01-01T00:00:00Z"] {
            #expect(throws: (any Error).self) { try EntityPropertyInput.value(kind: .date, text: date, boolean: false) }
        }
        for url in ["example.org", "file:///private/tmp/file", "https://", "https://example.org/a b"] {
            #expect(throws: (any Error).self) { try EntityPropertyInput.value(kind: .url, text: url, boolean: false) }
        }
        #expect(throws: (any Error).self) { try EntityPropertyInput.value(kind: .entityReference, text: "Person", boolean: false) }
    }

    @Test func definitionSearchKeepsCanonicalIdentityAndIncomingLabelsExplicit() throws {
        let vaultID = UUID(), revision = BlockStoreRevision(token: Data("fixture".utf8))
        let work = try EntityPropertyDefinition(vaultID: vaultID, label: "Created by", kind: .entityReference)
        let title = try EntityPropertyDefinition(vaultID: vaultID, label: "Working title", kind: .text)
        let definitions = [work, title].map { EntityPropertyDefinitionSnapshot(definition: $0, revision: revision) }
        #expect(EntityPropertiesPresentation.matchingDefinitions(definitions, query: "CREATED").map(\.definition.id) == [work.id])
        #expect(EntityPropertiesPresentation.matchingDefinitions(definitions, query: "missing").isEmpty)
        #expect(EntityPropertiesPresentation.matchingDefinitions(definitions, query: "").map(\.definition.id) == [work.id, title.id])
        #expect(EntityPropertiesPresentation.relationshipLabel(work, incoming: false) == work.label)
        let incoming = EntityPropertiesPresentation.relationshipLabel(work, incoming: true)
        #expect(incoming.contains(work.label))
        #expect(incoming != work.label)
        #expect(EntityPropertiesPresentation.previewLimit == 4)
    }

    @Test func delayedPropertyResultsRejectDifferentEntitySessionAndRequest() {
        let entity = UUID(), session = UUID()
        let request = EntityPropertiesRequestToken(entityID: entity, sessionID: session)
        #expect(request.matches(request: request, entityID: entity, sessionID: session))
        #expect(!request.matches(request: request, entityID: UUID(), sessionID: session))
        #expect(!request.matches(request: request, entityID: entity, sessionID: UUID()))
        #expect(!request.matches(request: request, entityID: entity, sessionID: nil))
        let replacement = EntityPropertiesRequestToken(entityID: entity, sessionID: session)
        #expect(!request.matches(request: replacement, entityID: entity, sessionID: session))
    }
}

extension VaultUIIntegrationTests {
    @Suite("Entity properties inspector canonical integration")
    @MainActor struct EntityPropertiesIntegrationTests {
        @Test func schemaSevenInspectorLoadsAndEditsScalarsWithoutImplicitRelationshipUpgrade() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("entity-inspector-schema-seven-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let vaultID = UUID()
            let content = try VaultStorageProvider.plaintext.makeStore(root: root)
            for path in ["Sources", "Conflicts"] { try content.createDirectory(at: path) }
            let store = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID)
            let entity = try await store.createEntity(.init(typeKey: "person", label: "Existing person"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Verified", kind: .boolean)
            _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            let assignment = EntityPropertyAssignment(definitionID: definition.id, value: .boolean(false))
            _ = try await store.savePropertyValues(entityID: entity.entity.id, assignments: [assignment], expectedEntity: entity.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            try await store.checkpoint()
            try await store.close()
            var manifest = VaultManifest(id: vaultID)
            manifest.storage?.schemaVersion = SQLiteBlockStore.propertySchemaVersion
            manifest.storage?.requiredCapabilities = SQLiteBlockStore.propertyRequiredCapabilities
            let manifestBytes = try JSONEncoder().encode(manifest)
            try content.write(manifestBytes, at: "vault.json", condition: .createOnly)
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)
            let initial = try await model.loadEntityProperties(entityID: entity.entity.id)
            #expect(initial.values.assignments == [assignment])
            #expect(!initial.supportsRelationships)
            #expect(initial.relationships.isEmpty)
            let updated = EntityPropertyAssignment(id: assignment.id, definitionID: definition.id, value: .boolean(true))
            try await model.editEntityProperties(.saveValues([updated]), snapshot: initial, isCurrent: { true })
            let edited = try await model.loadEntityProperties(entityID: entity.entity.id)
            #expect(edited.values.assignments == [updated])
            #expect(!edited.supportsRelationships)
            #expect(edited.relationships.isEmpty)
            await #expect(throws: KnowledgeStoreError.transitionRequired) {
                try await model.editEntityProperties(.createDefinition(label: "Relationship requires explicit upgrade", kind: .entityReference, cardinality: .many), snapshot: edited, isCurrent: { true })
            }
            #expect(try content.read(at: "vault.json") == manifestBytes)
            #expect(await model.closeVault(force: true))
            let reopened = try VaultStorageProvider.plaintext.makePropertyStagingStore(url: root.appendingPathComponent("blocks.sqlite"), vaultID: vaultID, createIfMissing: false)
            #expect(try await reopened.loadPropertyValues(entityID: entity.entity.id).assignments == [updated])
            #expect(try await reopened.listPropertyDefinitions().map(\.definition.id) == [definition.id])
            await #expect(throws: KnowledgeStoreError.transitionRequired) {
                try await reopened.queryPropertyRelationships(entityID: entity.entity.id)
            }
            try await reopened.close()
        }

        @Test func delayedEntitySearchCannotReturnOldVaultEntitiesAfterReopen() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("entity-inspector-search-race-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let store = repository.sqliteBlockStore
            _ = try await store.createEntity(.init(typeKey: "person", label: "Captured before close"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let entered = AsyncStream.makeStream(of: Void.self)
            let release = AsyncStream.makeStream(of: Void.self)
            model.entityPropertySearchDidLoad = {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
            let search = Task { try await model.searchEntityPropertyTargets(query: "Captured") }
            var enteredIterator = entered.stream.makeAsyncIterator()
            _ = await enteredIterator.next()
            let capturedSession = model.sessionState.sessionID
            #expect(await model.closeVault(force: true))
            await model.open(root, create: false)
            #expect(model.sessionState.sessionID != capturedSession)
            model.entityPropertySearchDidLoad = nil
            release.continuation.yield(())
            release.continuation.finish()
            await #expect(throws: (any Error).self) { try await search.value }
            #expect(try await model.searchEntityPropertyTargets(query: "Captured").count == 1)
            #expect(await model.closeVault(force: true))
        }

        @Test func inspectorHydratesAndSearchesRelationshipEndpointsBeyondCatalogueLimit() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("entity-inspector-catalogue-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let store = repository.sqliteBlockStore
            for index in 0..<1_000 {
                let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                _ = try await store.createEntity(.init(id: id, typeKey: "concept", label: "Filler \(index)"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            }
            let workID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFC"))
            let personID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFD"))
            let work = try await store.createEntity(.init(id: workID, typeKey: "creativeWork", label: "Outside catalogue work"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let person = try await store.createEntity(.init(id: personID, typeKey: "person", label: "Outside catalogue author"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let definition = try EntityPropertyDefinition(vaultID: repository.manifest.id, label: "Created by", kind: .entityReference)
            _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            let edge = try await store.createPropertyRelationship(definitionID: definition.id, entityID: workID, otherEntityID: personID, direction: .outgoing, expectedEntity: work.revision, expectedOther: person.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            #expect(try await store.knowledgeCatalogue().entities.count == 1_000)
            #expect(try await store.knowledgeCatalogue().entities.allSatisfy { $0.entity.id != workID && $0.entity.id != personID })
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let snapshot = try await model.loadEntityProperties(entityID: personID)
            #expect(snapshot.entities.contains { $0.entity.id == workID })
            #expect(snapshot.entities.contains { $0.entity.id == personID })
            #expect(try await model.searchEntityPropertyTargets(query: "Outside catalogue author").map(\.entity.id) == [personID])
            try await model.editEntityProperties(.removeRelationship(edge), snapshot: snapshot, isCurrent: { true })
            #expect(try await model.loadEntityProperties(entityID: personID).relationships.isEmpty)
            #expect(await model.closeVault(force: true))
        }

        @Test func canonicalEntityEditingPreservesScalarIdentityAndInverseEdgeIdentity() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("entity-inspector-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let store = repository.sqliteBlockStore
            let work = try await store.createEntity(.init(typeKey: "creativeWork", label: "Book"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let person = try await store.createEntity(.init(typeKey: "person", label: "Author"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)
            let initial = try await model.loadEntityProperties(entityID: work.entity.id)
            #expect(initial.values.assignments.isEmpty)
            try await model.editEntityProperties(.createDefinition(label: "Working title", kind: .text, cardinality: .one), snapshot: initial, isCurrent: { true })
            let withDefinition = try await model.loadEntityProperties(entityID: work.entity.id)
            let definition = try #require(withDefinition.definitions.first { $0.definition.label == "Working title" })
            let assignment = EntityPropertyAssignment(definitionID: definition.definition.id, value: .text("First"))
            try await model.editEntityProperties(.saveValues([assignment]), snapshot: withDefinition, isCurrent: { true })
            let withValue = try await model.loadEntityProperties(entityID: work.entity.id)
            let updated = EntityPropertyAssignment(id: assignment.id, definitionID: assignment.definitionID, value: .text("Revised"))
            try await model.editEntityProperties(.saveValues([updated]), snapshot: withValue, isCurrent: { true })
            let beforeRelation = try await model.loadEntityProperties(entityID: work.entity.id)
            #expect(beforeRelation.values.assignments == [updated])
            try await model.editEntityProperties(.createDefinition(label: "Created by", kind: .entityReference, cardinality: .many), snapshot: beforeRelation, isCurrent: { true })
            let incoming = try await model.loadEntityProperties(entityID: person.entity.id)
            let relationshipDefinition = try #require(incoming.definitions.first { $0.definition.label == "Created by" })
            try await model.editEntityProperties(.addRelationship(definitionID: relationshipDefinition.definition.id, otherID: work.entity.id, incoming: true), snapshot: incoming, isCurrent: { true })
            let forward = try await model.loadEntityProperties(entityID: work.entity.id)
            var inverse = try await model.loadEntityProperties(entityID: person.entity.id)
            var editedDefinition = relationshipDefinition.definition
            editedDefinition.presentation = .init(inverseLabel: "Creator of", sourceTypeKeys: ["creativeWork"], targetTypeKeys: ["person"])
            try await model.editEntityProperties(.saveDefinition(editedDefinition), snapshot: inverse, isCurrent: { true })
            inverse = try await model.loadEntityProperties(entityID: person.entity.id)
            #expect(inverse.definitions.first { $0.definition.id == editedDefinition.id }?.definition.presentation == editedDefinition.presentation)
            #expect(forward.relationships == inverse.relationships)
            let edge = try #require(inverse.relationships.first)
            #expect(edge.relationship.sourceID == work.entity.id)
            #expect(edge.relationship.targetID == person.entity.id)
            try await model.editEntityProperties(.removeRelationship(edge), snapshot: inverse, isCurrent: { true })
            #expect(try await model.loadEntityProperties(entityID: work.entity.id).relationships.isEmpty)
            #expect(await model.closeVault(force: true))
        }

        @Test func staleSelectionRevisionAndReopenedSessionRejectMutationWithoutWriting() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("entity-inspector-stale-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let store = repository.sqliteBlockStore
            let entity = try await store.createEntity(.init(typeKey: "person", label: "Person"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let snapshot = try await model.loadEntityProperties(entityID: entity.entity.id)
            let edit = EntityPropertyEdit.createDefinition(label: "Must not save", kind: .text, cardinality: .one)
            await #expect(throws: (any Error).self) {
                try await model.editEntityProperties(edit, snapshot: snapshot, isCurrent: { false })
            }
            #expect(try await store.canonicalVaultRevision() == snapshot.vaultRevision)
            try await model.editEntityProperties(.createDefinition(label: "Current", kind: .text, cardinality: .one), snapshot: snapshot, isCurrent: { true })
            await #expect(throws: KnowledgeStoreError.staleRevision) {
                try await model.editEntityProperties(edit, snapshot: snapshot, isCurrent: { true })
            }
            let beforeClose = try await model.loadEntityProperties(entityID: entity.entity.id)
            #expect(await model.closeVault(force: true))
            await model.open(root, create: false)
            #expect(model.sessionState.sessionID != beforeClose.sessionID)
            await #expect(throws: (any Error).self) {
                try await model.editEntityProperties(edit, snapshot: beforeClose, isCurrent: { true })
            }
            let reopened = try await model.loadEntityProperties(entityID: entity.entity.id)
            #expect(reopened.vaultRevision == beforeClose.vaultRevision)
            #expect(reopened.definitions.map(\.definition.label) == ["Current"])
            #expect(await model.closeVault(force: true))
        }
    }
}
