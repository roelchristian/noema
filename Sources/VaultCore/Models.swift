import Foundation
import CryptoKit

public enum EntryKind: String, Codable, Sendable { case wiki, source }
public struct VaultManifest: Codable, Sendable {
    public var formatVersion: Int = 1
    public var id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}
public struct NoteRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var aliases: [String]
    public var tags: [String]
    public var inlineTags: [String]
    public var createdAt: String
    public var updatedAt: String
    public var body: String
    public var relativePath: String
    public var contentHash: String
    public var editingLocked: Bool? = nil
    public var isEditingLocked: Bool { editingLocked == true }
    public var originalHeader: String?
    public var allTags: [String] { Array(Set(tags + inlineTags)).sorted() }
}
public struct SourceMetadata: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var capturedAt: String
    public var originalFilename: String
    public var originURL: String?
    public var sha256: String
    public var storedFilename: String
}
public struct SourceRecord: Codable, Identifiable, Sendable, Equatable {
    public var metadata: SourceMetadata
    public var body: String
    public var id: UUID { metadata.id }
    public var title: String { metadata.title }
}
public struct ScanBatch: Sendable {
    public var notes: [NoteRecord] = []
    public var sources: [SourceRecord] = []
    public var issues: [String] = []
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
    public var body: String
    public var tags: [String]
    public var capturedAt: String
    public var id: UUID { note.id }
    public init(note: NoteRecord, title: String, body: String, tags: [String]) {
        self.note = note; self.title = title; self.body = body; self.tags = tags
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
    public var id: String { note.relativePath }
    public init(note: NoteRecord) { self.note = note }
}
