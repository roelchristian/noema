import Foundation

/// JSON values retain optional future fields without coercing them to strings.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Decimal), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        guard decoder.codingPath.count <= 64 else { throw PersistencePayloadError.limitExceeded }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    func validate(depth: Int = 0) throws {
        guard depth <= 32 else { throw PersistencePayloadError.limitExceeded }
        switch self {
        case .array(let items): for item in items { try item.validate(depth: depth + 1) }
        case .object(let items): for item in items.values { try item.validate(depth: depth + 1) }
        default: break
        }
    }
}

public enum PersistencePayloadError: Error, Equatable, Sendable {
    case unsupportedVersion(Int), requiredFeature(String), limitExceeded, fieldCollision(String), unsupportedBlockKind(String), invalidAnnotation
}

/// Limits: 256 KiB encoded JSON per owning scope, maximum optional JSON depth 32.
/// Unknown required semantics are never granted write authority by preservation.
public struct PersistencePayload: Codable, Equatable, Sendable {
    public var version: Int
    public var requiredFeatures: [String]
    public var properties: [String: JSONValue]
    public var unknownFields: [String: JSONValue]
    public init(version: Int = 1, requiredFeatures: [String] = [], properties: [String: JSONValue] = [:]) {
        self.version = version; self.requiredFeatures = requiredFeatures; self.properties = properties; unknownFields = [:]
    }
    public func validateWritable(allowAnnotations: Bool = false) throws {
        guard version == 1 else { throw PersistencePayloadError.unsupportedVersion(version) }
        for feature in requiredFeatures where feature != "annotationsV1" || !allowAnnotations { throw PersistencePayloadError.requiredFeature(feature) }
        try validateOptionalFields(properties)
        try validateOptionalFields(unknownFields)
        guard try JSONEncoder().encode(self).count <= 262_144 else { throw PersistencePayloadError.limitExceeded }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        version = try c.decode(Int.self, forKey: .init("version"))
        requiredFeatures = try c.decodeIfPresent([String].self, forKey: .init("requiredFeatures")) ?? []
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .init("properties")) ?? [:]
        unknownFields = try decodeUnknownFields(c, known: ["version", "requiredFeatures", "properties"])
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(version, forKey: .init("version")); try c.encode(requiredFeatures, forKey: .init("requiredFeatures")); try c.encode(properties, forKey: .init("properties"))
        try encodeUnknownFields(unknownFields, known: ["version", "requiredFeatures", "properties"], into: &c)
    }
}

