import Foundation
import SQLite3

extension SQLiteBlockStore {
    static let entityPropertyTemplateSchema = """
    CREATE TABLE entity_property_templates (
      type_key TEXT PRIMARY KEY NOT NULL REFERENCES knowledge_entity_types(key) ON DELETE RESTRICT,
      revision BLOB NOT NULL CHECK(typeof(revision)='blob' AND length(revision)>0)
    );
    CREATE TABLE entity_property_template_entries (
      type_key TEXT NOT NULL REFERENCES entity_property_templates(type_key) ON DELETE RESTRICT,
      definition_id TEXT NOT NULL REFERENCES entity_property_definitions(id) ON DELETE RESTRICT,
      position INTEGER NOT NULL CHECK(typeof(position)='integer' AND position>=0 AND position<16),
      PRIMARY KEY(type_key,definition_id), UNIQUE(type_key,position)
    );
    """

    static func validateEntityPropertyTemplateTables(_ db: OpaquePointer) throws {
        func rows(_ sql: String, visit: (OpaquePointer) throws -> Void) throws {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK, let query else {
                throw VaultError.invalid("Cannot inspect property template schema.")
            }
            defer { sqlite3_finalize(query) }
            while true {
                let status = sqlite3_step(query)
                if status == SQLITE_DONE { return }
                guard status == SQLITE_ROW else { throw VaultError.invalid("Cannot inspect property template records.") }
                try visit(query)
            }
        }
        func string(_ row: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
        }
        for table in ["entity_property_templates", "entity_property_template_entries"] {
            var found = false
            try rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(table)'") { _ in found = true }
            guard found else { throw VaultError.invalid("Missing property template table: \(table).") }
            try rows("PRAGMA foreign_key_check(\(table))") { _ in throw VaultError.invalid("Dangling property template reference.") }
        }
        let expectedReferences: [String: Set<String>] = [
            "entity_property_templates": ["type_key|knowledge_entity_types|key|RESTRICT"],
            "entity_property_template_entries": ["type_key|entity_property_templates|type_key|RESTRICT", "definition_id|entity_property_definitions|id|RESTRICT"]
        ]
        for (table, expected) in expectedReferences {
            var references = Set<String>()
            try rows("PRAGMA foreign_key_list(\(table))") { row in
                references.insert("\(string(row, 3))|\(string(row, 2))|\(string(row, 4))|\(string(row, 6))")
            }
            guard references == expected else { throw VaultError.invalid("Invalid property template foreign keys.") }
        }
        let types = Set(KnowledgeEntityType.initial.map(\.key))
        try rows("SELECT type_key,revision FROM entity_property_templates") { row in
            guard types.contains(string(row, 0)), sqlite3_column_type(row, 1) == SQLITE_BLOB,
                  sqlite3_column_bytes(row, 1) > 0 else { throw VaultError.invalid("Invalid property template identity or revision.") }
        }
        try rows("SELECT e.type_key,e.definition_id,e.position,d.vault_id,v.vault_id FROM entity_property_template_entries e LEFT JOIN entity_property_definitions d ON d.id=e.definition_id CROSS JOIN vault_state v WHERE v.singleton=1 ORDER BY e.type_key,e.position") { row in
            guard types.contains(string(row, 0)), UUID(uuidString: string(row, 1)) != nil,
                  sqlite3_column_type(row, 2) == SQLITE_INTEGER,
                  sqlite3_column_int64(row, 2) >= 0,
                  sqlite3_column_int64(row, 2) < Int64(EntityPropertyTemplateSnapshot.maximumEntries),
                  string(row, 3) == string(row, 4) else { throw VaultError.invalid("Invalid property template entry.") }
        }
        try rows("SELECT type_key FROM entity_property_template_entries GROUP BY type_key HAVING count(*)>16 OR min(position)<>0 OR max(position)<>count(*)-1 OR count(DISTINCT position)<>count(*) OR count(DISTINCT definition_id)<>count(*)") { _ in
            throw VaultError.invalid("Invalid property template ordering or size.")
        }
    }

