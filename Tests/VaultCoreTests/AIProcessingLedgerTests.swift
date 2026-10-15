import Foundation
import XCTest
@testable import VaultCore

final class AIProcessingLedgerTests: XCTestCase {
    func testInterruptedWorkRecoversWithoutContentOrAuthority() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let vaultID = UUID()
        let key = AIWorkKey(vaultID: vaultID, entityKind: .page, entityID: UUID(), processorID: "deterministic")
        let item = AIWorkItem(key: key, revision: "revision-2", processorVersion: "1",
            state: .running, attemptCount: 2, eligibleAt: Date(timeIntervalSince1970: 100))
        try await ledger.save(item)
        let recovered = try await ledger.load(vaultID: vaultID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.state, .pending)
        XCTAssertEqual(recovered.first?.attemptCount, 2)
        let otherVault = try await ledger.load(vaultID: UUID())
        XCTAssertTrue(otherVault.isEmpty)
    }

    func testLogicalKeyUpsertAndEmptyBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try SQLiteAIWorkLedger(url: directory.appendingPathComponent("work.sqlite"))
        let vaultID = UUID()
        let missing = try await ledger.checkpoint(vaultID: vaultID)
        XCTAssertNil(missing)
        try await ledger.saveCheckpoint(vaultID: vaultID, changes: [])
        let baseline = try await ledger.checkpoint(vaultID: vaultID)
        XCTAssertEqual(baseline, [])
        let key = AIWorkKey(vaultID: vaultID, entityKind: .source, entityID: UUID(), processorID: "deterministic")
        for revision in ["old", "new"] {
            try await ledger.save(AIWorkItem(key: key, revision: revision, processorVersion: "1", eligibleAt: Date()))
        }
        let work = try await ledger.load(vaultID: vaultID)
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work.first?.revision, "new")
    }

    func testTerminalTransitionsAndRecursionEligibility() {
        XCTAssertFalse(AIWorkState.completed.permits(.running))
        XCTAssertTrue(AIWorkState.running.permits(.superseded))
        XCTAssertTrue(AIWorkState.blocked.permits(.pending))
    }
}
