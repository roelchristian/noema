import Darwin
import Foundation
import SQLite3
import Testing
@testable import VaultCore

private enum SemanticTerminationFixture {
    static let vaultID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let pageID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let generationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let replacementID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let batchID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    static let processor = "embedding.process-termination"
    static let stages = ["checkpointBeforeCommit", "checkpointAfterCommit", "activationBeforeCommit", "activationAfterCommit", "queueBeforeCommit", "queueAfterCommit"]
    static func model() throws -> EmbeddingModelDescriptor {
        try .init(providerID: "termination-synthetic", modelID: "two-dimensional", revision: "1", dimensions: 2,
            maximumInputUTF8Bytes: 1024, maximumBatchSize: 16)
    }
    static func generation(replacement: Bool = false) throws -> EmbeddingIndexGeneration {
        try .init(id: replacement ? replacementID : generationID, vaultID: vaultID, model: model(), chunkingVersion: EmbeddingChunker.version)
    }
    static func validatedRoot(_ path: String) throws -> URL {
        let managed = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs").standardizedFileURL.resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == managed,
              root.lastPathComponent.hasPrefix("semantic-process-"),
              UUID(uuidString: String(root.lastPathComponent.dropFirst("semantic-process-".count))) != nil else {
            throw EmbeddingContractError.authorityDenied
        }
        return root
    }
    static func readyAndWait(_ root: URL) throws -> Never {
        try Data("ready".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
        // Intentionally leaves the owned child alive at an exact publication boundary.
        // The parent bounds readiness and kills only its Process.processIdentifier.
        while true { _ = Darwin.pause() }
    }
}

/// Child-only entry: never runs in an ordinary test graph. No providers, credentials or user vault.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_SEMANTIC_TERMINATION_CHILD_ROOT"] != nil))
func semanticProcessTerminationChildEntry() async throws {
    let root = try SemanticTerminationFixture.validatedRoot(try #require(ProcessInfo.processInfo.environment["NOEMA_SEMANTIC_TERMINATION_CHILD_ROOT"]))
    let stage = try #require(ProcessInfo.processInfo.environment["NOEMA_SEMANTIC_TERMINATION_CHILD_STAGE"])
    try #require(SemanticTerminationFixture.stages.contains(stage))
    let canonical = root.appendingPathComponent("canonical")
    try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
    let session = VaultSession(vaultID: SemanticTerminationFixture.vaultID, root: canonical, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    let store = try SQLiteBlockStore(canonicalStagingURL: canonical.appendingPathComponent("blocks.sqlite"),
        vaultID: session.vaultID, requiredCapabilities: SQLiteBlockStore.organisationRequiredCapabilities,
        schemaVersion: SQLiteBlockStore.organisationSchemaVersion)
    let snapshot = try await store.save(BlockDocument(blocks: [EditorBlock(runs: [RichRun("First committed passage.")]),
        EditorBlock(runs: [RichRun("Second committed passage.")])]), pageID: SemanticTerminationFixture.pageID, condition: .createOnly)
    let identity = try EmbeddingEntityIdentity(vaultID: session.vaultID, entityKind: .page,
        entityID: snapshot.pageID, revision: snapshot.revision.token.base64EncodedString())
    let generation = try SemanticTerminationFixture.generation()
    let index = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"), lease: session.lease, accessGate: gate)
    let inputs = try EmbeddingInputPreparation.page(snapshot.document, identity: identity, model: generation.model)
    let fingerprint = digest(Data(inputs.map { $0.chunk.chunkID + ":" + $0.chunk.contentFingerprint }.joined(separator: "\n").utf8))
    let vector = try EmbeddingVector(values: [1, 0], model: generation.model)
    let records = try inputs.map { try EmbeddingRecord(generation: generation, chunk: $0.chunk, vector: vector) }
    func publish(_ selected: EmbeddingIndexGeneration, partial: Bool, stopBeforeCommit: Bool = false) async throws {
        let selectedRecords = try records.prefix(partial ? 1 : records.count).map { try EmbeddingRecord(generation: selected, chunk: $0.chunk, vector: $0.vector) }
        let permit = try await store.embeddingPublicationPermit(pageID: snapshot.pageID, expected: snapshot.revision)
        let authority = try EmbeddingPublicationAuthority(accessGate: gate, lease: session.lease, generation: selected)
        try await index.replaceDocument(identity: identity, generation: selected, records: selectedRecords,
            permit: permit, authority: authority,
            completion: partial ? nil : .init(identity: identity, workRevision: identity.revision, inputFingerprint: fingerprint, chunkCount: selectedRecords.count),
            checkpoint: partial ? .init(identity: identity, workRevision: identity.revision, inputFingerprint: fingerprint, chunkCount: selectedRecords.count) : nil,
            validatePublication: { if stopBeforeCommit { try SemanticTerminationFixture.readyAndWait(root) } })
    }
    try await publish(generation, partial: false)
    let ledger = try SQLiteAIWorkLedger(url: root.appendingPathComponent("work.sqlite"))
    let key = AIWorkKey(vaultID: session.vaultID, entityKind: .page, entityID: snapshot.pageID, processorID: SemanticTerminationFixture.processor)
    let item = AIWorkItem(key: key, revision: identity.revision, processorVersion: "1", state: .pending,
        attemptCount: 3, eligibleAt: Date(), inputFingerprint: "prior-attempt")
    try await ledger.save(item)
    try await ledger.setProcessorPaused(vaultID: session.vaultID, processorID: SemanticTerminationFixture.processor, paused: true)
    switch stage {
    case "checkpointBeforeCommit": try await publish(generation, partial: true, stopBeforeCommit: true)
    case "checkpointAfterCommit": try await publish(generation, partial: true)
    case "activationBeforeCommit", "activationAfterCommit":
        let replacement = try SemanticTerminationFixture.generation(replacement: true)
        try await publish(replacement, partial: false)
        let batch = try EmbeddingBackfillBatch(id: SemanticTerminationFixture.batchID, generation: replacement,
            scopes: [.page], mode: .rebuild, createdAt: Date())
        let change = AIContentChange(vaultID: session.vaultID, entityKind: .page, entityID: snapshot.pageID, revision: identity.revision)
        try await ledger.createEmbeddingBatch(batch, inventory: [change])
        let member = try #require(try await ledger.embeddingBatchMembers(batchID: batch.id).first)
        try await ledger.updateEmbeddingMember(batchID: batch.id, workID: member.workID, state: .completed)
        if stage == "activationAfterCommit" { try await ledger.setEmbeddingBatchState(batchID: batch.id, state: .completed) }
        else {
            try semanticTerminationUncommittedPayload(database: root.appendingPathComponent("work.sqlite"), table: "embedding_batches",
                keyColumn: "batch_id", key: batch.id.uuidString, values: ["state": "completed"], root: root)
        }
    case "queueBeforeCommit":
        try semanticTerminationUncommittedPayload(database: root.appendingPathComponent("work.sqlite"), table: "ai_work",
            keyColumn: "entity_id", key: snapshot.pageID.uuidString, values: ["state": "running", "attemptCount": 4], root: root)
    default:
        var running = item; running.state = .running; running.attemptCount = 4
        try await ledger.save(running)
    }
    try SemanticTerminationFixture.readyAndWait(root)
}

/// Ledger exposes no pre-COMMIT hook. This fixture-only second connection exercises the exact
/// existing WAL schema; it does not establish application-controller activation behavior.
private func semanticTerminationUncommittedPayload(database: URL, table: String, keyColumn: String,
    key: String, values: [String: Any], root: URL) throws -> Never {
    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else { throw AIWorkLedgerError.unavailable }
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw AIWorkLedgerError.unavailable }
    var statement: OpaquePointer?
    let keyExpression = key.replacingOccurrences(of: "'", with: "''")
    guard sqlite3_prepare_v2(db, "SELECT payload FROM \(table) WHERE \(keyColumn)='\(keyExpression)'", -1, &statement, nil) == SQLITE_OK,
          let statement, sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else { throw AIWorkLedgerError.unavailable }
    var payload = try #require(JSONSerialization.jsonObject(with: Data(String(cString: bytes).utf8)) as? [String: Any])
    sqlite3_finalize(statement)
    for (field, value) in values { payload[field] = value }
    let encoded = try #require(String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8))
    let escaped = encoded.replacingOccurrences(of: "'", with: "''")
    guard sqlite3_exec(db, "UPDATE \(table) SET payload='\(escaped)' WHERE \(keyColumn)='\(keyExpression)'", nil, nil, nil) == SQLITE_OK else { throw AIWorkLedgerError.unavailable }
    try SemanticTerminationFixture.readyAndWait(root)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_SEMANTIC_TERMINATION_CHILD_ROOT"] == nil),
      .timeLimit(.minutes(2)), .serialized, arguments: SemanticTerminationFixture.stages)
func semanticProcessTerminationPreservesCheckpointActivationAndQueue(stage: String) async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".local/agent-runs/semantic-process-\(UUID())")
    _ = try SemanticTerminationFixture.validatedRoot(root.path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(".active"))
    let child = Process()
    defer {
        // A cleanup failure keeps the active marker protected until termination is verified.
        if !child.isRunning {
            try? Data().write(to: root.appendingPathComponent(".complete"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".active"))
        }
    }
    do {
        let arguments = CommandLine.arguments
        let index = try #require(arguments.firstIndex(of: "--test-bundle-path"))
        try #require(index + 1 < arguments.count)
        let helper = URL(fileURLWithPath: arguments[0])
        try #require(helper.lastPathComponent == "swiftpm-testing-helper")
        child.executableURL = helper
        child.arguments = ["--test-bundle-path", arguments[index + 1], "--testing-library", "swift-testing",
            "--filter", "semanticProcessTerminationChildEntry", "--no-parallel"]
        child.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var environment = ProcessInfo.processInfo.environment
        environment["NOEMA_SEMANTIC_TERMINATION_CHILD_ROOT"] = root.path
        environment["NOEMA_SEMANTIC_TERMINATION_CHILD_STAGE"] = stage
        child.environment = environment
        let log = root.appendingPathComponent("child.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        child.standardOutput = output; child.standardError = output
        try child.run()
        defer { if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) } }
        for _ in 0..<2_000 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) || !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(child.isRunning && FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path),
            "Owned durability child failed before readiness; retain child.log")
        #expect(Darwin.kill(child.processIdentifier, SIGKILL) == 0)
        for _ in 0..<500 {
            if !child.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!child.isRunning, "Owned child did not report termination within five seconds")
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let session = VaultSession(vaultID: SemanticTerminationFixture.vaultID, root: root.appendingPathComponent("canonical"), generation: 2)
        let gate = VaultAccessGate(initialState: .open(session))
        let indexStore = try SQLiteEmbeddingIndex(applicationSupportRoot: root.appendingPathComponent("support"), lease: session.lease, accessGate: gate)
        let generation = try SemanticTerminationFixture.generation()
        let completions = try await indexStore.completedDocuments(generation: generation)
        let checkpoints = try await indexStore.documentCheckpoints(generation: generation)
        if stage == "checkpointAfterCommit" { #expect(completions.isEmpty && checkpoints.count == 1 && checkpoints[0].chunkCount == 1) }
        else { #expect(completions.count == 1 && completions[0].chunkCount == 2 && checkpoints.isEmpty) }
        let query = try EmbeddingVector(values: [1, 0], model: generation.model)
        let results = try await indexStore.searchCandidates(query: query, generation: generation, isCurrent: { _ in true }, validateQuery: {})
        #expect(results.count == (stage == "checkpointAfterCommit" ? 0 : 1))
        let ledger = try SQLiteAIWorkLedger(url: root.appendingPathComponent("work.sqlite"))
        #expect(try await ledger.pausedProcessors(vaultID: session.vaultID).contains(SemanticTerminationFixture.processor))
        if stage.hasPrefix("activation") {
            let batch = try #require(try await ledger.embeddingBatch(id: SemanticTerminationFixture.batchID))
            #expect(batch.state == (stage == "activationAfterCommit" ? .completed : .active))
            #expect(try batch.generation == SemanticTerminationFixture.generation(replacement: true))
            #expect(try await indexStore.completedDocuments(generation: batch.generation).count == 1)
            let members = try await ledger.embeddingBatchMembers(batchID: batch.id)
            #expect(members.count == 1 && members[0].state == .completed)
        }
        let recovered = try await ledger.load(vaultID: session.vaultID)
        #expect(recovered.count == 1 && recovered[0].state == .pending)
        #expect(recovered[0].attemptCount == (stage == "queueAfterCommit" ? 4 : 3))
        if stage == "queueAfterCommit" { #expect(recovered[0].inputFingerprint == nil) }
        print("SEMANTIC_PROCESS_TERMINATION stage=\(stage) owned_child_sigkill=true production_reopen=true physical_power_loss=false application_activation_controller=false")
    } catch { try? Data().write(to: root.appendingPathComponent(".failed")); throw error }
}
