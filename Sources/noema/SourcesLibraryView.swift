import SwiftUI
import AppKit
import VaultCore

/// Sources mounts only while its library is visible. Cached metadata and sort order live in
/// ContentView's presentation object; cell status state is discarded with this view.
struct SourcesLibraryView: View {
    let model: AppModel
    let presentation: SourcesTablePresentation
    @Binding var selection: UUID?
    var scrollPosition: Binding<ScrollPosition>? = nil
    var listFocus: FocusState<Bool>.Binding? = nil
    let rename: (SourceRecord) -> Void
    let delete: (SourceRecord) -> Void
    @State private var statuses = SourcesStatusPresentation()

    var body: some View {
        SourcesInboxList(model: model, presentation: presentation, statuses: statuses,
                         selection: $selection, scrollPosition: scrollPosition, listFocus: listFocus, rename: rename, delete: delete)
            .background {
                SourceMetadataBridge(model: model, presentation: presentation)
                SourceStatusBridge(model: model, presentation: statuses)
            }
            .onAppear { SourcesPerformance.event("SourcesTableAppear") }
            .onDisappear {
                statuses.clear()
                SourcesPerformance.event("SourcesTableDisappear")
            }
            .onChange(of: selection) { SourcesPerformance.event("SourceSelection") }
    }
}

/// Observe metadata separately from processing state. Comparing inputs never compares source bodies.
private struct SourceMetadataBridge: View {
    let model: AppModel
    let presentation: SourcesTablePresentation
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: model.sources.map(SourceTableInput.init(source:)), initial: true) { _, inputs in
                presentation.synchronize(inputs: inputs)
            }
    }
}

/// Only this bridge reads whole status collections. It updates observable cells for changed IDs;
/// neither the list nor unrelated cells subscribe to those collections.
private struct SourceStatusBridge: View {
    let model: AppModel
    let presentation: SourcesStatusPresentation
    private var snapshot: SourcesStatusSnapshot {
        SourcesStatusSnapshot(
            sourceIDs: Set(model.sources.map(\.id)),
            issues: Dictionary(model.sources.compactMap { source in
                source.availabilityIssue.map { (source.id, $0) }
            }, uniquingKeysWith: { first, _ in first }),
            downloading: model.downloadingSources,
            generatingTitles: model.generatingSourceTitles,
            checking: model.checkingSourceAvailability,
            availability: model.sourceAvailability
        )
    }
    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onChange(of: snapshot, initial: true) { _, snapshot in
                presentation.synchronize(snapshot)
            }
    }
}

/// AppModel is an action target here. List evaluation reads only cached metadata; processing
/// properties are observed by the independent status component below.
private struct SourcesInboxList: View {
    let model: AppModel
    let presentation: SourcesTablePresentation
    let statuses: SourcesStatusPresentation
    @Binding var selection: UUID?
    @State private var dragSelection: Set<UUID> = []
    var scrollPosition: Binding<ScrollPosition>? = nil
    var listFocus: FocusState<Bool>.Binding? = nil
    let rename: (SourceRecord) -> Void
    let delete: (SourceRecord) -> Void

