import Foundation

public enum SemanticReferentDisposition: String, Codable, Sendable { case live, tombstoned, unresolved }
public enum SemanticQuestionStatus: String, Codable, Sendable { case unanswered, answered }
public enum SemanticLocation: Codable, Equatable, Sendable {
    case wholeBlock(pageID: UUID, blockID: UUID)
    case inline(pageID: UUID, blockID: UUID, target: InlineAnnotationTarget)
    case entity(id: UUID)
    case object(id: UUID)
    public var pageID: UUID? { switch self { case .wholeBlock(let p, _), .inline(let p, _, _): p; default: nil } }
    public var blockID: UUID? { switch self { case .wholeBlock(_, let b), .inline(_, let b, _): b; default: nil } }
}
public struct SemanticReferent: Codable, Equatable, Sendable {
    public var identity: EntityIdentity
    public var unknownFields: [String: JSONValue] = [:]
    public var identityUnknownFields: [String: JSONValue] = [:]
    public var disposition: SemanticReferentDisposition
    public var payload: PersistencePayload?
    public init(identity: EntityIdentity, disposition: SemanticReferentDisposition = .live, payload: PersistencePayload? = nil) {
        self.identity = identity; self.disposition = disposition; self.payload = payload
    }
}
public struct SemanticObject: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var typeKey: String
    public var properties: PersistencePayload
    public var questionStatus: SemanticQuestionStatus
    public var answerText: String?
    public var definitionText: String?
    public var term: String?
    public var relatedEntityIDs: [UUID]
    public var subjectEntityID: UUID?
    public var lifecycle: KnowledgeLifecycle
    public var createdAt: Date
    public var modifiedAt: Date
    public var unknownFields: [String: JSONValue] = [:]
    public init(id: UUID = UUID(), typeKey: String, properties: PersistencePayload = .init(), questionStatus: SemanticQuestionStatus = .unanswered,
                answerText: String? = nil, definitionText: String? = nil, term: String? = nil, relatedEntityIDs: [UUID] = [], subjectEntityID: UUID? = nil,
                lifecycle: KnowledgeLifecycle = .live, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.typeKey = typeKey; self.properties = properties; self.questionStatus = questionStatus
        self.answerText = answerText; self.definitionText = definitionText; self.term = term
        self.relatedEntityIDs = relatedEntityIDs; self.subjectEntityID = subjectEntityID; self.lifecycle = lifecycle
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
    public func validateWritable() throws {
        guard ["question", "definition"].contains(typeKey) else { throw KnowledgeStoreError.unknownType(typeKey) }
        if typeKey == "question" {
            guard subjectEntityID == nil, definitionText == nil, term == nil else { throw KnowledgeStoreError.invalidProperty("question") }
            if questionStatus == .answered { guard !(answerText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KnowledgeStoreError.invalidProperty("answerText") } }
        } else {
            guard !(definitionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answerText == nil else { throw KnowledgeStoreError.invalidProperty("definitionText") }
        }
        guard Set(relatedEntityIDs).count == relatedEntityIDs.count else { throw KnowledgeStoreError.identityConflict(id) }
        try properties.validateWritable(); try validateUnknownScope(unknownFields, known: Self.keys)
        guard unknownFields["revision"] == nil else { throw KnowledgeStoreError.invalidProperty("revision") }
        for key in ["id", "typeKey", "revision", "lifecycle", "relatedEntityIDs", "subjectEntityID", "createdAt", "modifiedAt"] where properties.properties[key] != nil || properties.unknownFields[key] != nil { throw KnowledgeStoreError.invalidProperty(key) }
    }
}
public struct SemanticObjectPatch: Equatable, Sendable {
    public var questionStatus: SemanticQuestionStatus?
    public var answerText: String?
    public var definitionText: String?
    public var term: String?
    public var properties: [String: JSONValue]
    public init(questionStatus: SemanticQuestionStatus? = nil, answerText: String? = nil, definitionText: String? = nil, term: String? = nil, properties: [String: JSONValue] = [:]) {
        self.questionStatus = questionStatus; self.answerText = answerText; self.definitionText = definitionText; self.term = term; self.properties = properties
    }
    public func applying(to object: SemanticObject) throws -> SemanticObject {
        var value = object
        if let questionStatus { value.questionStatus = questionStatus }; if let answerText { value.answerText = answerText }
        if let definitionText { value.definitionText = definitionText }; if let term { value.term = term }
        value.properties.properties.merge(properties) { _, v in v }; try value.validateWritable(); return value
    }
}
public struct SemanticAnnotation: Codable, Equatable, Sendable, Identifiable {
    public var locationUnknownFields: [String: JSONValue] = [:]
    public var id: UUID
    public var location: SemanticLocation
    public var referent: SemanticReferent
    public var designation: String
    public var anchorDisposition: AnnotationDisposition
    public var expectedRevision: Data
    public var payload: PersistencePayload?
    public var createdAt: Date
    public var modifiedAt: Date
    public var unknownFields: [String: JSONValue] = [:]
    public init(id: UUID = UUID(), location: SemanticLocation, referent: SemanticReferent, designation: String,
                anchorDisposition: AnnotationDisposition = .resolved, expectedRevision: Data = Data(), payload: PersistencePayload? = nil,
                createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.location = location; self.referent = referent; self.designation = designation
        self.anchorDisposition = anchorDisposition; self.expectedRevision = expectedRevision; self.payload = payload
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}
public struct SemanticObjectSnapshot: Equatable, Sendable {
    public let object: SemanticObject
    public let revision: BlockStoreRevision
    public init(object: SemanticObject, revision: BlockStoreRevision) { self.object = object; self.revision = revision }
}
public struct SemanticAnnotationSnapshot: Equatable, Sendable {
    public let annotation: SemanticAnnotation
    public let revision: BlockStoreRevision
    public init(annotation: SemanticAnnotation, revision: BlockStoreRevision) { self.annotation = annotation; self.revision = revision }
}
public struct SemanticPageSnapshot: Equatable, Sendable {
    public let snapshot: BlockStoreSnapshot
    public let annotations: [SemanticAnnotationSnapshot]
    public init(snapshot: BlockStoreSnapshot, annotations: [SemanticAnnotationSnapshot]) { self.snapshot = snapshot; self.annotations = annotations }
}
public struct SemanticPageEdit: Equatable, Sendable {
    public var pageID: UUID
    public var document: BlockDocument
    public var annotations: [SemanticAnnotation]
    public var expectedAnnotationRevisions: [UUID: BlockStoreRevision]
    public var objects: [SemanticObject]
    var semanticMutationEvidence: AnnotationMutationEvidence? = nil
    public init(pageID: UUID, document: BlockDocument, annotations: [SemanticAnnotation], expectedAnnotationRevisions: [UUID: BlockStoreRevision] = [:], objects: [SemanticObject] = []) {
        self.pageID = pageID; self.document = document; self.annotations = annotations; self.expectedAnnotationRevisions = expectedAnnotationRevisions; self.objects = objects
    }
}
public enum SemanticQuestionAssociation: Sendable { case explicit, derivedOccurrences }
public protocol SemanticStore: Sendable {
    func saveAnnotation(_ annotation: SemanticAnnotation, condition: BlockStoreWriteCondition, expectedOwnerRevision: BlockStoreRevision, expectedReferentRevision: BlockStoreRevision?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<SemanticAnnotationSnapshot>
    func transitionAnnotation(id: UUID, to: AnnotationDisposition, expected: BlockStoreRevision, expectedOwnerRevision: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<SemanticAnnotationSnapshot>
    func occurrences(entityID: UUID) async throws -> [SemanticAnnotationSnapshot]
    func objects(pageID: UUID) async throws -> [SemanticObjectSnapshot]
    func annotations(pageID: UUID, blockID: UUID?) async throws -> [SemanticAnnotationSnapshot]
    func questions(entityID: UUID, association: SemanticQuestionAssociation) async throws -> [SemanticObjectSnapshot]
    func annotationsNeedingReview() async throws -> [SemanticAnnotationSnapshot]
    func createObject(_ object: SemanticObject, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<SemanticObjectSnapshot>
    func loadObject(id: UUID) async throws -> SemanticObjectSnapshot
    func updateObject(id: UUID, patch: SemanticObjectPatch, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<SemanticObjectSnapshot>
    func transitionObject(id: UUID, to: KnowledgeLifecycle, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<SemanticObjectSnapshot>
    func loadSemanticPage(pageID: UUID) async throws -> SemanticPageSnapshot
    func saveSemanticPage(_ edit: SemanticPageEdit, condition: BlockStoreWriteCondition, expectedObjectRevisions: [UUID: BlockStoreRevision], expectedEntityRevisions: [UUID: BlockStoreRevision], expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<SemanticPageSnapshot>
}

extension SemanticObject {
    private static let keys: Set<String> = ["id", "typeKey", "properties", "questionStatus", "answerText", "definitionText", "term", "relatedEntityIDs", "subjectEntityID", "lifecycle", "createdAt", "modifiedAt"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try c.decode(UUID.self, forKey: .init("id"))
        typeKey = try c.decode(String.self, forKey: .init("typeKey"))
        properties = try c.decode(PersistencePayload.self, forKey: .init("properties"))
        questionStatus = try c.decode(SemanticQuestionStatus.self, forKey: .init("questionStatus"))
        answerText = try c.decodeIfPresent(String.self, forKey: .init("answerText"))
        definitionText = try c.decodeIfPresent(String.self, forKey: .init("definitionText"))
        term = try c.decodeIfPresent(String.self, forKey: .init("term"))
        relatedEntityIDs = try c.decode([UUID].self, forKey: .init("relatedEntityIDs"))
        subjectEntityID = try c.decodeIfPresent(UUID.self, forKey: .init("subjectEntityID"))
        lifecycle = try c.decode(KnowledgeLifecycle.self, forKey: .init("lifecycle"))
        createdAt = try c.decode(Date.self, forKey: .init("createdAt"))
        modifiedAt = try c.decode(Date.self, forKey: .init("modifiedAt"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(id, forKey: .init("id"))
        try c.encode(typeKey, forKey: .init("typeKey"))
        try c.encode(properties, forKey: .init("properties"))
        try c.encode(questionStatus, forKey: .init("questionStatus"))
        try c.encodeIfPresent(answerText, forKey: .init("answerText"))
        try c.encodeIfPresent(definitionText, forKey: .init("definitionText"))
        try c.encodeIfPresent(term, forKey: .init("term"))
        try c.encode(relatedEntityIDs, forKey: .init("relatedEntityIDs"))
        try c.encodeIfPresent(subjectEntityID, forKey: .init("subjectEntityID"))
        try c.encode(lifecycle, forKey: .init("lifecycle"))
        try c.encode(createdAt, forKey: .init("createdAt"))
        try c.encode(modifiedAt, forKey: .init("modifiedAt"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}

extension SemanticAnnotation {
    private static let keys: Set<String> = ["id", "location", "referent", "designation", "anchorDisposition", "expectedRevision", "payload", "createdAt", "modifiedAt"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try c.decode(UUID.self, forKey: .init("id"))
        location = try c.decode(SemanticLocation.self, forKey: .init("location"))
        let originalLocation = try c.decode([String: JSONValue].self, forKey:.init("location"))
        let canonicalLocation = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(location))
        locationUnknownFields = [:]
        for (key, value) in originalLocation {
            if canonicalLocation[key] == nil { locationUnknownFields[key] = value }
            else if case .object(let current) = canonicalLocation[key], case .object(let original) = value { let unknown = original.filter { current[$0.key] == nil }; if !unknown.isEmpty { locationUnknownFields[key] = .object(unknown) } }
        }
        referent = try c.decode(SemanticReferent.self, forKey: .init("referent"))
        designation = try c.decode(String.self, forKey: .init("designation"))
        anchorDisposition = try c.decode(AnnotationDisposition.self, forKey: .init("anchorDisposition"))
        expectedRevision = try c.decode(Data.self, forKey: .init("expectedRevision"))
        payload = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("payload"))
        createdAt = try c.decode(Date.self, forKey: .init("createdAt"))
        modifiedAt = try c.decode(Date.self, forKey: .init("modifiedAt"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(id, forKey: .init("id"))
        var rawLocation = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(location))
        for (key, value) in locationUnknownFields {
            if rawLocation[key] == nil { rawLocation[key] = value }
            else if case .object(var current) = rawLocation[key], case .object(let original) = value { for (field, item) in original where current[field] == nil { current[field] = item }; rawLocation[key] = .object(current) }
        }
        try validateOptionalFields(rawLocation)
        try c.encode(rawLocation, forKey: .init("location"))
        try c.encode(referent, forKey: .init("referent"))
        try c.encode(designation, forKey: .init("designation"))
        try c.encode(anchorDisposition, forKey: .init("anchorDisposition"))
        try c.encode(expectedRevision, forKey: .init("expectedRevision"))
        try c.encodeIfPresent(payload, forKey: .init("payload"))
        try c.encode(createdAt, forKey: .init("createdAt"))
        try c.encode(modifiedAt, forKey: .init("modifiedAt"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}

extension SemanticReferent {
    private static let keys: Set<String> = ["identity", "disposition", "payload"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        identity = try c.decode(EntityIdentity.self, forKey:.init("identity"))
        disposition = try c.decode(SemanticReferentDisposition.self, forKey:.init("disposition"))
        payload = try c.decodeIfPresent(PersistencePayload.self, forKey:.init("payload"))
        unknownFields = try decodeUnknownFields(c, known:Self.keys)
        identityUnknownFields = try c.decode([String: JSONValue].self, forKey:.init("identity")).filter { !["kind","id"].contains($0.key) }
        try validateOptionalFields(identityUnknownFields)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy:PersistenceCodingKey.self)
        var fields = identityUnknownFields
        guard fields["id"] == nil, fields["kind"] == nil else { throw PersistencePayloadError.invalidAnnotation }
        fields["id"] = .string(identity.id.uuidString); fields["kind"] = .string(identity.kind)
        try validateOptionalFields(fields)
        try c.encode(fields,forKey:.init("identity")); try c.encode(disposition,forKey:.init("disposition")); try c.encodeIfPresent(payload,forKey:.init("payload"))
        try encodeUnknownFields(unknownFields,known:Self.keys,into:&c)
    }
}
