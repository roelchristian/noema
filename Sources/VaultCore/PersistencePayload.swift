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
        if let proof = annotationMutationEvidence, proof.before == previous.annotationEvidenceDigest(), proof.after == annotationEvidenceDigest() { return self }
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

struct AnnotationMutationEvidence: Equatable, Sendable {
    var before: String
    var after: String
}

extension BlockDocument {
    public static func == (lhs: BlockDocument, rhs: BlockDocument) -> Bool {
        lhs.extensions == rhs.extensions && lhs.unknownFields == rhs.unknownFields && lhs.blocks == rhs.blocks
            && lhs.trailingNewline == rhs.trailingNewline && lhs.recoveredMetadata == rhs.recoveredMetadata
            && lhs.unsupportedVersion == rhs.unsupportedVersion && lhs.originalSource == rhs.originalSource
    }
    func annotationEvidenceDigest() -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map(digest) ?? "invalid"
    }
    mutating func recordAnnotationMutation(from previous: BlockDocument) {
        let baseline = previous.annotationMutationEvidence.flatMap { $0.after == previous.annotationEvidenceDigest() ? $0.before : nil }
        annotationMutationEvidence = .init(before: baseline ?? previous.annotationEvidenceDigest(), after: annotationEvidenceDigest())
    }
    private func annotationFields(_ annotation: InlineAnnotation, preserving original: JSONValue) -> JSONValue {
        guard case .object(var fields) = original,
              let encoded = try? JSONEncoder().encode(annotation),
              case .object(let changed) = try? JSONDecoder().decode(JSONValue.self, from: encoded) else { return original }
        for key in ["id", "blockID", "target", "disposition", "modifiedAt", "payload", "targetEntity"] {
            if let value = changed[key] {
                if key == "target", case .object(let updates) = value, case .object(var old) = fields[key] {
                    old.merge(updates) { _, new in new }; fields[key] = .object(old)
                } else { fields[key] = value }
            } else { fields.removeValue(forKey: key) }
        }
        return .object(fields)
    }
    private func verified(_ annotation: InlineAnnotation, in previous: BlockDocument) -> Bool {
        guard let owner = previous.block(annotation.blockID), annotation.target.version == 1,
              annotation.target.end >= annotation.target.start else { return false }
        let range = NSRange(location: annotation.target.start, length: annotation.target.end - annotation.target.start)
        return InlineAnnotationTarget.validRange(range, in: owner.text)
            && (owner.text as NSString).substring(with: range) == annotation.target.quote
            && annotation.target.digest == InlineAnnotationTarget.evidence(quote: annotation.target.quote, revision: annotation.expectedRevision)
    }
    private func retarget(_ annotation: inout InlineAnnotation, blockID: UUID, start: Int, end: Int) {
        guard let owner = block(blockID), let target = try? InlineAnnotationTarget(text: owner.text, range: NSRange(location: start, length: end - start), revision: annotation.expectedRevision) else {
            annotation.disposition = .stale; return
        }
        var updatedTarget = target
        updatedTarget.startAffinity = annotation.target.startAffinity; updatedTarget.endAffinity = annotation.target.endAffinity
        annotation.blockID = blockID; annotation.target = updatedTarget; annotation.modifiedAt = Date()
    }
    mutating func transformAnnotations(for command: BlockMutation, owner: UUID, cursor: BlockCursor, previous: BlockDocument) {
        guard case .array(let records) = extensions?.properties["annotations"] else { return }
        var transformed: [JSONValue] = []
        var duplicateIDs: [UUID: UUID] = [:]
        if case .duplicate = command, let source = previous.block(owner), let copy = block(cursor.id) {
            func pair(_ source: EditorBlock, _ copy: EditorBlock) {
                duplicateIDs[source.id] = copy.id
                for (a, b) in zip(source.children, copy.children) { pair(a, b) }
            }
            pair(source, copy)
        }
        for value in records {
            guard var annotation = try? JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value)) else { transformed.append(value); continue }
            if let copiedBlock = duplicateIDs[annotation.blockID] {
                transformed.append(value)
                let originalID = annotation.id, originalBlock = annotation.blockID
                annotation.id = UUID(); annotation.blockID = copiedBlock
                annotation.createdAt = Date(); annotation.modifiedAt = annotation.createdAt
                var payload = annotation.payload ?? .init()
                payload.properties["copiedFromAnnotationID"] = .string(originalID.uuidString)
                payload.properties["copiedFromBlockID"] = .string(originalBlock.uuidString)
                // No designation currently grants semantic-target copying authority.
                if let target = annotation.targetEntity, let bytes = try? JSONEncoder().encode(target), let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) { payload.properties["copiedTargetEntity"] = value }
                annotation.targetEntity = nil; annotation.payload = payload
                var copy = annotationFields(annotation, preserving: value)
                if case .object(var fields) = copy, let data = try? JSONEncoder().encode(annotation.createdAt), let created = try? JSONDecoder().decode(JSONValue.self, from: data) { fields["createdAt"] = created; copy = .object(fields) }
                transformed.append(copy); continue
            }
            guard annotation.disposition == .resolved else { transformed.append(value); continue }
            guard verified(annotation, in: previous) else { annotation.disposition = .stale; transformed.append(annotationFields(annotation, preserving: value)); continue }
            switch command {
            case .split(let requested) where annotation.blockID == owner && cursor.id != owner:
                let offset = min(max(requested, 0), previous.block(owner)!.utf16Count)
                if annotation.target.start >= offset && (annotation.target.start != annotation.target.end || annotation.target.startAffinity == .after) {
                    retarget(&annotation, blockID: cursor.id, start: annotation.target.start - offset, end: annotation.target.end - offset)
                } else if annotation.target.end <= offset {
                    retarget(&annotation, blockID: owner, start: annotation.target.start, end: annotation.target.end)
                } else { annotation.disposition = .stale }
            case .mergeBackward where cursor.id != owner && annotation.blockID == owner:
                retarget(&annotation, blockID: cursor.id, start: annotation.target.start + cursor.offset, end: annotation.target.end + cursor.offset)
            default:
                if block(annotation.blockID) == nil { annotation.disposition = .deleted }
                else if previous.block(annotation.blockID)?.text != block(annotation.blockID)?.text {
                    // Only a merge extends the survivor while preserving its original prefix.
                    if case .mergeBackward = command, annotation.blockID == cursor.id {
                        retarget(&annotation, blockID: cursor.id, start: annotation.target.start, end: annotation.target.end)
                    } else { annotation.disposition = .stale }
                }
            }
            transformed.append(annotationFields(annotation, preserving: value))
        }
        extensions?.properties["annotations"] = .array(transformed)
        recordAnnotationMutation(from: previous)
    }

    /// Exact revision-checked text editing; offsets address concatenated UTF-16 text
    /// and must be extended-grapheme boundaries. Replacement intersections stale.
    public mutating func replaceText(in blockID: UUID, range: NSRange, with replacement: String, expectedRevision: BlockStoreRevision) throws {
        guard !unsupportedVersion, let owner = block(blockID), InlineAnnotationTarget.validRange(range, in: owner.text) else { throw PersistencePayloadError.invalidAnnotation }
        try validateWritablePayloads()
        let previous = self
        let values: [JSONValue]
        if case .array(let records) = extensions?.properties["annotations"] { values = records } else { values = [] }
        for value in values {
            let annotation = try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value))
            if annotation.disposition == .resolved, annotation.expectedRevision != expectedRevision.token { throw PersistencePayloadError.invalidAnnotation }
        }
        let suffixStart = range.location + range.length
        let inserted = replacement.isEmpty ? [] : [RichRun(replacement)]
        update(blockID) { block in
            block.runs = owner.slicing(NSRange(location: 0, length: range.location)) + inserted + owner.slicing(NSRange(location: suffixStart, length: owner.utf16Count - suffixStart))
        }
        let delta = replacement.utf16.count - range.length
        let transformedValues = try values.map { value in
            var annotation = try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value))
            guard annotation.blockID == blockID, annotation.disposition == .resolved else { return value }
            var start = annotation.target.start, end = annotation.target.end
            if range.length == 0 {
                if range.location < start || (range.location == start && annotation.target.startAffinity == .after) { start += delta }
                if range.location < end || (range.location == end && annotation.target.endAffinity == .after) { end += delta }
                if start > end { end = start }
                retarget(&annotation, blockID: blockID, start: start, end: end)
            } else if suffixStart <= start {
                retarget(&annotation, blockID: blockID, start: start + delta, end: end + delta)
            } else if range.location >= end {
                retarget(&annotation, blockID: blockID, start: start, end: end)
            } else { annotation.disposition = .stale }
            return annotationFields(annotation, preserving: value)
        }
        extensions?.properties["annotations"] = .array(transformedValues)
        originalSource = nil
        recordAnnotationMutation(from: previous)
    }
}
