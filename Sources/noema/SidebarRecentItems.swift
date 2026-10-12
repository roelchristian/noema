import Foundation
import VaultCore

enum RecentItemID: Hashable, Codable, Sendable {
    case page(UUID)
    case source(UUID)
    case semanticBlock(pageID: UUID, blockID: UUID)
}

struct SidebarRecentHistory: Equatable, Codable, Sendable {
    static let limit = 10
    private(set) var ids: [RecentItemID]

    init(ids: [RecentItemID] = []) {
        var seen: Set<RecentItemID> = []
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(Self.limit))
    }

    mutating func record(_ id: RecentItemID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        ids = Array(ids.prefix(Self.limit))
    }

    mutating func prune(keeping valid: Set<RecentItemID>) {
        ids.removeAll { !valid.contains($0) }
    }
}

struct SidebarRecentItem: Identifiable, Equatable {
    var id: RecentItemID
    var title: String
    var symbol: String
    var accessibilityLabel: String
    var pageID: UUID?
}
