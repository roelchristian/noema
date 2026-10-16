import Foundation
import SQLite3

public enum EmbeddingIndexError: Error, Sendable { case unavailable, unsupportedSchema, invalidMetadata, unsafeLocation }

/// Durable technical completion evidence, including a zero-chunk document. Construction grants no
/// inference authority; persistence validates it against the atomically replaced document.
public struct EmbeddingDocumentCompletion: Sendable, Equatable {
    public let identity: EmbeddingEntityIdentity
    public let workRevision: String
    public let inputFingerprint: String
    public let chunkCount: Int
    public init(identity: EmbeddingEntityIdentity, workRevision: String, inputFingerprint: String, chunkCount: Int) {
        self.identity = identity; self.workRevision = workRevision
        self.inputFingerprint = inputFingerprint; self.chunkCount = chunkCount
    }
}

/// Durable partial progress. This is reuse evidence, never a completed-document claim or authority.
public struct EmbeddingDocumentCheckpoint: Sendable, Equatable {
    public let identity: EmbeddingEntityIdentity
    public let workRevision: String
    public let inputFingerprint: String
    public let chunkCount: Int
    public init(identity: EmbeddingEntityIdentity, workRevision: String, inputFingerprint: String, chunkCount: Int) {
        self.identity = identity; self.workRevision = workRevision
        self.inputFingerprint = inputFingerprint; self.chunkCount = chunkCount
    }
    fileprivate var evidence: EmbeddingDocumentCompletion {
        .init(identity: identity, workRevision: workRevision, inputFingerprint: inputFingerprint, chunkCount: chunkCount)
    }
}

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

    private static let documentSchema = "CREATE TABLE embedding_documents(generation_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, chunk_count INTEGER NOT NULL CHECK(chunk_count>=0), metadata BLOB NOT NULL, PRIMARY KEY(generation_id,entity_kind,entity_id))"

    private static let checkpointSchema = "CREATE TABLE embedding_checkpoints(generation_id TEXT NOT NULL, entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, chunk_count INTEGER NOT NULL CHECK(chunk_count>=0), metadata BLOB NOT NULL, PRIMARY KEY(generation_id,entity_kind,entity_id))"

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
        guard (0...3).contains(version) else { throw EmbeddingIndexError.unsupportedSchema }
        if version == 0 {
            guard try Self.rows(db, "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").isEmpty else { throw EmbeddingIndexError.unsupportedSchema }
        } else {
            // Reject foreign layouts before enabling WAL or changing any database setting.
            let schema = try Self.rows(db, "SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name")
            let expected: [String]
            switch version {
            case 1: expected = [Self.chunkSchema, Self.generationSchema]
            case 2: expected = [Self.chunkSchema, Self.documentSchema, Self.generationSchema]
            default: expected = [Self.checkpointSchema, Self.chunkSchema, Self.documentSchema, Self.generationSchema]
            }
            guard schema == expected.map({ [Data($0.utf8)] }) else {
                throw EmbeddingIndexError.unsupportedSchema
            }
        }
        try Self.execute(db, "PRAGMA journal_mode=WAL")
        try Self.execute(db, "PRAGMA synchronous=FULL")
        if version < 3 {
            try Self.execute(db, "BEGIN IMMEDIATE")
            do {
                if version == 0 {
                    try Self.execute(db, Self.generationSchema)
                    try Self.execute(db, Self.chunkSchema)
                } else {
                    // Preserve only validated legacy data; vector presence never creates completion.
                    try Self.validateLegacyRows(db, vaultID: lease.vaultID)
                    if version == 2 {
                        let generations = try Self.rows(db, "SELECT metadata FROM embedding_generations").map {
                            try JSONDecoder().decode(GenerationMetadata.self, from: $0[0]).value()
                        }
                        var documentCount = 0
                        for generation in generations {
                            documentCount += try Self.readDocumentEvidence(db, generation: generation,
                                table: "embedding_documents").count
                        }
                        guard try Self.rows(db, "SELECT metadata FROM embedding_documents").count == documentCount else {
                            throw EmbeddingIndexError.invalidMetadata
                        }
                    }
                }
                if version < 2 { try Self.execute(db, Self.documentSchema) }
                try Self.execute(db, Self.checkpointSchema)
                try Self.execute(db, "PRAGMA user_version=3")
                try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index.open.commit")
                try Self.execute(db, "COMMIT")
            } catch { try? Self.execute(db, "ROLLBACK"); throw error }
        }
        try accessGate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index.open.return")
        self.connection = connection; self.lease = lease; self.gate = accessGate
    }

    /// Retain the selected generation before work admission, including a pause before its first
    /// vector. This metadata grants no inference, consent, or vector-publication authority.
    public func declareGeneration(generation: EmbeddingIndexGeneration) throws {
        try validate(generation)
        try transaction({}) { try ensure(generation, create: true) }
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

    /// Production publication: the store-issued permit and live generation authority span COMMIT.
    /// The supplied validator runs before acquiring publication locks and must revalidate linked
    /// originals and completed provider capabilities. It must not be mistaken for the permit.
    /// A checkpoint records full work-revision evidence for partial chunks and retires any
    /// previous completion claim in the same transaction. Only completion marks a document done.
    public func replaceDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration,
                                records: [EmbeddingRecord], permit: EmbeddingPublicationPermit,
                                authority: EmbeddingPublicationAuthority,
                                completion: EmbeddingDocumentCompletion? = nil,
                                checkpoint: EmbeddingDocumentCheckpoint? = nil,
                                validatePublication: @Sendable () throws -> Void) throws {
        guard permit.matches(identity), authority.lease == lease,
              authority.generation == generation else { throw EmbeddingContractError.authorityDenied }
        try replaceDocument(identity: identity, generation: generation, records: records,
                            validatePublication: validatePublication, protection: (permit, authority), completion: completion, checkpoint: checkpoint)
    }

    /// Infrastructure primitive retained for existing provider/index tests. Application processors
    /// must use the permit-bearing overload; revision validation alone does not serialize COMMIT.
    public func replaceDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration, records: [EmbeddingRecord], validatePublication: @Sendable () throws -> Void) throws {
        try replaceDocument(identity: identity, generation: generation, records: records,
                            validatePublication: validatePublication, protection: nil)
    }
    private func replaceDocument(identity: EmbeddingEntityIdentity, generation: EmbeddingIndexGeneration,
                                 records: [EmbeddingRecord], validatePublication: @Sendable () throws -> Void,
                                 protection: (EmbeddingPublicationPermit, EmbeddingPublicationAuthority)?,
                                 completion: EmbeddingDocumentCompletion? = nil,
                                 checkpoint: EmbeddingDocumentCheckpoint? = nil) throws {
        try validate(generation); try validatePublication()
        guard identity.vaultID == lease.vaultID, records.allSatisfy({ $0.generation == generation && $0.chunk.identity == identity }), Set(records.map(\.chunk.chunkID)).count == records.count, Set(records.map(\.chunk.ordinal)).count == records.count else { throw EmbeddingIndexError.invalidMetadata }
        guard completion == nil || checkpoint == nil else { throw EmbeddingIndexError.invalidMetadata }
        let evidence = completion ?? checkpoint?.evidence
        if let evidence {
            try Self.validateCompletion(evidence)
            guard evidence.identity == identity, evidence.chunkCount == records.count else { throw EmbeddingIndexError.invalidMetadata }
        }
        try transaction(validatePublication, protection: protection) {
            try ensure(generation, create: true)
            try delete(identity, generation)
            for record in records {
                try generation.validate(chunk: record.chunk, vector: record.vector)
                try Self.execute(db, "INSERT INTO embedding_chunks VALUES(?,?,?,?,?,?,?)", [Data(generation.id.uuidString.utf8), Data(identity.entityKind.rawValue.utf8), Data(identity.entityID.uuidString.utf8), Data(record.chunk.chunkID.utf8), Data(String(record.chunk.ordinal).utf8), try JSONEncoder().encode(ChunkMetadata(record.chunk)), record.vector.encodedFloat32LittleEndian()], blobIndices: [5, 6])
            }
            if let evidence {
                let table = completion == nil ? "embedding_checkpoints" : "embedding_documents"
                try Self.execute(db, "INSERT INTO \(table) VALUES(?,?,?,?,?)",
                    [Data(generation.id.uuidString.utf8), Data(identity.entityKind.rawValue.utf8),
                     Data(identity.entityID.uuidString.utf8), Data(String(evidence.chunkCount).utf8),
                     try JSONEncoder().encode(CompletionMetadata(evidence))], blobIndices: [4])
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
            try deleteCompletion(identity, generation)
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
            try Self.execute(db, "DELETE FROM embedding_documents WHERE generation_id=?", [Data(generation.id.uuidString.utf8)])
            try Self.execute(db, "DELETE FROM embedding_checkpoints WHERE generation_id=?", [Data(generation.id.uuidString.utf8)])
            try Self.execute(db, "DELETE FROM embedding_generations WHERE id=?", [Data(generation.id.uuidString.utf8)])
        }
    }
    /// Reads a coherent document/chunk snapshot and rejects damaged completion claims.
    public func completedDocuments(generation: EmbeddingIndexGeneration) throws -> [EmbeddingDocumentCompletion] {
        try documentEvidence(generation: generation, table: "embedding_documents")
    }

    public func documentCheckpoints(generation: EmbeddingIndexGeneration) throws -> [EmbeddingDocumentCheckpoint] {
        try documentEvidence(generation: generation, table: "embedding_checkpoints").map {
            .init(identity: $0.identity, workRevision: $0.workRevision,
                  inputFingerprint: $0.inputFingerprint, chunkCount: $0.chunkCount)
        }
    }

    private func documentEvidence(generation: EmbeddingIndexGeneration, table: String) throws -> [EmbeddingDocumentCompletion] {
        try validate(generation)
        try Self.execute(db, "BEGIN")
        do {
            try ensure(generation, create: false)
            let result = try Self.readDocumentEvidence(db, generation: generation, table: table)
            try validate(generation); try Self.execute(db, "COMMIT")
            return result
        } catch { try? Self.execute(db, "ROLLBACK"); throw error }
    }

    private static func readDocumentEvidence(_ db: OpaquePointer, generation: EmbeddingIndexGeneration,
                                             table: String) throws -> [EmbeddingDocumentCompletion] {
        let rows = try Self.rows(db, "SELECT entity_kind,entity_id,chunk_count,metadata FROM \(table) WHERE generation_id=? ORDER BY entity_kind,entity_id", [Data(generation.id.uuidString.utf8)])
        if !rows.isEmpty {
            guard !(try Self.rows(db, "SELECT id FROM embedding_generations WHERE id=?", [Data(generation.id.uuidString.utf8)])).isEmpty else { throw EmbeddingIndexError.invalidMetadata }
        }
        let result = try rows.map { row -> EmbeddingDocumentCompletion in
            let value = try JSONDecoder().decode(CompletionMetadata.self, from: row[3]).value(vaultID: generation.vaultID)
            try Self.validateCompletion(value)
            guard row[0] == Data(value.identity.entityKind.rawValue.utf8),
                  row[1] == Data(value.identity.entityID.uuidString.utf8),
                  row[2] == Data(String(value.chunkCount).utf8) else { throw EmbeddingIndexError.invalidMetadata }
            let chunks = try Self.rows(db, "SELECT metadata,vector,entity_kind,entity_id,chunk_id,ordinal FROM embedding_chunks WHERE generation_id=? AND entity_kind=? AND entity_id=?", [Data(generation.id.uuidString.utf8), row[0], row[1]])
            guard chunks.count == value.chunkCount else { throw EmbeddingIndexError.invalidMetadata }
            for chunkRow in chunks {
                let chunk = try JSONDecoder().decode(ChunkMetadata.self, from: chunkRow[0]).value(vaultID: generation.vaultID)
                guard chunk.identity == value.identity,
                      chunkRow[2] == Data(chunk.identity.entityKind.rawValue.utf8),
                      chunkRow[3] == Data(chunk.identity.entityID.uuidString.utf8),
                      chunkRow[4] == Data(chunk.chunkID.utf8),
                      chunkRow[5] == Data(String(chunk.ordinal).utf8) else { throw EmbeddingIndexError.invalidMetadata }
                try generation.validate(chunk: chunk, vector: EmbeddingVector(float32LittleEndian: chunkRow[1], model: generation.model))
            }
            return value
        }
        return result
    }

    /// Explicit deletion integration: coordinator removal does not invoke processors.
    public func removeEntity(identity: EmbeddingEntityIdentity, validatePublication: @Sendable () throws -> Void) throws {
        guard identity.vaultID == lease.vaultID else { throw EmbeddingIndexError.invalidMetadata }
        try validatePublication()
        try transaction(validatePublication) {
            for table in ["embedding_chunks", "embedding_documents", "embedding_checkpoints"] {
                try Self.execute(db, "DELETE FROM \(table) WHERE entity_kind=? AND entity_id=?", [Data(identity.entityKind.rawValue.utf8), Data(identity.entityID.uuidString.utf8)])
            }
        }
    }

    /// Metadata-only startup cleanup. The inventory does not admit inference or historical work.
    /// Callers must revalidate the captured vault lease/inventory before the final commit.
    public func reconcile(current: [AIContentChange], validatePublication: @Sendable () throws -> Void) throws {
        try validateLease(); try validatePublication()
        var revisions: [String: String] = [:]
        var inventoryIdentities: Set<String> = []
        func key(_ kind: AIEntityKind, _ id: UUID) -> String { kind.rawValue + ":" + id.uuidString }
        for change in current {
            guard change.vaultID == lease.vaultID, !change.revision.isEmpty,
                  inventoryIdentities.insert(key(change.entityKind, change.entityID)).inserted else { throw EmbeddingIndexError.invalidMetadata }
            if change.kind != .removed { revisions[key(change.entityKind, change.entityID)] = change.revision }
        }
        // Gather before BEGIN; actor serialization excludes concurrent writes through this owner.
        var obsolete: [(EmbeddingEntityIdentity, EmbeddingIndexGeneration)] = []
        for generation in try generations() {
            let completions = try completedDocuments(generation: generation)
            var checked: Set<String> = []
            for completion in completions {
                let id = key(completion.identity.entityKind, completion.identity.entityID)
                checked.insert(id)
                if revisions[id] != completion.workRevision { obsolete.append((completion.identity, generation)) }
            }
            for checkpoint in try documentCheckpoints(generation: generation) {
                let identity = checkpoint.identity, id = key(identity.entityKind, identity.entityID)
                checked.insert(id)
                // Startup inventory cannot certify original bytes. Preserve partial Source rows
                // as reuse candidates when its canonical revision is current; fresh preparation
                // must reread originals and match each chunk fingerprint before reusing a vector.
                // This exception never preserves a completed-document claim.
                let canonicalSourceOnly = identity.entityKind == .source && revisions[id] == identity.revision &&
                    checkpoint.workRevision.hasPrefix(identity.revision + ":")
                if revisions[id] != checkpoint.workRevision && !canonicalSourceOnly {
                    obsolete.append((identity, generation))
                }
            }
            for record in try records(generation: generation) {
                let identity = record.chunk.identity, id = key(identity.entityKind, identity.entityID)
                guard checked.insert(id).inserted else { continue }
                // Legacy Source vectors lack original-byte completion evidence. Conservatively
                // retire them rather than equating a canonical token with a composite revision.
                if revisions[id] != identity.revision { obsolete.append((identity, generation)) }
            }
        }
        try transaction(validatePublication) {
            for (identity, generation) in obsolete { try delete(identity, generation) }
        }
    }

    private static func validateCompletion(_ value: EmbeddingDocumentCompletion) throws {
        guard value.chunkCount >= 0,
              [value.workRevision, value.inputFingerprint].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512 }) else {
            throw EmbeddingIndexError.invalidMetadata
        }
    }

    private static func validateLegacyRows(_ db: OpaquePointer, vaultID: UUID) throws {
        var generations: [String: EmbeddingIndexGeneration] = [:]
        for row in try rows(db, "SELECT id,metadata FROM embedding_generations") {
            let value = try JSONDecoder().decode(GenerationMetadata.self, from: row[1]).value()
            guard value.vaultID == vaultID, row[0] == Data(value.id.uuidString.utf8) else { throw EmbeddingIndexError.invalidMetadata }
            generations[value.id.uuidString] = value
        }
        for row in try rows(db, "SELECT generation_id,entity_kind,entity_id,chunk_id,ordinal,metadata,vector FROM embedding_chunks") {
            guard let id = String(data: row[0], encoding: .utf8), let generation = generations[id] else { throw EmbeddingIndexError.invalidMetadata }
            let chunk = try JSONDecoder().decode(ChunkMetadata.self, from: row[5]).value(vaultID: vaultID)
            guard row[1] == Data(chunk.identity.entityKind.rawValue.utf8), row[2] == Data(chunk.identity.entityID.uuidString.utf8),
                  row[3] == Data(chunk.chunkID.utf8), row[4] == Data(String(chunk.ordinal).utf8) else { throw EmbeddingIndexError.invalidMetadata }
            try generation.validate(chunk: chunk, vector: EmbeddingVector(float32LittleEndian: row[6], model: generation.model))
        }
    }

    private func validate(_ generation: EmbeddingIndexGeneration) throws {
        try Task.checkCancellation()
        guard generation.vaultID == lease.vaultID else { throw EmbeddingIndexError.invalidMetadata }
        try validateLease()
    }
    private func validateLease() throws { try gate.validate(lease: lease, targetRoot: lease.root, targetVaultID: lease.vaultID, operation: "embedding.index") }
    private func transaction(_ publication: @Sendable () throws -> Void,
                             protection: (EmbeddingPublicationPermit, EmbeddingPublicationAuthority)? = nil,
                             _ body: () throws -> Void) throws {
        try validateLease(); try Self.execute(db, "BEGIN IMMEDIATE")
        do {
            try body(); try Task.checkCancellation(); try validateLease(); try publication()
            if let (permit, authority) = protection {
                // Gate validation is deliberately outside these locks: its invalidator acquires
                // authority and publication must never reverse that order by reentering the gate.
                try permit.withPublication(authority: authority) { try Self.execute(db, "COMMIT") }
            } else { try Self.execute(db, "COMMIT") }
        }
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
    private func deleteCompletion(_ identity: EmbeddingEntityIdentity, _ generation: EmbeddingIndexGeneration) throws {
        for table in ["embedding_documents", "embedding_checkpoints"] {
            try Self.execute(db, "DELETE FROM \(table) WHERE generation_id=? AND entity_kind=? AND entity_id=?", [Data(generation.id.uuidString.utf8), Data(identity.entityKind.rawValue.utf8), Data(identity.entityID.uuidString.utf8)])
        }
    }
    private func delete(_ identity: EmbeddingEntityIdentity, _ generation: EmbeddingIndexGeneration) throws {
        try deleteCompletion(identity, generation)
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
private struct CompletionMetadata: Codable {
    let entityKind: AIEntityKind
    let entityID: UUID
    let revision: String, workRevision: String, inputFingerprint: String
    let chunkCount: Int
    init(_ value: EmbeddingDocumentCompletion) {
        entityKind = value.identity.entityKind; entityID = value.identity.entityID
        revision = value.identity.revision; workRevision = value.workRevision
        inputFingerprint = value.inputFingerprint; chunkCount = value.chunkCount
    }
    func value(vaultID: UUID) throws -> EmbeddingDocumentCompletion {
        EmbeddingDocumentCompletion(identity: try EmbeddingEntityIdentity(vaultID: vaultID, entityKind: entityKind, entityID: entityID, revision: revision), workRevision: workRevision, inputFingerprint: inputFingerprint, chunkCount: chunkCount)
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
