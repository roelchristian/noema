import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct AIProviderIntegrationTests {
    @MainActor private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProviderFixtureFailure.timedOut
    }

    @MainActor private func fixture() async throws -> ProviderFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-provider-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        var document = BlockDocumentCodec.decode("Selected page content")
        document.setAISummary("Prior summary")
        let note = try await repository.create(title: "Fixture", body: BlockDocumentCodec.encode(document))
        let domain = "noema-provider-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: EditorPreferences.aiSummariesKey)
        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id)
        try await waitUntil { model.currentNote?.id == note.id }
        return ProviderFixture(root: root, model: model, note: note, repository: repository, defaults: defaults, domain: domain)
    }

    @MainActor private func mock(_ model: AppModel, probe: ProviderProbe) {
        model.aiClient = AppModel.AIProcessingClient(
            unavailabilityReason: { nil },
            summarize: { text in try await probe.summarize(text) },
            inferLCC: { text in await probe.record("inferLCC", text); return "QA76" },
            lccCode: { text in await probe.record("lccCode", text); return "QA76" },
            pageTitle: { text in await probe.record("pageTitle", text); return "Native Fixture Title" },
            pageFromTopic: { topic, _ in await probe.record("pageFromTopic", topic); return "Native topic" },
            pageFromSource: { text in await probe.record("pageFromSource", text); return "Native source article" },
            researchTopic: { text in await probe.record("researchTopic", text); return [] }
        )
        model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            await probe.record("cloud", request.content)
            return try ExternalAISummaryResult(request: request, summary: "Cloud fixture summary",
                provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
        }
        model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
    }

    @MainActor private func source(_ fixture: ProviderFixture) async throws -> SourceRecord {
        let source = try await fixture.repository.importSource(data: Data("Selected source content".utf8),
            filename: "fixture.txt", title: "Source fixture", originURL: nil)
        await fixture.model.refresh()
        return source
    }

    @Test @MainActor func preferredCloudSummaryRequiresExplicitSingleUseApproval() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.requestPageSummary(id: f.note.id)
        try await waitUntil { f.model.cloudSummaryConfirmation != nil || f.model.aiProviderNotice != nil }
        let confirmation = try #require(f.model.cloudSummaryConfirmation)
        #expect(confirmation.request.target == .page(f.note.id))
        #expect(confirmation.request.content == "Selected page content")
        #expect(f.model.isSummarizing(target: .page(f.note.id)))
        #expect(await probe.count("cloud") == 0)
        #expect(await probe.count("summarize") == 0)
        f.model.confirmCloudSummary()
        let worker = try #require(f.model.cloudSummaryTaskForTesting)
        await worker.value
        #expect(await probe.count("cloud") == 1)
        f.model.confirmCloudSummary()
        #expect(await probe.count("cloud") == 1)
        #expect(f.model.cloudSummaryConfirmation == nil)
        let stored = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Cloud fixture summary")
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.metadata.extra["aiProvider"] == "OpenAI")
    }

    @Test @MainActor func sourceOverrideAndTemporaryCloudChoiceNeverChangeSavedIntent() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.aiProviderPreferences.setOverride(.specific(.onDevice), for: .summarizeSource)
        let saved = f.defaults.data(forKey: AIProviderPreferences.preferenceKey)
        f.model.requestSourceSummary(selected)
        let native = try #require(f.model.nativeSourceSummaryTaskForTesting(id: selected.id))
        await native.value
        #expect(await probe.count("summarize") == 1)
        #expect(await probe.count("cloud") == 0)
        #expect(try await f.repository.loadSource(id: selected.id).metadata.aiSummaryProvenance?.provider == "On-device")
        f.model.requestSourceSummary(selected, provider: .openAI)
        try await waitUntil { f.model.cloudSummaryConfirmation != nil }
        #expect(f.model.cloudSummaryConfirmation?.request.target == .source(selected.id))
        #expect(await probe.count("cloud") == 0)
        f.model.cancelSummary(target: .source(selected.id))
        f.model.confirmCloudSummary()
        #expect(await probe.count("cloud") == 0)
        #expect(f.defaults.data(forKey: AIProviderPreferences.preferenceKey) == saved)
        #expect(f.model.preferredAIProvider(for: .summarizeSource) == .onDevice)
    }

    @Test @MainActor func unsupportedCloudActionsRejectBeforeAnyProviderExecutes() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.suggestPageTitle()
        #expect(f.model.aiProviderNotice != nil)
        f.model.refreshPageLCC()
        #expect(f.model.aiProviderNotice != nil)
        f.model.refreshSourceLCC(selected)
        #expect(f.model.aiProviderNotice != nil)
        f.model.createPageFromSource(selected)
        #expect(f.model.aiProviderNotice != nil)
        #expect(!f.model.generatingPageTitle && !f.model.generatingPageLCC)
        #expect(f.model.generatingSourceLCCs.isEmpty && f.model.generatingSourcePages.isEmpty)
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(await probe.total == 0)
        #expect(try await f.repository.scan().notes.count == 1)
    }

    @Test @MainActor func unavailableNativeChoiceNeverFallsBackToCloudOrChangesPreferences() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        let saved = f.defaults.data(forKey: AIProviderPreferences.preferenceKey)
        f.model.aiClient.unavailabilityReason = { "Unavailable native model" }
        f.model.requestPageSummary(id: f.note.id, provider: .onDevice)
        #expect(f.model.aiProviderNotice == AIProviderUnavailableReason.localModelUnavailable.errorMessage)
        #expect(!f.model.isSummarizing(target: .page(f.note.id)))
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(await probe.total == 0)
        #expect(f.defaults.data(forKey: AIProviderPreferences.preferenceKey) == saved)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func missingCloudKeyRejectsBeforeConsentWithoutNativeFallback() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.cloudSummaryOverride = nil
        f.model.cloudCredentialAvailabilityOverride = { false }
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        let saved = f.defaults.data(forKey: AIProviderPreferences.preferenceKey)
        f.model.requestPageSummary(id: f.note.id)
        try await waitUntil { !f.model.isSummarizing(target: .page(f.note.id)) }
        #expect(f.model.aiProviderNotice == "Configure an OpenAI API key in Intelligence settings, then try again.")
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(f.model.cloudSummaryTaskForTesting == nil)
        #expect(await probe.total == 0)
        #expect(f.defaults.data(forKey: AIProviderPreferences.preferenceKey) == saved)
        #expect(f.model.preferredAIProvider(for: .summarizePage) == .openAI)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func explicitNativeOverridesExecuteTitleClassificationAndSourcePage() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        let saved = f.defaults.data(forKey: AIProviderPreferences.preferenceKey)
        f.model.suggestPageTitle(provider: .onDevice)
        try await waitUntil { !f.model.generatingPageTitle }
        #expect(f.model.title == "Native Fixture Title")
        #expect(await f.model.saveCurrent())
        f.model.refreshPageLCC(provider: .onDevice)
        try await waitUntil { !f.model.generatingPageLCC }
        #expect(f.model.currentNote?.lcc == "QA76")
        f.model.refreshSourceLCC(selected, provider: .onDevice)
        try await waitUntil { !f.model.generatingSourceLCCs.contains(selected.id) }
        #expect(try await f.repository.loadSource(id: selected.id).metadata.lcc == "QA76")
        f.model.createPageFromSource(selected, provider: .onDevice)
        try await waitUntil { !f.model.generatingSourcePages.contains(selected.id) }
        let created = try #require(try await f.repository.scan().notes.first { $0.id != f.note.id })
        #expect(created.body.contains("Native source article"))
        #expect(created.linkedSourceIDs.contains(selected.id))
        #expect(await probe.count("pageFromSource") == 1)
        #expect(await probe.count("lccCode") == 2)
        #expect(await probe.count("cloud") == 0)
        #expect(f.defaults.data(forKey: AIProviderPreferences.preferenceKey) == saved)
    }

    @Test @MainActor func automaticPageAndSourceNamingRemainNativeWithCloudDefault() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.enqueueSourceTitle(selected)
        try await waitUntil { !f.model.generatingSourceTitles.contains(selected.id) }
        let stored = try await f.repository.loadSource(id: selected.id)
        #expect(stored.title == "Native Fixture Title")
        #expect(stored.metadata.aiSummary == "Native fixture summary")
        f.model.newPage()
        try await waitUntil { f.model.currentNote?.id != f.note.id }
        f.model.body = "New page content for automatic naming"; f.model.edited()
        #expect(await f.model.finishCurrentPage(waitForTitles: true))
        #expect(f.model.title == "Native Fixture Title")
        #expect(await probe.count("pageTitle") == 2)
        #expect(await probe.count("cloud") == 0)
        #expect(f.model.aiProviderPreferences.settings.defaultProvider == .openAI)
    }

    @Test @MainActor func cancelledNativePageWorkerCannotPublishAfterIgnoringCancellation() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(holdSummary: true); mock(f.model, probe: probe)
        f.model.requestPageSummary(id: f.note.id)
        let worker = try #require(f.model.nativePageSummaryTaskForTesting)
        try await waitUntil { await probe.count("summarize") == 1 }
        f.model.cancelSummary(target: .page(f.note.id))
        #expect(!f.model.isSummarizing(target: .page(f.note.id)))
        try await probe.releaseSummary()
        await worker.value
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
        #expect(await f.model.saveCurrent())
        let stored = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func cancelledNativePageFailureCannotReplaceCancellationOrNewRequestState() async throws {
        for startReplacement in [false, true] {
            let f = try await fixture(); defer { f.cleanup() }
            let delayed = ProviderProbe(holdSummary: true); mock(f.model, probe: delayed)
            f.model.requestPageSummary(id: f.note.id)
            let oldWorker = try #require(f.model.nativePageSummaryTaskForTesting)
            try await waitUntil { await delayed.count("summarize") == 1 }
            f.model.cancelSummary(target: .page(f.note.id))
            let cancellationNotice = f.model.aiProviderNotice
            var replacementWorker: Task<Void, Never>?
            let replacement = ProviderProbe(holdSummary: true)
            if startReplacement {
                mock(f.model, probe: replacement)
                f.model.requestPageSummary(id: f.note.id)
                replacementWorker = try #require(f.model.nativePageSummaryTaskForTesting)
                try await waitUntil { await replacement.count("summarize") == 1 }
            }
            try await delayed.releaseSummaryFailure()
            await oldWorker.value
            #expect(f.model.aiSummaryNotice == nil)
            #expect(f.model.aiProviderNotice == (startReplacement ? nil : cancellationNotice))
            #expect(f.model.isSummarizing(target: .page(f.note.id)) == startReplacement)
            #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
            if let replacementWorker {
                try await replacement.releaseSummary()
                await replacementWorker.value
                #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Native fixture summary")
                #expect(await f.model.saveCurrent())
            }
        }
    }

    @Test @MainActor func editorBodyABARejectsDelayedNativeSummary() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(holdSummary: true); mock(f.model, probe: probe)
        f.model.requestPageSummary(id: f.note.id)
        let worker = try #require(f.model.nativePageSummaryTaskForTesting)
        try await waitUntil { await probe.count("summarize") == 1 }
        let captured = f.model.body
        f.model.body = "Changed body"; f.model.body = captured
        try await probe.releaseSummary()
        await worker.value
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
        #expect(!f.model.generatingAISummary)
    }

    @Test @MainActor func pageSelectionABARejectsDelayedNativeSummary() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let other = try await f.repository.create(title: "Other", body: "Other page content")
        await f.model.refresh()
        let probe = ProviderProbe(holdSummary: true); mock(f.model, probe: probe)
        f.model.requestPageSummary(id: f.note.id)
        let worker = try #require(f.model.nativePageSummaryTaskForTesting)
        try await waitUntil { await probe.count("summarize") == 1 }
        f.model.select(other.id)
        try await waitUntil { f.model.currentNote?.id == other.id }
        #expect(!f.model.generatingAISummary)
        #expect(!f.model.isSummarizing(target: .page(f.note.id)))
        f.model.select(f.note.id)
        try await waitUntil { f.model.currentNote?.id == f.note.id }
        try await probe.releaseSummary()
        await worker.value
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func staleSourceOriginalAndIndependentSummaryRejectNativePublication() async throws {
        for mutateOriginal in [false, true] {
            let f = try await fixture(); defer { f.cleanup() }
            let selected = try await source(f)
            let probe = ProviderProbe(holdSummary: true); mock(f.model, probe: probe)
            f.model.requestSourceSummary(selected)
            let worker = try #require(f.model.nativeSourceSummaryTaskForTesting(id: selected.id))
            try await waitUntil { await probe.count("summarize") == 1 }
            if mutateOriginal {
                let path = "Sources/" + selected.id.uuidString.lowercased() + "/" + selected.metadata.storedFilename
                try f.repository.contentStore.write(Data("Changed original".utf8), at: path,
                    condition: .replace(expected: Data("Selected source content".utf8)))
            } else {
                _ = try await f.repository.renameSource(selected, title: selected.title, summary: "Independent summary")
            }
            try await probe.releaseSummary()
            await worker.value
            let stored = try #require(try await f.repository.scanSources(loading: .metadataOnly).sources.first { $0.id == selected.id })
            #expect(stored.metadata.aiSummary == (mutateOriginal ? nil : "Independent summary"))
            #expect(stored.metadata.aiSummaryProvenance == nil)
            #expect(f.model.aiProviderNotice != nil)
        }
    }

    @Test @MainActor func cancelledNativeSourceWorkerCannotOverwriteAReplacementRequest() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let delayed = ProviderProbe(holdSummary: true); mock(f.model, probe: delayed)
        f.model.requestSourceSummary(selected)
        let oldWorker = try #require(f.model.nativeSourceSummaryTaskForTesting(id: selected.id))
        try await waitUntil { await delayed.count("summarize") == 1 }
        f.model.cancelSummary(target: .source(selected.id))
        let replacement = ProviderProbe(holdSummary: true); mock(f.model, probe: replacement)
        f.model.requestSourceSummary(selected)
        let newWorker = try #require(f.model.nativeSourceSummaryTaskForTesting(id: selected.id))
        try await waitUntil { await replacement.count("summarize") == 1 }
        try await delayed.releaseSummary()
        await oldWorker.value
        #expect(f.model.isSummarizing(target: .source(selected.id)))
        #expect(try await f.repository.loadSource(id: selected.id).metadata.aiSummary == nil)
        try await replacement.releaseSummary()
        await newWorker.value
        #expect(!f.model.isSummarizing(target: .source(selected.id)))
        #expect(try await f.repository.loadSource(id: selected.id).metadata.aiSummary == "Native fixture summary")
    }
}
}

