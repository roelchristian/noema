import Foundation
import SQLite3

public enum EmbeddingIndexError: Error, Sendable { case unavailable, unsupportedSchema, invalidMetadata, unsafeLocation }

public protocol EmbeddingIndexStorage: Sendable {
    func replaceDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, records: [EmbeddingRecord], validatePublication: @Sendable () throws -> Void) async throws
    func records(generation: EmbeddingIndexGeneration) async throws -> [EmbeddingRecord]
    func removeChunk(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, chunkID: String, validatePublication: @Sendable () throws -> Void) async throws
    func removeDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, validatePublication: @Sendable () throws -> Void) async throws
    func removeGeneration(generation: EmbeddingIndexGeneration, validatePublication: @Sendable () throws -> Void) async throws
}

// The actor exclusively owns the connection; SQLite owns its WAL/SHM sidecars.
private final class EmbeddingIndexConnection: @unchecked Sendable {
    let pointer: OpaquePointer
    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw EmbeddingIndexError.unavailable
        }
        pointer = handle
    }
    deinit { sqlite3_close(pointer) }
}

/// Rebuildable app-local projection. Never writes canonical content or stores input text/authority.
public actor SQLiteEmbeddingIndex: EmbeddingIndexStorage {
    private let connection: EmbeddingIndexConnection
    private let lease: VaultSessionLease
    private let gate: VaultAccessGate
    private var db: OpaquePointer { connection.pointer }
    private static let generationSchema = "CREATE TABLE embedding_generations(id TEXT PRIMARY KEY, metadata BLOB NOT NULL)"
    private static let chunkSchema = "CREATE TABLE embedding_chunks(generation_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, chunk_id TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal>=0), metadata BLOB NOT NULL, vector BLOB NOT NULL, PRIMARY KEY(generation_id,entity_kind,entity_id,chunk_id), UNIQUE(generation_id,entity_kind,entity_id,ordinal))"

    public init(applicationSupportRoot: URL, lease: VaultSessionLease, accessGate: VaultAccessGate) throws {
        try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index.open")
        let root = applicationSupportRoot.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("KnowledgeVault").appendingPathComponent(lease.vaultID.uuidString).standardizedFileURL.resolvingSymlinksInPath()
        let url = directory.appendingPathComponent("semantic.sqlite").standardizedFileURL.resolvingSymlinksInPath()
        func overlaps(_ a: URL, _ b: URL) -> Bool { a == b || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/") }
        let canonicalRoot = lease.root.standardizedFileURL.resolvingSymlinksInPath()
        guard !overlaps(root, canonicalRoot), !overlaps(directory, canonicalRoot), !overlaps(url, canonicalRoot) else { throw EmbeddingIndexError.unsafeLocation }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let connection = try EmbeddingIndexConnection(url: url)
        let db = connection.pointer
        sqlite3_busy_timeout(db, 2_000)
        let version = try Self.rows(db, "PRAGMA user_version").first?.first.flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? -1
        guard version == 0 || version == 1 else { throw EmbeddingIndexError.unsupportedSchema }
        if version == 0 {
            guard try Self.rows(db, "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").isEmpty else { throw EmbeddingIndexError.unsupportedSchema }
        } else {
            // Reject foreign layouts before enabling WAL or changing any database setting.
            let schema = try Self.rows(db, "SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
            guard schema == [[Data(Self.chunkSchema.utf8)], [Data(Self.generationSchema.utf8)]] else {
                throw EmbeddingIndexError.unsupportedSchema
            }
        }
        try Self.execute(db, "PRAGMA journal_mode=WAL")
        try Self.execute(db, "PRAGMA synchronous=FULL")
        if version == 0 {
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                try Self.execute(db, Self.generationSchema)
                try Self.execute(db, Self.chunkSchema)
                try Self.execute(db, "PRAGMA user_version=1")
                try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index.open.commit")
                try Self.execute(db, "COMMIT")
            } catch { try? Self.execute(db, "ROLLBACK"); throw error }
        }
        try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index.open.return")
        self.connection = connection; self.lease = lease; self.gate = accessGate
    }

    /// Persisted generations are metadata only; availability does not grant query authority.
    public func generations() throws -> [EmbeddingIndexGeneration] {
        try Task.checkCancellation(); try validateLease()
        let values = try Self.rows(db, "SELECT id,metadata FROM embedding_generations ORDER BY id").map { row in
            let generation = try JSONDecoder().decode(GenerationMetadata.self, from: row[1]).value()
            guard generation.vaultID == lease.vaultID, row[0] == Data(generation.id.uuidString.utf8) else {
                throw EmbeddingIndexError.invalidMetadata
            }
            return generation
        }
        try validateLease()
        return values
    }

    public func indexedDocuments(generation: EmbeddingIndexGeneration) throws -> [EmbeddingEntityIdentity] {
        var identities: [EmbeddingEntityIdentity] = []
        var seen: Set<String> = []
        for record in try records(generation: generation) {
            let identity = record.chunk.identity
            let key = identity.entityKind.rawValue + ":" + identity.entityID.uuidString + ":" + identity.revision
            if seen.insert(key).inserted { identities.append(identity) }
        }
        try validate(generation)
        return identities
    }

    public func replaceDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, records: [EmbeddingRecord], validatePublication: @Sendable () throws -> Void) throws {
        try validate(generation); try validatePublication()
        guard identity.vaultID == lease.vaultID, records.allSatisfy({ $0.generation == generation && $0.chunk.identity == identity }), Set(records.map(\.chunk.chunkID)).count == records.count, Set(records.map(\.chunk.ordinal)).count == records.count else { throw EmbeddingIndexError.invalidMetadata }
        try transaction(validatePublication) {
            try ensure(generation, create: true)
            try delete(identity, generation)
            for record in records {
                try generation.validate(chunk: record.chunk, vector: record.vector)
                try Self.execute(db, "INSERT INTO embedding_chunks VALUES(?,?,?,?,?,?,?)", [Data(generation.id.uuidString.utf8), Data(identity.entityKind.rawValue.utf8), Data(identity.entityID.uuidString.utf8), Data(record.chunk.chunkID.utf8), Data(String(record.chunk.ordinal).utf8), try JSONEncoder().encode(ChunkMetadata(record.chunk)), record.vector.encodedFloat32LittleEndian()], blobIndices: [5, 6])
            }
        }
    }

    public func records(generation: EmbeddingIndexGeneration) throws -> [EmbeddingRecord] {
        try validate(generation)
        try Self.execute(db, "BEGIN")
        do {
            try ensure(generation, create: false)
            let rows = try Self.rows(db, "SELECT metadata,vector,entity_kind,entity_id,chunk_id,ordinal FROM embedding_chunks WHERE generation_id=? ORDER BY entity_kind,entity_id,ordinal", [Data(generation.id.uuidString.utf8)])
            let records = try rows.map { row -> EmbeddingRecord in
                guard row.count == 6 else { throw EmbeddingIndexError.invalidMetadata }
                let chunk = try JSONDecoder().decode(ChunkMetadata.self, from: row[0]).value(vaultID: generation.vaultID)
                guard row[2] == Data(chunk.identity.entityKind.rawValue.utf8), row[3] == Data(chunk.identity.entityID.uuidString.utf8), row[4] == Data(chunk.chunkID.utf8), row[5] == Data(String(chunk.ordinal).utf8) else { throw EmbeddingIndexError.invalidMetadata }
                return try EmbeddingRecord(generation: generation, chunk: chunk, vector: EmbeddingVector(float32LittleEndian: row[1], model: generation.model))
            }
            try validate(generation); try Self.execute(db, "COMMIT")
            return records
        } catch { try? Self.execute(db, "ROLLBACK"); throw error }
    }

    public func removeChunk(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, chunkID: String, validatePublication: @Sendable () throws -> Void) throws {
        try validate(generation); try validatePublication()
        guard identity.vaultID == lease.vaultID, !chunkID.isEmpty else { throw EmbeddingIndexError.invalidMetadata }
        try transaction(validatePublication) {
            try ensure(generation, create: false)
            try Self.execute(db, "DELETE FROM embedding_chunks WHERE generation_id=? AND entity_kind=? AND entity_id=? AND chunk_id=?", [Data(generation.id.uuidString.utf8), Data(identity.entityKind.rawValue.utf8), Data(identity.entityID.uuidString.utf8), Data(chunkID.utf8)])
        }
    }

    public func removeDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, validatePublication: @Sendable () throws -> Void) throws {
        try validate(generation); try validatePublication()
        guard identity.vaultID == lease.vaultID else { throw EmbeddingIndexError.invalidMetadata }
        try transaction(validatePublication) { try ensure(generation, create: false); try delete(identity, generation) }
    }
    public func removeGeneration(generation: EmbeddingIndexGeneration, validatePublication: @Sendable () throws -> Void) throws {
        try validate(generation); try validatePublication()
        try transaction(validatePublication) {
            try ensure(generation, create: false)
            try Self.execute(db, "DELETE FROM embedding_chunks WHERE generation_id=?", [Data(generation.id.uuidString.utf8)])
            try Self.execute(db, "DELETE FROM embedding_generations WHERE id=?", [Data(generation.id.uuidString.utf8)])
        }
    }
    private func validate(_ generation: EmbeddingIndexGeneration) throws {
        try Task.checkCancellation()
        guard generation.vaultID == lease.vaultID else { throw EmbeddingIndexError.invalidMetadata }
        try validateLease()
    }
    private func validateLease() throws { try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index") }
    private func transaction(_ publication: @Sendable () throws -> Void, _ body: () throws -> Void) throws {
        try validateLease(); try Self.execute(db, "BEGIN IMMEDIATE")
        do { try body(); try Task.checkCancellation(); try validateLease(); try publication(); try Self.execute(db, "COMMIT") }
        catch { try? Self.execute(db, "ROLLBACK"); throw error }
        try validateLease()
    }
    private func ensure(_ generation: EmbeddingIndexGeneration, create: Bool) throws {
        let rows = try Self.rows(db, "SELECT metadata FROM embedding_generations WHERE id=?", [Data(generation.id.uuidString.utf8)])
        if let row = rows.first {
            guard try JSONDecoder().decode(GenerationMetadata.self, from: row[0]).value() == generation else { throw EmbeddingContractError.incompatibleGeneration }
        } else if create {
            try Self.execute(db, "INSERT INTO embedding_generations VALUES(?,?)", [Data(generation.id.uuidString.utf8), try JSONEncoder().encode(GenerationMetadata(generation))], blobIndices: [1])
        }
    }
    private func delete(_ identity: EmbeddingEntityIdentity, _ generation: EmbeddingIndexGeneration) throws {
        try Self.execute(db, "DELETE FROM embedding_chunks WHERE generation_id=? AND entity_kind=? AND entity_id=?", [Data(generation.id.uuidString.utf8), Data(identity.entityKind.rawValue.utf8), Data(identity.entityID.uuidString.utf8)])
    }
    private static func execute(_ db: OpaquePointer, _ sql: String, _ bindings: [Data] = [], blobIndices: Set<Int> = []) throws { _ = try rows(db, sql, bindings, blobIndices: blobIndices) }
    private static func rows(_ db: OpaquePointer, _ sql: String, _ bindings: [Data] = [], blobIndices: Set<Int> = []) throws -> [[Data]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw EmbeddingIndexError.unavailable }
        defer { sqlite3_finalize(statement) }
        for (index, data) in bindings.enumerated() {
            let status = data.withUnsafeBytes { bytes in
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                if blobIndices.contains(index) { return sqlite3_bind_blob(statement, Int32(index + 1), bytes.baseAddress, Int32(data.count), transient) }
                return sqlite3_bind_text(statement, Int32(index + 1), bytes.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), transient)
            }
            guard status == SQLITE_OK else { throw EmbeddingIndexError.unavailable }
        }
        var result: [[Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw EmbeddingIndexError.unavailable }
            var row: [Data] = []
            for column in 0..<sqlite3_column_count(statement) {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else { throw EmbeddingIndexError.invalidMetadata }
                let count = Int(sqlite3_column_bytes(statement, column))
                if count == 0 { row.append(Data()) }
                else { guard let bytes = sqlite3_column_blob(statement, column) else { throw EmbeddingIndexError.invalidMetadata }; row.append(Data(bytes: bytes, count: count)) }
            }
            result.append(row)
        }
    }
}

