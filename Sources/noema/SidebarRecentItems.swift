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

/// Session presentation order; persisted history remains most-recent-first.
struct SidebarRecentPresentation: Equatable {
    private(set) var ids: [RecentItemID] = []

    mutating func reconcile(_ recentIDs: [RecentItemID]) {
        let members = Set(recentIDs)
        ids.removeAll { !members.contains($0) }
        var seen = Set(ids)
        ids.append(contentsOf: recentIDs.filter { seen.insert($0).inserted })
    }
}

struct SidebarRecentItem: Identifiable, Equatable {
    var id: RecentItemID
    var title: String
    var symbol: String
    var accessibilityLabel: String
    var pageID: UUID?
}