struct PersistenceCodingKey: CodingKey {
    var stringValue: String; var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
func validateOptionalFields(_ fields: [String: JSONValue]) throws {
    try JSONValue.object(fields).validate()
    guard try JSONEncoder().encode(fields).count <= 262_144 else { throw PersistencePayloadError.limitExceeded }
}
func validateUnknownScope(_ fields: [String: JSONValue], known: Set<String>) throws {
    try validateOptionalFields(fields)
    for key in fields.keys where known.contains(key) { throw PersistencePayloadError.fieldCollision(key) }
}
func decodeUnknownFields(_ container: KeyedDecodingContainer<PersistenceCodingKey>, known: Set<String>) throws -> [String: JSONValue] {
    var fields: [String: JSONValue] = [:]
    for key in container.allKeys where !known.contains(key.stringValue) { fields[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
    try validateOptionalFields(fields)
    return fields
}
func encodeUnknownFields(_ fields: [String: JSONValue], known: Set<String>, into container: inout KeyedEncodingContainer<PersistenceCodingKey>) throws {
    try validateOptionalFields(fields)
    for (key, value) in fields {
        guard !known.contains(key) else { throw PersistencePayloadError.fieldCollision(key) }
        try container.encode(value, forKey: .init(key))
    }
}

/// Stable UUID plus a string-backed type permits future entity kinds without title matching.
public struct EntityIdentity: Codable, Equatable, Sendable {
    public var kind: String
    public var id: UUID
    public init(kind: String, id: UUID) { self.kind = kind; self.id = id }
}
public struct TypedEntityReference: Codable, Equatable, Sendable {
    public var id: UUID
    public var origin: EntityIdentity
    public var target: EntityIdentity
    public var designation: String
    public var payload: PersistencePayload?
    public init(id: UUID = UUID(), origin: EntityIdentity, target: EntityIdentity, designation: String, payload: PersistencePayload? = nil) {
        self.id = id; self.origin = origin; self.target = target; self.designation = designation; self.payload = payload
    }
}
public enum AnnotationDisposition: String, Codable, Sendable { case resolved, stale, deleted }
public enum AnnotationAffinity: String, Codable, Sendable { case before, after }
public struct InlineAnnotationTarget: Codable, Equatable, Sendable {
    public var version = 1
    public var start: Int
    public var end: Int
    public var startAffinity: AnnotationAffinity = .after
    public var endAffinity: AnnotationAffinity = .before
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var digest: String
    public init(text: String, range: NSRange, revision: Data) throws {
        guard Self.validRange(range, in: text) else { throw PersistencePayloadError.invalidAnnotation }
        start = range.location; end = range.location + range.length
        quote = (text as NSString).substring(with: range)
        let before = (text as NSString).substring(to: start), after = (text as NSString).substring(from: end)
        prefix = String(before.suffix(64)); suffix = String(after.prefix(64))
        digest = Self.evidence(quote: quote, revision: revision)
    }
    static func evidence(quote: String, revision: Data) -> String {
        var bytes = Data(quote.utf8); bytes.append(0); bytes.append(revision); return VaultCoreDigest(bytes)
    }
    public static func validRange(_ range: NSRange, in text: String) -> Bool {
        guard range.location >= 0, range.length >= 0, range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return false }
        var boundaries: Set<Int> = [0]; var offset = 0
        for character in text { offset += String(character).utf16.count; boundaries.insert(offset) }
        return boundaries.contains(range.location) && boundaries.contains(range.location + range.length)
    }
}
private func VaultCoreDigest(_ bytes: Data) -> String { digest(bytes) }
public struct InlineAnnotation: Codable, Equatable, Sendable {
    public var id: UUID
    public var pageID: UUID
    public var blockID: UUID
    public var designation: String
    public var targetEntity: EntityIdentity?
    public var payload: PersistencePayload?
    public var createdAt: Date
    public var modifiedAt: Date
    public var expectedRevision: Data
    public var target: InlineAnnotationTarget
    public var disposition: AnnotationDisposition
    public init(id: UUID = UUID(), pageID: UUID, blockID: UUID, designation: String, expectedRevision: Data, target: InlineAnnotationTarget, disposition: AnnotationDisposition = .resolved) {
        self.id = id; self.pageID = pageID; self.blockID = blockID; self.designation = designation; self.expectedRevision = expectedRevision; self.target = target; self.disposition = disposition
        createdAt = Date(); modifiedAt = createdAt
    }
}

extension BlockDocument {
    public func validateWritablePayloads(requireKnownBlockKinds: Bool = true) throws {
        guard !unsupportedVersion else { throw PersistencePayloadError.unsupportedVersion(-1) }
        try extensions?.validateWritable(allowAnnotations: true); try validateUnknownScope(unknownFields, known: Self.persistenceKeys)
        for block in flattened {
            guard !requireKnownBlockKinds || [BlockKind.paragraph, .heading1, .heading2, .heading3, .bullet, .numbered, .task, .quote, .code, .math, .divider, .callout, .toggle].contains(block.kind) else { throw PersistencePayloadError.unsupportedBlockKind(block.kind.rawValue) }
            try block.extensions?.validateWritable(); try validateUnknownScope(block.unknownFields, known: EditorBlock.persistenceKeys)
            try block.metadata.extensions?.validateWritable(); try validateUnknownScope(block.metadata.unknownFields, known: BlockMetadata.persistenceKeys)
            for run in block.runs {
                try run.extensions?.validateWritable(); try validateUnknownScope(run.unknownFields, known: RichRun.persistenceKeys)
                try run.style.extensions?.validateWritable(); try validateUnknownScope(run.style.unknownFields, known: InlineStyle.persistenceKeys)
            }
        }
        if let records = extensions?.properties["annotations"] {
            guard case .array(let values) = records else { throw PersistencePayloadError.invalidAnnotation }
            var ids: Set<UUID> = []
            for value in values {
                let annotation = try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value))
                guard ids.insert(annotation.id).inserted, annotation.target.version == 1, annotation.target.prefix.count <= 64, annotation.target.suffix.count <= 64 else { throw PersistencePayloadError.invalidAnnotation }
                try annotation.payload?.validateWritable()
                if annotation.disposition == .resolved {
                    guard let owner = block(annotation.blockID), annotation.target.end >= annotation.target.start else { throw PersistencePayloadError.invalidAnnotation }
                    let range = NSRange(location: annotation.target.start, length: annotation.target.end - annotation.target.start)
                    guard InlineAnnotationTarget.validRange(range, in: owner.text), (owner.text as NSString).substring(with: range) == annotation.target.quote,
                          annotation.target.digest == InlineAnnotationTarget.evidence(quote: annotation.target.quote, revision: annotation.expectedRevision) else { throw PersistencePayloadError.invalidAnnotation }
                }
            }
        }
    }
    /// A new-page annotation uses an empty revision until its create-only transaction
    /// issues the first canonical revision. Existing resolved anchors require exact evidence.
    public func validatingAnnotations(pageID: UUID, expectedRevision: BlockStoreRevision?) throws {
        guard case .array(let records) = extensions?.properties["annotations"] else { return }
        for value in records {
            let annotation = try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value))
            guard annotation.pageID == pageID else { throw PersistencePayloadError.invalidAnnotation }
            if annotation.disposition == .resolved {
                guard annotation.expectedRevision == (expectedRevision?.token ?? Data()) else { throw PersistencePayloadError.invalidAnnotation }
            }
        }
    }
    /// Call inside the same page transaction after verifying prior revision evidence.
    /// Only resolved anchors advance; stale/deleted evidence remains untouched.
    public func advancingAnnotationRevision(to revision: BlockStoreRevision) -> BlockDocument {
        guard case .array(let records) = extensions?.properties["annotations"] else { return self }
        var copy = self
        copy.extensions?.properties["annotations"] = .array(records.map { value in
            guard case .object(var fields) = value, fields["disposition"] == .string("resolved"),
                  case .object(var target) = fields["target"], case .string(let quote) = target["quote"] else { return value }
            fields["expectedRevision"] = .string(revision.token.base64EncodedString())
            target["digest"] = .string(InlineAnnotationTarget.evidence(quote: quote, revision: revision.token))
            fields["target"] = .object(target)
            return .object(fields)
        })
        return copy
    }
    /// Bare replacements cannot safely infer anchor survival. Keep original evidence.
    public func preparingAnnotationsForPersistence(comparedTo previous: BlockDocument) -> BlockDocument {
        guard case .array(let records) = extensions?.properties["annotations"] else { return self }
        var copy = self
        copy.extensions?.properties["annotations"] = .array(records.map { value in
            guard case .object(var fields) = value,
                  case .string(let id) = fields["blockID"], let blockID = UUID(uuidString: id),
                  fields["disposition"] == .string("resolved") else { return value }
            if block(blockID) == nil { fields["disposition"] = .string("deleted") }
            else if previous.block(blockID)?.text != block(blockID)?.text { fields["disposition"] = .string("stale") }
            return .object(fields)
        })
        return copy
    }
}

