import Foundation
import Testing
@testable import VaultCore
@testable import noema

struct EntityPropertyTemplatePresentationTests {
    @Test func cachedEntityContentIsHiddenImmediatelyWhenSelectionSessionOrLockChanges() {
        let revision = BlockStoreRevision(token: Data("fixture".utf8)), session = UUID()
        let entity = KnowledgeEntitySnapshot(entity: .init(typeKey: "person", label: "Private previous entity"), revision: revision)
        var snapshot = EntityPropertiesSnapshot(entity: entity, definitions: [],
            values: .init(entityID: entity.entity.id, assignments: [], entityRevision: revision),
            relationships: [], entities: [entity], vaultRevision: revision, sessionID: session)
        #expect(EntityPropertiesPresentation.canDisplay(snapshot, entityID: entity.entity.id, sessionID: session, isLocked: false))
        #expect(!EntityPropertiesPresentation.canDisplay(snapshot, entityID: UUID(), sessionID: session, isLocked: false))
        #expect(!EntityPropertiesPresentation.canDisplay(snapshot, entityID: entity.entity.id, sessionID: UUID(), isLocked: false))
        #expect(!EntityPropertiesPresentation.canDisplay(snapshot, entityID: entity.entity.id, sessionID: nil, isLocked: false))
        #expect(!EntityPropertiesPresentation.canDisplay(snapshot, entityID: entity.entity.id, sessionID: session, isLocked: true))
        // Deliberately mismatched value ownership must never surface another entity's facts.
        snapshot = .init(entity: entity, definitions: [], values: .init(entityID: UUID(), assignments: [], entityRevision: revision),
            relationships: [], entities: [entity], vaultRevision: revision, sessionID: session)
        #expect(!EntityPropertiesPresentation.canDisplay(snapshot, entityID: entity.entity.id, sessionID: session, isLocked: false))
        let preview = EntityPropertiesSnapshot(entity: entity, definitions: [],
            values: .init(entityID: entity.entity.id, assignments: [], entityRevision: revision),
            relationships: [], entities: [entity], vaultRevision: revision, sessionID: nil)
        #expect(EntityPropertiesPresentation.canDisplay(preview, entityID: entity.entity.id, sessionID: nil, isLocked: false))
    }

    @Test func removingTemplateRowFocusesNextThenPreviousThenExistingPropertyPicker() {
        let first = UUID(), middle = UUID(), last = UUID()
        #expect(EntityPropertyTemplateFocus.afterRemoving(first, from: [first, middle, last]) == .remove(middle))
        #expect(EntityPropertyTemplateFocus.afterRemoving(middle, from: [first, middle, last]) == .remove(last))
        #expect(EntityPropertyTemplateFocus.afterRemoving(last, from: [first, middle, last]) == .remove(middle))
        #expect(EntityPropertyTemplateFocus.afterRemoving(first, from: [first]) == .definitionPicker)
        #expect(EntityPropertyTemplateFocus.afterRemoving(first, from: []) == .definitionPicker)
    }

    @Test func templateConfigurationIsHiddenBeforeTypeOrSessionReloadCompletes() {
        let session = UUID(), revision = BlockStoreRevision(token: Data("fixture".utf8))
        let configuration = EntityPropertyTemplateConfiguration(template: .init(typeKey: "person", definitionIDs: [], revision: revision),
            definitions: [], vaultRevision: revision, sessionID: session)
        #expect(EntityPropertyTemplatePresentation.canDisplay(configuration, typeKey: "person", sessionID: session, isLocked: false))
        #expect(!EntityPropertyTemplatePresentation.canDisplay(configuration, typeKey: "creativeWork", sessionID: session, isLocked: false))
        #expect(!EntityPropertyTemplatePresentation.canDisplay(configuration, typeKey: "person", sessionID: UUID(), isLocked: false))
        #expect(!EntityPropertyTemplatePresentation.canDisplay(configuration, typeKey: "person", sessionID: session, isLocked: true))
    }

