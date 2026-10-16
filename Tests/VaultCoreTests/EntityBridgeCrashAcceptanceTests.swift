import Darwin
import Foundation
import SQLite3
import Testing
@testable import VaultCore

// Opt-in worker for scripts/entity-bridge-crash-acceptance.py. Never visits a user vault.
private struct BridgeCrashState: Codable {
    let action: String
    let phase: String
    let vaultID: UUID
    let sourceID: UUID
    let entityID: UUID
    let definitionIDs: [UUID]
    let operationID: UUID
    let originalSchema: Int
    let manifest: Data
    let original: Data
    let originalPath: String
    let vaultRevision: BlockStoreRevision
    let templates: [EntityPropertyTemplateSnapshot]
    let originalAssociation: SourceEntityAssociationSnapshot?
}

private struct BridgeDatabaseImage: Codable, Equatable {
    let version: Int
    let vaultRevision: BlockStoreRevision
    let requiredCapabilities: [String]
    let schema: [[String]]
    let tables: [String: [[String]]]
}

private func bridgeImage(_ root: URL) throws -> BridgeDatabaseImage {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(root.appendingPathComponent("blocks.sqlite").path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
        throw VaultError.storage("Crash fixture cannot be inspected.")
    }
    defer { sqlite3_close(handle) }
    func rows(_ sql: String) throws -> [[String]] {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query else { throw VaultError.storage("Crash inspection query failed.") }
        defer { sqlite3_finalize(query) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw VaultError.storage("Crash inspection read failed.") }
            result.append((0..<sqlite3_column_count(query)).map { column in
                switch sqlite3_column_type(query, column) {
                case SQLITE_NULL: return "null"
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(query, column))
                    return "blob:" + (sqlite3_column_blob(query, column).map { Data(bytes: $0, count: count).base64EncodedString() } ?? "")
                case SQLITE_INTEGER: return "int:\(sqlite3_column_int64(query, column))"
                case SQLITE_FLOAT: return "real:\(sqlite3_column_double(query, column))"
                default: return "text:" + String(cString: sqlite3_column_text(query, column))
                }
            })
        }
    }
    let versionRows = try rows("PRAGMA user_version")
    let version = Int(versionRows[0][0].dropFirst(4))!
    let schema = try rows("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name")
    var tables: [String: [[String]]] = [:]
    for row in schema where row[0] == "text:table" {
        let name = String(row[1].dropFirst(5)).replacingOccurrences(of: "\"", with: "\"\"")
        // Sorting the encoded rows ignores physical row order while retaining every value/type.
        tables[name] = try rows("SELECT * FROM \"\(name)\"").sorted { $0.lexicographicallyPrecedes($1) }
    }
    func bytes(_ encoded: String) throws -> Data {
        if encoded.hasPrefix("blob:"), let data = Data(base64Encoded: String(encoded.dropFirst(5))) { return data }
        if encoded.hasPrefix("text:") { return Data(encoded.dropFirst(5).utf8) }
        throw VaultError.invalid("Crash fixture has invalid admission bytes.")
    }
    let admission = try rows("SELECT revision,required_capabilities FROM vault_state WHERE singleton=1")
    let row = try #require(admission.first)
    return .init(version: version, vaultRevision: .init(token: try bytes(row[0])),
        requiredCapabilities: try JSONDecoder().decode([String].self, from: bytes(row[1])), schema: schema, tables: tables)
}

private func bridgeCapabilities(_ version: Int) throws -> [String] {
    switch version {
    case 8: SQLiteBlockStore.relationshipRequiredCapabilities
    case 9: SQLiteBlockStore.templateRequiredCapabilities
    case 10: SQLiteBlockStore.associationRequiredCapabilities
    default: throw VaultError.invalid("Unexpected crash fixture schema.")
    }
}

