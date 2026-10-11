import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct CloudSummaryAdversarialTests {
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CloudAuditFailure.timedOut
    }
    @MainActor private func fixture() async throws -> (URL, AppModel, NoteRecord, FileVaultRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        var document = BlockDocumentCodec.decode("Captured page body")
        document.setAISummary("Original summary")
        let note = try await repository.create(title: "Captured", body: BlockDocumentCodec.encode(document))
        _ = try await repository.create(title: "Other", body: "Unrelated page body")
        let model = AppModel()
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id)
        try await waitUntil { model.currentNote?.id == note.id }
        return (root, model, note, repository)
    }
    @MainActor private func begin(_ model: AppModel, note: NoteRecord) async throws -> CloudAuditLatch {
        let latch = CloudAuditLatch()
        model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            return try await latch.perform(request)
        }
        model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
        model.prepareCloudPageSummary(id: note.id)
        try await waitUntil { model.cloudSummaryConfirmation != nil || model.cloudSummaryError != nil }
        _ = try #require(model.cloudSummaryConfirmation)
        model.confirmCloudSummary()
        await latch.waitUntilStarted()
        return latch
    }
    @Test @MainActor func unchangedRefreshRetainsPendingPublicationAuthority() async throws {
        let (root, model, note, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let latch = try await begin(model, note: note)
        await model.refresh()
        try await latch.finish()
        try await waitUntil { model.cloudSummaryTarget == nil }
        #expect(model.cloudSummaryError == nil)
        let stored = try #require(try await repository.scan().notes.first { $0.id == note.id })
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Delayed cloud summary")
    }
    @Test @MainActor func selectionABARejectsDelayedCloudSummary() async throws {
        let (root, model, note, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let latch = try await begin(model, note: note)
        let other = try #require(model.notes.first { $0.id != note.id })
        model.select(other.id)
        try await waitUntil { model.currentNote?.id == other.id }
        model.select(note.id)
        try await waitUntil { model.currentNote?.id == note.id }
        try await latch.finish()
        try await waitUntil { model.cloudSummaryTarget == nil }
        let stored = try #require(try await repository.scan().notes.first { $0.id == note.id })
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Original summary")
    }
    @Test @MainActor func vaultSwitchRejectsDelayedResultAndPreservesBothVaults() async throws {
        let (root, model, note, repository) = try await fixture()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-audit-target-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let targetRepository = try FileVaultRepository.open(root: destination, create: true)
        let target = try await targetRepository.create(title: "Destination", body: "Destination content")
        let latch = try await begin(model, note: note)
        await model.open(destination, create: false)
        try await latch.finish()
        #expect(model.cloudSummaryTarget == nil)
        let original = try #require(try await repository.scan().notes.first { $0.id == note.id })
        let destinationNote = try #require(try await targetRepository.scan().notes.first { $0.id == target.id })
        #expect(BlockDocumentCodec.decode(original.body).aiSummary?.text == "Original summary")
        #expect(destinationNote.body == target.body)
    }
    @Test @MainActor func deletedTargetIsNotRecreatedByDelayedCloudSummary() async throws {
        let (root, model, note, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let latch = try await begin(model, note: note)
        try await repository.trash(note: note)
        try await latch.finish()
        try await waitUntil { model.cloudSummaryTarget == nil }
        #expect(try await repository.scan().notes.allSatisfy { $0.id != note.id })
        let trash = try await repository.trashedPages()
        #expect(trash.contains { $0.note.id == note.id })
    }
    @Test func independentPageSummaryRejectsCapturedConditionalPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-cloud-page-cas-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let note = try await repository.create(title: "Captured", body: "Original body")
        let snapshot = try await repository.pageSummarySnapshot(note)
        var changed = BlockDocumentCodec.decode(note.body)
        changed.setAISummary("Independently generated local summary")
        _ = try await repository.save(note: note, title: note.title, body: BlockDocumentCodec.encode(changed), tags: note.tags)
        await #expect(throws: (any Error).self) {
            _ = try await repository.publishPageSummary(snapshot, summary: "Delayed cloud result", provenance: SummaryProvenance(provider: "OpenAI", model: "gpt-4.1-mini", generatedAt: Date()), validate: {})
        }
        let stored = try #require(try await repository.scan().notes.first { $0.id == note.id })
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Independently generated local summary")
    }
}
}
private enum CloudAuditFailure: Error { case timedOut }
private actor CloudAuditLatch {
    private var request: ExternalAISummaryRequest?
    private var pending: CheckedContinuation<ExternalAISummaryResult, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func perform(_ request: ExternalAISummaryRequest) async throws -> ExternalAISummaryResult {
        self.request = request
        return try await withCheckedThrowingContinuation { pending = $0; waiter?.resume(); waiter = nil }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() throws {
        guard let request, let pending else { throw CloudAuditFailure.timedOut }
        self.pending = nil
        pending.resume(returning: try ExternalAISummaryResult(request: request, summary: "Delayed cloud summary", provenance: ExternalAIProvenance(model: "gpt-4.1-mini")))
    }
}