    private func requirePropertyTemplates() throws {
        try requireKnowledge()
        let query = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) >= Int32(Self.templateSchemaVersion) else { throw KnowledgeStoreError.transitionRequired }
    }

    private func propertyTemplate(typeKey: String) throws -> EntityPropertyTemplateSnapshot {
        guard KnowledgeEntityType.initial.contains(where: { $0.key == typeKey }) else { throw VaultError.invalid("Unknown property template entity type.") }
        let registered = try statement("SELECT version FROM knowledge_entity_types WHERE key=?", [.text(typeKey)])
        defer { sqlite3_finalize(registered) }
        guard sqlite3_step(registered) == SQLITE_ROW, sqlite3_column_int(registered, 0) == 1 else { throw VaultError.invalid("Unregistered property template entity type.") }
        let parent = try statement("SELECT revision FROM entity_property_templates WHERE type_key=?", [.text(typeKey)])
        defer { sqlite3_finalize(parent) }
        let status = sqlite3_step(parent)
        if status == SQLITE_DONE { return .init(typeKey: typeKey, definitionIDs: [], revision: nil) }
        guard status == SQLITE_ROW, sqlite3_column_type(parent, 0) == SQLITE_BLOB, !blob(parent, 0).isEmpty else { throw VaultError.invalid("Invalid property template revision.") }
        let revision = BlockStoreRevision(token: blob(parent, 0))
        let query = try statement("SELECT definition_id,position FROM entity_property_template_entries WHERE type_key=? ORDER BY position", [.text(typeKey)])
        defer { sqlite3_finalize(query) }
        var ids: [UUID] = []
        while true {
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)),
                  sqlite3_column_type(query, 1) == SQLITE_INTEGER,
                  sqlite3_column_int64(query, 1) == Int64(ids.count),
                  ids.count < EntityPropertyTemplateSnapshot.maximumEntries, !ids.contains(id) else { throw VaultError.invalid("Invalid property template entries.") }
            _ = try propertyDefinition(id: id)
            ids.append(id)
        }
        return .init(typeKey: typeKey, definitionIDs: ids, revision: revision)
    }

    public func loadPropertyTemplate(typeKey: String) throws -> EntityPropertyTemplateSnapshot {
        try requirePropertyTemplates()
        return try readTransaction { try propertyTemplate(typeKey: typeKey) }
    }

    public func savePropertyTemplate(typeKey: String, definitionIDs: [UUID], expected: BlockStoreRevision?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<EntityPropertyTemplateSnapshot> {
        try requirePropertyTemplates()
        return try transaction {
            try checkedKnowledgeRevision(expectedVaultRevision)
            try checkKnowledgeOperation(operationID)
            let current = try propertyTemplate(typeKey: typeKey)
            guard current.revision == expected else { throw KnowledgeStoreError.staleRevision }
            guard definitionIDs.count <= EntityPropertyTemplateSnapshot.maximumEntries,
                  Set(definitionIDs).count == definitionIDs.count else { throw VaultError.invalid("A property template accepts at most 16 distinct definitions.") }
            for id in definitionIDs {
                let definition = try propertyDefinition(id: id).definition
                guard definition.vaultID == canonicalVaultID,
                      !definition.isRetired || current.definitionIDs.contains(id) else { throw VaultError.invalid("New template suggestions require active definitions in this vault.") }
            }
            let revision = BlockStoreRevision(token: Data(UUID().uuidString.utf8))
            try run("INSERT INTO entity_property_templates(type_key,revision) VALUES(?,?) ON CONFLICT(type_key) DO UPDATE SET revision=excluded.revision", [.text(typeKey), .blob(revision.token)])
            try run("DELETE FROM entity_property_template_entries WHERE type_key=?", [.text(typeKey)])
            for (position, id) in definitionIDs.enumerated() {
                try run("INSERT INTO entity_property_template_entries(type_key,definition_id,position) VALUES(?,?,?)", [.text(typeKey), .text(id.uuidString), .integer(Int64(position))])
            }
            let snapshot = try propertyTemplate(typeKey: typeKey)
            let vault = try recordKnowledgeOperation(snapshot, revision: revision, kind: "propertyTemplate", operationID: operationID)
            return .init(value: snapshot, vaultRevision: vault, operationID: operationID)
        }
    }
}
