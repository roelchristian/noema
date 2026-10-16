import SwiftUI
import VaultCore

/// Manual Source-to-entity assertions. Loading this section reads metadata only.
struct SourceEntityLinksView: View {
    @Bindable var model: AppModel
    let sourceID: UUID
    private let previewSnapshot: SourceEntityLinksSnapshot?
    @State private var snapshot: SourceEntityLinksSnapshot?
    @State private var request = UUID()
    @State private var active = false
    @State private var busy = false
    @State private var error: String?
    @State private var offset = 0
    @State private var adding = false
    @State private var query = ""
    @State private var role: SourceEntityAssociationRole = .aboutEntity
    @State private var choices: [KnowledgeEntitySnapshot] = []
    @State private var selectedEntityID: UUID?
    @State private var searchRequest = UUID()
    @State private var searching = false
    @State private var pendingUnlink: SourceEntityAssociationSnapshot?
    @State private var relatedEntityID: UUID?
    @State private var inspectedAssociationID: UUID?
    private enum FocusTarget: Hashable { case refresh, role, search, entityPicker, add, entity(UUID), associationRemoval(UUID) }
    @FocusState private var focusedControl: FocusTarget?
    @AccessibilityFocusState private var accessibleControl: FocusTarget?

    init(model: AppModel, sourceID: UUID, previewSnapshot: SourceEntityLinksSnapshot? = nil) {
        self.model = model; self.sourceID = sourceID; self.previewSnapshot = previewSnapshot
        _snapshot = State(initialValue: previewSnapshot)
    }

