import Foundation
import SQLite3
import Testing
@testable import VaultCore

private struct BackfillAdversarialFixture {
    let url: URL
    let generation: EmbeddingIndexGeneration
    let page: AIContentChange
    let source: AIContentChange
    let removed: AIContentChange

    init(provider: String = "test-native") throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs/sem-emb-05/adversarial-fixtures/\(UUID())/work.sqlite")
        let vaultID = UUID()
        let model = try EmbeddingModelDescriptor(providerID: provider, modelID: "historical-fixture", revision: "1",
            dimensions: 3, maximumInputUTF8Bytes: 1024, maximumBatchSize: 1)
        generation = try EmbeddingIndexGeneration(vaultID: vaultID, model: model, chunkingVersion: EmbeddingChunker.version)
        page = AIContentChange(vaultID: vaultID, entityKind: .page, entityID: UUID(), revision: "opaque-page")
        source = AIContentChange(vaultID: vaultID, entityKind: .source, entityID: UUID(), revision: "opaque-source")
        removed = AIContentChange(vaultID: vaultID, entityKind: .page, entityID: UUID(), revision: "removed", kind: .removed)
    }

    func batch(scopes: Set<AIEntityKind> = [.page, .source]) throws -> EmbeddingBackfillBatch {
        try EmbeddingBackfillBatch(generation: generation, scopes: scopes, createdAt: Date(timeIntervalSince1970: 100))
    }
}

private func mutateBackfillFixture(_ url: URL, _ sql: String) throws {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let connection else { throw AIWorkLedgerError.unavailable }
    defer { sqlite3_close(connection) }
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw AIWorkLedgerError.unavailable }
}

struct EmbeddingBackfillAdversarialTests {
    @Test func selectedScopeDoesNotCaptureRemovedOrOtherKindsAndRejectsForeignVault() async throws {
        let f = try BackfillAdversarialFixture(), ledger = try SQLiteAIWorkLedger(url: f.url)
        let batch = try f.batch(scopes: [.source])
        try await ledger.createEmbeddingBatch(batch, inventory: [f.page, f.source, f.removed])
        let members = try await ledger.embeddingBatchMembers(batchID: batch.id)
        #expect(members.count == 1)
        #expect(members.first?.entityID == f.source.entityID)
        #expect(members.first?.entityKind == .source)
        let foreign = AIContentChange(vaultID: UUID(), entityKind: .source, entityID: UUID(), revision: "foreign")
        let rejected = try f.batch()
        await #expect(throws: AIWorkLedgerError.invalidMetadata) {
            try await ledger.createEmbeddingBatch(rejected, inventory: [foreign])
        }
        #expect(try await ledger.embeddingBatch(id: rejected.id) == nil)
    }

    @Test func cloudBatchIntentAloneNeverOffersAdmissionAcrossReopen() async throws {
        let f = try BackfillAdversarialFixture(provider: "openai")
        let batch = try f.batch()
        do {
            let ledger = try SQLiteAIWorkLedger(url: f.url)
            try await ledger.createEmbeddingBatch(batch, inventory: [f.page, f.source])
            #expect(try await ledger.embeddingBatch(id: batch.id)?.state == .awaitingApproval)
            #expect(try await ledger.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
        }
        let reopened = try SQLiteAIWorkLedger(url: f.url)
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
        #expect(try await reopened.embeddingBatchMembers(batchID: batch.id).count == 2)
        #expect(try await reopened.load(vaultID: f.generation.vaultID).isEmpty)
    }

    @Test(arguments: [EmbeddingBackfillState.paused, .cancellationRequested, .cancelled])
    func inactiveIntentSurvivesReopenAndDuplicateCreate(_ state: EmbeddingBackfillState) async throws {
        let f = try BackfillAdversarialFixture(), batch = try f.batch()
        do {
            let ledger = try SQLiteAIWorkLedger(url: f.url)
            try await ledger.createEmbeddingBatch(batch, inventory: [f.page, f.source])
            try await ledger.setEmbeddingBatchState(batchID: batch.id, state: state)
        }
        let reopened = try SQLiteAIWorkLedger(url: f.url)
        let repeated = try await reopened.createEmbeddingBatch(batch, inventory: [f.page, f.source])
        #expect(repeated.state == state)
        #expect(try await reopened.pendingEmbeddingAdmissions(batchID: batch.id).isEmpty)
        if state != .paused {
            await #expect(throws: AIWorkLedgerError.invalidMetadata) {
                try await reopened.setEmbeddingBatchState(batchID: batch.id, state: .active)
            }
        }
    }

    @Test(arguments: ["entity_id", "entity_kind", "work_id", "state"])
    func memberSQLIdentityAndStateCannotDisagreeWithPayload(_ column: String) async throws {
        let f = try BackfillAdversarialFixture(), ledger = try SQLiteAIWorkLedger(url: f.url), batch = try f.batch()
        try await ledger.createEmbeddingBatch(batch, inventory: [f.page])
        let replacement = column == "state" ? "admitted" : column == "entity_kind" ? "source" : UUID().uuidString
        try mutateBackfillFixture(f.url, "UPDATE embedding_batch_members SET \(column)='\(replacement)' WHERE batch_id='\(batch.id.uuidString)'")
        await #expect(throws: AIWorkLedgerError.invalidMetadata) {
            _ = try await ledger.embeddingBatchMembers(batchID: batch.id)
        }
    }

    @Test func batchSQLVaultCannotDisagreeWithPayload() async throws {
        let f = try BackfillAdversarialFixture(), ledger = try SQLiteAIWorkLedger(url: f.url), batch = try f.batch()
        try await ledger.createEmbeddingBatch(batch, inventory: [f.page])
        try mutateBackfillFixture(f.url, "UPDATE embedding_batches SET vault_id='\(UUID().uuidString)' WHERE batch_id='\(batch.id.uuidString)'")
        await #expect(throws: AIWorkLedgerError.invalidMetadata) {
            _ = try await ledger.embeddingBatch(id: batch.id)
        }
    }

    @Test func limitsAndStaleWorkIdentityRejectWithoutChangingCapturedMembers() async throws {
        let f = try BackfillAdversarialFixture(), ledger = try SQLiteAIWorkLedger(url: f.url), batch = try f.batch()
        try await ledger.createEmbeddingBatch(batch, inventory: [f.page])
        let before = try await ledger.embeddingBatchMembers(batchID: batch.id)
        await #expect(throws: AIWorkLedgerError.invalidMetadata) {
            _ = try await ledger.embeddingBatchMembers(batchID: batch.id, limit: 129)
        }
        await #expect(throws: AIWorkLedgerError.invalidMetadata) {
            _ = try await ledger.embeddingBatchMembers(batchID: batch.id, offset: -1)
        }
        await #expect(throws: AIWorkLedgerError.invalidMetadata) {
            try await ledger.updateEmbeddingMember(batchID: batch.id, workID: UUID(), state: .completed)
        }
        #expect(try await ledger.embeddingBatchMembers(batchID: batch.id) == before)
    }
}
