import Foundation
import SQLite3

extension SQLiteBlockStore {
    static let entityPropertySchema = """
    CREATE TABLE entity_property_definitions (
      id TEXT PRIMARY KEY NOT NULL,
      vault_id TEXT NOT NULL,
      normalized_key TEXT NOT NULL UNIQUE CHECK(length(normalized_key)>0),
      label TEXT NOT NULL CHECK(length(trim(label))>0),
      kind TEXT NOT NULL CHECK(kind IN ('text','number','date','boolean','url','entityReference')),
      cardinality TEXT NOT NULL CHECK(cardinality IN ('one','many')),
      display_order INTEGER NOT NULL,
      created_at REAL NOT NULL, updated_at REAL NOT NULL CHECK(updated_at>=created_at),
      retired INTEGER NOT NULL CHECK(retired IN (0,1)), revision BLOB NOT NULL
    );
    CREATE TABLE entity_property_values (
      id TEXT PRIMARY KEY NOT NULL,
      definition_id TEXT NOT NULL REFERENCES entity_property_definitions(id) ON DELETE RESTRICT,
      entity_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT,
      position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position>=0),
      kind TEXT NOT NULL CHECK(kind IN ('text','number','date','boolean','url')),
      text_value TEXT, number_value REAL, date_year INTEGER, date_month INTEGER, date_day INTEGER, bool_value INTEGER,
      UNIQUE(entity_id,position),
      CHECK (
        (kind IN ('text','url') AND text_value IS NOT NULL AND number_value IS NULL AND date_year IS NULL AND date_month IS NULL AND date_day IS NULL AND bool_value IS NULL)
        OR (kind='number' AND text_value IS NULL AND number_value IS NOT NULL AND typeof(number_value) IN ('integer','real') AND abs(number_value)<=1.7976931348623157e308 AND date_year IS NULL AND date_month IS NULL AND date_day IS NULL AND bool_value IS NULL)
        OR (kind='boolean' AND text_value IS NULL AND number_value IS NULL AND date_year IS NULL AND date_month IS NULL AND date_day IS NULL AND bool_value IN (0,1) AND bool_value IS NOT NULL)
        OR (kind='date' AND text_value IS NULL AND number_value IS NULL AND bool_value IS NULL AND date_year IS NOT NULL AND typeof(date_year)='integer' AND date_year BETWEEN 1 AND 9999 AND (date_month IS NULL OR (typeof(date_month)='integer' AND date_month BETWEEN 1 AND 12)) AND (date_day IS NULL OR (date_month IS NOT NULL AND typeof(date_day)='integer' AND date_day BETWEEN 1 AND CASE date_month WHEN 2 THEN 28+(date_year%4=0 AND (date_year%100!=0 OR date_year%400=0)) WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END)))
      )
    );
    CREATE INDEX entity_property_values_definition ON entity_property_values(definition_id,entity_id);
    CREATE TRIGGER entity_property_definition_shape BEFORE UPDATE OF kind,cardinality ON entity_property_definitions
    WHEN (NEW.kind<>OLD.kind OR NEW.cardinality<>OLD.cardinality) AND EXISTS(SELECT 1 FROM entity_property_values WHERE definition_id=OLD.id)
    BEGIN SELECT RAISE(ABORT,'Populated property shape is immutable'); END;
    """ + ["INSERT", "UPDATE"].map { action in
        """
        CREATE TRIGGER entity_property_values_validate_\(action.lowercased()) BEFORE \(action) ON entity_property_values
        BEGIN
          SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM entity_property_definitions WHERE id=NEW.definition_id AND kind=NEW.kind) THEN RAISE(ABORT,'Property kind mismatch') END;
          SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM knowledge_entities WHERE id=NEW.entity_id AND lifecycle='live') THEN RAISE(ABORT,'Property requires live entity') END;
          SELECT CASE WHEN EXISTS(SELECT 1 FROM entity_property_definitions WHERE id=NEW.definition_id AND cardinality='one') AND EXISTS(SELECT 1 FROM entity_property_values WHERE definition_id=NEW.definition_id AND entity_id=NEW.entity_id AND id<>NEW.id) THEN RAISE(ABORT,'Property cardinality exceeded') END;
        END;
        """
    }.joined(separator: "\n") + ["INSERT", "UPDATE"].map { action in
        """
        CREATE TRIGGER entity_property_definition_vault_\(action.lowercased()) BEFORE \(action) ON entity_property_definitions
        WHEN NEW.vault_id<>(SELECT vault_id FROM vault_state WHERE singleton=1)
        BEGIN SELECT RAISE(ABORT,'Property vault mismatch'); END;
        """
    }.joined(separator: "\n")

