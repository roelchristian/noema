import SwiftUI
import VaultCore

/// Sources mounts only while its library is visible. Cached metadata and sort order live in
/// ContentView's presentation object; cell status state is discarded with this view.
struct SourcesLibraryView: View {
    let model: AppModel
    let presentation: SourcesTablePresentation
    @Binding var selection: UUID?
    let rename: (SourceRecord) -> Void
    let delete: (SourceRecord) -> Void
    @State private var statuses = SourcesStatusPresentation()

    var body: some View {
        SourcesNativeTable(model: model, presentation: presentation, statuses: statuses,
                           selection: $selection, rename: rename, delete: delete)
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
/// neither the table nor unrelated cells subscribe to those collections.
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

/// AppModel is an action target here. Table evaluation reads only cached metadata; processing
/// properties are observed by the two individual cell components below.
private struct SourcesNativeTable: View {
    let model: AppModel
    let presentation: SourcesTablePresentation
    let statuses: SourcesStatusPresentation
    @Binding var selection: UUID?
    let rename: (SourceRecord) -> Void
    let delete: (SourceRecord) -> Void

    var body: some View {
        Table(presentation.rows, selection: $selection,
              sortOrder: Binding(get: { presentation.sortOrder }, set: { presentation.setSortOrder($0) })) {
            TableColumn("File Name", value: \.title) { row in
                SourceTitleCell(row: row, status: statuses.status(for: row.id))
            }.width(min: 160, ideal: 220)
            TableColumn("Original File Name", value: \.originalFilename) { row in
                Text(row.originalFilename).lineLimit(1).help(row.originalFilename)
            }.width(min: 100, ideal: 150)
            TableColumn("Location", value: \.sourceLocation) { row in
                Label(row.sourceLocation, systemImage: row.sourceLocation == "Linked" ? "link" : "tray.full")
                    .help(row.sourceLocation == "Linked" ? "Read-only linked original" : "Original stored in vault")
            }.width(min: 85, ideal: 95)
            TableColumn("Availability") { row in
                SourceAvailabilityCell(status: statuses.status(for: row.id))
            }.width(min: 150, ideal: 180)
            TableColumn("Kind", value: \.fileKind)
                .width(min: 80, ideal: 90)
            TableColumn("Size", value: \.fileSize) { row in
                Text(row.formattedFileSize)
            }.width(min: 70, ideal: 90)
            TableColumn("Captured", value: \.captureSortDate) { row in
                if let date = row.updatedAt {
                    Text(date, format: .dateTime.month(.abbreviated).day().year())
                        .lineLimit(1).help(row.captureHelp)
                } else { Text("—") }
            }.width(min: 100, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first {
                SourceTableContextMenu(model: model, sourceID: id, rename: rename, delete: delete)
            }
        } primaryAction: { ids in
            if let id = ids.first { model.openSource(id) }
        }
        .accessibilityLabel("Sources table")
    }
}

private struct SourceTitleCell: View {
    let row: SourceTableRow
    let status: SourceRowStatus
    var body: some View {
        switch status.titleState {
        case .downloading:
            SourceProgressLabel(title: "Downloading from iCloud")
        case .generating:
            SourceProgressLabel(title: "Generating title")
        case .ready:
            Label(row.title, systemImage: "doc.text").lineLimit(1).help(row.title)
        }
    }
}

private struct SourceAvailabilityCell: View {
    let status: SourceRowStatus
    var body: some View {
        switch status.availabilityState {
        case .downloading:
            SourceProgressLabel(title: "Downloading from iCloud")
        case .checking:
            SourceProgressLabel(title: "Checking availability…")
        case .available(let label):
            Text(label).lineLimit(1).help(label)
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
/// avoiding retained source bodies in table presentation state.
private struct SourceTableContextMenu: View {
    let model: AppModel
    let sourceID: UUID
    let rename: (SourceRecord) -> Void
    let delete: (SourceRecord) -> Void
    var body: some View {
        if let source = model.sources.first(where: { $0.id == sourceID }) {
            Button("Open Preview") { model.openSource(sourceID) }
                .disabled(model.downloadingSources.contains(sourceID))
            Button { model.createPageFromSource(source) } label: {
                Label(model.generatingSourcePages.contains(sourceID) ? "Creating Page…" : "Create Page with AI", systemImage: "sparkles")
            }
            .disabled(model.downloadingSources.contains(sourceID) || model.generatingSourcePages.contains(sourceID)
                      || model.generatingSourceTitles.contains(sourceID) || model.generatingSourceSummaries.contains(sourceID))
            Button(source.metadata.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                   ? "Regenerate AI Summary" : "Generate AI Summary") {
                model.generateSourceSummary(source)
            }
            .disabled(model.downloadingSources.contains(sourceID) || model.generatingSourceTitles.contains(sourceID)
                      || model.generatingSourceSummaries.contains(sourceID))
            Button("Check Availability") { model.checkSourceAvailability([source]) }
                .disabled(model.checkingSourceAvailability.contains(sourceID) || model.downloadingSources.contains(sourceID))
            Button { rename(source) } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { delete(source) } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
