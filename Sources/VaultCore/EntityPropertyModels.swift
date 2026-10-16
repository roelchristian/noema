import Foundation

public enum EntityPropertyKind: String, Codable, Sendable, CaseIterable {
    case text, number, date, boolean, url, entityReference
}

public enum EntityPropertyCardinality: String, Codable, Sendable {
    case one, many
}

public enum EntityPropertyValidationError: Error, Equatable, Sendable {
    case emptyLabel, invalidDate, nonFiniteNumber, invalidURL, kindMismatch, invalidMetadata
}

/// A proleptic Gregorian calendar date, without a time or time zone.
/// Missing month/day expresses year/month granularity rather than a default date.
public struct EntityPropertyDate: Codable, Equatable, Sendable {
    public let year: Int
    public let month: Int?
    public let day: Int?

    public init(year: Int, month: Int? = nil, day: Int? = nil) throws {
        self.year = year; self.month = month; self.day = day
        try validate()
    }

    public func validate() throws {
        guard (1...9999).contains(year), day == nil || month != nil else {
            throw EntityPropertyValidationError.invalidDate
        }
        if let month {
            guard (1...12).contains(month) else { throw EntityPropertyValidationError.invalidDate }
            if let day {
                let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
                let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                guard (1...lengths[month - 1]).contains(day) else {
                    throw EntityPropertyValidationError.invalidDate
                }
            }
        }
    }

    public var encodedDate: String {
        var result = String(format: "%04d", year)
        if let month { result += String(format: "-%02d", month) }
        if let day { result += String(format: "-%02d", day) }
        return result
    }
}

public enum EntityPropertyValue: Codable, Equatable, Sendable {
    case text(String), number(Double), date(EntityPropertyDate), boolean(Bool), url(String)

    public var kind: EntityPropertyKind {
        switch self {
        case .text: .text
        case .number: .number
        case .date: .date
        case .boolean: .boolean
        case .url: .url
        }
    }

    public func validate(for expectedKind: EntityPropertyKind? = nil) throws {
        if let expectedKind, expectedKind != kind { throw EntityPropertyValidationError.kindMismatch }
        switch self {
        case .number(let value):
            guard value.isFinite else { throw EntityPropertyValidationError.nonFiniteNumber }
        case .date(let value): try value.validate()
        case .url(let value):
            guard !value.contains(where: { $0.isWhitespace }),
                  let components = URLComponents(string: value),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty, components.url != nil else {
                throw EntityPropertyValidationError.invalidURL
            }
        default: break
        }
    }
}

/// Definitions are reusable within one vault. An absent assignment means unset.
public struct EntityPropertyDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let vaultID: UUID
    public var label: String
    public var kind: EntityPropertyKind
    public var cardinality: EntityPropertyCardinality
    public var displayOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var isRetired: Bool

    public var normalizedKey: String { Self.normalize(label) }

    public static func normalize(_ label: String) -> String {
        label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public init(id: UUID = UUID(), vaultID: UUID, label: String, kind: EntityPropertyKind,
                cardinality: EntityPropertyCardinality = .one, displayOrder: Int = 0,
                createdAt: Date = Date(), updatedAt: Date? = nil, isRetired: Bool = false) throws {
        self.id = id; self.vaultID = vaultID; self.label = label; self.kind = kind
        self.cardinality = cardinality; self.displayOrder = displayOrder
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.isRetired = isRetired
        try validate()
    }

    public func validate() throws {
        guard !normalizedKey.isEmpty else { throw EntityPropertyValidationError.emptyLabel }
        guard createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt else { throw EntityPropertyValidationError.invalidMetadata }
    }
}


public struct EntityPropertyDefinitionSnapshot: Codable, Equatable, Sendable {
    public let definition: EntityPropertyDefinition
    public let revision: BlockStoreRevision
    public init(definition: EntityPropertyDefinition, revision: BlockStoreRevision) {
        self.definition = definition; self.revision = revision
    }
}

public struct EntityPropertyAssignment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let definitionID: UUID
    public let value: EntityPropertyValue
    public init(id: UUID = UUID(), definitionID: UUID, value: EntityPropertyValue) {
        self.id = id; self.definitionID = definitionID; self.value = value
    }
}

public struct EntityPropertyValuesSnapshot: Codable, Equatable, Sendable {
    public let entityID: UUID
    public let assignments: [EntityPropertyAssignment]
    public let entityRevision: BlockStoreRevision
    public init(entityID: UUID, assignments: [EntityPropertyAssignment], entityRevision: BlockStoreRevision) {
        self.entityID = entityID; self.assignments = assignments; self.entityRevision = entityRevision
    }
}

/// One canonical directed fact; incoming views never create reciprocal records.
public struct EntityPropertyRelationship: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let definitionID: UUID
    public let sourceID: UUID
    public let targetID: UUID
    public let createdAt: Date
    public init(id: UUID = UUID(), definitionID: UUID, sourceID: UUID, targetID: UUID, createdAt: Date = Date()) {
        self.id = id; self.definitionID = definitionID; self.sourceID = sourceID
        self.targetID = targetID; self.createdAt = createdAt
    }
}

public struct EntityPropertyRelationshipSnapshot: Codable, Equatable, Sendable {
    public let relationship: EntityPropertyRelationship
    public let revision: BlockStoreRevision
    public init(relationship: EntityPropertyRelationship, revision: BlockStoreRevision) {
        self.relationship = relationship; self.revision = revision
    }
}
