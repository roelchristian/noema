import Foundation

// The same domain metadata travels through SQLite, exports and recovery without
// discarding optional future fields. Relational source IDs are removed by the
// canonical adapter before storage and reconstructed from its ordered links.
extension NoteRecord {
    private static var persistenceKeys: Set<String> { ["id", "title", "aliases", "tags", "inlineTags", "createdAt", "updatedAt", "body", "relativePath", "contentHash", "lcc", "lccClassification", "aiTitleProvenance", "aiLCCProvenance", "editingLocked", "sourceIDs", "originalHeader", "extensions"] }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try values.decode(UUID.self, forKey: .init("id"))
        title = try values.decode(String.self, forKey: .init("title"))
        aliases = try values.decode([String].self, forKey: .init("aliases"))
        tags = try values.decode([String].self, forKey: .init("tags"))
        inlineTags = try values.decode([String].self, forKey: .init("inlineTags"))
        createdAt = try values.decode(String.self, forKey: .init("createdAt"))
        updatedAt = try values.decode(String.self, forKey: .init("updatedAt"))
        body = try values.decode(String.self, forKey: .init("body"))
        relativePath = try values.decode(String.self, forKey: .init("relativePath"))
        contentHash = try values.decode(String.self, forKey: .init("contentHash"))
        lcc = try values.decodeIfPresent(String.self, forKey: .init("lcc"))
        lccClassification = try values.decodeIfPresent(LCCClassification.self, forKey: .init("lccClassification"))
        aiTitleProvenance = try values.decodeIfPresent(SummaryProvenance.self, forKey: .init("aiTitleProvenance"))
        aiLCCProvenance = try values.decodeIfPresent(SummaryProvenance.self, forKey: .init("aiLCCProvenance"))
        editingLocked = try values.decodeIfPresent(Bool.self, forKey: .init("editingLocked"))
        sourceIDs = try values.decodeIfPresent([UUID].self, forKey: .init("sourceIDs"))
        originalHeader = try values.decodeIfPresent(String.self, forKey: .init("originalHeader"))
        extensions = try values.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        unknownFields = try decodeUnknownFields(values, known: Self.persistenceKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: PersistenceCodingKey.self)
        try values.encode(id, forKey: .init("id"))
        try values.encode(title, forKey: .init("title"))
        try values.encode(aliases, forKey: .init("aliases"))
        try values.encode(tags, forKey: .init("tags"))
        try values.encode(inlineTags, forKey: .init("inlineTags"))
        try values.encode(createdAt, forKey: .init("createdAt"))
        try values.encode(updatedAt, forKey: .init("updatedAt"))
        try values.encode(body, forKey: .init("body"))
        try values.encode(relativePath, forKey: .init("relativePath"))
        try values.encode(contentHash, forKey: .init("contentHash"))
        try values.encodeIfPresent(lcc, forKey: .init("lcc"))
        try values.encodeIfPresent(lccClassification, forKey: .init("lccClassification"))
        try values.encodeIfPresent(aiTitleProvenance, forKey: .init("aiTitleProvenance"))
        try values.encodeIfPresent(aiLCCProvenance, forKey: .init("aiLCCProvenance"))
        try values.encodeIfPresent(editingLocked, forKey: .init("editingLocked"))
        try values.encodeIfPresent(sourceIDs, forKey: .init("sourceIDs"))
        try values.encodeIfPresent(originalHeader, forKey: .init("originalHeader"))
        try values.encodeIfPresent(extensions, forKey: .init("extensions"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &values)
    }
}
