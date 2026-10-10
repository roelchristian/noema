import Foundation
import SQLite3

public protocol SearchIndex: Sendable {
    func cachedEntries() async throws -> ScanBatch
    func reconcile(_ entries: ScanBatch) async throws
    func search(_ query: String, kind: EntryKind, tag: String?) async throws -> [SearchHit]
    func backlinks(to note: NoteRecord) async throws -> [UUID]
}

// The connection is confined to the index actor after initialization.
private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw VaultError.storage("Could not open the local search index.")
        }
        self.pointer = pointer
    }
    deinit { sqlite3_close(pointer) }
}

public actor SQLiteSearchIndex: SearchIndex {
    private let connection: SQLiteConnection
    private var revisions: [String: String] = [:]
    private let encoder: JSONEncoder = { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }()
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        connection = try SQLiteConnection(url: url)
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, kind TEXT NOT NULL, revision TEXT NOT NULL, record BLOB NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS fulltext USING fts5(id UNINDEXED, kind UNINDEXED, title, body, aliases, tokenize='unicode61');
        CREATE TABLE IF NOT EXISTS tags (id TEXT NOT NULL, tag TEXT NOT NULL, PRIMARY KEY(id, tag));
        CREATE INDEX IF NOT EXISTS tag_name ON tags(tag);
        CREATE TABLE IF NOT EXISTS links (id TEXT NOT NULL, target TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS link_target ON links(target);
        """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection.pointer, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(error); throw VaultError.storage(message)
        }
    }
    private var db: OpaquePointer { connection.pointer }
    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (i, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient) == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    private func failure() -> VaultError { .storage("Search index: " + String(cString: sqlite3_errmsg(db))) }
    private func run(_ sql: String, _ values: [String] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
    }
    private func text(_ s: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(s, column).map { String(cString: $0) } ?? ""
    }
    public func cachedEntries() throws -> ScanBatch {
        let s = try statement("SELECT id,kind,revision,record FROM entries"); defer { sqlite3_finalize(s) }
        var entries = ScanBatch()
        while sqlite3_step(s) == SQLITE_ROW {
            let data = Data(bytes: sqlite3_column_blob(s, 3)!, count: Int(sqlite3_column_bytes(s, 3)))
            if text(s, 1) == EntryKind.wiki.rawValue { entries.notes.append(try JSONDecoder().decode(NoteRecord.self, from: data)) }
            else { entries.sources.append(try JSONDecoder().decode(SourceRecord.self, from: data)) }
            revisions[text(s, 0)] = text(s, 2)
        }
        return entries
    }
    public func reconcile(_ entries: ScanBatch) throws {
        if revisions.isEmpty { _ = try cachedEntries() }
        var next = revisions
        try run("BEGIN IMMEDIATE")
        do {
            var present: Set<String> = []
            for note in entries.notes {
                let id = note.id.uuidString, revision = note.contentHash + note.relativePath
                present.insert(id)
                guard revisions[id] != revision else { continue }
                try remove(id)
                try insert(id: id, kind: .wiki, revision: revision, data: encoder.encode(note), title: note.title, body: note.body, aliases: note.aliases.joined(separator: " "))
                for tag in note.allTags { try run("INSERT INTO tags VALUES(?,?)", [id, tag]) }
                for link in MarkdownService.analyze(note.body).links { try run("INSERT INTO links VALUES(?,?)", [id, normalized(link.target)]) }
                next[id] = revision
            }
            for source in entries.sources {
                let id = source.id.uuidString, revision = digest(try encoder.encode(source.metadata))
                present.insert(id)
                guard revisions[id] != revision else { continue }
                try remove(id)
                try insert(id: id, kind: .source, revision: revision, data: encoder.encode(source), title: source.title, body: source.body, aliases: "")
                next[id] = revision
            }
            for id in Set(revisions.keys).subtracting(present) { try remove(id); next.removeValue(forKey: id) }
            try run("COMMIT"); revisions = next
        } catch { try? run("ROLLBACK"); throw error }
    }
    private func insert(id: String, kind: EntryKind, revision: String, data: Data, title: String, body: String, aliases: String) throws {
        let s = try statement("INSERT INTO entries VALUES(?,?,?,?)", [id, kind.rawValue, revision, String(decoding: data, as: UTF8.self)]); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
        try run("INSERT INTO fulltext(id,kind,title,body,aliases) VALUES(?,?,?,?,?)", [id, kind.rawValue, title, body, aliases])
    }
    private func remove(_ id: String) throws {
        for table in ["entries", "fulltext", "tags", "links"] { try run("DELETE FROM \(table) WHERE id=?", [id]) }
    }
    public func search(_ query: String, kind: EntryKind, tag: String? = nil) throws -> [SearchHit] {
        let words = query.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        var values = [kind.rawValue]
        var whereSQL = "fulltext.kind=?"
        if !words.isEmpty {
            whereSQL += " AND fulltext MATCH ?"
            values.append(words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND "))
        }
        if let tag { whereSQL += " AND fulltext.id IN (SELECT id FROM tags WHERE tag=?)"; values.append(normalized(tag)) }
        let excerpt = words.isEmpty ? "substr(body,1,160)" : "snippet(fulltext,3,'','',' … ',24)"
        let order = words.isEmpty ? "title COLLATE NOCASE" : "bm25(fulltext,0,0,5,1,2)"
        let s = try statement("SELECT id,kind,\(excerpt) FROM fulltext WHERE \(whereSQL) ORDER BY \(order)", values)
        defer { sqlite3_finalize(s) }
        var results: [SearchHit] = []
        var status = sqlite3_step(s)
        while status == SQLITE_ROW {
            if let id = UUID(uuidString: text(s, 0)), let kind = EntryKind(rawValue: text(s, 1)) { results.append(SearchHit(id: id, kind: kind, excerpt: text(s, 2))) }
            status = sqlite3_step(s)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return results
    }
    public func backlinks(to note: NoteRecord) throws -> [UUID] {
        let names = Array(Set(([note.title] + note.aliases).map(normalized)))
        let slots = Array(repeating: "?", count: names.count).joined(separator: ",")
        let s = try statement("SELECT DISTINCT id FROM links WHERE target IN (\(slots)) AND id != ?", names + [note.id.uuidString])
        defer { sqlite3_finalize(s) }
        var ids: [UUID] = []
        while sqlite3_step(s) == SQLITE_ROW { if let id = UUID(uuidString: text(s, 0)) { ids.append(id) } }
        return ids
    }
}
