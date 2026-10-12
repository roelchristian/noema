import Foundation
import CryptoKit

public enum EntryKind: String, Codable, Sendable { case wiki, source }
public struct VaultCanonicalStorageDeclaration: Codable, Sendable, Equatable {
    public var mode: String = "sqliteBlocks"
    public var schemaVersion: Int = 5
    public var database: String = "blocks.sqlite"
    public var localOnly: Bool = true
    public var requiredCapabilities: [String] = ["canonicalKnowledgeV1", "canonicalMetadataV1", "semanticAnnotationsV1"]
    public var unknownFields: [String: JSONValue] = [:]
    public init() {}
    public var isSupported: Bool {
        mode == "sqliteBlocks" && database == "blocks.sqlite" && localOnly &&
        schemaVersion == 5 && requiredCapabilities == SQLiteBlockStore.semanticRequiredCapabilities
    }
    private static let keys: Set<String> = ["mode", "schemaVersion", "database", "localOnly", "requiredCapabilities"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        mode = try c.decode(String.self, forKey: .init("mode"))
        schemaVersion = try c.decode(Int.self, forKey: .init("schemaVersion"))
        database = try c.decode(String.self, forKey: .init("database"))
        localOnly = try c.decode(Bool.self, forKey: .init("localOnly"))
        requiredCapabilities = try c.decode([String].self, forKey: .init("requiredCapabilities"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(mode, forKey: .init("mode")); try c.encode(schemaVersion, forKey: .init("schemaVersion"))
        try c.encode(database, forKey: .init("database")); try c.encode(localOnly, forKey: .init("localOnly"))
        try c.encode(requiredCapabilities, forKey: .init("requiredCapabilities"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}
public struct VaultManifest: Codable, Sendable {
    public static let sqliteDatabasePath = "blocks.sqlite"
    public var formatVersion: Int = 2
    public var id: UUID
    public var storageMode: BlockStorageMode = .sqliteBlocks
    public var storage: VaultCanonicalStorageDeclaration? = VaultCanonicalStorageDeclaration()
    public var unknownFields: [String: JSONValue] = [:]
    public var canonicalStorage: Bool { storage != nil }
    public var isSupported: Bool {
        formatVersion == 2 && storageMode == .sqliteBlocks && storage?.isSupported == true
    }
    public init(id: UUID = UUID()) { self.id = id }
    private static let keys: Set<String> = ["formatVersion", "id", "storageMode", "storage"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        formatVersion = try c.decode(Int.self, forKey: .init("formatVersion"))
        id = try c.decode(UUID.self, forKey: .init("id"))
        storageMode = try c.decode(BlockStorageMode.self, forKey: .init("storageMode"))
        storage = try c.decodeIfPresent(VaultCanonicalStorageDeclaration.self, forKey: .init("storage"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(formatVersion, forKey: .init("formatVersion")); try c.encode(id, forKey: .init("id"))
        try c.encode(storageMode, forKey: .init("storageMode")); try c.encodeIfPresent(storage, forKey: .init("storage"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}
public struct NoteRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var aliases: [String]
    public var tags: [String]
    public var inlineTags: [String]
    public var createdAt: String
    public var updatedAt: String
    public var body: String { didSet { document = nil } }
    public var document: BlockDocument? = nil
    public var relativePath: String
    public var contentHash: String
    public var lcc: String? = nil
    public var lccClassification: LCCClassification? = nil
    public var aiTitleProvenance: SummaryProvenance? = nil
    public var aiLCCProvenance: SummaryProvenance? = nil
    public var editingLocked: Bool? = nil
    public var isEditingLocked: Bool { editingLocked == true }
    public var sourceIDs: [UUID]? = nil
    public var linkedSourceIDs: [UUID] { sourceIDs ?? [] }
    public var originalHeader: String?
    public var extensions: PersistencePayload? = nil
    public var unknownFields: [String: JSONValue] = [:]
    public var allTags: [String] { Array(Set(tags + inlineTags)).sorted() }
}
/// Portable generation facts for an accepted AI artifact; no request authority or secret.
public struct SummaryProvenance: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var generatedAt: Date
    public var sourceRevision: String? = nil
    /// Shared identity of published artifacts; unrelated to transient request authority.
    public var generationID: UUID? = nil
    public init(provider: String, model: String, generatedAt: Date, sourceRevision: String? = nil, generationID: UUID? = nil) {
        self.provider = provider; self.model = model; self.generatedAt = generatedAt
        self.sourceRevision = sourceRevision; self.generationID = generationID
    }
}
/// A locally verified generated subject classification. Legacy `lcc` values remain readable.
public struct LCCClassification: Codable, Sendable, Equatable {
    public var code: String
    public var level: LCCClassificationLevel
    public var caption: String
    public var provenance: SummaryProvenance?
    public var classifiedAt: Date?
    public init(code: String, level: LCCClassificationLevel, caption: String,
        provenance: SummaryProvenance? = nil, classifiedAt: Date? = nil) {
        self.code = code; self.level = level; self.caption = caption
        self.provenance = provenance; self.classifiedAt = classifiedAt
    }
}
public struct SourceMetadata: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var capturedAt: String
    public var originalFilename: String
    public var originURL: String?
    public var sha256: String
    public var lcc: String? = nil
    public var lccClassification: LCCClassification? = nil
    public var aiTitleProvenance: SummaryProvenance? = nil
    public var aiLCCProvenance: SummaryProvenance? = nil
    public var aiSummary: String? = nil
    public var aiSummaryProvenance: SummaryProvenance? = nil
    public var isURLSource: Bool? = nil
    public var webAvailabilityIssue: String? = nil
    public var fileSize: Int? = nil
    public var linkedBookmark: Data? = nil
    public var isLinked: Bool { linkedBookmark != nil }
    public var extensions: PersistencePayload? = nil
    public var unknownFields: [String: JSONValue] = [:]
    public var storedFilename: String
}
public enum SourceContentState: String, Codable, Sendable {
    case loaded, notLoaded, unavailable
}

public struct SourceRecord: Codable, Identifiable, Sendable, Equatable {
    public var metadata: SourceMetadata
    public var body: String
    public var availabilityIssue: String? = nil
    public var contentState: SourceContentState
    public var id: UUID { metadata.id }
    public var title: String { metadata.title }

    public init(metadata: SourceMetadata, body: String, availabilityIssue: String? = nil, contentState: SourceContentState = .loaded) {
        self.metadata = metadata; self.body = body
        self.availabilityIssue = availabilityIssue; self.contentState = contentState
    }

    private enum CodingKeys: String, CodingKey { case metadata, body, availabilityIssue, contentState }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try values.decode(SourceMetadata.self, forKey: .metadata)
        body = try values.decode(String.self, forKey: .body)
        availabilityIssue = try values.decodeIfPresent(String.self, forKey: .availabilityIssue)
        // Existing index records contain complete bodies, including genuinely empty originals.
        contentState = try values.decodeIfPresent(SourceContentState.self, forKey: .contentState) ?? .loaded
    }
}

public enum SourceLoadingPolicy: Sendable { case metadataOnly, complete, verifyOriginals }
public enum SourceScanVerification: Sendable, Equatable {
    case notVerified, verifiedThisScan, reusedPreviouslyVerified, linkedContentRead
}

public struct ScanBatch: Sendable {
    public var notes: [NoteRecord] = []
    public var sources: [SourceRecord] = []
    public var issues: [String] = []
    /// Transient scan evidence; neither timestamps nor metadata-only discovery verify bytes.
    public var sourceVerification: [UUID: SourceScanVerification] = [:]
    /// Extracted-content revisions permit index reconciliation without hashing cached bodies again.
    public var sourceContentRevisions: [UUID: String] = [:]
    /// Verified original-byte fingerprints for invalidating open previews, including binary linked files.
    public var sourceOriginalRevisions: [UUID: String] = [:]
    public init() {}
}
public struct WikiLink: Codable, Sendable, Equatable {
    public var target: String
    public var label: String
}
public struct TextAnalysis: Sendable {
    public var links: [WikiLink]
    public var tags: [String]
}
public struct DraftRecord: Codable, Identifiable, Sendable {
    public var note: NoteRecord
    public var title: String
    public var document: BlockDocument? = nil
    public var contentBody: String { document.map(BlockDocumentCodec.encode) ?? body }
    public var body: String
    public var tags: [String]
    public var capturedAt: String
    public var semanticEdit: SemanticPageEdit? = nil
    public var id: UUID { note.id }
    public init(note: NoteRecord, title: String, body: String, tags: [String], semanticEdit: SemanticPageEdit? = nil) {
        self.note = note; self.title = title; self.body = body; self.tags = tags; self.semanticEdit = semanticEdit
        self.capturedAt = timestamp()
    }
    public init(note: NoteRecord, title: String, document: BlockDocument, tags: [String], semanticEdit: SemanticPageEdit? = nil) {
        self.note = note; self.title = title; self.body = ""; self.document = document; self.tags = tags; self.semanticEdit = semanticEdit
        self.capturedAt = timestamp()
    }
}
public struct SearchHit: Sendable {
    public var id: UUID
    public var kind: EntryKind
    public var excerpt: String
}
public enum VaultError: Error, LocalizedError, Sendable {
    case invalid(String), unavailable(String), conflict(String), duplicateTitle(String), storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .storage(let s): return s
        case .conflict(let p): return "This page changed outside the editor. Both versions are preserved. Your draft is also saved at \(p)."
        case .duplicateTitle(let s): return "A page or alias named ‘\(s)’ already exists. Choose another title."
        }
    }
}
public func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
public func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
public func normalized(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased() }
public func normalizeTags(_ tags: [String]) -> [String] {
    Array(Set(tags.map { normalized($0).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }.filter { !$0.isEmpty })).sorted()
}
public func externalID(vault: UUID, path: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data((vault.uuidString + path).utf8)).prefix(16))
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
}

public struct TrashedPage: Identifiable, Sendable {
    public var note: NoteRecord
    public var readIssue: String?
    public var id: String { note.relativePath }
    public var canRestore: Bool { readIssue == nil }
    public var canPermanentlyDelete: Bool { !note.contentHash.isEmpty }
    public init(note: NoteRecord, readIssue: String? = nil) { self.note = note; self.readIssue = readIssue }
}


public struct TrashedSource: Identifiable, Sendable {
    public var id: String
    public var source: SourceRecord?
    public var contentHash: String
    public var readIssue: String?
    public var title: String { source?.title ?? URL(fileURLWithPath: id).lastPathComponent }
}

public enum TrashedItem: Identifiable, Sendable {
    case page(TrashedPage)
    case source(TrashedSource)
    public var id: String { switch self { case .page(let page): page.id; case .source(let source): source.id } }
    public var title: String { switch self { case .page(let page): page.note.title; case .source(let source): source.title } }
    public var readIssue: String? { switch self { case .page(let page): page.readIssue; case .source(let source): source.readIssue } }
    public var canRestore: Bool { switch self { case .page(let page): page.canRestore; case .source(let source): source.source != nil && source.readIssue == nil } }
    public var canPermanentlyDelete: Bool { switch self { case .page(let page): page.canPermanentlyDelete; case .source(let source): !source.contentHash.isEmpty } }
    public var excerpt: String { switch self { case .page(let page): String(page.note.body.prefix(240)); case .source(let source): source.source?.metadata.originalFilename ?? "" } }
    public var kindLabel: String { switch self { case .page: "Page"; case .source(let source): source.source?.metadata.isLinked == true ? "Linked source" : "Imported source" } }
}
