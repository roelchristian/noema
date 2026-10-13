import Foundation

/// Knowledge identities are UUIDs; labels and aliases never identify a record.
public enum KnowledgeLifecycle: String, Codable, Sendable { case live, tombstoned }
public enum KnowledgeRelationDirection: String, Codable, Sendable { case outgoing, incoming, both }
public enum KnowledgeStoreError: Error, Equatable, Sendable {
    case notFound(UUID), identityConflict(UUID), staleRevision, unknownType(String), unknownPredicate(String)
    case invalidLabel, missingReference(UUID), tombstoned(UUID), unsupportedCapability(String)
    case unsupportedPayload, transitionRequired, leaseLost, invalidProperty(String)
}

public struct KnowledgeTypeDescriptor: Codable, Equatable, Sendable {
    public var key: String
    public var version: Int
    public var metadata: PersistencePayload
    public var unknownFields: [String: JSONValue] = [:]
    public init(key: String, version: Int = 1, metadata: PersistencePayload = .init()) {
        self.key = key; self.version = version; self.metadata = metadata
    }
    private static let keys: Set<String> = ["key", "version", "metadata"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        key = try c.decode(String.self, forKey: .init("key")); version = try c.decode(Int.self, forKey: .init("version"))
        metadata = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("metadata")) ?? .init()
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(key, forKey: .init("key")); try c.encode(version, forKey: .init("version"))
        try c.encode(metadata, forKey: .init("metadata"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}
public struct KnowledgeEntityType: Codable, Equatable, Sendable {
    public var descriptor: KnowledgeTypeDescriptor
    public var key: String { descriptor.key }
    public var version: Int { descriptor.version }
    public init(key: String, version: Int = 1, metadata: PersistencePayload = .init()) { descriptor = .init(key: key, version: version, metadata: metadata) }
    public static let initial: [Self] = ["person", "place", "concept", "event"].map { .init(key: $0) }
    public init(from decoder: any Decoder) throws { descriptor = try .init(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try descriptor.encode(to: encoder) }
}
public struct KnowledgeRelationType: Codable, Equatable, Sendable {
    public var descriptor: KnowledgeTypeDescriptor
    public var key: String { descriptor.key }
    public var version: Int { descriptor.version }
    public init(key: String, version: Int = 1, metadata: PersistencePayload = .init()) { descriptor = .init(key: key, version: version, metadata: metadata) }
    public static let initial: [Self] = [.init(key: "relatedTo")]
    public init(from decoder: any Decoder) throws { descriptor = try .init(from: decoder) }
    public func encode(to encoder: any Encoder) throws { try descriptor.encode(to: encoder) }
}

public struct KnowledgeAlias: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var label: String
    public var payload: PersistencePayload?
    public var unknownFields: [String: JSONValue] = [:]
    public init(id: UUID = UUID(), label: String, payload: PersistencePayload? = nil) {
        self.id = id; self.label = label; self.payload = payload
    }
    public func validateWritable() throws {
        try knowledgeValidateLabel(label)
        if let payload { try knowledgeValidateProperties(payload) }
        try validateUnknownScope(unknownFields, known: Self.keys)
    }
    private static let keys: Set<String> = ["id", "label", "payload"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try c.decode(UUID.self, forKey: .init("id"))
        label = try c.decode(String.self, forKey: .init("label"))
        payload = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("payload"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(id, forKey: .init("id")); try c.encode(label, forKey: .init("label"))
        try c.encodeIfPresent(payload, forKey: .init("payload"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}

public struct KnowledgeEntity: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var typeKey: String
    public var label: String
    public var description: String?
    public var aliases: [KnowledgeAlias]
    public var properties: PersistencePayload
    public var createdAt: Date
    public var modifiedAt: Date
    public var lifecycle: KnowledgeLifecycle
    public var unknownFields: [String: JSONValue] = [:]
    public init(id: UUID = UUID(), typeKey: String, label: String, description: String? = nil,
                aliases: [KnowledgeAlias] = [], properties: PersistencePayload = .init(),
                createdAt: Date = Date(), modifiedAt: Date = Date(), lifecycle: KnowledgeLifecycle = .live) {
        self.id = id; self.typeKey = typeKey; self.label = label; self.description = description
        self.aliases = aliases; self.properties = properties; self.createdAt = createdAt
        self.modifiedAt = modifiedAt; self.lifecycle = lifecycle
    }
    public func validateWritable() throws {
        guard KnowledgeEntityType.initial.contains(where: { $0.key == typeKey && $0.version == 1 }) else {
            throw KnowledgeStoreError.unknownType(typeKey)
        }
        try knowledgeValidateLabel(label)
        guard Set(aliases.map(\.id)).count == aliases.count else { throw KnowledgeStoreError.identityConflict(id) }
        for alias in aliases { try alias.validateWritable() }
        try knowledgeValidateProperties(properties)
        try validateUnknownScope(unknownFields, known: Self.keys)
    }
    private static let keys: Set<String> = ["id", "typeKey", "label", "description", "aliases", "properties", "createdAt", "modifiedAt", "lifecycle"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try c.decode(UUID.self, forKey: .init("id")); typeKey = try c.decode(String.self, forKey: .init("typeKey"))
        label = try c.decode(String.self, forKey: .init("label")); description = try c.decodeIfPresent(String.self, forKey: .init("description"))
        aliases = try c.decode([KnowledgeAlias].self, forKey: .init("aliases"))
        properties = try c.decode(PersistencePayload.self, forKey: .init("properties"))
        createdAt = try c.decode(Date.self, forKey: .init("createdAt")); modifiedAt = try c.decode(Date.self, forKey: .init("modifiedAt"))
        lifecycle = try c.decode(KnowledgeLifecycle.self, forKey: .init("lifecycle"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(id, forKey: .init("id")); try c.encode(typeKey, forKey: .init("typeKey"))
        try c.encode(label, forKey: .init("label")); try c.encodeIfPresent(description, forKey: .init("description"))
        try c.encode(aliases, forKey: .init("aliases")); try c.encode(properties, forKey: .init("properties"))
        try c.encode(createdAt, forKey: .init("createdAt")); try c.encode(modifiedAt, forKey: .init("modifiedAt"))
        try c.encode(lifecycle, forKey: .init("lifecycle"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}

/// A patch changes selected fields and retains all unmentioned optional payload data.
public struct KnowledgeEntityPatch: Equatable, Sendable {
    public var label: String?
    public var description: String?
    public var clearDescription: Bool
    public var properties: [String: JSONValue]
    public init(label: String? = nil, description: String? = nil, clearDescription: Bool = false,
                properties: [String: JSONValue] = [:]) {
        self.label = label; self.description = description; self.clearDescription = clearDescription; self.properties = properties
    }
    public func applying(to entity: KnowledgeEntity) throws -> KnowledgeEntity {
        var value = entity
        if let label { value.label = label }
        if clearDescription { value.description = nil } else if let description { value.description = description }
        value.properties.properties.merge(properties) { _, replacement in replacement }
        try value.validateWritable()
        return value
    }
}

public struct KnowledgeRelation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var predicate: String
    public var sourceID: UUID
    public var targetID: UUID
    public var provenance: PersistencePayload?
    public var createdAt: Date
    public var modifiedAt: Date
    public var lifecycle: KnowledgeLifecycle
    public var unknownFields: [String: JSONValue] = [:]
    public init(id: UUID = UUID(), predicate: String = "relatedTo", sourceID: UUID, targetID: UUID,
                provenance: PersistencePayload? = nil, createdAt: Date = Date(), modifiedAt: Date = Date(),
                lifecycle: KnowledgeLifecycle = .live) {
        self.id = id; self.predicate = predicate; self.sourceID = sourceID; self.targetID = targetID
        self.provenance = provenance; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.lifecycle = lifecycle
    }
    public func validateWritable() throws {
        guard KnowledgeRelationType.initial.contains(where: { $0.key == predicate && $0.version == 1 }) else {
            throw KnowledgeStoreError.unknownPredicate(predicate)
        }
        if let provenance { try knowledgeValidateProperties(provenance) }
        try validateUnknownScope(unknownFields, known: Self.keys)
    }
    private static let keys: Set<String> = ["id", "predicate", "sourceID", "targetID", "provenance", "createdAt", "modifiedAt", "lifecycle"]
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: PersistenceCodingKey.self)
        id = try c.decode(UUID.self, forKey: .init("id")); predicate = try c.decode(String.self, forKey: .init("predicate"))
        sourceID = try c.decode(UUID.self, forKey: .init("sourceID")); targetID = try c.decode(UUID.self, forKey: .init("targetID"))
        provenance = try c.decodeIfPresent(PersistencePayload.self, forKey: .init("provenance"))
        createdAt = try c.decode(Date.self, forKey: .init("createdAt")); modifiedAt = try c.decode(Date.self, forKey: .init("modifiedAt"))
        lifecycle = try c.decode(KnowledgeLifecycle.self, forKey: .init("lifecycle"))
        unknownFields = try decodeUnknownFields(c, known: Self.keys)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: PersistenceCodingKey.self)
        try c.encode(id, forKey: .init("id")); try c.encode(predicate, forKey: .init("predicate"))
        try c.encode(sourceID, forKey: .init("sourceID")); try c.encode(targetID, forKey: .init("targetID"))
        try c.encodeIfPresent(provenance, forKey: .init("provenance"))
        try c.encode(createdAt, forKey: .init("createdAt")); try c.encode(modifiedAt, forKey: .init("modifiedAt"))
        try c.encode(lifecycle, forKey: .init("lifecycle"))
        try encodeUnknownFields(unknownFields, known: Self.keys, into: &c)
    }
}

public struct KnowledgeEntitySnapshot: Equatable, Sendable {
    public let entity: KnowledgeEntity
    public let revision: BlockStoreRevision
    public init(entity: KnowledgeEntity, revision: BlockStoreRevision) { self.entity = entity; self.revision = revision }
}
public struct KnowledgeRelationSnapshot: Equatable, Sendable {
    public let relation: KnowledgeRelation
    public let revision: BlockStoreRevision
    public init(relation: KnowledgeRelation, revision: BlockStoreRevision) { self.relation = relation; self.revision = revision }
}
public struct KnowledgeMutationResult<Value: Sendable>: Sendable {
    public let value: Value
    public let vaultRevision: BlockStoreRevision
    public let operationID: UUID
    public init(value: Value, vaultRevision: BlockStoreRevision, operationID: UUID) {
        self.value = value; self.vaultRevision = vaultRevision; self.operationID = operationID
    }
}
extension KnowledgeMutationResult: Equatable where Value: Equatable {}
public enum KnowledgeEntityResolution: Equatable, Sendable {
    case live(KnowledgeEntitySnapshot), tombstoned(KnowledgeEntitySnapshot), unresolved(UUID)
}

/// Mutations compare vault and record revisions within the one owning actor transaction.
public protocol KnowledgeStore: Sendable {
    func createEntity(_ entity: KnowledgeEntity, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot>
    func loadEntity(id: UUID) async throws -> KnowledgeEntitySnapshot
    func searchEntities(query: String, limit: Int) async throws -> [KnowledgeEntitySnapshot]
    func updateEntity(id: UUID, patch: KnowledgeEntityPatch, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot>
    func addAlias(entityID: UUID, alias: KnowledgeAlias, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot>
    func removeAlias(entityID: UUID, aliasID: UUID, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot>
    func createRelation(_ relation: KnowledgeRelation, expectedSource: BlockStoreRevision, expectedTarget: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeRelationSnapshot>
    func queryRelations(entityID: UUID, direction: KnowledgeRelationDirection) async throws -> [KnowledgeRelationSnapshot]
    func resolveEntity(id: UUID) async throws -> KnowledgeEntityResolution
    func transitionEntity(id: UUID, to: KnowledgeLifecycle, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeEntitySnapshot>
    func transitionRelation(id: UUID, to: KnowledgeLifecycle, expected: BlockStoreRevision, expectedSource: BlockStoreRevision, expectedTarget: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<KnowledgeRelationSnapshot>
}

private func knowledgeValidateLabel(_ label: String) throws {
    guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KnowledgeStoreError.invalidLabel }
}
private func knowledgeValidateProperties(_ payload: PersistencePayload) throws {
    try payload.validateWritable()
    let reserved: Set<String> = ["id", "typeKey", "predicate", "sourceID", "targetID", "revision", "vaultRevision", "lifecycle", "createdAt", "modifiedAt"]
    for key in Set(payload.properties.keys).union(payload.unknownFields.keys) where reserved.contains(key) { throw KnowledgeStoreError.invalidProperty(key) }
}