    private var identity: String { "\(sourceID):\(String(describing: model.sessionState.sessionID)):\(model.isLocked)" }
    private var searchIdentity: String { "\(query):\(role.rawValue):\(adding):\(identity)" }
    private var displayed: SourceEntityLinksSnapshot? {
        guard !model.isLocked, let snapshot, snapshot.sessionID == model.sessionState.sessionID,
              snapshot.sources.contains(where: { $0.source.id == sourceID }) else { return nil }
        return snapshot
    }
    private var editable: Bool { previewSnapshot == nil && displayed != nil && model.canEditSemanticTarget && !busy && !model.isLocked }
    private var sourceTrashed: Bool { displayed?.sources.first(where: { $0.source.id == sourceID })?.trashed != false }
    private var selectable: [KnowledgeEntitySnapshot] {
        SourceEntityLinksPresentation.eligibleEntities(choices, role: role)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            HStack {
                Text("Explicit links to existing knowledge entities.").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh linked entities").help("Refresh linked entities")
                    .accessibilityHint(error.map { "\($0) Activate to reload linked entities." } ?? "Reload linked entities.")
                    .focused($focusedControl, equals: .refresh)
                    .accessibilityFocused($accessibleControl, equals: .refresh)
                    .disabled(busy || model.isLocked || previewSnapshot != nil)
            }
            if busy { ProgressView().controlSize(.small) }
            if !model.isLocked, let error { Text(error).font(NoemaTypography.metadata).foregroundStyle(.secondary) }
            if let snapshot = displayed {
                if let source = snapshot.sources.first(where: { $0.source.id == sourceID }) {
                    Text(SourceEntityLinksPresentation.sourceStatus(source, availability: model.sourceAvailability[sourceID]))
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                if snapshot.associations.isEmpty { Text("No linked entities on this page.").font(NoemaTypography.metadata).foregroundStyle(.secondary) }
                ForEach(snapshot.associations, id: \.association.id) { association in
                    associationRow(association, snapshot: snapshot)
                }
                HStack {
                    Button("Previous") { offset = max(0, snapshot.offset - SourceEntityLinksSnapshot.pageSize); Task { await reload() } }
                        .accessibilityLabel("Previous linked entities page").disabled(busy || snapshot.offset == 0 || previewSnapshot != nil)
                    Text("Page \(snapshot.offset / SourceEntityLinksSnapshot.pageSize + 1)").font(.caption).foregroundStyle(.secondary)
                    Button("Next") { offset = snapshot.offset + SourceEntityLinksSnapshot.pageSize; Task { await reload() } }
                        .accessibilityLabel("Next linked entities page").disabled(busy || !snapshot.hasNextPage || previewSnapshot != nil)
                }
                DisclosureGroup("Link existing entity", isExpanded: $adding) {
                    linkEditor.disabled(!editable || sourceTrashed)
                }
                .disabled(sourceTrashed || busy)
                if sourceTrashed { Text("Restore this Source before adding links. Existing links are preserved.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task { active = true; if previewSnapshot == nil { await reload(restoringFocus: false) } }
        .onChange(of: searchIdentity) { restartSearch() }
        .onChange(of: adding) { if adding { restoreFocus(.search, token: request) } }
        .onChange(of: identity) { invalidate(); offset = 0; if previewSnapshot == nil { Task { await reload(restoringFocus: false) } } }
        .onDisappear { active = false; invalidate() }
        .sheet(isPresented: Binding(get: { relatedEntityID != nil && displayed != nil }, set: { if !$0 { relatedEntityID = nil } }), onDismiss: {
            if let id = inspectedAssociationID { restoreFocus(.entity(id), token: request) }
            inspectedAssociationID = nil
        }) {
            if let relatedEntityID, displayed != nil { AnyView(EntityPropertiesDetail(model: model, entityID: relatedEntityID)) }
        }
        .confirmationDialog("Unlink this entity from the Source?", isPresented: Binding(get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }), titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                if let association = pendingUnlink, let snapshot = displayed {
                    scheduleRemoval(association, snapshot: snapshot)
                }
                pendingUnlink = nil
            }
            Button("Cancel", role: .cancel) {
                if let edge = pendingUnlink { restoreFocus(.associationRemoval(edge.association.id), token: request) }
                pendingUnlink = nil
            }
        } message: { Text("The Source, its original file and the knowledge entity are preserved.") }
    }

    private func associationRow(_ snapshot: SourceEntityAssociationSnapshot, snapshot collection: SourceEntityLinksSnapshot) -> some View {
        let entity = collection.entities.first { $0.entity.id == snapshot.association.entityID }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let entity {
                    Button(entity.entity.label) {
                        inspectedAssociationID = snapshot.association.id
                        focusedControl = .entity(snapshot.association.id)
                        relatedEntityID = entity.entity.id
                    }
                        .buttonStyle(.link).accessibilityLabel("Inspect \(entity.entity.label)")
                        .focused($focusedControl, equals: .entity(snapshot.association.id))
                        .accessibilityFocused($accessibleControl, equals: .entity(snapshot.association.id))
                    Text("\(KnowledgeTypePresentation.label(for: entity.entity.typeKey)) · \(entity.entity.id.uuidString.prefix(8))")
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                    if entity.entity.lifecycle != .live { Text("Deleted entity · link retained").font(.caption).foregroundStyle(.secondary) }
                } else { Text("Unavailable entity · \(snapshot.association.entityID.uuidString.prefix(8))").font(.caption) }
                Text(SourceEntityLinksPresentation.roleLabel(snapshot.association.role)).font(NoemaTypography.metadata)
            }
            Spacer(minLength: NoemaSpacing.xs)
            Button { pendingUnlink = snapshot } label: { Image(systemName: "minus.circle") }
                .accessibilityLabel("Unlink \(entity?.entity.label ?? "entity") · \(SourceEntityLinksPresentation.roleLabel(snapshot.association.role))")
                .help("Unlink entity").disabled(!editable)
                .focused($focusedControl, equals: .associationRemoval(snapshot.association.id))
                .accessibilityFocused($accessibleControl, equals: .associationRemoval(snapshot.association.id))
        }
    }

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            Picker("Association role", selection: $role) {
                ForEach(SourceEntityAssociationRole.allCases, id: \.self) { role in
                    Text(SourceEntityLinksPresentation.roleLabel(role)).tag(role)
                }
            }
            .accessibilityLabel("Source association role")
            .accessibilityHint("Represents Work links only Creative Works; About Entity can link any registered entity type.")
            .focused($focusedControl, equals: .role)
            .accessibilityFocused($accessibleControl, equals: .role)
            Text(role == .representsWork ? "This Source represents the selected Creative Work." : "This Source concerns the selected entity.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search existing entities", text: $query).accessibilityLabel("Search existing entities to link")
                .accessibilityHint("Type to find an existing entity; searching does not create a link.")
                .focused($focusedControl, equals: .search)
                .accessibilityFocused($accessibleControl, equals: .search)
            if searching { ProgressView().controlSize(.mini) }
            Picker("Existing entity", selection: $selectedEntityID) {
                Text("Choose entity").tag(nil as UUID?)
                ForEach(selectable, id: \.entity.id) { entity in
                    Text("\(entity.entity.label) · \(KnowledgeTypePresentation.label(for: entity.entity.typeKey)) · \(entity.entity.id.uuidString.prefix(8))").tag(entity.entity.id as UUID?)
                }
            }
            .accessibilityLabel("Existing entity to link")
            .accessibilityHint("Choose a search result, then activate Add link to save the association.")
            .focused($focusedControl, equals: .entityPicker)
            .accessibilityFocused($accessibleControl, equals: .entityPicker)
            Button("Add link") { scheduleLink() }
                .accessibilityLabel("Add explicit Source entity link")
                .focused($focusedControl, equals: .add)
                .accessibilityFocused($accessibleControl, equals: .add)
                .disabled(selectedEntityID == nil || searching)
        }
        .padding(.top, NoemaSpacing.xs)
    }

    private func invalidate() {
        request = UUID(); searchRequest = UUID(); snapshot = nil; choices = []; selectedEntityID = nil
        pendingUnlink = nil; relatedEntityID = nil; inspectedAssociationID = nil; adding = false; query = ""; role = .aboutEntity
        busy = false; searching = false; error = nil
        focusedControl = nil; accessibleControl = nil
    }

    private func current(_ token: UUID, source: UUID, session: UUID?) -> Bool {
        active && !Task.isCancelled && request == token && sourceID == source && model.sessionState.sessionID == session && !model.isLocked
    }

    private func restoreFocus(_ target: FocusTarget, token: UUID) {
        let source = sourceID, session = model.sessionState.sessionID
        Task { @MainActor in
            await Task.yield()
            guard current(token, source: source, session: session), !busy else { return }
            switch target {
            case .associationRemoval(let id), .entity(let id):
                guard displayed?.associations.contains(where: { $0.association.id == id }) == true else { return }
            default: break
            }
            if target == .search && !adding { return }
            focusedControl = target; accessibleControl = target
        }
    }

    private func reload(restoringFocus: Bool = true) async {
        guard active, !model.isLocked, previewSnapshot == nil else { return }
        let page = offset
        invalidate()
        let token = request, source = sourceID, session = model.sessionState.sessionID
        busy = true
        do {
            let loaded = try await model.loadSourceEntityLinks(sourceID: source, offset: page)
            guard current(token, source: source, session: session), loaded.sessionID == session else { return }
            snapshot = loaded; busy = false
            if restoringFocus { restoreFocus(.refresh, token: token) }
        } catch {
            guard current(token, source: source, session: session) else { return }
            self.error = message(error); busy = false
            restoreFocus(.refresh, token: token)
        }
    }

    /// Clear the old selection and allocate its successor before launching work.
    /// The async entry check prevents a superseded queued task starting a search.
    private func restartSearch() {
        selectedEntityID = nil; choices = []; searchRequest = UUID(); searching = false
        guard previewSnapshot == nil, active, displayed != nil, !model.isLocked, adding else { return }
        let token = request, source = sourceID, session = model.sessionState.sessionID
        let searchID = searchRequest, text = query, selectedRole = role
        searching = true
        Task { await search(text: text, role: selectedRole, searchID: searchID, token: token, source: source, session: session) }
    }

    private func search(text: String, role selectedRole: SourceEntityAssociationRole, searchID: UUID, token: UUID, source: UUID, session: UUID?) async {
        guard current(token, source: source, session: session), searchRequest == searchID,
              query == text, role == selectedRole, adding else { return }
        do {
            let results = try await model.searchEntityPropertyTargets(query: text)
            guard current(token, source: source, session: session), searchRequest == searchID, query == text, role == selectedRole, adding else { return }
            choices = results; searching = false
        } catch {
            guard current(token, source: source, session: session), searchRequest == searchID,
                  query == text, role == selectedRole, adding else { return }
            self.error = message(error); searching = false
        }
    }

    /// Capture the asserted endpoints and role in the native button event, before
    /// a queued task can encounter another selection, draft or vault session.
    private func scheduleLink() {
        guard editable, !sourceTrashed, let snapshot = displayed,
              let entity = selectable.first(where: { $0.entity.id == selectedEntityID }) else { return }
        let token = request, source = sourceID, session = model.sessionState.sessionID, selectedRole = role
        busy = true; error = nil
        Task { await link(source: source, entity: entity, role: selectedRole, snapshot: snapshot, token: token, session: session) }
    }

    private func link(source: UUID, entity: KnowledgeEntitySnapshot, role: SourceEntityAssociationRole,
                      snapshot: SourceEntityLinksSnapshot, token: UUID, session: UUID?) async {
        guard current(token, source: source, session: session), snapshot.sessionID == session,
              snapshot.sources.contains(where: { $0.source.id == source && !$0.trashed }) else { return }
        guard model.canEditSemanticTarget else { busy = false; return }
        do {
            try await model.linkSourceEntity(sourceID: source, entity: entity, role: role, snapshot: snapshot,
                isCurrent: { current(token, source: source, session: session) })
            guard current(token, source: source, session: session) else { return }
            offset = 0; await reload()
        } catch {
            guard current(token, source: source, session: session) else { return }
            self.error = message(error); busy = false
            restoreFocus(.refresh, token: token)
        }
    }

    private func scheduleRemoval(_ association: SourceEntityAssociationSnapshot, snapshot: SourceEntityLinksSnapshot) {
        guard editable, association.association.sourceID == sourceID,
              displayed?.sessionID == snapshot.sessionID else { return }
        let token = request, source = sourceID, session = model.sessionState.sessionID
        busy = true; error = nil
        Task { await removeAssociation(association, snapshot: snapshot, token: token, source: source, session: session) }
    }

    private func removeAssociation(_ association: SourceEntityAssociationSnapshot, snapshot: SourceEntityLinksSnapshot,
                                   token: UUID, source: UUID, session: UUID?) async {
        guard current(token, source: source, session: session), snapshot.sessionID == session,
              association.association.sourceID == source else { return }
        guard model.canEditSemanticTarget else { busy = false; return }
        do {
            try await model.unlinkSourceEntity(association, snapshot: snapshot,
                isCurrent: { current(token, source: source, session: session) })
            guard current(token, source: source, session: session) else { return }
            offset = 0; await reload()
        } catch {
            guard current(token, source: source, session: session) else { return }
            self.error = message(error); busy = false
            restoreFocus(.refresh, token: token)
        }
    }

    private func message(_ error: Error) -> String {
        if case KnowledgeStoreError.transitionRequired = error {
            return "Source links require an explicit vault upgrade. Existing Source data is preserved."
        }
        return error.localizedDescription
    }
}
