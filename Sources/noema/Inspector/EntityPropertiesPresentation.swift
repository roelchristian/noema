import Foundation
import VaultCore

struct EntityPropertiesSnapshot: Sendable {
    let entity: KnowledgeEntitySnapshot
    let definitions: [EntityPropertyDefinitionSnapshot]
    let values: EntityPropertyValuesSnapshot
    let relationships: [EntityPropertyRelationshipSnapshot]
    var entities: [KnowledgeEntitySnapshot]
    let vaultRevision: BlockStoreRevision
    let sessionID: UUID?
    var supportsRelationships = true
}

enum EntityPropertiesPresentation {
    static let previewLimit = 4
    static func matchingDefinitions(_ definitions: [EntityPropertyDefinitionSnapshot], query: String) -> [EntityPropertyDefinitionSnapshot] {
        let key = EntityPropertyDefinition.normalize(query)
        return definitions.filter { !$0.definition.isRetired && (key.isEmpty || $0.definition.normalizedKey.contains(key)) }
    }
    static func relationshipLabel(_ definition: EntityPropertyDefinition, incoming: Bool) -> String {
        definition.relationshipLabel(direction: incoming ? .incoming : .outgoing)
    }
    static func display(_ value: EntityPropertyValue) -> String {
        switch value {
        case .text(let text), .url(let text): text
        case .number(let number): String(number)
        case .date(let date): date.encodedDate
        case .boolean(let flag): flag ? "Yes" : "No"
        }
    }
}

enum EntityPropertyInput {
    static func value(kind: EntityPropertyKind, text: String, boolean: Bool) throws -> EntityPropertyValue {
        let value: EntityPropertyValue
        switch kind {
        case .text: value = .text(text)
        case .url: value = .url(text)
        case .number:
            guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw VaultError.invalid("Enter a finite number.") }
            value = .number(number)
        case .date:
            let parts = text.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count), parts[0].count == 4,
                  parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  parts.dropFirst().allSatisfy({ $0.count == 2 }), let year = Int(parts[0]) else {
                throw VaultError.invalid("Use YYYY, YYYY-MM, or YYYY-MM-DD.")
            }
            value = .date(try .init(year: year, month: parts.count > 1 ? Int(parts[1]) : nil, day: parts.count > 2 ? Int(parts[2]) : nil))
        case .boolean: value = .boolean(boolean)
        case .entityReference: throw VaultError.invalid("Choose a canonical entity.")
        }
        try value.validate(for: kind)
        return value
    }
}

enum EntityPropertyEdit {
    case saveValues([EntityPropertyAssignment])
    case createDefinition(label: String, kind: EntityPropertyKind, cardinality: EntityPropertyCardinality, presentation: EntityPropertyPresentation? = nil)
    case saveDefinition(EntityPropertyDefinition)
    case addRelationship(definitionID: UUID, otherID: UUID, incoming: Bool)
    case removeRelationship(EntityPropertyRelationshipSnapshot)
}

struct EntityPropertiesRequestToken: Equatable, Sendable {
    let entityID: UUID
    let sessionID: UUID?
    let requestID: UUID
    init(entityID: UUID, sessionID: UUID?, requestID: UUID = UUID()) {
        self.entityID = entityID; self.sessionID = sessionID; self.requestID = requestID
    }
    func matches(request: Self, entityID: UUID, sessionID: UUID?) -> Bool {
        self == request && self.entityID == entityID && self.sessionID == sessionID
    }
}
