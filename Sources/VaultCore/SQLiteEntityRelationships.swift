import Foundation
import SQLite3

extension SQLiteBlockStore {
    static let entityRelationshipSchema = """
    CREATE TABLE entity_property_relationships (
      id TEXT PRIMARY KEY NOT NULL,
      definition_id TEXT NOT NULL REFERENCES entity_property_definitions(id) ON DELETE RESTRICT,
      source_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT,
      target_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT,
      revision BLOB NOT NULL CHECK(length(revision)>0), created_at REAL NOT NULL,
      UNIQUE(definition_id,source_id,target_id)
    );
    CREATE INDEX entity_property_relationships_source ON entity_property_relationships(source_id,created_at,id);
    CREATE INDEX entity_property_relationships_target ON entity_property_relationships(target_id,created_at,id);
    CREATE TRIGGER entity_property_relationship_shape BEFORE UPDATE OF kind,cardinality ON entity_property_definitions
    WHEN (NEW.kind<>OLD.kind OR NEW.cardinality<>OLD.cardinality) AND EXISTS(SELECT 1 FROM entity_property_relationships WHERE definition_id=OLD.id)
    BEGIN SELECT RAISE(ABORT,'Populated relationship shape is immutable'); END;
    """ + ["INSERT", "UPDATE"].map { action in
        """
        CREATE TRIGGER entity_property_relationships_validate_\(action.lowercased()) BEFORE \(action) ON entity_property_relationships
        BEGIN
          SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM entity_property_definitions WHERE id=NEW.definition_id AND kind='entityReference' AND retired=0) THEN RAISE(ABORT,'Relationship requires active reference definition') END;
          SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM knowledge_entities WHERE id=NEW.source_id AND lifecycle='live') OR NOT EXISTS(SELECT 1 FROM knowledge_entities WHERE id=NEW.target_id AND lifecycle='live') THEN RAISE(ABORT,'Relationship requires live endpoints') END;
          SELECT CASE WHEN EXISTS(SELECT 1 FROM entity_property_definitions WHERE id=NEW.definition_id AND cardinality='one') AND EXISTS(SELECT 1 FROM entity_property_relationships WHERE definition_id=NEW.definition_id AND source_id=NEW.source_id AND id<>NEW.id) THEN RAISE(ABORT,'Relationship cardinality exceeded') END;
        END;
        """
    }.joined(separator: "\n")