private enum ProviderFixtureFailure: Error { case timedOut, providerFailure }

@MainActor private struct ProviderFixture {
    let root: URL
    let model: AppModel
    let note: NoteRecord
    let repository: FileVaultRepository
    let defaults: UserDefaults
    let domain: String

    func cleanup() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ProviderProbe {
    private var calls: [String: [String]] = [:]
    private let holdSummary: Bool
    private var pendingSummary: CheckedContinuation<String, any Error>?
    init(holdSummary: Bool = false) { self.holdSummary = holdSummary }
    var total: Int { calls.values.reduce(0) { $0 + $1.count } }
    func count(_ action: String) -> Int { calls[action]?.count ?? 0 }
    func record(_ action: String, _ text: String) { calls[action, default: []].append(text) }
    func summarize(_ text: String) async throws -> String {
        record("summarize", text)
        if holdSummary {
            // Deliberately ignore cancellation, as a provider can return after it.
            return try await withCheckedThrowingContinuation { pendingSummary = $0 }
        }
        return "Native fixture summary"
    }
    func releaseSummary() throws {
        guard let pendingSummary else { throw ProviderFixtureFailure.timedOut }
        self.pendingSummary = nil
        pendingSummary.resume(returning: "Native fixture summary")
    }
    func releaseSummaryFailure() throws {
        guard let pendingSummary else { throw ProviderFixtureFailure.timedOut }
        self.pendingSummary = nil
        pendingSummary.resume(throwing: ProviderFixtureFailure.providerFailure)
    }
}
