import Foundation

/// The editable document is owned here; Markdown is an asynchronous export format.
@MainActor public final class EditorSession {
    public struct Identity: Equatable, Sendable {
        public var pageID: UUID?
        public var vaultID: UUID?
        public var sessionID: UUID?
        public init(pageID: UUID? = nil, vaultID: UUID? = nil, sessionID: UUID? = nil) { self.pageID = pageID; self.vaultID = vaultID; self.sessionID = sessionID }
    }
    public struct DocumentSnapshot: Sendable {
        public let identity: Identity
        public let generation: UUID
        public let revision: UInt64
        public let document: BlockDocument
        public let selection: NSRange
    }
    public struct Mutation: Sendable {
        public let revision: UInt64
        public let name: String
        public let changedBlockIDs: Set<UUID>
        public let selection: NSRange
    }
    public private(set) var document: BlockDocument
    public private(set) var identity: Identity
    public private(set) var revision: UInt64 = 0
    public private(set) var generation = UUID()
    public var selection = NSRange(location: 0, length: 0)
    public private(set) var changedBlockIDs = Set<UUID>()
    public private(set) var mutationHistory: [Mutation] = []
    public private(set) var publishedRevision: UInt64 = 0

    public init(document: BlockDocument = .init(), identity: Identity = .init()) {
        self.document = document; self.identity = identity
    }
    public func load(_ document: BlockDocument, identity: Identity, selection: NSRange) {
        self.document = document; self.identity = identity; self.selection = selection
        generation = UUID(); revision = 0; publishedRevision = 0
        changedBlockIDs.removeAll(); mutationHistory.removeAll()
    }
    public func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(identity: identity, generation: generation, revision: revision, document: document, selection: selection)
    }
    public func accepts(_ snapshot: DocumentSnapshot) -> Bool {
        snapshot.identity == identity && snapshot.generation == generation && snapshot.revision == revision && snapshot.revision > publishedRevision
    }
    @discardableResult public func markPublished(_ snapshot: DocumentSnapshot) -> Bool {
        guard accepts(snapshot) else { return false }
        publishedRevision = snapshot.revision; changedBlockIDs.removeAll(); return true
    }
    /// Used for native typing. Only the active block is inspected and mutated.
    public func updateRuns(_ id: UUID, runs: [RichRun], selection: NSRange, name: String = "Typing") {
        guard !document.unsupportedVersion, let block = document.block(id), block.runs != runs else { self.selection = selection; return }
        document.update(id) { $0.runs = runs }
        record(name, ids: [id], selection: selection)
    }
    public func replaceDocument(_ value: BlockDocument, selection: NSRange? = nil, name: String = "Edit blocks") {
        guard value != document else { return }
        let old = Dictionary(uniqueKeysWithValues: document.flattened.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: value.flattened.map { ($0.id, $0) })
        let ids = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
        document = value; record(name, ids: Set(ids), selection: selection ?? self.selection)
    }
    @discardableResult public func apply(_ mutation: BlockMutation, to id: UUID, name: String = "Edit block") -> BlockCursor? {
        guard !document.unsupportedVersion else { return nil }
        var value = document
        let cursor = value.apply(mutation, to: id)
        replaceDocument(value, name: name)
        return cursor
    }
    public func replaceText(_ id: UUID, range: NSRange, runs: [RichRun], selection: NSRange) {
        guard let block = document.block(id), range.location >= 0, range.length >= 0, NSMaxRange(range) <= block.utf16Count else { return }
        updateRuns(id, runs: block.slicing(NSRange(location: 0, length: range.location)) + runs + block.slicing(NSRange(location: NSMaxRange(range), length: block.utf16Count - NSMaxRange(range))), selection: selection, name: "Replace text")
    }
    public func restore(_ snapshot: DocumentSnapshot, name: String) {
        guard snapshot.identity == identity, snapshot.generation == generation else { return }
        replaceDocument(snapshot.document, selection: snapshot.selection, name: name)
        selection = snapshot.selection
    }
    private func record(_ name: String, ids: Set<UUID>, selection: NSRange) {
        revision &+= 1; self.selection = selection; changedBlockIDs.formUnion(ids)
        mutationHistory.append(Mutation(revision: revision, name: name, changedBlockIDs: ids, selection: selection))
        // Native NSUndoManager owns undo payloads; this bounded journal describes revisions.
        if mutationHistory.count > 256 { mutationHistory.removeFirst(mutationHistory.count - 256) }
    }
}