    var body: some View {
        List(selection: Binding(get: { dragSelection }, set: { ids in
            dragSelection = ids
            if ids.count == 1, !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) {
                selection = ids.first
            } else if ids.isEmpty { selection = nil }
        })) {
            ForEach(presentation.rows) { row in
                SourceInboxRow(row: row, status: statuses.status(for: row.id))
                    .tag(row.id)
                    .draggable(model.organisationDragBatch(presentation.rows.filter {
                        dragSelection.contains(row.id) ? dragSelection.contains($0.id) : $0.id == row.id
                    }.map { OrganisationDrag.item(.init(kind: .source, itemID: $0.id)) }))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if presentation.rows.isEmpty {
                ContentUnavailableView("Sources is empty", systemImage: "tray",
                                       description: Text("Import a file or paste a source to begin."))
                    .allowsHitTesting(false)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first {
                SourceTableContextMenu(model: model, sourceID: id, rename: rename, delete: delete)
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { model.openSource(id) }
        }
        .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        .modifier(CollectionListFocusModifier(focus: listFocus))
        .onAppear { dragSelection = Set(selection.map { [$0] } ?? []) }
        .onChange(of: selection) {
            if let selection, !dragSelection.contains(selection) {
                dragSelection = [selection]
            } else if selection == nil { dragSelection = [] }
        }
        .onChange(of: model.sessionState.sessionID) { dragSelection = [] }
        .onChange(of: presentation.rows.map(\.id)) { dragSelection.formIntersection(Set(presentation.rows.map(\.id))) }
        .accessibilityLabel("Sources list")
    }
}

private struct CollectionListFocusModifier: ViewModifier {
    let focus: FocusState<Bool>.Binding?
    func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}

/// Metadata stays visible during processing; only this row's status label observes status changes.
private struct SourceInboxRow: View {
    let row: SourceTableRow
    let status: SourceRowStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(NoemaTypography.interfaceEmphasis)
                    .lineLimit(1)
                    .help(row.title)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let date = row.updatedAt {
                    Text(date, format: Calendar.current.isDateInToday(date)
                         ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                        .font(NoemaTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(row.captureHelp)
                        .accessibilityLabel("Captured \(row.captureHelp)")
                }
            }
            Text("\(row.compactFileKind) · \(row.sourceLocation) · \(row.formattedFileSize)")
                .font(NoemaTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("\(row.originalFilename) · \(row.fileKind) · \(row.sourceLocation) · \(row.formattedFileSize)")
            SourceInboxStatus(status: status)
                .font(NoemaTypography.metadata)
        }
        .padding(.horizontal, NoemaSpacing.sm)
        .padding(.vertical, 4)
    }
}

private struct SourceInboxStatus: View {
    let status: SourceRowStatus
    var body: some View {
        if status.titleState == .downloading {
            SourceProgressLabel(title: "Downloading from iCloud")
        } else if status.titleState == .generating {
            SourceProgressLabel(title: "Generating title")
        } else {
            switch status.availabilityState {
            case .downloading:
                SourceProgressLabel(title: "Downloading from iCloud")
            case .checking:
                SourceProgressLabel(title: "Checking availability…")
            case .available(let label):
                if label != "Available" {
                    Text(label).foregroundStyle(.secondary).lineLimit(1).help(label)
                }
            }
        }
    }
}

private struct SourceProgressLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(title).foregroundStyle(.secondary)
        }
    }
}

/// Resolve the current record when presenting the menu, preserving existing action gates and
/// avoiding retained source bodies in list presentation state.
private struct SourceTableContextMenu: View {
    let model: AppModel
    let sourceID: UUID
    let rename: (SourceRecord) -> Void
    let delete: (SourceRecord) -> Void
    var body: some View {
        if let source = model.sources.first(where: { $0.id == sourceID }) {
            AISummaryMenuCommands(model: model, target: .source(sourceID))
            Button("Open Preview") { model.openSource(sourceID) }
                .disabled(model.downloadingSources.contains(sourceID))
            Button { model.createPageFromSource(source) } label: {
                Label(model.generatingSourcePages.contains(sourceID) ? "Creating Page…" : "Create Page with AI · \(aiProviderLabel(model.preferredAIProvider(for: .composePage)))", systemImage: "sparkles")
            }
            .disabled(model.downloadingSources.contains(sourceID) || model.generatingSourcePages.contains(sourceID)
                      || model.generatingSourceTitles.contains(sourceID) || model.generatingSourceSummaries.contains(sourceID))
            Button("Suggest Title · \(model.preferredAIProvider(for: .suggestTitle).displayName)") { model.suggestSourceTitle(source) }
                .disabled(model.downloadingSources.contains(sourceID) || model.generatingSourceTitles.contains(sourceID))
            Button("Check Availability") { model.checkSourceAvailability([source]) }
                .disabled(model.checkingSourceAvailability.contains(sourceID) || model.downloadingSources.contains(sourceID))
            Button { rename(source) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { delete(source) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