    @Test func suggestionsPreserveTemplateOrderAndIgnoreRetiredAndAlreadyAssertedFacts() throws {
        let revision = BlockStoreRevision(token: Data("fixture".utf8)), vault = UUID()
        let entity = KnowledgeEntitySnapshot(entity: .init(typeKey: "person", label: "Person"), revision: revision)
        let other = UUID()
        let definitions = try (0..<7).map { index in
            EntityPropertyDefinitionSnapshot(definition: try .init(vaultID: vault, label: "P\(index)",
                kind: index > 3 ? .entityReference : .text, isRetired: index == 2), revision: revision)
        }
        let values = EntityPropertyValuesSnapshot(entityID: entity.entity.id,
            assignments: [.init(definitionID: definitions[1].definition.id, value: .text("Fact"))], entityRevision: revision)
        let incoming = EntityPropertyRelationshipSnapshot(relationship: .init(definitionID: definitions[4].definition.id,
            sourceID: other, targetID: entity.entity.id), revision: revision)
        let outgoing = EntityPropertyRelationshipSnapshot(relationship: .init(definitionID: definitions[5].definition.id,
            sourceID: entity.entity.id, targetID: other), revision: revision)
        var snapshot = EntityPropertiesSnapshot(entity: entity, definitions: definitions, values: values,
            relationships: [incoming, outgoing], entities: [entity], vaultRevision: revision, sessionID: UUID(),
            template: .init(typeKey: "person", definitionIDs: [6, 2, 1, 4, 5, 0, 3].map { definitions[$0].definition.id }, revision: revision))
        #expect(EntityPropertyTemplatePresentation.suggestions(snapshot).map(\.definition.id) == [6, 4, 0, 3].map { definitions[$0].definition.id })
        #expect(snapshot.values == values)
        #expect(snapshot.relationships == [incoming, outgoing])
        #expect(EntityPropertyTemplatePresentation.previewLimit == 4)
        #expect(EntityPropertiesPresentation.previewLimit == 4)
        snapshot.template = nil
        #expect(EntityPropertyTemplatePresentation.suggestions(snapshot).isEmpty)
        #expect(EntityPropertiesPresentation.matchingDefinitions(snapshot.definitions, query: "P0").count == 1)
    }
}

extension VaultUIIntegrationTests {
    @MainActor struct EntityPropertyTemplateInspectorTests {
        @Test func allTypesConfigureWithoutEntitiesAndTemplatesDoNotAssertFacts() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("template-ui-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let store = repository.sqliteBlockStore
            let definition = try EntityPropertyDefinition(vaultID: repository.manifest.id, label: "Title", kind: .text)
            _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)
            for type in KnowledgeEntityType.initial {
                let config = try await model.loadPropertyTemplateConfiguration(typeKey: type.key)
                #expect(config.template.definitionIDs.isEmpty)
                try await model.savePropertyTemplateConfiguration([definition.id], snapshot: config, isCurrent: { true })
            }
            #expect(try await store.knowledgeCatalogue().entities.isEmpty)
            let entity = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work"),
                expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            let loaded = try await model.loadEntityProperties(entityID: entity.entity.id)
            #expect(loaded.template?.definitionIDs == [definition.id])
            #expect(loaded.values.assignments.isEmpty)
            #expect(loaded.relationships.isEmpty)
            #expect(loaded.entity == entity)
            #expect(EntityPropertyTemplatePresentation.suggestions(loaded).map(\.definition.id) == [definition.id])
            let config = try await model.loadPropertyTemplateConfiguration(typeKey: "creativeWork")
            try await model.savePropertyTemplateConfiguration([], snapshot: config, isCurrent: { true })
            let cleared = try await model.loadEntityProperties(entityID: entity.entity.id)
            #expect(cleared.entity == entity)
            #expect(cleared.values.assignments.isEmpty)
            #expect(cleared.template?.definitionIDs.isEmpty == true)
            #expect(await model.closeVault(force: true))
            try await store.close()
        }

        @Test func templateConfigurationRejectsOldSelectionRevisionAndReopenedSession() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("template-ui-race-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("State")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let config = try await model.loadPropertyTemplateConfiguration(typeKey: "person")
            await #expect(throws: (any Error).self) {
                try await model.savePropertyTemplateConfiguration([], snapshot: config, isCurrent: { false })
            }
            #expect(try await model.loadPropertyTemplateConfiguration(typeKey: "person").template.revision == nil)
            try await model.savePropertyTemplateConfiguration([], snapshot: config, isCurrent: { true })
            await #expect(throws: KnowledgeStoreError.staleRevision) {
                try await model.savePropertyTemplateConfiguration([], snapshot: config, isCurrent: { true })
            }
            let beforeClose = try await model.loadPropertyTemplateConfiguration(typeKey: "person")
            #expect(await model.closeVault(force: true))
            await model.open(root, create: false)
            await #expect(throws: (any Error).self) {
                try await model.savePropertyTemplateConfiguration([], snapshot: beforeClose, isCurrent: { true })
            }
            #expect(try await model.loadPropertyTemplateConfiguration(typeKey: "person").template == beforeClose.template)
            #expect(await model.closeVault(force: true))
            try await repository.sqliteBlockStore.close()
        }
    }
}
