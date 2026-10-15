import SwiftUI
import VaultCore

/// A document menu only moves the membership named by its source. Other placements
/// and the independent favourite are never included in that operation.
struct DocumentOrganisationActions {
    struct Destination: Identifiable, Equatable {
        let container: OrganisationContainer
        let title: String
        let isMember: Bool
        var id: UUID { container.id }
    }

    enum Action: Equatable {
        case membership(UUID, OrganisationItemReference, Bool)
        case place(OrganisationItemReference, UUID, UUID)
    }

    let reference: OrganisationItemReference
    let destinations: [Destination]
    let sourceContainerID: UUID?
    var memberships: [Destination] { destinations.filter(\.isMember) }
    var contextualSource: Destination? {
        memberships.first { $0.id == sourceContainerID }
    }

    init(reference: OrganisationItemReference, containers: [OrganisationContainer],
         memberships: [OrganisationMembership], sourceContainerID: UUID? = nil) {
        self.reference = reference
        self.sourceContainerID = sourceContainerID
        let valid = reference.pageID == nil && (reference.kind == .page || reference.kind == .source)
        let byID = Dictionary(containers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        destinations = valid ? containers.map { container in
            var names = [container.name]
            var visited: Set<UUID> = [container.id]
            var parentID = container.parentID
            while let id = parentID, visited.insert(id).inserted, let parent = byID[id] {
                names.insert(parent.name, at: 0)
                parentID = parent.parentID
            }
            return Destination(container: container, title: names.joined(separator: " / "),
                isMember: memberships.contains { $0.containerID == container.id && $0.reference == reference })
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        } : []
    }

    func toggleMembership(in id: UUID) -> Action? {
        guard let destination = destinations.first(where: { $0.id == id }) else { return nil }
        return .membership(id, reference, !destination.isMember)
    }

    func removeFromContext() -> Action? {
        contextualSource.map { .membership($0.id, reference, false) }
    }

    func move(to destinationID: UUID, from sourceID: UUID) -> Action? {
        guard sourceID != destinationID, memberships.contains(where: { $0.id == sourceID }),
              destinations.contains(where: { $0.id == destinationID }) else { return nil }
        return .place(reference, destinationID, sourceID)
    }
}

extension AppModel {
    /// Avoid synthesizing page references for sources, semantic rows or stale selections.
    func isOrganisableDocument(_ reference: OrganisationItemReference) -> Bool {
        guard reference.pageID == nil else { return false }
        switch reference.kind {
        case .page: return notes.contains { $0.id == reference.itemID }
        case .source: return sources.contains { $0.id == reference.itemID }
        default: return false
        }
    }

    func performDocumentOrganisationAction(_ action: DocumentOrganisationActions.Action) {
        switch action {
        case .membership(let id, let reference, let adding):
            guard isOrganisableDocument(reference), organisationContainers.contains(where: { $0.id == id }) else { return }
            editOrganisation(.membership(id, reference, adding))
        case .place(let reference, let destination, let source):
            guard isOrganisableDocument(reference), destination != source,
                  organisationContainers.contains(where: { $0.id == destination }),
                  organisationMemberships.contains(where: { $0.containerID == source && $0.reference == reference }) else { return }
            editOrganisation(.place(reference, destination, source))
        }
    }
}

/// Shared by page and source context menus and the active document toolbar menu.
struct DocumentOrganisationMenuCommands: View {
    let model: AppModel
    let reference: OrganisationItemReference
    var sourceContainerID: UUID? = nil

    private var actions: DocumentOrganisationActions {
        .init(reference: reference, containers: model.organisationContainers,
              memberships: model.organisationMemberships, sourceContainerID: sourceContainerID)
    }
    private var disabled: Bool {
        !model.isVaultAvailable || !model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress
    }

    var body: some View {
        if model.isOrganisableDocument(reference) {
            Menu("Add to…") {
                if actions.destinations.isEmpty { Text("No collections or folders").disabled(true) }
                ForEach(actions.destinations) { destination in
                    Toggle(destination.title, isOn: Binding(get: { destination.isMember }, set: { _ in
                        if let action = actions.toggleMembership(in: destination.id) { model.performDocumentOrganisationAction(action) }
                    }))
                }
            }.disabled(disabled)
            if let source = actions.contextualSource {
                moveMenu(from: source)
                Button("Remove from \(source.container.name)") {
                    if let action = actions.removeFromContext() { model.performDocumentOrganisationAction(action) }
                }.disabled(disabled)
            } else if sourceContainerID == nil, !actions.memberships.isEmpty {
                Menu("Move to…") {
                    ForEach(actions.memberships) { source in
                        Menu("From \(source.title)") { moveDestinations(from: source) }
                    }
                }.disabled(disabled || actions.destinations.count < 2)
            }
        }
    }

    private func moveMenu(from source: DocumentOrganisationActions.Destination) -> some View {
        Menu("Move to…") { moveDestinations(from: source) }
            .disabled(disabled || actions.destinations.count < 2)
    }

    @ViewBuilder private func moveDestinations(from source: DocumentOrganisationActions.Destination) -> some View {
        ForEach(actions.destinations.filter { $0.id != source.id }) { destination in
            Button {
                if let action = actions.move(to: destination.id, from: source.id) { model.performDocumentOrganisationAction(action) }
            } label: {
                if destination.isMember { Label(destination.title, systemImage: "checkmark") }
                else { Text(destination.title) }
            }
        }
    }
}

struct DocumentFavouriteMenuCommand: View {
    let model: AppModel
    let reference: OrganisationItemReference
    private var isFavourite: Bool { model.favouriteReferences.contains(reference) }

    var body: some View {
        if model.isOrganisableDocument(reference) {
            Button { model.toggleFavourite(reference) } label: {
                Label(isFavourite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavourite ? "star.fill" : "star")
            }
            .disabled(!model.isVaultAvailable || !model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress)
        }
    }
}