extension InlineStyle {
    fileprivate static var persistenceKeys: Set<String> { ["extensions", "bold", "italic", "underline", "strike", "code", "math", "rawMath", "highlight", "link", "wikiTarget"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        extensions = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        bold = try c.decodeIfPresent(Bool.self, forKey: .init("bold")) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .init("italic")) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .init("underline")) ?? false
        strike = try c.decodeIfPresent(Bool.self, forKey: .init("strike")) ?? false
        code = try c.decodeIfPresent(Bool.self, forKey: .init("code")) ?? false
        math = try c.decodeIfPresent(Bool.self, forKey: .init("math")) ?? false
        rawMath = try c.decodeIfPresent(String.self, forKey: .init("rawMath"))
        highlight = try c.decodeIfPresent(Bool.self, forKey: .init("highlight")) ?? false
        link = try c.decodeIfPresent(String.self, forKey: .init("link"))
        wikiTarget = try c.decodeIfPresent(String.self, forKey: .init("wikiTarget"))
        unknownFields = try decodeUnknownFields(c, known: Self.persistenceKeys)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encodeIfPresent(extensions, forKey: .init("extensions"))
        try c.encode(bold, forKey: .init("bold"))
        try c.encode(italic, forKey: .init("italic"))
        try c.encode(underline, forKey: .init("underline"))
        try c.encode(strike, forKey: .init("strike"))
        try c.encode(code, forKey: .init("code"))
        try c.encode(math, forKey: .init("math"))
        try c.encodeIfPresent(rawMath, forKey: .init("rawMath"))
        try c.encode(highlight, forKey: .init("highlight"))
        try c.encodeIfPresent(link, forKey: .init("link"))
        try c.encodeIfPresent(wikiTarget, forKey: .init("wikiTarget"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &c)
    }
}

