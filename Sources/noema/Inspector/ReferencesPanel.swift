import SwiftUI
import VaultCore

/// Presentation model for a source linked to a wiki page.
struct LinkedSourceItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let isAvailable: Bool
    let canOpen: Bool
    let canRemove: Bool
}

/// Presentation model for a wiki page referring to a source.
struct ReferringPageItem: Identifiable, Equatable, Sendable {
    let note: NoteRecord
    let canOpen: Bool
    let canRemove: Bool

    var id: UUID { note.id }
    var title: String { note.title }
}

/// Pure presentation model for the References inspector panel (UI.R5).
/// Evaluates linked sources, referring pages, unavailable records, editing locks, and concurrent mutation guards.
struct ReferencesPanelModel: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case page(
            noteID: UUID,
            linkedSources: [LinkedSourceItem],
            availableSourcesToAdd: [SourceRecord],
            canEdit: Bool
        )
        case source(
            source: SourceRecord,
            referringPages: [ReferringPageItem],
            availablePagesToAdd: [NoteRecord],
            canPresentAddMenu: Bool,
            canCreatePageWithAI: Bool,
            isCreatingPageWithAI: Bool
        )
    }

    let mode: Mode

    static func forPage(
        note: NoteRecord,
        sources: [SourceRecord],
        editorReadOnly: Bool,
        updatingSourceReferences: Bool
    ) -> ReferencesPanelModel {
        let canEdit = !note.isEditingLocked && !editorReadOnly && !updatingSourceReferences
        let linked: [LinkedSourceItem] = note.linkedSourceIDs.map { id in
            if let source = sources.first(where: { $0.id == id }) {
                return LinkedSourceItem(
                    id: id,
                    title: source.title,
                    isAvailable: true,
                    canOpen: true,
                    canRemove: canEdit
                )
            } else {
                return LinkedSourceItem(
                    id: id,
                    title: "Unavailable source",
                    isAvailable: false,
                    canOpen: false,
                    canRemove: canEdit
                )
            }
        }
        let availableToAdd = sources.filter { !note.linkedSourceIDs.contains($0.id) }
        return ReferencesPanelModel(
            mode: .page(
                noteID: note.id,
                linkedSources: linked,
                availableSourcesToAdd: availableToAdd,
                canEdit: canEdit
            )
        )
    }

    static func forSource(
        source: SourceRecord,
        notes: [NoteRecord],
        updatingSourceReferences: Bool,
        downloadingSources: Set<UUID>,
        generatingSourcePages: Set<UUID>,
        generatingSourceTitles: Set<UUID>,
        generatingSourceSummaries: Set<UUID>
    ) -> ReferencesPanelModel {
        let referring = notes
            .filter { $0.linkedSourceIDs.contains(source.id) }
            .map { note in
                ReferringPageItem(
                    note: note,
                    canOpen: true,
                    canRemove: !note.isEditingLocked && !updatingSourceReferences
                )
            }
        let availableToAdd = notes.filter {
            !$0.isEditingLocked && !$0.linkedSourceIDs.contains(source.id)
        }
        let isCreatingPage = generatingSourcePages.contains(source.id)
        let canCreateWithAI = !downloadingSources.contains(source.id)
            && !isCreatingPage
            && !generatingSourceTitles.contains(source.id)
            && !generatingSourceSummaries.contains(source.id)
        return ReferencesPanelModel(
            mode: .source(
                source: source,
                referringPages: referring,
                availablePagesToAdd: availableToAdd,
                canPresentAddMenu: !updatingSourceReferences,
                canCreatePageWithAI: canCreateWithAI,
                isCreatingPageWithAI: isCreatingPage
            )
        )
    }
}

/// Inspector panel presenting explicit page-to-source associations (UI.R5).
struct ReferencesPanel: View {
    @Bindable var model: AppModel
    let context: InspectorContext
    var scrollPosition: Binding<ScrollPosition>? = nil

    var body: some View {
        switch context {
        case .none:
            EmptyView()
        case .page(let note):
            pageReferencesView(note)
        case .source(let source, _):
            sourceReferencesView(source)
        }
    }