    static func validateEntityRelationshipTables(_ db: OpaquePointer) throws {
        func rows(_ sql: String, _ visit: (OpaquePointer) throws -> Void) throws {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw VaultError.invalid("Cannot inspect relationship schema.") }
            defer { sqlite3_finalize(pointer) }
            while true {
                let status = sqlite3_step(pointer)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW else { throw VaultError.invalid("Cannot read relationship schema.") }
                try visit(pointer)
            }
        }
        for name in ["entity_property_relationships", "entity_property_relationships_source", "entity_property_relationships_target", "entity_property_relationship_shape", "entity_property_relationships_validate_insert", "entity_property_relationships_validate_update"] {
            var found = false
            try rows("SELECT 1 FROM sqlite_master WHERE name='\(name)'") { _ in found = true }
            guard found else { throw VaultError.invalid("Missing relationship schema object: \(name).") }
        }
        try rows("PRAGMA foreign_key_check(entity_property_relationships)") { _ in throw VaultError.invalid("Dangling relationship reference.") }
        try rows("SELECT 1 FROM entity_property_relationships r LEFT JOIN entity_property_definitions d ON d.id=r.definition_id WHERE d.kind IS NULL OR d.kind<>'entityReference' UNION ALL SELECT 1 FROM entity_property_relationships GROUP BY definition_id,source_id,target_id HAVING count(*)>1 UNION ALL SELECT 1 FROM entity_property_relationships r JOIN entity_property_definitions d ON d.id=r.definition_id WHERE d.cardinality='one' GROUP BY r.definition_id,r.source_id HAVING count(*)>1") { _ in throw VaultError.invalid("Invalid relationship definition or cardinality.") }
        try rows("SELECT id,definition_id,source_id,target_id,created_at,revision FROM entity_property_relationships") { row in
            for column: Int32 in 0...3 {
                guard let raw = sqlite3_column_text(row,column), UUID(uuidString: String(cString: raw)) != nil else { throw VaultError.invalid("Invalid relationship identity.") }
            }
            guard sqlite3_column_double(row,4).isFinite, sqlite3_column_bytes(row,5)>0 else { throw VaultError.invalid("Invalid relationship metadata.") }
        }
    }

    func validateEntityRelationshipRecords() throws {
        try requireEntityRelationships()
        let query = try statement("SELECT id FROM entity_property_relationships")
        defer { sqlite3_finalize(query) }
        while true {
            let status = sqlite3_step(query); if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(query,0)) else { throw VaultError.invalid("Invalid relationship identity.") }
            let record = try propertyRelationship(id: id).relationship
            let definition = try propertyDefinition(id: record.definitionID).definition
            guard definition.kind == .entityReference else { throw VaultError.invalid("Relationship definition kind mismatch.") }
            _ = try entityInTransaction(id: record.sourceID)
            _ = try entityInTransaction(id: record.targetID)
        }
    }

    func requireEntityRelationships() throws {
        try requireKnowledge()
        let query = try statement("PRAGMA user_version"); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query,0) >= 8 else { throw KnowledgeStoreError.transitionRequired }
    }

    private func propertyRelationship(id: UUID) throws -> EntityPropertyRelationshipSnapshot {
        let query = try statement("SELECT definition_id,source_id,target_id,created_at,revision FROM entity_property_relationships WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { throw KnowledgeStoreError.notFound(id) }
        guard status == SQLITE_ROW, let definitionID = UUID(uuidString: text(query,0)), let sourceID = UUID(uuidString: text(query,1)), let targetID = UUID(uuidString: text(query,2)), sqlite3_column_double(query,3).isFinite, !blob(query,4).isEmpty else { throw VaultError.invalid("Invalid stored relationship.") }
        return .init(relationship: .init(id: id, definitionID: definitionID, sourceID: sourceID, targetID: targetID, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query,3))), revision: .init(token: blob(query,4)))
    }

    public func queryPropertyRelationships(entityID: UUID, direction: KnowledgeRelationDirection = .both) throws -> [EntityPropertyRelationshipSnapshot] {
        try requireEntityRelationships()
        return try readTransaction {
            _ = try entityInTransaction(id: entityID)
            let condition: String
            switch direction {
            case .outgoing: condition = "source_id=?"
            case .incoming: condition = "target_id=?"
            case .both: condition = "source_id=? OR target_id=?"
            }
            let fields: [Value] = direction == .both ? [.text(entityID.uuidString),.text(entityID.uuidString)] : [.text(entityID.uuidString)]
            let query = try statement("SELECT id FROM entity_property_relationships WHERE \(condition) ORDER BY created_at,id", fields)
            defer { sqlite3_finalize(query) }
            var result: [EntityPropertyRelationshipSnapshot] = []
            while true {
                let status = sqlite3_step(query); if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let id = UUID(uuidString: text(query,0)) else { throw failure() }
                result.append(try propertyRelationship(id: id))
            }
            return result
        }
    }

    public func createPropertyRelationship(definitionID: UUID, entityID: UUID, otherEntityID: UUID, direction: KnowledgeRelationDirection, expectedEntity: BlockStoreRevision, expectedOther: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<EntityPropertyRelationshipSnapshot> {
        try requireEntityRelationships()
        guard direction != .both else { throw VaultError.invalid("Relationship creation requires a direction.") }
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let entity = try entityInTransaction(id: entityID), other = try entityInTransaction(id: otherEntityID)
            guard entity.revision == expectedEntity, other.revision == expectedOther else { throw KnowledgeStoreError.staleRevision }
            guard entity.entity.lifecycle == .live, other.entity.lifecycle == .live else { throw VaultError.invalid("Relationship requires live endpoints.") }
            let definition = try propertyDefinition(id: definitionID).definition
            guard definition.kind == .entityReference, !definition.isRetired else { throw VaultError.invalid("Relationship requires active reference definition.") }
            let relationship = EntityPropertyRelationship(definitionID: definitionID, sourceID: direction == .incoming ? otherEntityID : entityID, targetID: direction == .incoming ? entityID : otherEntityID)
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("INSERT INTO entity_property_relationships(id,definition_id,source_id,target_id,created_at,revision) VALUES(?,?,?,?,?,?)", [.text(relationship.id.uuidString),.text(definitionID.uuidString),.text(relationship.sourceID.uuidString),.text(relationship.targetID.uuidString),.real(relationship.createdAt.timeIntervalSince1970),.blob(revision.token)])
            let snapshot = try propertyRelationship(id: relationship.id)
            let vault = try recordKnowledgeOperation(snapshot, revision: revision, kind: "propertyRelationship", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }

    public func removePropertyRelationship(id: UUID, expected: BlockStoreRevision, expectedSource: BlockStoreRevision, expectedTarget: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<EntityPropertyRelationshipSnapshot> {
        try requireEntityRelationships()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let snapshot = try propertyRelationship(id: id)
            let source = try entityInTransaction(id: snapshot.relationship.sourceID), target = try entityInTransaction(id: snapshot.relationship.targetID)
            guard snapshot.revision == expected, source.revision == expectedSource, target.revision == expectedTarget else { throw KnowledgeStoreError.staleRevision }
            try run("DELETE FROM entity_property_relationships WHERE id=?", [.text(id.uuidString)])
            let vault = try recordKnowledgeOperation(snapshot, revision: snapshot.revision, kind: "propertyRelationshipRemoval", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }
}