private struct GenerationMetadata: Codable {
    let id: UUID, vaultID: UUID
    let providerID: String, modelID: String, revision: String, chunkingVersion: String
    let dimensions: Int, maximumInputUTF8Bytes: Int, maximumBatchSize: Int
    init(_ g: EmbeddingIndexGeneration) {
        id = g.id; vaultID = g.vaultID; providerID = g.model.providerID; modelID = g.model.modelID; revision = g.model.revision; chunkingVersion = g.chunkingVersion
        dimensions = g.model.dimensions; maximumInputUTF8Bytes = g.model.maximumInputUTF8Bytes; maximumBatchSize = g.model.maximumBatchSize
    }
    func value() throws -> EmbeddingIndexGeneration {
        try EmbeddingIndexGeneration(id: id, vaultID: vaultID, model: EmbeddingModelDescriptor(providerID: providerID, modelID: modelID, revision: revision, dimensions: dimensions, maximumInputUTF8Bytes: maximumInputUTF8Bytes, maximumBatchSize: maximumBatchSize), chunkingVersion: chunkingVersion)
    }
}
private struct ChunkMetadata: Codable {
    let entityKind: AIEntityKind
    let entityID: UUID
    let revision: String, chunkID: String, fingerprint: String, chunkingVersion: String
    let ordinal: Int
    init(_ c: EmbeddingChunk) { entityKind = c.identity.entityKind; entityID = c.identity.entityID; revision = c.identity.revision; chunkID = c.chunkID; ordinal = c.ordinal; fingerprint = c.contentFingerprint; chunkingVersion = c.chunkingVersion }
    func value(vaultID: UUID) throws -> EmbeddingChunk {
        try EmbeddingChunk(identity: EmbeddingEntityIdentity(vaultID: vaultID, entityKind: entityKind, entityID: entityID, revision: revision), chunkID: chunkID, ordinal: ordinal, contentFingerprint: fingerprint, chunkingVersion: chunkingVersion)
    }
}

