import Foundation
import Testing
import VaultCore
@testable import noema

struct DocumentOrganisationActionsTests {
    private func container(_ name: String, parentID: UUID? = nil) -> OrganisationContainer {
        .init(id: UUID(), kind: parentID == nil ? .collection : .folder, name: name,
              parentID: parentID, sortOrder: 0, revision: .init(token: Data(name.utf8)),
              createdAt: .distantPast, modifiedAt: .distantPast)
    }

    @Test(arguments: [OrganisationItemKind.page, .source])
    func placementPlanNamesItsSourceAndShowsAllMemberships(kind: OrganisationItemKind) throws {
        let root = container("Research"), unrelated = container("Projects")
        let folder = container("Reading", parentID: root.id)
        let reference = OrganisationItemReference(kind: kind, itemID: UUID())
        let memberships = [root, unrelated].map {
            OrganisationMembership(id: UUID(), containerID: $0.id, reference: reference, sortOrder: 0)
        }
        let plan = DocumentOrganisationActions(reference: reference, containers: [folder, unrelated, root],
                                               memberships: memberships, sourceContainerID: root.id)
        #expect(plan.destinations.first { $0.id == folder.id }?.title == "Research / Reading")
        #expect(Set(plan.memberships.map(\.id)) == [root.id, unrelated.id])
        #expect(plan.move(to: folder.id, from: root.id) == .place(reference, folder.id, root.id))
        #expect(plan.move(to: unrelated.id, from: root.id) == .place(reference, unrelated.id, root.id))
        #expect(plan.removeFromContext() == .membership(root.id, reference, false))
        #expect(plan.toggleMembership(in: root.id) == .membership(root.id, reference, false))
        #expect(plan.toggleMembership(in: folder.id) == .membership(folder.id, reference, true))
        #expect(plan.move(to: root.id, from: root.id) == nil)
        #expect(plan.move(to: folder.id, from: folder.id) == nil)
        #expect(plan.move(to: UUID(), from: root.id) == nil)
        let global = DocumentOrganisationActions(reference: reference, containers: [root, folder, unrelated], memberships: memberships)
        #expect(global.removeFromContext() == nil)
        #expect(Set(global.memberships.map(\.id)) == [root.id, unrelated.id])
    }

    @Test func invalidAndNonDocumentReferencesHaveNoPlacementActions() {
        let destination = container("Research")
        for reference in [OrganisationItemReference(kind: .page, itemID: UUID(), pageID: UUID()),
                          .init(kind: .source, itemID: UUID(), pageID: UUID()),
                          .init(kind: .semanticBlock, itemID: UUID(), pageID: UUID()),
                          .init(kind: .knowledgeEntity, itemID: UUID())] {
            let plan = DocumentOrganisationActions(reference: reference, containers: [destination], memberships: [])
            #expect(plan.destinations.isEmpty)
            #expect(plan.toggleMembership(in: destination.id) == nil)
        }
    }

    @Test func staleContextCannotRemoveAnotherMembership() {
        let source = container("Old context"), other = container("Other")
        let reference = OrganisationItemReference(kind: .source, itemID: UUID())
        let plan = DocumentOrganisationActions(reference: reference, containers: [source, other],
            memberships: [.init(id: UUID(), containerID: other.id, reference: reference, sortOrder: 0)],
            sourceContainerID: source.id)
        #expect(plan.contextualSource == nil)
        #expect(plan.removeFromContext() == nil)
        #expect(plan.move(to: other.id, from: source.id) == nil)
    }
}

extension VaultUIIntegrationTests {
    @Suite @MainActor struct DocumentOrganisationRoutes {
        @Test(arguments: [false, true])
        func moveRemoveAndRowFavouritePreserveDocumentAndOtherMemberships(sourceTarget: Bool) async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaDocumentMenus-" + UUID().uuidString)
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let current = try await repository.create(title: "Current", body: "Current page")
            let page = try await repository.create(title: "Target", body: "Preserved page")
            let source = try await repository.importSource(data: Data("Preserved source".utf8), filename: "source.txt", title: "Source", originURL: nil)
            let reference = OrganisationItemReference(kind: sourceTarget ? .source : .page, itemID: sourceTarget ? source.id : page.id)
            let store = repository.sqliteBlockStore
            var containers: [OrganisationContainer] = []
            for name in ["From", "To", "Unrelated"] {
                containers.append(try await store.createContainer(kind: .collection, name: name, parentID: nil,
                    expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value)
            }
            for container in [containers[0], containers[2]] {
                _ = try await store.addMembership(containerID: container.id, reference: reference,
                    expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
            }
            let originalPage = try await canonicalAppPageSnapshot(repository, id: page.id)
            let originalSource = try await repository.loadSource(id: source.id)
            try await repository.shutdownPageStorage()
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            try #require(model.isVaultAvailable)
            model.select(current.id)
            try await settle(model)
            try #require(model.currentNote?.id == current.id)
            let plan = DocumentOrganisationActions(reference: reference, containers: model.organisationContainers,
                memberships: model.organisationMemberships, sourceContainerID: containers[0].id)
            model.performDocumentOrganisationAction(try #require(plan.move(to: containers[1].id, from: containers[0].id)))
            try await settle(model)
            #expect(Set(model.organisationMemberships.filter { $0.reference == reference }.map(\.containerID)) == [containers[1].id, containers[2].id])
            model.toggleFavourite(reference)
            try await settle(model)
            #expect(model.favouriteReferences.contains(reference))
            #expect(!model.favouriteReferences.contains(.init(kind: .page, itemID: current.id)))
            let removePlan = DocumentOrganisationActions(reference: reference, containers: model.organisationContainers,
                memberships: model.organisationMemberships, sourceContainerID: containers[1].id)
            model.performDocumentOrganisationAction(try #require(removePlan.removeFromContext()))
            try await settle(model)
            #expect(Set(model.organisationMemberships.filter { $0.reference == reference }.map(\.containerID)) == [containers[2].id])
            #expect(model.favouriteReferences.contains(reference))
            #expect(model.notes.contains { $0.id == page.id })
            #expect(model.sources.contains { $0.id == source.id })
            let invalid = OrganisationItemReference(kind: .page, itemID: source.id)
            #expect(!model.isOrganisableDocument(invalid))
            model.toggleFavourite(invalid)
            model.performDocumentOrganisationAction(.membership(containers[0].id, invalid, true))
            #expect(!model.favouriteMutationInProgress && !model.organisationMutationInProgress)
            #expect(model.currentNote?.id == current.id)
            #expect(await model.closeVault())
            let reopened = try await openCanonicalAppFixture(root: root)
            #expect(try await canonicalAppPageSnapshot(reopened, id: page.id) == originalPage)
            #expect(try await reopened.loadSource(id: source.id).body == originalSource.body)
            try await reopened.shutdownPageStorage()
        }

        private func settle(_ model: AppModel) async throws {
            for _ in 0..<200 {
                if !model.organisationMutationInProgress && !model.favouriteMutationInProgress { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(!model.organisationMutationInProgress && !model.favouriteMutationInProgress)
        }
    }
}
