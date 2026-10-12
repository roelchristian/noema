import Foundation
import Testing
import VaultCore
@testable import noema

@Test @MainActor func activityHistoryHidesIdentityWithoutAnAccessibleVault() throws {
    let model = AppModel()
    let vaultID = UUID(), targetID = UUID()
    let record = AIActivityRecord(vaultID: vaultID, target: .init(type: .page, id: targetID),
        action: .summarizePage, executionMode: .userInvoked, provider: .onDevice)
    #expect(AIActivityPrivacy.title(for: record, model: model) == "Private vault item")
    #expect(!AIActivityPrivacy.canNavigate(record, model: model))
    let data = try AIActivityPrivacy.export([record])
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains(vaultID.uuidString))
    #expect(!json.contains(targetID.uuidString))
    #expect(!json.contains("title"))
}

extension VaultUIIntegrationTests {
    @Test @MainActor func activityHistoryChecksTheGateBeforeLockObservationAndRejectsStaleTargets() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaActivityPrivacy-\(UUID())")
        let folder = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: folder, create: true)
        let note = try await repository.create(title: "Sensitive activity title", body: "Private body")
        let model = AppModel()
        model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(folder, create: false)
        let lease = try #require(model.sessionManager.accessGate.currentLease)
        let record = AIActivityRecord(vaultID: lease.vaultID, target: .init(type: .page, id: note.id),
            action: .summarizePage, executionMode: .userInvoked, provider: .openAI)
        #expect(AIActivityPrivacy.title(for: record, model: model) == note.title)
        #expect(AIActivityPrivacy.canNavigate(record, model: model))
        let openExport = String(decoding: try AIActivityPrivacy.export([record]), as: UTF8.self)
        #expect(!openExport.contains(lease.vaultID.uuidString))
        #expect(!openExport.contains(note.id.uuidString))
        let otherVault = AIActivityRecord(vaultID: UUID(), target: record.target,
            action: .summarizePage, executionMode: .userInvoked, provider: .openAI)
        #expect(AIActivityPrivacy.title(for: otherVault, model: model) == "Private vault item")
        #expect(!AIActivityPrivacy.canNavigate(otherVault, model: model))
        let stale = AIActivityRecord(vaultID: lease.vaultID, target: .init(type: .source, id: UUID()),
            action: .summarizeSource, executionMode: .userInvoked, provider: .openAI)
        #expect(AIActivityPrivacy.title(for: stale, model: model) == "Unavailable source")
        #expect(!AIActivityPrivacy.canNavigate(stale, model: model))
        // Bypass asynchronous model observation deliberately: the history must fail
        // closed as soon as dispatch admission closes, even with old notes loaded.
        let oldState = model.sessionManager.accessGate.currentState
        if case .open(let session) = oldState {
            model.sessionManager.accessGate.updateState(.locking(session))
        }
        #expect(AIActivityPrivacy.accessibleVaultID(model) == nil)
        #expect(AIActivityPrivacy.title(for: record, model: model) == "Private vault item")
        #expect(!AIActivityPrivacy.canNavigate(record, model: model))
        let json = try #require(String(data: AIActivityPrivacy.export([record]), encoding: .utf8))
        #expect(!json.contains(lease.vaultID.uuidString))
        #expect(!json.contains(note.id.uuidString))
        #expect(!json.contains(note.title))
        model.sessionManager.accessGate.updateState(oldState)
        _ = await model.closeVault()
    }
}
