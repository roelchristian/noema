import Foundation

extension SourceMetadata {
    private static var persistenceKeys: Set<String> { ["id", "title", "capturedAt", "originalFilename", "originURL", "sha256", "lcc", "lccClassification", "aiTitleProvenance", "aiLCCProvenance", "aiSummary", "aiSummaryProvenance", "isURLSource", "webAvailabilityIssue", "fileSize", "linkedBookmark", "storedFilename", "extensions"] }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try values.decode(UUID.self, forKey: .init("id"))
        title = try values.decode(String.self, forKey: .init("title"))
        capturedAt = try values.decode(String.self, forKey: .init("capturedAt"))
        originalFilename = try values.decode(String.self, forKey: .init("originalFilename"))
        originURL = try values.decodeIfPresent(String.self, forKey: .init("originURL"))
        sha256 = try values.decode(String.self, forKey: .init("sha256"))
        lcc = try values.decodeIfPresent(String.self, forKey: .init("lcc"))
        lccClassification = try values.decodeIfPresent(LCCClassification.self, forKey: .init("lccClassification"))
        aiTitleProvenance = try values.decodeIfPresent(SummaryProvenance.self, forKey: .init("aiTitleProvenance"))
        aiLCCProvenance = try values.decodeIfPresent(SummaryProvenance.self, forKey: .init("aiLCCProvenance"))
        aiSummary = try values.decodeIfPresent(String.self, forKey: .init("aiSummary"))
        aiSummaryProvenance = try values.decodeIfPresent(SummaryProvenance.self, forKey: .init("aiSummaryProvenance"))
        isURLSource = try values.decodeIfPresent(Bool.self, forKey: .init("isURLSource"))
        webAvailabilityIssue = try values.decodeIfPresent(String.self, forKey: .init("webAvailabilityIssue"))
        fileSize = try values.decodeIfPresent(Int.self, forKey: .init("fileSize"))
        linkedBookmark = try values.decodeIfPresent(Data.self, forKey: .init("linkedBookmark"))
        storedFilename = try values.decode(String.self, forKey: .init("storedFilename"))
        extensions = try values.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        unknownFields = try decodeUnknownFields(values, known: Self.persistenceKeys)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: PersistenceCodingKey.self)
        try values.encode(id, forKey: .init("id"))
        try values.encode(title, forKey: .init("title"))
        try values.encode(capturedAt, forKey: .init("capturedAt"))
        try values.encode(originalFilename, forKey: .init("originalFilename"))
        try values.encodeIfPresent(originURL, forKey: .init("originURL"))
        try values.encode(sha256, forKey: .init("sha256"))
        try values.encodeIfPresent(lcc, forKey: .init("lcc"))
        try values.encodeIfPresent(lccClassification, forKey: .init("lccClassification"))
        try values.encodeIfPresent(aiTitleProvenance, forKey: .init("aiTitleProvenance"))
        try values.encodeIfPresent(aiLCCProvenance, forKey: .init("aiLCCProvenance"))
        try values.encodeIfPresent(aiSummary, forKey: .init("aiSummary"))
        try values.encodeIfPresent(aiSummaryProvenance, forKey: .init("aiSummaryProvenance"))
        try values.encodeIfPresent(isURLSource, forKey: .init("isURLSource"))
        try values.encodeIfPresent(webAvailabilityIssue, forKey: .init("webAvailabilityIssue"))
        try values.encodeIfPresent(fileSize, forKey: .init("fileSize"))
        try values.encodeIfPresent(linkedBookmark, forKey: .init("linkedBookmark"))
        try values.encode(storedFilename, forKey: .init("storedFilename"))
        try values.encodeIfPresent(extensions, forKey: .init("extensions"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &values)
    }
}
