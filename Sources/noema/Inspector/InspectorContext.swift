import Foundation
import VaultCore

/// Typed tab destinations for the contextual right inspector.
enum InspectorTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case links
    case references
    case tags
    case properties
    case insights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .links: "Links"
        case .references: "References"
        case .tags: "Tags"
        case .properties: "Properties"
        case .insights: "Insights"
        }
    }

    var symbol: String {
        switch self {
        case .links: "link"
        case .references: "books.vertical"
        case .tags: "tag"
        case .properties: "slider.horizontal.3"
        case .insights: "sparkles"
        }
    }

    static let pageTabs: [InspectorTab] = [.links, .references, .tags, .properties, .insights]
    static let sourceTabs: [InspectorTab] = [.references, .properties, .insights]

    static func applicableTabs(for kind: InspectorTargetKind) -> [InspectorTab] {
        switch kind {
        case .page: pageTabs
        case .source: sourceTabs
        }
    }
}

/// Identifies the kind of document or item currently inspected in the right sidebar.
enum InspectorTargetKind: String, Hashable, Sendable {
    case page
    case source
}

/// Represents the active contextual target of the right inspector, or `.none` when no item is inspectable.
enum InspectorContext: Equatable, Sendable {
    case none
    case page(NoteRecord)
    case source(SourceRecord, isDetail: Bool)

    var targetKind: InspectorTargetKind? {
        switch self {
        case .none: nil
        case .page: .page
        case .source: .source
        }
    }

    var targetID: UUID? {
        switch self {
        case .none: nil
        case .page(let note): note.id
        case .source(let source, _): source.id
        }
    }

    var applicableTabs: [InspectorTab] {
        guard let kind = targetKind else { return [] }
        return InspectorTab.applicableTabs(for: kind)
    }

    var isInspectable: Bool {
        self != .none
    }

    @MainActor
    static func resolve(
        model: AppModel,
        librarySourceSelection: UUID?
    ) -> InspectorContext {
        guard model.isVaultAvailable, !model.isLocked else {
            return .none
        }
        if let note = model.currentNote {
            return .page(note)
        }
        if let source = model.currentSource {
            return .source(source, isDetail: true)
        }
        if !model.isSearching,
           model.scope == .sources,
           let selectedID = librarySourceSelection,
           let source = model.sources.first(where: { $0.id == selectedID }) {
            return .source(source, isDetail: false)
        }
        return .none
    }
}
