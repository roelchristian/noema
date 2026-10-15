import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

enum SourceInboxSortOrder: String, CaseIterable, Identifiable {
    case captured = "Recently Captured"
    case title = "Title"
    var id: String { rawValue }

    var comparators: [KeyPathComparator<SourceTableRow>] {
        switch self {
        case .captured:
            [KeyPathComparator(\SourceTableRow.captureSortDate, order: .reverse),
             KeyPathComparator(\SourceTableRow.title, comparator: .localizedStandard)]
        case .title:
            [KeyPathComparator(\SourceTableRow.title, comparator: .localizedStandard)]
        }
    }
}

/// The metadata that affects list display. No source content, summaries, or bookmark data is retained.
struct SourceTableInput: Identifiable, Equatable {
    let id: UUID
    let title: String
    let capturedAt: String
    let originalFilename: String
    let fileSize: Int
    let isLinked: Bool

    init(metadata: SourceMetadata, fallbackFileSize: Int = 0) {
        id = metadata.id
        title = metadata.title
        capturedAt = metadata.capturedAt
        originalFilename = metadata.originalFilename
        fileSize = metadata.fileSize ?? fallbackFileSize
        isLinked = metadata.isLinked
    }

    init(source: SourceRecord) {
        // Older sources may lack a persisted file size. Counting bytes preserves their existing display
        // without interpreting the content; the fallback is evaluated only when size is absent.
        self.init(metadata: source.metadata, fallbackFileSize: source.metadata.fileSize ?? source.body.utf8.count)
    }
}

/// Ready-to-display list values. Equality never compares source bodies or excerpts.
struct SourceTableRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let originalFilename: String
    let sourceLocation: String
    let fileKind: String
    let compactFileKind: String
    let fileSize: Int
    let formattedFileSize: String
    let updatedAt: Date?
    let captureHelp: String
    var captureSortDate: Date { updatedAt ?? .distantPast }

    init(input: SourceTableInput) {
        id = input.id
        title = input.title
        originalFilename = input.originalFilename
        sourceLocation = input.isLinked ? "Linked" : "In vault"
        let fileExtension = URL(fileURLWithPath: input.originalFilename).pathExtension.lowercased()
        fileKind = UTType(filenameExtension: fileExtension)?.localizedDescription ?? "File"
        switch fileExtension {
        case "txt": compactFileKind = "Text"
        case "md", "markdown": compactFileKind = "Markdown"
        case "": compactFileKind = "File"
        default: compactFileKind = fileExtension.uppercased()
        }
        fileSize = input.fileSize
        formattedFileSize = ByteCountFormatter.string(fromByteCount: Int64(input.fileSize), countStyle: .file)
        updatedAt = LibraryRow.date(input.capturedAt)
        captureHelp = updatedAt?.formatted(date: .long, time: .shortened) ?? ""
    }
}

/// Small, presentation-only state: retain unchanged rows and sort only when metadata or sorting changes.
/// Status indicators are owned separately so their updates cannot reconstruct or sort these rows.
@MainActor @Observable final class SourcesTablePresentation {
    private(set) var rows: [SourceTableRow] = []
    private(set) var sortOrder = [KeyPathComparator(\SourceTableRow.title)]
    private(set) var inboxSortOrder: SourceInboxSortOrder = .title
    var columnCustomization = TableColumnCustomization<SourceTableRow>()
    @ObservationIgnored private var inputs: [SourceTableInput] = []
    @ObservationIgnored private let rowBuilder: (SourceTableInput) -> SourceTableRow

    init(rowBuilder: @escaping (SourceTableInput) -> SourceTableRow = SourceTableRow.init(input:)) {
        self.rowBuilder = rowBuilder
    }

    @discardableResult
    func synchronize(_ sources: [SourceRecord]) -> Bool {
        synchronize(inputs: sources.map(SourceTableInput.init(source:)))
    }

    @discardableResult
    func synchronize(inputs newInputs: [SourceTableInput]) -> Bool {
        guard inputs != newInputs else { return false }
        let oldInputs = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let oldRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let nextRows = SourcesPerformance.measure("Source Row Construction") {
            newInputs.map { input in
                if oldInputs[input.id] == input, let row = oldRows[input.id] { return row }
                return rowBuilder(input)
            }
        }
        inputs = newInputs
        rows = SourcesPerformance.measure("Source Table Sort") { nextRows.sorted(using: sortOrder) }
        return true
    }

    func setInboxSortOrder(_ order: SourceInboxSortOrder) {
        inboxSortOrder = order
        setSortOrder(order.comparators)
    }

    @discardableResult
    func setSortOrder(_ newOrder: [KeyPathComparator<SourceTableRow>]) -> Bool {
        guard sortOrder != newOrder else { return false }
        sortOrder = newOrder
        rows = SourcesPerformance.measure("Source Table Sort") { rows.sorted(using: newOrder) }
        return true
    }

    /// Drop all sensitive metadata when the owning workspace is locked, closed, or replaced.
    /// Sorting and legacy column preferences contain no vault data and can survive sessions.
    func clear() {
        inputs = []
        if !rows.isEmpty { rows = [] }
    }
}