public struct EmbeddingSimilarityMatch: Sendable, Equatable {
    public let record: EmbeddingRecord
    public let score: Double
}

public extension SQLiteEmbeddingIndex {
    /// Exact chunk retrieval. The caller supplies authoritative revision/availability checks;
    /// this local primitive does not generate query embeddings or grant cloud authority.
    func nearest(query: EmbeddingVector, generation: EmbeddingIndexGeneration, limit: Int = 20,
                 kind: AIEntityKind? = nil,
                 isCurrent: @Sendable (EmbeddingEntityIdentity) throws -> Bool,
                 validateQuery: @Sendable () throws -> Void) throws -> [EmbeddingSimilarityMatch] {
        guard query.model == generation.model else { throw EmbeddingContractError.incompatibleGeneration }
        guard (1...1000).contains(limit) else { throw EmbeddingContractError.invalidInput }
        try validateQuery()
        var matches: [EmbeddingSimilarityMatch] = []
        for record in try records(generation: generation) {
            try Task.checkCancellation()
            guard kind == nil || record.chunk.identity.entityKind == kind,
                  try isCurrent(record.chunk.identity) else { continue }
            matches.append(EmbeddingSimilarityMatch(record: record, score: try query.cosineSimilarity(to: record.vector)))
        }
        matches.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let left = $0.record.chunk, right = $1.record.chunk
            if left.identity.entityKind.rawValue != right.identity.entityKind.rawValue {
                return left.identity.entityKind.rawValue < right.identity.entityKind.rawValue
            }
            if left.identity.entityID != right.identity.entityID {
                return left.identity.entityID.uuidString < right.identity.entityID.uuidString
            }
            if left.ordinal != right.ordinal { return left.ordinal < right.ordinal }
            return left.chunkID < right.chunkID
        }
        try validate(generation); try validateQuery()
        return Array(matches.prefix(limit))
    }
}
