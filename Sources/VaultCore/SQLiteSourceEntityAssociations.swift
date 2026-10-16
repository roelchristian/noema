import Foundation
import SQLite3

extension SQLiteBlockStore {
    static let sourceEntityAssociationSchema = """
    CREATE TABLE source_entity_associations (
      id TEXT PRIMARY KEY NOT NULL,
      source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE RESTRICT,
      entity_id TEXT NOT NULL REFERENCES knowledge_entities(id) ON DELETE RESTRICT,
      role TEXT NOT NULL CHECK(role IN ('representsWork','aboutEntity')),
      revision BLOB NOT NULL CHECK(typeof(revision)='blob' AND length(revision)>0),
      created_at REAL NOT NULL,
      UNIQUE(source_id,entity_id,role)
    );
    CREATE INDEX source_entity_associations_source ON source_entity_associations(source_id,role,created_at,id);
    CREATE INDEX source_entity_associations_entity ON source_entity_associations(entity_id,role,created_at,id);
    """ + ["INSERT", "UPDATE"].map { action in
        """
        CREATE TRIGGER source_entity_associations_validate_\(action.lowercased()) BEFORE \(action) ON source_entity_associations
        BEGIN
          SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM sources WHERE id=NEW.source_id AND trashed=0) THEN RAISE(ABORT,'Association requires active Source') END;
          SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM knowledge_entities WHERE id=NEW.entity_id AND lifecycle='live' AND type_key IN ('person','place','concept','event','creativeWork')) THEN RAISE(ABORT,'Association requires live registered entity') END;
          SELECT CASE WHEN NEW.role='representsWork' AND NOT EXISTS(SELECT 1 FROM knowledge_entities WHERE id=NEW.entity_id AND type_key='creativeWork') THEN RAISE(ABORT,'representsWork requires Creative Work') END;
        END;
        """
    }.joined(separator: "\n")

