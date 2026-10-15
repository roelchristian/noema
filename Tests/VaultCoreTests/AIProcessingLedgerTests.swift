import Foundation
import Testing
@testable import VaultCore

@Suite struct AIProcessingLedgerTests {
    @Test func testInterruptedWorkRecoversWithoutContentOrAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let vaultID = UUID()
        let key = AIWorkKey(vaultID: vaultID, entityKind: .page, entityID: UUID(), processorID: "deterministic")
        let item = AIWorkItem(key: key, revision: "revision-2", processorVersion: "1",
            state: .running, attemptCount: 2, eligibleAt: Date(timeIntervalSince1970: 100))
        try await ledger.save(item)
        let recovered = try await ledger.load(vaultID: vaultID)
        #expect(recovered.count == 1)
        #expect(recovered.first?.state == .pending)
        #expect(recovered.first?.attemptCount == 2)
        let otherVault = try await ledger.load(vaultID: UUID())
        #expect(otherVault.isEmpty)
    }

    @Test func testLogicalKeyUpsertAndEmptyBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let vaultID = UUID()
        let missing = try await ledger.checkpoint(vaultID: vaultID)
        #expect(missing == nil)
        try await ledger.saveCheckpoint(vaultID: vaultID, changes: [])
        let baseline = try await ledger.checkpoint(vaultID: vaultID)
        #expect(baseline == [])
        let key = AIWorkKey(vaultID: vaultID, entityKind: .source, entityID: UUID(), processorID: "deterministic")
        for revision in ["old", "new"] {
            try await ledger.save(AIWorkItem(key: key, revision: revision, processorVersion: "1", eligibleAt: Date()))
        }
        let work = try await ledger.load(vaultID: vaultID)
        #expect(work.count == 1)
        #expect(work.first?.revision == "new")
    }

    @Test func testTerminalTransitionsAndRecursionEligibility() {
        #expect(!(AIWorkState.completed.permits(.running)))
        #expect(AIWorkState.running.permits(.superseded))
        #expect(AIWorkState.blocked.permits(.pending))
    }
}
