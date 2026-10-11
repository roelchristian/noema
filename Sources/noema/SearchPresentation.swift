import Foundation
import VaultCore

enum VaultSearchMode: Equatable, Sendable {
    case vault, quickOpen
}

enum VaultSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, pages, sources, blocks
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .pages: "Pages"
        case .sources: "Sources"
        case .blocks: "Semantic Blocks"
        }
    }
}

enum VaultSearchStatus: Equatable, Sendable {
    case idle, searching, results, failed(String)
}

extension SidebarSearchResults {
    var totalCount: Int { pages.count + sources.count + blocks.count }

    func filtered(to scope: VaultSearchScope) -> Self {
        var result = self
        if scope != .all && scope != .pages { result.pages = []; result.pageExcerpts = [:] }
        if scope != .all && scope != .sources { result.sources = []; result.sourceExcerpts = [:] }
        if scope != .all && scope != .blocks { result.blocks = [] }
        return result
    }

    /// Quick Open only reads titles and aliases from the loaded catalog. Body-only
    /// matches belong to vault search and source originals are never loaded here.
    static func quickOpen(_ query: String, notes: [NoteRecord], sources: [SourceRecord]) -> Self {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let pages = notes.filter { note in
            let titles = ([note.title] + note.aliases).joined(separator: " ")
            return terms.allSatisfy { titles.localizedCaseInsensitiveContains($0) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let sources = sources.filter { source in
            terms.allSatisfy { source.title.localizedCaseInsensitiveContains($0) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Self(query: query, pages: pages, sources: sources)
    }
}
