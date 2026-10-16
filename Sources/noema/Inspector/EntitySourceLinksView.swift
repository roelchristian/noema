import SwiftUI
import VaultCore

/// Metadata-only source associations; original content loads only after Open Source.
struct EntitySourceLinksView: View {
    @Bindable var model: AppModel
    let entityID: UUID
    private let previewSnapshot: SourceEntityLinksSnapshot?
    @State private var snapshot: SourceEntityLinksSnapshot?
    @State private var request = UUID()
    @State private var requestedEntityID: UUID?
    @State private var requestedSessionID: UUID?
    @State private var active = false
    @State private var busy = false
    @State private var error: String?
    @State private var pendingUnlink: SourceEntityAssociationSnapshot?

    init(model: AppModel, entityID: UUID, previewSnapshot: SourceEntityLinksSnapshot? = nil) {
        self.model = model; self.entityID = entityID; self.previewSnapshot = previewSnapshot
        _snapshot = State(initialValue: previewSnapshot)
    }

    private var identity: String { "\(entityID):\(String(describing: model.sessionState.sessionID)):\(model.isLocked)" }
    private var editable: Bool { model.canEditSemanticTarget && !model.isLocked && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            HStack {
                Text("Sources").font(NoemaTypography.interfaceEmphasis)
                Spacer()
                Button { requestPage(snapshot?.offset ?? 0) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh sources associated with this entity")
                    .disabled(busy || model.isLocked || previewSnapshot != nil)
            }
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Loading associated sources") }
            if let error { Text(error).font(NoemaTypography.metadata).foregroundStyle(.secondary) }
            if let snapshot, !model.isLocked, snapshot.sessionID == model.sessionState.sessionID {
                if snapshot.associations.isEmpty {
                    Text(snapshot.offset == 0 ? "No sources associated. Link an existing entity from a Source's inspector." : "No more source associations on this page.")
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                ForEach(SourceEntityAssociationRole.allCases, id: \.self) { role in
                    let associations = snapshot.associations.filter { $0.association.role == role }
                    if !associations.isEmpty {
                        Text(SourceEntityLinksPresentation.roleLabel(role)).font(NoemaTypography.interfaceEmphasis)
                        ForEach(associations, id: \.association.id) { edge in sourceRow(edge, snapshot: snapshot) }
                    }
                }
                if snapshot.offset > 0 || snapshot.hasNextPage {
                    VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
                        if !snapshot.associations.isEmpty {
                            Text("Source associations \(snapshot.offset + 1)–\(snapshot.offset + snapshot.associations.count)")
                                .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Previous") { requestPage(max(0, snapshot.offset - SourceEntityLinksSnapshot.pageSize)) }
                                .accessibilityLabel("Previous page of associated sources").disabled(busy || snapshot.offset == 0)
                            Button("Next") { requestPage(snapshot.offset + SourceEntityLinksSnapshot.pageSize) }
                                .accessibilityLabel("Next page of associated sources").disabled(busy || !snapshot.hasNextPage)
                        }
                    }
                }
            }
        }
        .task {
            active = true
            if previewSnapshot == nil { requestPage(0) }
            else { requestedEntityID = entityID; requestedSessionID = model.sessionState.sessionID }
        }
        .onChange(of: identity) { invalidate(); if previewSnapshot == nil { requestPage(0) } }
        .onDisappear { active = false; invalidate() }
        .confirmationDialog("Unlink this Source from the entity?", isPresented: Binding(
            get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }), titleVisibility: .visible) {
            Button("Unlink Source", role: .destructive) {
                if let edge = pendingUnlink, let snapshot {
                    let token = request
                    Task { await unlink(edge, snapshot: snapshot, token: token) }
                }
                pendingUnlink = nil
            }
            Button("Cancel", role: .cancel) { pendingUnlink = nil }
        } message: {
            Text("The Source, its original and the entity's properties are preserved.")
        }
    }

    private func sourceRow(_ edge: SourceEntityAssociationSnapshot, snapshot: SourceEntityLinksSnapshot) -> some View {
        let source = snapshot.sources.first { $0.source.id == edge.association.sourceID }
        let title = source.map { SourceEntityLinksPresentation.sourceTitle($0) } ?? "Unavailable Source"
        let librarySource = model.sources.first { $0.id == edge.association.sourceID }
        let availability = model.sourceAvailability[edge.association.sourceID] ?? librarySource?.availabilityIssue
        let navigable = source?.trashed == false && librarySource != nil && !busy && !model.isLocked
        return VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
            Button(title) {
                let token = request
                model.openAssociatedSource(edge.association.sourceID, snapshot: snapshot, isCurrent: { current(token) })
            }
            .buttonStyle(.link)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Open Source \(title)")
            .disabled(!navigable)
            if let source {
                Text(SourceEntityLinksPresentation.sourceStatus(source, availability: availability))
                    .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Unlink") { pendingUnlink = edge }
                .accessibilityLabel("Unlink \(title), \(SourceEntityLinksPresentation.roleLabel(edge.association.role))")
                .disabled(!editable || source == nil || !snapshot.entities.contains { $0.entity.id == entityID })
        }
    }

    private func invalidate() {
        request = UUID(); requestedEntityID = nil; requestedSessionID = nil
        snapshot = nil; pendingUnlink = nil; error = nil; busy = false
    }

    private func current(_ token: UUID) -> Bool {
        active && !Task.isCancelled && request == token && requestedEntityID == entityID &&
            requestedSessionID == model.sessionState.sessionID && !model.isLocked
    }

    private func requestPage(_ offset: Int) {
        invalidate()
        guard active, !model.isLocked, previewSnapshot == nil else { return }
        let token = request, requestedEntity = entityID, sessionID = model.sessionState.sessionID
        requestedEntityID = requestedEntity; requestedSessionID = sessionID
        busy = true
        Task { @MainActor in
            do {
                let result = try await model.loadEntitySourceLinks(entityID: requestedEntity, offset: offset)
                guard current(token), entityID == requestedEntity, model.sessionState.sessionID == sessionID else { return }
                snapshot = result; busy = false
            } catch {
                guard current(token), entityID == requestedEntity, model.sessionState.sessionID == sessionID else { return }
                if case KnowledgeStoreError.transitionRequired = error {
                    self.error = "Source associations require an explicit vault upgrade. Existing Source and entity data are preserved."
                } else { self.error = error.localizedDescription }
                busy = false
            }
        }
    }

    private func unlink(_ edge: SourceEntityAssociationSnapshot, snapshot: SourceEntityLinksSnapshot, token: UUID) async {
        guard current(token), editable else { return }
        busy = true; error = nil
        do {
            try await model.unlinkSourceEntity(edge, snapshot: snapshot, isCurrent: { current(token) })
            guard current(token) else { return }
            requestPage(snapshot.offset)
        } catch {
            guard current(token) else { return }
            self.error = error.localizedDescription; busy = false
        }
    }
}