extension RichRun {
    fileprivate static var persistenceKeys: Set<String> { ["extensions", "text", "style"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        extensions = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        text = try c.decode(String.self, forKey: .init("text"))
        style = try c.decode(InlineStyle.self, forKey: .init("style"))
        unknownFields = try decodeUnknownFields(c, known: Self.persistenceKeys)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encodeIfPresent(extensions, forKey: .init("extensions"))
        try c.encode(text, forKey: .init("text"))
        try c.encode(style, forKey: .init("style"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &c)
    }
}

extension BlockMetadata {
    fileprivate static var persistenceKeys: Set<String> { ["extensions", "semantic", "status", "checked", "collapsed", "language", "icon", "extra"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        extensions = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        semantic = try c.decodeIfPresent(String.self, forKey: .init("semantic"))
        status = try c.decodeIfPresent(String.self, forKey: .init("status"))
        checked = try c.decodeIfPresent(Bool.self, forKey: .init("checked")) ?? false
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .init("collapsed")) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .init("language"))
        icon = try c.decodeIfPresent(String.self, forKey: .init("icon"))
        extra = try c.decodeIfPresent([String:String].self, forKey: .init("extra")) ?? [:]
        unknownFields = try decodeUnknownFields(c, known: Self.persistenceKeys)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encodeIfPresent(extensions, forKey: .init("extensions"))
        try c.encodeIfPresent(semantic, forKey: .init("semantic"))
        try c.encodeIfPresent(status, forKey: .init("status"))
        try c.encode(checked, forKey: .init("checked"))
        try c.encode(collapsed, forKey: .init("collapsed"))
        try c.encodeIfPresent(language, forKey: .init("language"))
        try c.encodeIfPresent(icon, forKey: .init("icon"))
        try c.encode(extra, forKey: .init("extra"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &c)
    }
}

extension EditorBlock {
    fileprivate static var persistenceKeys: Set<String> { ["extensions", "id", "kind", "runs", "metadata", "children", "createdAt", "modifiedAt", "originalMarkdown", "originalSignature", "originalIndentation", "originalDepth"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        extensions = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        id = try c.decode(UUID.self, forKey: .init("id"))
        kind = try c.decode(BlockKind.self, forKey: .init("kind"))
        runs = try c.decode([RichRun].self, forKey: .init("runs"))
        metadata = try c.decode(BlockMetadata.self, forKey: .init("metadata"))
        children = try c.decode([EditorBlock].self, forKey: .init("children"))
        createdAt = try c.decode(Date.self, forKey: .init("createdAt"))
        modifiedAt = try c.decode(Date.self, forKey: .init("modifiedAt"))
        originalMarkdown = try c.decodeIfPresent(String.self, forKey: .init("originalMarkdown"))
        originalSignature = try c.decodeIfPresent(String.self, forKey: .init("originalSignature"))
        originalIndentation = try c.decodeIfPresent(String.self, forKey: .init("originalIndentation"))
        originalDepth = try c.decodeIfPresent(Int.self, forKey: .init("originalDepth"))
        unknownFields = try decodeUnknownFields(c, known: Self.persistenceKeys)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encodeIfPresent(extensions, forKey: .init("extensions"))
        try c.encode(id, forKey: .init("id"))
        try c.encode(kind, forKey: .init("kind"))
        try c.encode(runs, forKey: .init("runs"))
        try c.encode(metadata, forKey: .init("metadata"))
        try c.encode(children, forKey: .init("children"))
        try c.encode(createdAt, forKey: .init("createdAt"))
        try c.encode(modifiedAt, forKey: .init("modifiedAt"))
        try c.encodeIfPresent(originalMarkdown, forKey: .init("originalMarkdown"))
        try c.encodeIfPresent(originalSignature, forKey: .init("originalSignature"))
        try c.encodeIfPresent(originalIndentation, forKey: .init("originalIndentation"))
        try c.encodeIfPresent(originalDepth, forKey: .init("originalDepth"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &c)
    }
}

extension BlockDocument {
    fileprivate static var persistenceKeys: Set<String> { ["extensions", "blocks", "trailingNewline", "recoveredMetadata", "unsupportedVersion", "originalSource"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        extensions = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("extensions"))
        blocks = try c.decode([EditorBlock].self, forKey: .init("blocks"))
        trailingNewline = try c.decode(Bool.self, forKey: .init("trailingNewline"))
        recoveredMetadata = try c.decodeIfPresent(String.self, forKey: .init("recoveredMetadata"))
        unsupportedVersion = try c.decodeIfPresent(Bool.self, forKey: .init("unsupportedVersion")) ?? false
        originalSource = try c.decodeIfPresent(String.self, forKey: .init("originalSource"))
        unknownFields = try decodeUnknownFields(c, known: Self.persistenceKeys)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encodeIfPresent(extensions, forKey: .init("extensions"))
        try c.encode(blocks, forKey: .init("blocks"))
        try c.encode(trailingNewline, forKey: .init("trailingNewline"))
        try c.encodeIfPresent(recoveredMetadata, forKey: .init("recoveredMetadata"))
        try c.encode(unsupportedVersion, forKey: .init("unsupportedVersion"))
        try c.encodeIfPresent(originalSource, forKey: .init("originalSource"))
        try encodeUnknownFields(unknownFields, known: Self.persistenceKeys, into: &c)
    }
}