/// Independent intended-delta oracle; the captured post-write image alone is not an oracle.
private func bridgeAssertDatabaseOutcome(_ state: BridgeCrashState, baseline: BridgeDatabaseImage,
                                         observed: BridgeDatabaseImage, committed: Bool) throws {
    let migration = state.action.hasPrefix("migrate")
    let target = state.originalSchema + (committed && migration ? 1 : 0)
    let capabilities = try bridgeCapabilities(target)
    try #require(observed.version == target)
    try #require(observed.requiredCapabilities == capabilities)
    try #require(baseline.vaultRevision == state.vaultRevision)
    try #require((observed.vaultRevision != state.vaultRevision) == committed)
    if !committed { try #require(observed == baseline); return }
    var changed: Set<String> = ["vault_state"]
    switch state.action {
    case "save", "reorder": changed.formUnion(["entity_property_templates", "entity_property_template_entries", "knowledge_operations"])
    case "link", "unlink": changed.formUnion(["source_entity_associations", "knowledge_operations"])
    case "migrate8":
        try #require(observed.tables["entity_property_templates"] == [])
        try #require(observed.tables["entity_property_template_entries"] == [])
    case "migrate9": try #require(observed.tables["source_entity_associations"] == [])
    default: throw VaultError.invalid("Unexpected crash action.")
    }
    for (table, rows) in baseline.tables where !changed.contains(table) {
        try #require(observed.tables[table] == rows)
    }
    if !migration { try #require(observed.schema == baseline.schema) }
}

private func bridgeAssertOperationOutcome(_ state: BridgeCrashState, store: SQLiteBlockStore, committed: Bool) async throws {
    if state.originalSchema >= 9 {
        for before in state.templates {
            let current = try await store.loadPropertyTemplate(typeKey: before.typeKey)
            if committed && ["save", "reorder"].contains(state.action) && before.typeKey == "person" {
                let desired = state.action == "reorder" ? Array(state.definitionIDs.reversed()) : state.definitionIDs
                try #require(current.definitionIDs == desired)
                try #require(current.revision != nil && current.revision != before.revision)
            } else { try #require(current == before) }
        }
    } else if committed {
        for type in KnowledgeEntityType.initial {
            let template = try await store.loadPropertyTemplate(typeKey: type.key)
            try #require(template.definitionIDs.isEmpty && template.revision == nil)
        }
    }
    guard committed else { return }
    if state.action == "link" {
        let rows = try await store.associationsForSource(id: state.sourceID)
        let edge = try #require(rows.first)
        try #require(rows.count == 1 && edge.association.sourceID == state.sourceID && edge.association.entityID == state.entityID && edge.association.role == .representsWork)
        try #require(!edge.revision.token.isEmpty)
        try #require(try await store.sourcesForEntity(id: state.entityID) == rows)
    } else if state.action == "unlink" {
        _ = try #require(state.originalAssociation)
        try #require(try await store.associationsForSource(id: state.sourceID).isEmpty)
        try #require(try await store.sourcesForEntity(id: state.entityID).isEmpty)
    }
}

private func bridgeWrite<T: Encodable>(_ value: T, _ file: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: file, options: .atomic)
}

private final class BridgeCrashBarrier: @unchecked Sendable {
    let directory: URL
    let token: String
    let phase: String
    init(directory: URL, token: String, phase: String) { self.directory = directory; self.token = token; self.phase = phase }
    func stop() -> Never {
        do {
            try bridgeWrite(["pid": String(getpid()), "token": token, "phase": phase], directory.appendingPathComponent("ready.json"))
        } catch { _exit(91) }
        // The controller kills this exact worker. A lost controller cannot leave it running forever.
        for _ in 0..<60 { Darwin.sleep(1) }
        _exit(92)
    }
}

private extension SQLiteBlockStore {
    func installBridgeCrashCommitBarrier(_ barrier: BridgeCrashBarrier) throws {
        let query = try statement("SELECT 1")
        defer { sqlite3_finalize(query) }
        guard let handle = sqlite3_db_handle(query) else { throw VaultError.storage("Missing test connection.") }
        // Retained until process death; no production connection or hook API is added.
        let context = BridgeCommitContext(handle: handle, barrier: barrier)
        sqlite3_commit_hook(handle, { pointer in
            let context = Unmanaged<BridgeCommitContext>.fromOpaque(pointer!).takeUnretainedValue()
            // Argument/snapshot reads may commit first. Stop only after this connection wrote.
            if sqlite3_total_changes(context.handle) > context.initialChanges { context.barrier.stop() }
            return 0
        }, Unmanaged.passRetained(context).toOpaque())
    }
}

private final class BridgeCommitContext: @unchecked Sendable {
    let handle: OpaquePointer
    let initialChanges: Int32
    let barrier: BridgeCrashBarrier
    init(handle: OpaquePointer, barrier: BridgeCrashBarrier) {
        self.handle = handle; initialChanges = sqlite3_total_changes(handle); self.barrier = barrier
    }
}

private struct BridgeManifestBarrierStore: VaultContentStore {
    let base: any VaultContentStore
    let directory: URL
    let afterWrite: Bool
    let barrier: BridgeCrashBarrier
    func read(at path: String) throws -> Data { try base.read(at: path) }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try base.changeToken(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        guard path == "vault.json" else { try base.write(data, at: path, condition: condition); return }
        if afterWrite { try base.write(data, at: path, condition: condition) }
        let state = try JSONDecoder().decode(BridgeCrashState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        let baseline = try JSONDecoder().decode(BridgeDatabaseImage.self, from: Data(contentsOf: directory.appendingPathComponent("baseline.json")))
        let observed = try bridgeImage(directory.appendingPathComponent("Vault"))
        try bridgeAssertDatabaseOutcome(state, baseline: baseline, observed: observed, committed: true)
        try bridgeWrite(observed, directory.appendingPathComponent("expected.json"))
        barrier.stop()
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

private func bridgeSeed(directory: URL, action: String, phase: String) async throws -> BridgeCrashState {
    let root = directory.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let vaultID = UUID(), schema = action == "migrate8" ? 8 : action == "migrate9" ? 9 : 10
    let url = root.appendingPathComponent("blocks.sqlite"), provider = VaultStorageProvider.plaintext
    let store: SQLiteBlockStore
    switch schema {
    case 8: store = try provider.makeRelationshipStagingStore(url: url, vaultID: vaultID)
    case 9: store = try provider.makeTemplateStagingStore(url: url, vaultID: vaultID)
    default: store = try provider.makeAssociationStagingStore(url: url, vaultID: vaultID)
    }
    let bytes = Data("Immutable ENT04–05 process-crash evidence.\n".utf8)
    var metadata = SourceMetadata(id: UUID(), title: "Crash fixture evidence", capturedAt: "2026-10-16", originalFilename: "evidence.txt", originURL: nil,
        sha256: digest(bytes), fileSize: bytes.count, storedFilename: "original.txt")
    metadata.unknownFields["futureSource"] = .object(["preserve": .bool(true)])
    let content = try provider.makeStore(root: root), publicationID = UUID()
    let receipt = try content.publishCanonicalOriginal(bytes, metadata: metadata, vaultID: vaultID, operationID: publicationID)
    _ = try await store.publishSourceAndPage(source: CanonicalSource(metadata: metadata), condition: .createOnly,
        operationID: publicationID, expectedVaultRevision: store.canonicalVaultRevision(), byteReceipt: receipt)
    var entity = KnowledgeEntity(typeKey: "creativeWork", label: "Preserved work")
    entity.unknownFields["futureEntity"] = .array([.string("retain"), .bool(true)])
    let owner = try await store.createEntity(entity, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    var definitions: [UUID] = []
    for label in ["Preserved note", "Second note"] {
        let definition = try EntityPropertyDefinition(vaultID: vaultID, label: label, kind: .text)
        definitions.append(try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value.definition.id)
    }
    _ = try await store.savePropertyValues(entityID: entity.id, assignments: [.init(definitionID: definitions[0], value: .text("Existing factual value"))],
        expectedEntity: owner.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    let person = try await store.createEntity(.init(typeKey: "person", label: "Preserved author"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let reference = try EntityPropertyDefinition(vaultID: vaultID, label: "Existing directed edge", kind: .entityReference)
    _ = try await store.savePropertyDefinition(reference, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    _ = try await store.createPropertyRelationship(definitionID: reference.id, entityID: entity.id, otherEntityID: person.entity.id,
        direction: .outgoing, expectedEntity: store.loadEntity(id: entity.id).revision, expectedOther: person.revision,
        expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    if schema >= 9 {
        _ = try await store.savePropertyTemplate(typeKey: "creativeWork", definitionIDs: definitions, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        if action == "reorder" {
            _ = try await store.savePropertyTemplate(typeKey: "person", definitionIDs: definitions, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        }
    }
    if action == "unlink" {
        _ = try await store.linkSource(metadata.id, to: entity.id, role: .representsWork,
            expectedSource: store.sourceSnapshot(id: metadata.id).revision, expectedEntity: store.loadEntity(id: entity.id).revision,
            expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
    }
    try await store.checkpoint(); try await store.close()
    var manifest = VaultManifest(id: vaultID)
    manifest.storage?.schemaVersion = schema
    manifest.storage?.requiredCapabilities = schema == 8 ? SQLiteBlockStore.relationshipRequiredCapabilities : schema == 9 ? SQLiteBlockStore.templateRequiredCapabilities : SQLiteBlockStore.associationRequiredCapabilities
    manifest.unknownFields["futureManifest"] = .object(["preserve": .string("exact")])
    let manifestBytes = try JSONEncoder().encode(manifest)
    try content.write(manifestBytes, at: "vault.json", condition: .createOnly)
    for name in ["Removed Pages", "Conflicts"] { try content.createDirectory(at: name) }
    // Seed a genuine Page–Source link through the repository, rather than SQL imitation.
    let session = VaultSession(vaultID: vaultID, root: root, generation: 1), gate = VaultAccessGate(initialState: .open(session))
    let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
    _ = try await repository.create(title: "Preserved page", body: "Existing page body", source: SourceRecord(metadata: metadata, body: String(decoding: bytes, as: UTF8.self)))
    let finalStore = repository.sqliteBlockStore
    let vaultRevision = try await finalStore.canonicalVaultRevision()
    var templates: [EntityPropertyTemplateSnapshot] = []
    if schema >= 9 {
        for type in KnowledgeEntityType.initial { templates.append(try await finalStore.loadPropertyTemplate(typeKey: type.key)) }
    }
    let association = schema >= 10 ? try await finalStore.associationsForSource(id: metadata.id).first : nil
    try await finalStore.checkpoint(); try await finalStore.close()
    let state = BridgeCrashState(action: action, phase: phase, vaultID: vaultID, sourceID: metadata.id, entityID: entity.id,
        definitionIDs: definitions, operationID: UUID(), originalSchema: schema, manifest: manifestBytes, original: bytes,
        originalPath: "Sources/\(metadata.id.uuidString.lowercased())/original.txt", vaultRevision: vaultRevision,
        templates: templates, originalAssociation: association)
    try bridgeWrite(state, directory.appendingPathComponent("state.json"))
    try bridgeWrite(bridgeImage(root), directory.appendingPathComponent("baseline.json"))
    return state
}

private func bridgeMutate(_ state: BridgeCrashState, store: SQLiteBlockStore) async throws {
    let vault = try await store.canonicalVaultRevision()
    switch state.action {
    case "save", "reorder":
        let current = try await store.loadPropertyTemplate(typeKey: "person")
        _ = try await store.savePropertyTemplate(typeKey: "person", definitionIDs: state.action == "reorder" ? state.definitionIDs.reversed().map { $0 } : state.definitionIDs,
            expected: current.revision, expectedVaultRevision: vault, operationID: state.operationID)
    case "link":
        let source = try await store.sourceSnapshot(id: state.sourceID), entity = try await store.loadEntity(id: state.entityID)
        _ = try await store.linkSource(state.sourceID, to: state.entityID, role: .representsWork, expectedSource: source.revision,
            expectedEntity: entity.revision, expectedVaultRevision: vault, operationID: state.operationID)
    case "unlink":
        let edge = try #require(try await store.associationsForSource(id: state.sourceID).first)
        let source = try await store.sourceSnapshot(id: state.sourceID), entity = try await store.loadEntity(id: state.entityID)
        _ = try await store.unlinkSourceAssociation(id: edge.association.id, expected: edge.revision,
            expectedSource: source.revision, expectedEntity: entity.revision, expectedVaultRevision: vault, operationID: state.operationID)
    case "migrate8": _ = try await store.upgradeEntityPropertyTemplateSchema(expectedVaultRevision: vault)
    case "migrate9": _ = try await store.upgradeSourceEntityAssociationSchema(expectedVaultRevision: vault)
    default: throw VaultError.invalid("Unknown crash action.")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_ENTITY_BRIDGE_CRASH"] == "1"))
func entityBridgeProcessCrashWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(env["NOEMA_CRASH_CASE_DIR"])).standardizedFileURL
    let managed = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/agent-runs").standardizedFileURL
    try #require(directory.path.hasPrefix(managed.path + "/"))
    try #require(directory.resolvingSymlinksInPath() == directory)
    try #require(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent(".active").path))
    let root = directory.appendingPathComponent("Vault"), token = try #require(env["NOEMA_CRASH_TOKEN"])
    if env["NOEMA_CRASH_MODE"] == "verify" {
        let state = try JSONDecoder().decode(BridgeCrashState.self, from: Data(contentsOf: directory.appendingPathComponent("state.json")))
        let baseline = try JSONDecoder().decode(BridgeDatabaseImage.self, from: Data(contentsOf: directory.appendingPathComponent("baseline.json")))
        let precommit = state.phase == "precommit"
        let expected = precommit ? baseline : try JSONDecoder().decode(BridgeDatabaseImage.self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        let recovered = try bridgeImage(root)
        try #require(recovered == expected)
        try bridgeAssertDatabaseOutcome(state, baseline: baseline, observed: recovered, committed: !precommit)
        if !state.action.hasPrefix("migrate") {
            let operationRows = recovered.tables["knowledge_operations"] ?? []
            try #require(operationRows.contains { $0.first == "text:\(state.operationID.uuidString)" } == !precommit)
        }
        // Content/factual tables must remain byte/type/revision identical even on acknowledged writes.
        for table in ["sources", "pages", "blocks", "page_sources", "knowledge_entities", "knowledge_entity_aliases", "knowledge_relations", "entity_property_definitions", "entity_property_values", "entity_property_relationships", "conflicts", "tombstones"] {
            try #require(recovered.tables[table] == baseline.tables[table])
        }
        let content = try VaultStorageProvider.plaintext.makeStore(root: root)
        try #require(try content.read(at: state.originalPath) == state.original)
        let session = VaultSession(vaultID: state.vaultID, root: root, generation: 1), gate = VaultAccessGate(initialState: .open(session))
        if state.phase == "before-manifest" {
            try #require(try content.read(at: "vault.json") == state.manifest)
            #expect(throws: VaultError.self) { try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate) }
            if state.action == "migrate8" {
                _ = try await FileVaultRepository.resumeEntityPropertyTemplatesUpgrade(root: root, sessionLease: session.lease, accessGate: gate)
            } else {
                _ = try await FileVaultRepository.resumeSourceEntityAssociationsUpgrade(root: root, sessionLease: session.lease, accessGate: gate)
            }
        }
        let manifest = try FileVaultRepository.inspectManifest(at: root)
        let originalManifest = try JSONDecoder().decode(VaultManifest.self, from: state.manifest)
        try #require(manifest.unknownFields == originalManifest.unknownFields)
        try #require(manifest.storage?.schemaVersion == expected.version)
        let capabilities = try bridgeCapabilities(expected.version)
        try #require(manifest.storage?.requiredCapabilities == capabilities)
        let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate), store = repository.sqliteBlockStore
        try await store.validateCanonicalLogicalIntegrity()
        try await bridgeAssertOperationOutcome(state, store: store, committed: !precommit)
        if !precommit && !state.action.hasPrefix("migrate") {
            // Same operation cannot publish a second mutation after crash/reopen.
            await #expect(throws: (any Error).self) { try await store.checkKnowledgeOperation(state.operationID) }
            if state.action == "unlink" {
                let original = try #require(state.originalAssociation)
                let source = try await store.sourceSnapshot(id: state.sourceID), entity = try await store.loadEntity(id: state.entityID)
                await #expect(throws: (any Error).self) {
                    try await store.unlinkSourceAssociation(id: original.association.id, expected: original.revision,
                        expectedSource: source.revision, expectedEntity: entity.revision,
                        expectedVaultRevision: store.canonicalVaultRevision(), operationID: state.operationID)
                }
            } else {
                await #expect(throws: (any Error).self) { try await bridgeMutate(state, store: store) }
            }
        }
        try #require(try bridgeImage(root) == expected)
        try await store.close()
        try bridgeWrite(["status": "passed", "case": "\(state.action)-\(state.phase)", "processCrashOnly": "true", "powerLossProven": "false"], directory.appendingPathComponent("verified.json"))
        return
    }
    let action = try #require(env["NOEMA_CRASH_ACTION"]), phase = try #require(env["NOEMA_CRASH_PHASE"])
    let state = try await bridgeSeed(directory: directory, action: action, phase: phase)
    let barrier = BridgeCrashBarrier(directory: directory, token: token, phase: phase)
    let session = VaultSession(vaultID: state.vaultID, root: root, generation: 1), gate = VaultAccessGate(initialState: .open(session))
    if phase == "before-manifest" || phase == "after-manifest" {
        let content = try VaultStorageProvider.plaintext.makeStore(root: root)
        let wrapper = BridgeManifestBarrierStore(base: content, directory: directory, afterWrite: phase == "after-manifest", barrier: barrier)
        let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
        let revision = try await repository.sqliteBlockStore.canonicalVaultRevision()
        try await repository.sqliteBlockStore.close()
        if action == "migrate8" {
            _ = try await FileVaultRepository.upgradeEntityPropertyTemplates(root: root, sessionLease: session.lease, accessGate: gate, expectedVaultRevision: revision, contentStore: wrapper)
        } else {
            _ = try await FileVaultRepository.upgradeSourceEntityAssociations(root: root, sessionLease: session.lease, accessGate: gate, expectedVaultRevision: revision, contentStore: wrapper)
        }
        Issue.record("Manifest barrier was not reached.")
        return
    }
    let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate), store = repository.sqliteBlockStore
    if phase == "precommit" { try await store.installBridgeCrashCommitBarrier(barrier) }
    try await bridgeMutate(state, store: store)
    try #require(phase == "postack")
    let baseline = try JSONDecoder().decode(BridgeDatabaseImage.self, from: Data(contentsOf: directory.appendingPathComponent("baseline.json")))
    let observed = try bridgeImage(root)
    try bridgeAssertDatabaseOutcome(state, baseline: baseline, observed: observed, committed: true)
    try await bridgeAssertOperationOutcome(state, store: store, committed: true)
    try bridgeWrite(observed, directory.appendingPathComponent("expected.json"))
    // Deliberately no close/checkpoint between acknowledged mutation and SIGKILL.
    barrier.stop()
}