    private func pageReferencesView(_ note: NoteRecord) -> some View {
        let isCurrent = model.currentNote?.id == note.id
        let state = ReferencesPanelModel.forPage(
            note: note,
            sources: model.sources,
            editorReadOnly: isCurrent ? model.editorReadOnly : false,
            updatingSourceReferences: model.updatingSourceReferences
        )
        guard case .page(_, let linkedSources, let availableSourcesToAdd, let canEdit) = state.mode else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(spacing: 0) {
                InspectorPanelHeader(title: "References", count: linkedSources.count) {
                    Menu("Add") {
                        ForEach(availableSourcesToAdd) { source in
                            Button(source.title) {
                                model.setSourceReference(pageID: note.id, sourceID: source.id, linked: true)
                            }
                        }
                    }
                    .disabled(!canEdit || availableSourcesToAdd.isEmpty)
                    .help(
                        note.isEditingLocked
                            ? "Unlock editing to modify source associations"
                            : "Attach a source to this page"
                    )
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        InspectorSection(title: "Sources", count: linkedSources.count, showTopDivider: false) {
                            if linkedSources.isEmpty {
                                Text("No sources linked")
                                    .foregroundStyle(.secondary)
                                Text("Attach a reference from your source library.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(linkedSources) { item in
                                    SourceAssociationRow(
                                        title: item.title,
                                        openLabel: "Open source",
                                        canOpen: item.canOpen,
                                        canRemove: item.canRemove,
                                        open: { model.openSource(item.id) },
                                        remove: { model.setSourceReference(pageID: note.id, sourceID: item.id, linked: false) }
                                    )
                                    .id(note.id.uuidString + item.id.uuidString)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .modifier(OptionalScrollPositionModifier(position: scrollPosition))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("References panel")
        )
    }

    private func sourceReferencesView(_ source: SourceRecord) -> some View {
        let state = ReferencesPanelModel.forSource(
            source: source,
            notes: model.notes,
            updatingSourceReferences: model.updatingSourceReferences,
            downloadingSources: model.downloadingSources,
            generatingSourcePages: model.generatingSourcePages,
            generatingSourceTitles: model.generatingSourceTitles,
            generatingSourceSummaries: model.generatingSourceSummaries
        )
        guard case .source(_, let referringPages, let availablePagesToAdd, let canPresentAddMenu, let canCreatePageWithAI, let isCreatingPageWithAI) = state.mode else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(spacing: 0) {
                InspectorPanelHeader(title: "References", count: referringPages.count) {
                    Menu("Add") {
                        Button {
                            model.createPageFromSource(source)
                        } label: {
                            Label(
                                isCreatingPageWithAI ? "Creating Page…" : "Create Page with AI",
                                systemImage: "sparkles"
                            )
                        }
                        .disabled(!canCreatePageWithAI)
                        Divider()
                        ForEach(availablePagesToAdd) { note in
                            Button(note.title) {
                                model.setSourceReference(pageID: note.id, sourceID: source.id, linked: true)
                            }
                        }
                    }
                    .disabled(!canPresentAddMenu)
                    .help("Reference this source from a page")
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        InspectorSection(title: "Referring pages", count: referringPages.count, showTopDivider: false) {
                            if isCreatingPageWithAI {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Creating page…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if referringPages.isEmpty {
                                Text("No pages reference this source.")
                                    .foregroundStyle(.secondary)
                                Text("Link an existing page or create a new page from this source.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(referringPages) { item in
                                    SourceAssociationRow(
                                        title: item.title,
                                        openLabel: "Open page",
                                        canOpen: item.canOpen,
                                        canRemove: item.canRemove,
                                        open: { model.select(item.id, scope: .wiki) },
                                        remove: { model.setSourceReference(pageID: item.id, sourceID: source.id, linked: false) }
                                    )
                                    .id(source.id.uuidString + item.id.uuidString)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .modifier(OptionalScrollPositionModifier(position: scrollPosition))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("References panel")
        )
    }
}