    static func validateSourceEntityAssociationTables(_ db: OpaquePointer) throws {
        func rows(_ sql: String, _ visit: (OpaquePointer) throws -> Void) throws {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else { throw VaultError.invalid("Cannot inspect Source association schema.") }
            defer { sqlite3_finalize(query) }
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW else { throw VaultError.invalid("Cannot inspect Source associations.") }
                try visit(query)
            }
        }
        func string(_ row: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
        }
        for (name, type) in [("source_entity_associations", "table"), ("source_entity_associations_source", "index"), ("source_entity_associations_entity", "index"), ("source_entity_associations_validate_insert", "trigger"), ("source_entity_associations_validate_update", "trigger")] {
            var found = false
            try rows("SELECT 1 FROM sqlite_master WHERE name='\(name)' AND type='\(type)'") { _ in found = true }
            guard found else { throw VaultError.invalid("Missing Source association schema object: \(name).") }
        }
        var references = Set<String>()
        try rows("PRAGMA foreign_key_list(source_entity_associations)") { row in
            references.insert("\(string(row, 3))|\(string(row, 2))|\(string(row, 4))|\(string(row, 6))")
        }
        guard references == ["source_id|sources|id|RESTRICT", "entity_id|knowledge_entities|id|RESTRICT"] else { throw VaultError.invalid("Invalid Source association foreign keys.") }
        try rows("PRAGMA foreign_key_check(source_entity_associations)") { _ in throw VaultError.invalid("Dangling Source association reference.") }
        try rows("SELECT id,source_id,entity_id,role,revision,created_at FROM source_entity_associations") { row in
            for column: Int32 in 0...2 {
                guard UUID(uuidString: string(row, column)) != nil else { throw VaultError.invalid("Invalid Source association identity.") }
            }
            guard SourceEntityAssociationRole(rawValue: string(row, 3)) != nil,
                  sqlite3_column_type(row, 4) == SQLITE_BLOB, sqlite3_column_bytes(row, 4)>0,
                  [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(row, 5)),
                  sqlite3_column_double(row, 5).isFinite else { throw VaultError.invalid("Invalid Source association metadata.") }
        }
        // Endpoint inactivity is preserved; only invalid identity/type/role is corruption.
        try rows("SELECT 1 FROM source_entity_associations a JOIN knowledge_entities e ON e.id=a.entity_id WHERE e.type_key NOT IN ('person','place','concept','event','creativeWork') OR (a.role='representsWork' AND e.type_key<>'creativeWork') UNION ALL SELECT 1 FROM source_entity_associations GROUP BY source_id,entity_id,role HAVING count(*)>1") { _ in throw VaultError.invalid("Invalid Source association role or duplicate.") }
    }

    private func requireSourceEntityAssociations() throws {
        try requireKnowledge()
        let query = try statement("PRAGMA user_version"); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) >= Int32(Self.associationSchemaVersion) else { throw KnowledgeStoreError.transitionRequired }
    }

    private func sourceEntityAssociation(id: UUID) throws -> SourceEntityAssociationSnapshot {
        let query = try statement("SELECT source_id,entity_id,role,revision,created_at FROM source_entity_associations WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_DONE { throw KnowledgeStoreError.notFound(id) }
        guard status == SQLITE_ROW, let sourceID = UUID(uuidString: text(query, 0)), let entityID = UUID(uuidString: text(query, 1)),
              let role = SourceEntityAssociationRole(rawValue: text(query, 2)),
              sqlite3_column_type(query, 3) == SQLITE_BLOB, !blob(query, 3).isEmpty,
              [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(query, 4)), sqlite3_column_double(query, 4).isFinite else { throw VaultError.invalid("Invalid stored Source association.") }
        return .init(association: .init(id: id, sourceID: sourceID, entityID: entityID, role: role, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 4))), revision: .init(token: blob(query, 3)))
    }

    private func querySourceEntityAssociations(id: UUID, bySource: Bool, limit: Int, offset: Int) throws -> [SourceEntityAssociationSnapshot] {
        try requireSourceEntityAssociations()
        guard (1...1000).contains(limit), offset >= 0 else { throw VaultError.invalid("Source association queries require a limit from 1 to 1000 and a nonnegative offset.") }
        return try readTransaction {
            if bySource { _ = try sourceSnapshot(id: id) } else { _ = try entityInTransaction(id: id) }
            let query = try statement("SELECT id FROM source_entity_associations WHERE \(bySource ? "source_id" : "entity_id")=? ORDER BY created_at,id LIMIT ? OFFSET ?", [.text(id.uuidString), .integer(Int64(limit)), .integer(Int64(offset))])
            defer { sqlite3_finalize(query) }
            var results: [SourceEntityAssociationSnapshot] = []
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let associationID = UUID(uuidString: text(query, 0)) else { throw VaultError.invalid("Invalid Source association identity.") }
                results.append(try sourceEntityAssociation(id: associationID))
            }
            return results
        }
    }

    public func associationsForSource(id: UUID, limit: Int = 100, offset: Int = 0) throws -> [SourceEntityAssociationSnapshot] {
        try querySourceEntityAssociations(id: id, bySource: true, limit: limit, offset: offset)
    }

    public func sourcesForEntity(id: UUID, limit: Int = 100, offset: Int = 0) throws -> [SourceEntityAssociationSnapshot] {
        try querySourceEntityAssociations(id: id, bySource: false, limit: limit, offset: offset)
    }

    public func linkSource(_ sourceID: UUID, to entityID: UUID, role: SourceEntityAssociationRole, expectedSource: BlockStoreRevision, expectedEntity: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SourceEntityAssociationSnapshot> {
        try requireSourceEntityAssociations()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let source = try sourceSnapshot(id: sourceID), entity = try entityInTransaction(id: entityID)
            guard source.revision == expectedSource, entity.revision == expectedEntity else { throw KnowledgeStoreError.staleRevision }
            guard !source.trashed, entity.entity.lifecycle == .live else { throw VaultError.invalid("Restore this Source and entity before linking them.") }
            guard KnowledgeEntityType.initial.contains(where: { $0.key == entity.entity.typeKey }), role != .representsWork || entity.entity.typeKey == "creativeWork" else { throw VaultError.invalid("Represents Work requires a Creative Work entity.") }
            let duplicate = try statement("SELECT 1 FROM source_entity_associations WHERE source_id=? AND entity_id=? AND role=?", [.text(sourceID.uuidString), .text(entityID.uuidString), .text(role.rawValue)])
            defer { sqlite3_finalize(duplicate) }
            let duplicateStatus = sqlite3_step(duplicate)
            guard duplicateStatus == SQLITE_DONE else {
                if duplicateStatus == SQLITE_ROW { throw VaultError.conflict("This Source already has that entity and role. Unlink the existing association to remove it.") }
                throw failure()
            }
            let association = SourceEntityAssociation(sourceID: sourceID, entityID: entityID, role: role)
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("INSERT INTO source_entity_associations(id,source_id,entity_id,role,revision,created_at) VALUES(?,?,?,?,?,?)", [.text(association.id.uuidString), .text(sourceID.uuidString), .text(entityID.uuidString), .text(role.rawValue), .blob(revision.token), .real(association.createdAt.timeIntervalSince1970)])
            let snapshot = try sourceEntityAssociation(id: association.id)
            let vault = try recordKnowledgeOperation(snapshot, revision: revision, kind: "sourceEntityAssociation", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }

    public func unlinkSourceAssociation(id: UUID, expected: BlockStoreRevision, expectedSource: BlockStoreRevision, expectedEntity: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<SourceEntityAssociationSnapshot> {
        try requireSourceEntityAssociations()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision); try checkKnowledgeOperation(operationID)
            let snapshot = try sourceEntityAssociation(id: id)
            let source = try sourceSnapshot(id: snapshot.association.sourceID), entity = try entityInTransaction(id: snapshot.association.entityID)
            guard snapshot.revision == expected, source.revision == expectedSource, entity.revision == expectedEntity else { throw KnowledgeStoreError.staleRevision }
            try run("DELETE FROM source_entity_associations WHERE id=?", [.text(id.uuidString)])
            let vault = try recordKnowledgeOperation(snapshot, revision: snapshot.revision, kind: "sourceEntityAssociationRemoval", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }
}