    static func validateEntityPropertyTables(_ db: OpaquePointer) throws {
        for name in ["entity_property_definitions", "entity_property_values", "entity_property_values_definition", "entity_property_definition_shape", "entity_property_values_validate_insert", "entity_property_values_validate_update", "entity_property_definition_vault_insert", "entity_property_definition_vault_update"] {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE name=?", -1, &query, nil) == SQLITE_OK, let query else { throw VaultError.invalid("Cannot inspect property schema.") }
            defer { sqlite3_finalize(query) }
            sqlite3_bind_text(query,1,name,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))
            guard sqlite3_step(query) == SQLITE_ROW else { throw VaultError.invalid("Property schema object missing: \(name).") }
        }
        func rows(_ sql: String, _ visit: (OpaquePointer) throws -> Void) throws {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw VaultError.invalid("Cannot inspect property records.") }
            defer { sqlite3_finalize(pointer) }
            while true {
                let status = sqlite3_step(pointer); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw VaultError.invalid("Cannot read property records.") }
                try visit(pointer)
            }
        }
        func string(_ row: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(row,column).map { String(cString: $0) } ?? ""
        }
        var schemaVersion: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &schemaVersion, nil) == SQLITE_OK, let schemaVersion else { throw VaultError.invalid("Cannot inspect property version.") }
        defer { sqlite3_finalize(schemaVersion) }
        guard sqlite3_step(schemaVersion) == SQLITE_ROW else { throw VaultError.invalid("Missing property version.") }
        let supportsRelationships = sqlite3_column_int(schemaVersion, 0) >= 8
        try rows("SELECT p.id,p.vault_id,p.label,p.kind,p.cardinality,p.created_at,p.updated_at,p.normalized_key,v.vault_id FROM entity_property_definitions p CROSS JOIN vault_state v WHERE v.singleton=1") { row in
            guard let id = UUID(uuidString: string(row,0)), let vaultID = UUID(uuidString: string(row,1)),
                string(row,1) == string(row,8), let kind = EntityPropertyKind(rawValue: string(row,3)),
                let cardinality = EntityPropertyCardinality(rawValue: string(row,4)), supportsRelationships || kind != .entityReference else { throw VaultError.invalid("Invalid stored property definition.") }
            let value = try EntityPropertyDefinition(id: id, vaultID: vaultID, label: string(row,2), kind: kind, cardinality: cardinality,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(row,5)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(row,6)))
            guard value.normalizedKey == string(row,7) else { throw VaultError.invalid("Stored property key mismatch.") }
        }
        try rows("SELECT p.id,p.definition_id,p.entity_id,p.kind,p.text_value,p.number_value,p.date_year,p.date_month,p.date_day,p.bool_value,d.kind FROM entity_property_values p LEFT JOIN entity_property_definitions d ON d.id=p.definition_id") { row in
            guard UUID(uuidString: string(row,0)) != nil, UUID(uuidString: string(row,1)) != nil, UUID(uuidString: string(row,2)) != nil,
                let kind = EntityPropertyKind(rawValue: string(row,3)), string(row,3) == string(row,10) else { throw VaultError.invalid("Invalid stored property assignment.") }
            let value: EntityPropertyValue
            switch kind {
            case .entityReference: throw VaultError.invalid("Relationship cannot be a scalar value.")
            case .text: value = .text(string(row,4))
            case .url: value = .url(string(row,4))
            case .number:
                guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(row,5)) else { throw VaultError.invalid("Invalid stored number type.") }
                value = .number(sqlite3_column_double(row,5))
            case .boolean: value = .boolean(sqlite3_column_int(row,9) != 0)
            case .date:
                guard sqlite3_column_type(row,6) == SQLITE_INTEGER,
                      [SQLITE_NULL, SQLITE_INTEGER].contains(sqlite3_column_type(row,7)),
                      [SQLITE_NULL, SQLITE_INTEGER].contains(sqlite3_column_type(row,8)) else { throw VaultError.invalid("Invalid stored date type.") }
                value = .date(try .init(year: Int(sqlite3_column_int(row,6)), month: sqlite3_column_type(row,7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row,7)), day: sqlite3_column_type(row,8) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row,8))))
            }
            try value.validate(for: kind)
        }
        try rows("SELECT 1 FROM entity_property_values p LEFT JOIN knowledge_entities e ON e.id=p.entity_id LEFT JOIN entity_property_definitions d ON d.id=p.definition_id WHERE e.id IS NULL OR d.id IS NULL UNION ALL SELECT 1 FROM entity_property_values p JOIN entity_property_definitions d ON d.id=p.definition_id WHERE d.cardinality='one' GROUP BY p.definition_id,p.entity_id HAVING count(*)>1") { _ in
            throw VaultError.invalid("Invalid property reference or cardinality.")
        }
    }

    func validateEntityPropertyRecords() throws {
        _ = try listPropertyDefinitions(includeRetired: true)
        let query = try statement("SELECT DISTINCT entity_id FROM entity_property_values")
        defer { sqlite3_finalize(query) }
        while true {
            let status = sqlite3_step(query); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(query,0)) else { throw VaultError.invalid("Invalid property entity identity.") }
            _ = try propertyValues(entityID: id)
        }
    }

    private func requireEntityProperties() throws {
        try requireKnowledge()
        let query = try statement("PRAGMA user_version"); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) >= 7 else {
            throw KnowledgeStoreError.transitionRequired
        }
    }

    func propertyDefinition(id: UUID) throws -> EntityPropertyDefinitionSnapshot {
        let query = try statement("SELECT vault_id,label,kind,cardinality,display_order,created_at,updated_at,retired,revision,normalized_key FROM entity_property_definitions WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { throw KnowledgeStoreError.notFound(id) }
        guard status == SQLITE_ROW, let vaultID = UUID(uuidString: text(query,0)), vaultID == canonicalVaultID,
              let kind = EntityPropertyKind(rawValue: text(query,2)), let cardinality = EntityPropertyCardinality(rawValue: text(query,3)) else { throw VaultError.invalid("Invalid property definition identity.") }
        let definition = try EntityPropertyDefinition(id: id, vaultID: vaultID, label: text(query,1), kind: kind,
            cardinality: cardinality, displayOrder: Int(sqlite3_column_int64(query,4)),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query,5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(query,6)), isRetired: sqlite3_column_int(query,7) != 0)
        guard definition.normalizedKey == text(query,9) else { throw VaultError.invalid("Property key mismatch.") }
        return .init(definition: definition, revision: .init(token: blob(query,8)))
    }

    public func listPropertyDefinitions(includeRetired: Bool = false) throws -> [EntityPropertyDefinitionSnapshot] {
        try requireEntityProperties()
        return try readTransaction {
            let query = try statement("SELECT id FROM entity_property_definitions WHERE (?=1 OR retired=0) ORDER BY display_order,normalized_key,id", [.integer(includeRetired ? 1 : 0)])
            defer { sqlite3_finalize(query) }
            var values: [EntityPropertyDefinitionSnapshot] = []
            while true {
                let status = sqlite3_step(query); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: text(query,0)) else { throw failure() }
                values.append(try propertyDefinition(id: id))
            }
            return values
        }
    }

    public func savePropertyDefinition(_ definition: EntityPropertyDefinition, expected: BlockStoreRevision?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<EntityPropertyDefinitionSnapshot> {
        try requireEntityProperties(); try definition.validate()
        if definition.kind == .entityReference { try requireEntityRelationships() }
        guard definition.vaultID == canonicalVaultID else { throw VaultError.invalid("Property belongs to another vault.") }
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            var definition = definition
            if let expected {
                let current = try propertyDefinition(id: definition.id)
                guard current.revision == expected else { throw KnowledgeStoreError.staleRevision }
                definition.createdAt = current.definition.createdAt
            } else {
                let query = try statement("SELECT 1 FROM entity_property_definitions WHERE id=?", [.text(definition.id.uuidString)])
                defer { sqlite3_finalize(query) }
                guard sqlite3_step(query) == SQLITE_DONE else { throw KnowledgeStoreError.identityConflict(definition.id) }
            }
            definition.updatedAt = max(Date(), definition.createdAt)
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            let fields: [Value] = [.text(definition.vaultID.uuidString),.text(definition.normalizedKey),.text(definition.label),.text(definition.kind.rawValue),.text(definition.cardinality.rawValue),.integer(Int64(definition.displayOrder)),.real(definition.createdAt.timeIntervalSince1970),.real(definition.updatedAt.timeIntervalSince1970),.integer(definition.isRetired ? 1 : 0),.blob(revision.token),.text(definition.id.uuidString)]
            if expected != nil {
                try run("UPDATE entity_property_definitions SET vault_id=?,normalized_key=?,label=?,kind=?,cardinality=?,display_order=?,created_at=?,updated_at=?,retired=?,revision=? WHERE id=?", fields)
            } else {
                try run("INSERT INTO entity_property_definitions(vault_id,normalized_key,label,kind,cardinality,display_order,created_at,updated_at,retired,revision,id) VALUES(?,?,?,?,?,?,?,?,?,?,?)", fields)
            }
            let snapshot = try propertyDefinition(id: definition.id)
            let vault = try recordKnowledgeOperation(snapshot, revision: revision, kind: "propertyDefinition", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }

    private func propertyValues(entityID: UUID) throws -> EntityPropertyValuesSnapshot {
        let entity = try entityInTransaction(id: entityID)
        let query = try statement("SELECT id,definition_id,kind,text_value,number_value,date_year,date_month,date_day,bool_value FROM entity_property_values WHERE entity_id=? ORDER BY position,id", [.text(entityID.uuidString)])
        defer { sqlite3_finalize(query) }
        var assignments: [EntityPropertyAssignment] = []
        while true {
            let status = sqlite3_step(query); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(query,0)), let definitionID = UUID(uuidString: text(query,1)), let kind = EntityPropertyKind(rawValue: text(query,2)) else { throw VaultError.invalid("Invalid property assignment.") }
            let value: EntityPropertyValue
            switch kind {
            case .entityReference: throw VaultError.invalid("Relationship cannot be a scalar value.")
            case .text: value = .text(text(query,3))
            case .url: value = .url(text(query,3))
            case .number:
                guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(query,4)) else { throw VaultError.invalid("Invalid stored number type.") }
                value = .number(sqlite3_column_double(query,4))
            case .boolean: value = .boolean(sqlite3_column_int(query,8) != 0)
            case .date:
                guard sqlite3_column_type(query,5) == SQLITE_INTEGER,
                      [SQLITE_NULL, SQLITE_INTEGER].contains(sqlite3_column_type(query,6)),
                      [SQLITE_NULL, SQLITE_INTEGER].contains(sqlite3_column_type(query,7)) else { throw VaultError.invalid("Invalid stored date type.") }
                value = .date(try .init(year: Int(sqlite3_column_int(query,5)), month: sqlite3_column_type(query,6) == SQLITE_NULL ? nil : Int(sqlite3_column_int(query,6)), day: sqlite3_column_type(query,7) == SQLITE_NULL ? nil : Int(sqlite3_column_int(query,7))))
            }
            try value.validate(for: propertyDefinition(id: definitionID).definition.kind)
            assignments.append(.init(id: id, definitionID: definitionID, value: value))
        }
        return .init(entityID: entityID, assignments: assignments, entityRevision: entity.revision)
    }

    public func loadPropertyValues(entityID: UUID) throws -> EntityPropertyValuesSnapshot {
        try requireEntityProperties()
        return try readTransaction { try propertyValues(entityID: entityID) }
    }

    public func savePropertyValues(entityID: UUID, assignments: [EntityPropertyAssignment], expectedEntity: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<EntityPropertyValuesSnapshot> {
        try requireEntityProperties()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let current = try propertyValues(entityID: entityID)
            guard current.entityRevision == expectedEntity else { throw KnowledgeStoreError.staleRevision }
            var entity = try entityInTransaction(id: entityID).entity
            guard entity.lifecycle == .live else { throw KnowledgeStoreError.tombstoned(entityID) }
            guard Set(assignments.map(\.id)).count == assignments.count else { throw VaultError.invalid("Duplicate property assignment identity.") }
            var counts: [UUID: Int] = [:]
            for assignment in assignments {
                let definition = try propertyDefinition(id: assignment.definitionID).definition
                try assignment.value.validate(for: definition.kind)
                counts[definition.id, default: 0] += 1
                guard definition.cardinality == .many || counts[definition.id] == 1 else { throw VaultError.invalid("Property cardinality exceeded.") }
                guard !definition.isRetired || current.assignments.contains(assignment) else { throw VaultError.invalid("Retired properties cannot receive changed values.") }
            }
            try run("DELETE FROM entity_property_values WHERE entity_id=?", [.text(entityID.uuidString)])
            for (position, assignment) in assignments.enumerated() {
                var payload: [Value] = [.null,.null,.null,.null,.null,.null]
                switch assignment.value {
                case .text(let value), .url(let value): payload[0] = .text(value)
                case .number(let value): payload[1] = .real(value)
                case .date(let value): payload[2] = .integer(Int64(value.year)); payload[3] = value.month.map { .integer(Int64($0)) } ?? .null; payload[4] = value.day.map { .integer(Int64($0)) } ?? .null
                case .boolean(let value): payload[5] = .integer(value ? 1 : 0)
                }
                try run("INSERT INTO entity_property_values(id,definition_id,entity_id,position,kind,text_value,number_value,date_year,date_month,date_day,bool_value) VALUES(?,?,?,?,?,?,?,?,?,?,?)", [.text(assignment.id.uuidString),.text(assignment.definitionID.uuidString),.text(entityID.uuidString),.integer(Int64(position)),.text(assignment.value.kind.rawValue)] + payload)
            }
            entity.modifiedAt = Date()
            let saved = try persistKnowledgeEntity(entity, inserting: false)
            let snapshot = EntityPropertyValuesSnapshot(entityID: entityID, assignments: assignments, entityRevision: saved.revision)
            let vault = try recordKnowledgeOperation(snapshot, revision: saved.revision, kind: "propertyValues", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }
}
