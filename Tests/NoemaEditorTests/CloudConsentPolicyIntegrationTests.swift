import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct CloudConsentPolicyIntegrationTests {
    @Test @MainActor
    func alwaysAsksAndNeverAskAutomaticallyDispatchesExplicitEnrichment() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.externalAIService.setConsentPolicy(.always)
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
        #expect(model.cloudSummaryConfirmation != nil)
        #expect(await fixture.probe.count == 0)
        model.confirmCloudSummary()
        try await waitUntil { model.cloudSummaryTarget == nil }
        #expect(model.cloudSummaryError == nil)
        #expect(await fixture.probe.count == 1)
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
        #expect(await fixture.probe.count == 1)
        model.cancelCloudSummary()
        model.externalAIService.setConsentPolicy(.neverAsk)
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { await fixture.probe.count == 2 && model.cloudSummaryTarget == nil }
        #expect(model.cloudSummaryConfirmation == nil)
        #expect(model.cloudSummaryError == nil)
        #expect(await model.externalAIService.sessionManager.state == .unauthorized)
        // The injected transport proves application policy only; it never grants gateway auth.
        let stored = try #require(try await fixture.repository.scan().notes.first)
        #expect(stored.title == fixture.note.title)
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Combined summary 2")
    }

    @Test @MainActor
    func onceSessionSkipsOnlySubsequentExplicitRequestsAndLockReopensDisclosure() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.externalAIService.setConsentPolicy(.oncePerSession)
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil }
        #expect(await fixture.probe.count == 0)
        model.confirmCloudSummary()
        try await waitUntil { await fixture.probe.count == 1 && model.cloudSummaryTarget == nil }
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { await fixture.probe.count == 2 && model.cloudSummaryTarget == nil }
        #expect(model.cloudSummaryConfirmation == nil)
        #expect(await model.lockVault())
        #expect(await model.unlockVault(using: fixture.root))
        model.select(fixture.note.id)
        try await waitUntil { model.currentNote?.id == fixture.note.id }
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
        #expect(model.cloudSummaryConfirmation != nil)
        #expect(await fixture.probe.count == 2)
        model.cancelCloudSummary()
    }

    @Test @MainActor
    func unconfirmedPendingRequestCannotDispatchUnderAlwaysAsk() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        model.externalAIService.setConsentPolicy(.always)
        model.prepareCloudPageSummary(id: fixture.note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil }
        model.confirmCloudSummary(userConfirmed: false)
        try await waitUntil { model.cloudSummaryTarget == nil }
        #expect(await fixture.probe.count == 0)
        #expect(model.cloudSummaryError == ExternalAIError.consentRequired.localizedDescription)
    }

    @MainActor private func fixture() async throws -> ConsentFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-consent-flow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let note = try await repository.create(title: "Human title", body: "Selected content")
        let domain = "noema-consent-flow-defaults-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id)
        try await waitUntil { model.currentNote?.id == note.id }
        let probe = ConsentFlowProbe()
        model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            return try await probe.perform(request)
        }
        model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
        return ConsentFixture(root: root, repository: repository, model: model, note: note,
            defaults: defaults, domain: domain, probe: probe)
    }

    @MainActor private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ConsentFlowFailure.timedOut
    }
}
}

private enum ConsentFlowFailure: Error { case timedOut }

@MainActor private struct ConsentFixture {
    let root: URL
    let repository: FileVaultRepository
    let model: AppModel
    let note: NoteRecord
    let defaults: UserDefaults
    let domain: String
    let probe: ConsentFlowProbe
    func cleanup() {
        model.cancelCloudSummary()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ConsentFlowProbe {
    private(set) var count = 0
    func perform(_ request: ExternalAISummaryRequest) throws -> ExternalAISummaryResult {
        count += 1
        let enrichment = try ExternalAIEnrichment(summary: "Combined summary \(count)",
            classification: nil, mode: request.mode)
        return try ExternalAISummaryResult(request: request, enrichment: enrichment,
            provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
    }
}
