import Foundation
import Synchronization

/// Repository-owned, session-scoped memory only. Retirement is terminal so an admitted
/// operation finishing during lock cannot repopulate the cache after invalidation.
final class SourceSnapshotCache: Sendable {
    struct Entry: Sendable {
        let metadataBytes: Data
        let token: VaultContentChangeToken
        let record: SourceRecord
        let contentRevision: String
    }
    private struct State: Sendable {
        var retired = false
        var entries: [UUID: Entry] = [:]
    }
    private let state = Mutex(State())
    func entry(_ id: UUID) -> Entry? { state.withLock { $0.entries[id] } }
    func insert(_ entry: Entry, id: UUID) {
        state.withLock { if !$0.retired { $0.entries[id] = entry } }
    }
    func remove(_ id: UUID) { _ = state.withLock { $0.entries.removeValue(forKey: id) } }
    func retain(_ ids: Set<UUID>) { state.withLock { $0.entries = $0.entries.filter { ids.contains($0.key) } } }
    func clear() { state.withLock { $0.entries.removeAll() } }
    func retire() { state.withLock { $0.retired = true; $0.entries.removeAll() } }
    var count: Int { state.withLock { $0.entries.count } }
}
