import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct CloudSummaryIntegrationTests {
    @MainActor private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CloudTestFailure.timedOut
    }

    @MainActor private func fixture() async throws -> (URL, AppModel, NoteRecord, FileVaultRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-summary-\(UUID().uuidString)")
        let repository = try FileVaultRepository.open(root: root, create: true)
        var document = BlockDocumentCodec.decode("Selected page body")
        document.setAISummary("Existing local summary")
        let note = try await repository.create(title: "Fixture", body: BlockDocumentCodec.encode(document))
        let model = AppModel()
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id)
        try await waitUntil { model.currentNote?.id == note.id }
        return (root, model, note, repository)
    }

    @MainActor private func mock(_ model: AppModel, latch: CloudResponseLatch) {
        model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            return try await latch.summarize(request)
        }
        model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
    }

    @Test @MainActor func pageConsentExcludesSummaryAndPublishesProvenance() async throws {
        let (root, model, note, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let latch = CloudResponseLatch(); mock(model, latch: latch)
        model.prepareCloudPageSummary(id: note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
        let consent = try #require(model.cloudSummaryConfirmation)
        #expect(consent.request.content.contains("Selected page body"))
        #expect(!consent.request.content.contains("Existing local summary"))
        #expect(!consent.request.content.contains("created_at"))
        #expect(await latch.count == 0) // Preview does not submit anything.
        model.confirmCloudSummary()
        await latch.waitForRequest()
        try await latch.finish()
        try await waitUntil { model.cloudSummaryTarget == nil }
        #expect(model.cloudSummaryError == nil)
        let stored = try #require(try await repository.scan().notes.first { $0.id == note.id })
        let summary = try #require(BlockDocumentCodec.decode(stored.body).aiSummary)
        #expect(summary.text == "Cloud summary")
        #expect(summary.metadata.extra["aiProvider"] == "OpenAI")
        #expect(summary.metadata.extra["aiModel"] == "gpt-4.1-mini")
        #expect(summary.metadata.extra["aiGeneratedAt"] != nil)
    }

    @Test @MainActor func editorABAAndCancellationRejectDelayedPageResult() async throws {
        let (root, model, note, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let latch = CloudResponseLatch(); mock(model, latch: latch)
            model.prepareCloudPageSummary(id: note.id)
            try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
            _ = try #require(model.cloudSummaryConfirmation)
            model.confirmCloudSummary(); await latch.waitForRequest()
            if cancel { model.cancelCloudSummary() }
            else { let original = model.body; model.body = "Changed"; model.body = original }
            try await latch.finish()
            try await waitUntil { model.cloudSummaryTarget == nil }
            let stored = try #require(try await repository.scan().notes.first { $0.id == note.id })
            #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Existing local summary")
            model.cloudSummaryError = nil
        }
    }

    @Test @MainActor func vaultLockClearsConsentAndRejectsDelayedResult() async throws {
        let (root, model, note, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let latch = CloudResponseLatch(); mock(model, latch: latch)
        model.prepareCloudPageSummary(id: note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil }
        model.confirmCloudSummary(); await latch.waitForRequest()
        _ = await model.lockVault()
        #expect(model.cloudSummaryConfirmation == nil)
        #expect(model.cloudSummaryTarget == nil)
        try await latch.finish()
        let stored = try #require(try await repository.scan().notes.first { $0.id == note.id })
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Existing local summary")
    }

    @Test @MainActor func oversizedTextDoesNotCreateConsentOrDispatch() async throws {
        let (root, model, note, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.body = String(repeating: "x", count: ExternalAILimits.maximumContentBytes + 1)
        model.edited()
        let latch = CloudResponseLatch(); mock(model, latch: latch)
        model.prepareCloudPageSummary(id: note.id)
        try await waitUntil { model.cloudSummaryError != nil }
        #expect(model.cloudSummaryConfirmation == nil)
        #expect(await latch.count == 0)
        #expect(model.cloudSummaryError == ExternalAIError.payloadTooLarge.localizedDescription)
    }

    @Test @MainActor func sourceConsentExcludesMetadataAndRejectsIndependentSummary() async throws {
        let (root, model, _, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try await repository.importSource(data: Data("---\nprivate_tag: secret\n---\nSelected source content".utf8), filename: "fixture.md", title: "Source", originURL: nil)
        await model.refresh()
        let latch = CloudResponseLatch(); mock(model, latch: latch)
        model.prepareCloudSourceSummary(source)
        try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
        let confirmation = try #require(model.cloudSummaryConfirmation)
        #expect(confirmation.request.content == "Selected source content")
        model.confirmCloudSummary(); await latch.waitForRequest()
        _ = try await repository.renameSource(source, title: source.title, summary: "Independent local summary")
        try await latch.finish()
        try await waitUntil { model.cloudSummaryTarget == nil }
        let stored = try await repository.loadSource(id: source.id)
        #expect(stored.metadata.aiSummary == "Independent local summary")
        #expect(stored.metadata.aiSummaryProvenance == nil)
    }

    @Test func sourceOriginalMutationRejectsPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-cas-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileVaultRepository.open(root: root, create: true)
        let source = try await repository.importSource(data: Data("Original".utf8), filename: "fixture.txt", title: "Source", originURL: nil)
        let snapshot = try await repository.sourceSummarySnapshot(id: source.id)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename
        try repository.contentStore.write(Data("Changed".utf8), at: path, condition: .replace(expected: snapshot.original))
        await #expect(throws: (any Error).self) {
            _ = try await repository.publishSourceSummary(snapshot, summary: "Cloud", provenance: SummaryProvenance(provider: "OpenAI", model: "gpt-4.1-mini", generatedAt: Date()), validate: {})
        }
        #expect(try await repository.scanSources(loading: .metadataOnly).sources.first?.metadata.aiSummary == nil)
    }

    @Test func sourceProvenanceRoundTripAndLocalRegenerationClearsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-provenance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileVaultRepository.open(root: root, create: true)
        let source = try await repository.importSource(data: Data("Original".utf8), filename: "fixture.txt", title: "Source", originURL: nil)
        let snapshot = try await repository.sourceSummarySnapshot(id: source.id)
        let cloud = try await repository.publishSourceSummary(snapshot, summary: "Cloud", provenance: SummaryProvenance(provider: "OpenAI", model: "gpt-4.1-mini", generatedAt: Date()), validate: {})
        #expect(try await repository.loadSource(id: source.id).metadata.aiSummaryProvenance?.provider == "OpenAI")
        let local = try await repository.renameSource(cloud, title: cloud.title, summary: "Local")
        #expect(local.metadata.aiSummaryProvenance == nil)
        #expect(try await repository.loadSource(id: source.id).metadata.aiSummaryProvenance == nil)
    }

    @Test func queuedPublicationPredicateRejectsInvalidatedRequest() throws {
        let guardState = CloudSummaryPublicationGuard()
        let id = UUID(); guardState.arm(requestID: id)
        try guardState.validate(requestID: id)
        guardState.invalidate()
        #expect(throws: ExternalAIError.staleContent) { try guardState.validate(requestID: id) }
    }
}
}

private enum CloudTestFailure: Error { case timedOut }
private actor CloudResponseLatch {
    private var pending: CheckedContinuation<ExternalAISummaryResult, any Error>?
    private var request: ExternalAISummaryRequest?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func summarize(_ request: ExternalAISummaryRequest) async throws -> ExternalAISummaryResult {
        self.request = request; count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            waiter?.resume(); waiter = nil
        }
    }
    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() throws {
        guard let request, let pending else { throw CloudTestFailure.timedOut }
        self.pending = nil
        pending.resume(returning: try ExternalAISummaryResult(request: request, summary: "Cloud summary",
            provenance: ExternalAIProvenance(model: "gpt-4.1-mini")))
    }
}
