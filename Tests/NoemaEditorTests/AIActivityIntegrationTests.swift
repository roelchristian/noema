import Foundation
import Testing
import ExternalAI
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct AIActivityIntegrationTests {
    @MainActor private func waitUntil(_ predicate: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ActivityFixtureError.timedOut
    }

    @MainActor private func fixture(recording: Bool = true, finishGate: ActivityInferenceGate? = nil,
                                    beginGate: ActivityInferenceGate? = nil) async throws -> ActivityFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-activity-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let note = try await repository.create(title: "Fixture", body: "Private model input never stored in history")
        let store = try SQLiteAIActivityStore(url: root.appendingPathComponent("activity.sqlite"))
        let recordingStore: any AIActivityStore
        if finishGate != nil || beginGate != nil {
            recordingStore = ActivityDelayedFinishStore(store: store, gate: finishGate, beginGate: beginGate)
        }
        else { recordingStore = store }
        let recorder = AIActivityRecorder(store: recording ? recordingStore : nil)
        let domain = "noema-activity-integration-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: EditorPreferences.aiSummariesKey)
        let model = AppModel(aiDefaults: defaults, activityRecorder: recorder)
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        model.aiClient = .init(unavailabilityReason: { nil }, summarize: { _ in "Generated summary" },
            inferLCC: { _ in "QA" }, lccCode: { _ in "QA" }, pageTitle: { _ in "Generated Title" },
            pageFromTopic: { _, _ in "Generated topic article" }, pageFromSource: { _ in "Generated source article" },
            researchTopic: { _ in [] })
        await model.open(root, create: false)
        model.select(note.id)
        try await waitUntil { model.currentNote?.id == note.id }
        return ActivityFixture(root: root, repository: repository, note: note, model: model,
            recorder: recorder, store: store, defaults: defaults, domain: domain)
    }

    @Test @MainActor func nativeSummaryRecordsPublicationAndNoFabricatedUsage() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        f.model.summarizePage()
        let worker = try #require(f.model.nativePageSummaryTaskForTesting)
        await worker.value
        let records = try await f.store.query()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.action == .summarizePage && record.provider == .onDevice)
        #expect(record.executionMode == .userInvoked && record.status == .completed)
        #expect(record.outcome == .published && record.target?.id == f.note.id)
        #expect(record.modelID == "apple-foundation-models")
        #expect(record.usage == nil && record.estimatedCostUSD == nil && record.requestCount == 0)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Generated summary")
        let exported = String(decoding: try await f.recorder.exportMetadata(), as: UTF8.self)
        #expect(!exported.contains("Private model input") && !exported.contains("Generated summary"))
    }

    @Test @MainActor func nativeCancellationFinalizesEvenWhenProviderReturnsLate() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let gate = ActivityInferenceGate()
        f.model.aiClient.summarize = { _ in await gate.wait(); return "Late generated summary" }
        f.model.summarizePage()
        let worker = try #require(f.model.nativePageSummaryTaskForTesting)
        try await waitUntil { await gate.entered }
        f.model.cancelSummary(target: .page(f.note.id))
        await gate.release()
        await worker.value
        let records = try await f.store.query()
        #expect(records.count == 1 && records.first?.status == .cancelled)
        #expect(records.first?.outcome == .notApplicable)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary == nil)
    }

    @Test @MainActor func abandonedCloudConsentIsCancelledWithoutDispatch() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        f.model.prepareCloudPageSummary(id: f.note.id)
        let worker = try #require(f.model.cloudSummaryTaskForTesting)
        await worker.value
        let confirmation = try #require(f.model.cloudSummaryConfirmation)
        f.model.cancelCloudSummary()
        try await waitUntil { try await f.store.query().first?.status == .cancelled }
        let records = try await f.store.query()
        #expect(records.count == 1 && records.first?.id == confirmation.request.id)
        #expect(records.first?.provider == .openAI && records.first?.requestCount == 0)
        #expect(records.first?.outcome == .notApplicable)
    }

    @Test @MainActor func modelChangeDuringCloudActivityBeginCancelsBeforeConsent() async throws {
        let gate = ActivityInferenceGate()
        let f = try await fixture(beginGate: gate); defer { f.cleanup() }
        let originalModel = f.model.externalAIService.configuration.model
        let changedModel = originalModel == "gpt-4.1-mini" ? "gpt-4.1" : "gpt-4.1-mini"
        f.model.prepareCloudPageSummary(id: f.note.id)
        let worker = try #require(f.model.cloudSummaryTaskForTesting)
        try await waitUntil { await gate.entered }
        try f.model.externalAIService.setModel(changedModel)
        await gate.release()
        await worker.value
        let records = try await f.store.query()
        let record = try #require(records.first)
        #expect(records.count == 1 && record.modelID == originalModel)
        #expect(record.status == .cancelled && record.failureCode == .publication)
        #expect(record.requestCount == 0 && record.outcome == .notApplicable)
        #expect(f.model.cloudSummaryConfirmation == nil && f.model.cloudSummaryTarget == nil)
    }

    @Test @MainActor func suggestionsRecordReviewOutcomesWithoutAnotherInference() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        f.model.suggestPageTitle(provider: .onDevice)
        await f.model.aiSuggestionTaskForTesting?.value
        let rejected = try #require(f.model.pendingAISuggestion)
        f.model.dismissAISuggestion()
        try await waitUntil { try await f.store.query().first?.outcome == .rejected }
        f.model.suggestPageTitle(provider: .onDevice)
        await f.model.aiSuggestionTaskForTesting?.value
        let accepted = try #require(f.model.pendingAISuggestion)
        f.model.acceptAISuggestion()
        await f.model.aiSuggestionAcceptanceTaskForTesting?.value
        let records = try await f.store.query()
        #expect(records.count == 2)
        #expect(records.first(where: { $0.id == rejected.id })?.outcome == .rejected)
        #expect(records.first(where: { $0.id == accepted.id })?.outcome == .published)
        #expect(records.allSatisfy { $0.status == .completed && $0.action == .suggestTitle })
    }

    @Test @MainActor func automaticSourceProcessingGroupsThreeHelpersAndSourceDraftGroupsHelpers() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let source = try await f.repository.importSource(data: Data("Source input".utf8),
            filename: "fixture.txt", title: "Source Fixture", originURL: nil)
        await f.model.refresh()
        f.model.enqueueSourceTitle(source)
        try await waitUntil { try await f.store.query(.init(action: .processSource)).first?.status == .completed }
        let automatic = try await f.store.query(.init(action: .processSource))
        #expect(automatic.count == 1 && automatic.first?.executionMode == .automatic)
        #expect(automatic.first?.target == AIActivityTarget(type: .source, id: source.id))
        try await waitUntil { f.model.generatingSourceTitles.isEmpty }
        let updated = try await f.repository.loadSource(id: source.id)
        injectComposition(f.model)
        f.model.createPageFromSource(updated)
        #expect(await f.model.prepareAIPage(.source(updated.id)))
        let draft = try #require(f.model.aiPageDraft)
        #expect(await f.model.publishAIPageDraft(title: try #require(draft.enrichment.title)))
        let records = try await f.store.query()
        #expect(records.count == 2)
        #expect(records.first(where: { $0.action == .composePage })?.executionMode == .userInvoked)
        #expect(records.first(where: { $0.action == .composePage })?.outcome == .published)
    }

    @Test @MainActor func unavailableRecorderNeverChangesSuccessfulInference() async throws {
        let f = try await fixture(recording: false); defer { f.cleanup() }
        f.model.summarizePage()
        await f.model.nativePageSummaryTaskForTesting?.value
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Generated summary")
        #expect(await f.recorder.recordingUnavailable)
        #expect(try await f.store.count() == 0)
        injectComposition(f.model)
        #expect(await f.model.prepareAIPage(.topic("Fixture topic")))
        #expect(await f.model.publishAIPageDraft(title: "Reviewed Title"))
        #expect(try await f.store.count() == 0)
    }

    @Test @MainActor func cancellationWhileSuggestionFinishIsDelayedNeverExposesReview() async throws {
        let gate = ActivityInferenceGate()
        let f = try await fixture(finishGate: gate); defer { f.cleanup() }
        f.model.suggestPageTitle(provider: .onDevice)
        let worker = try #require(f.model.aiSuggestionTaskForTesting)
        try await waitUntil { await gate.entered }
        #expect(f.model.pendingAISuggestion == nil)
        f.model.dismissAISuggestion()
        await gate.release()
        await worker.value
        let records = try await f.store.query()
        #expect(records.count == 1 && records.first?.outcome == .rejected)
        #expect(f.model.pendingAISuggestion == nil && f.model.title == "Fixture")
    }

    @Test @MainActor func cloudCancellationWaitsForDispatchAndUsageObservations() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let gate = ActivityInferenceGate(), recorder = f.recorder
        f.model.cloudSummaryOverride = { request, _ in
            await gate.wait()
            await recorder.recordDispatch(request.id)
            await recorder.recordUsage(request.id, usage: .init(inputTokens: 17, outputTokens: 9))
            return try ExternalAISummaryResult(request: request, summary: "Unpublished result",
                provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
        }
        f.model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
        f.model.prepareCloudPageSummary(id: f.note.id)
        await f.model.cloudSummaryTaskForTesting?.value
        _ = try #require(f.model.cloudSummaryConfirmation)
        f.model.confirmCloudSummary()
        let worker = try #require(f.model.cloudSummaryTaskForTesting)
        try await waitUntil { await gate.entered }
        f.model.cancelCloudSummary()
        #expect(try await f.store.query().first?.status == .running)
        await gate.release()
        await worker.value
        let record = try #require(try await f.store.query().first)
        #expect(record.status == .cancelled && record.requestCount == 1)
        #expect(record.usage?.inputTokens == 17 && record.usage?.outputTokens == 9)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary == nil)
    }

    @Test @MainActor func staleNativeSummaryPreservesEditedContentAndEndsCancelled() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let gate = ActivityInferenceGate()
        f.model.aiClient.summarize = { _ in await gate.wait(); return "Stale summary" }
        f.model.summarizePage()
        let worker = try #require(f.model.nativePageSummaryTaskForTesting)
        try await waitUntil { await gate.entered }
        f.model.body = "Content changed during inference"
        f.model.edited()
        await gate.release()
        await worker.value
        let record = try #require(try await f.store.query().first)
        #expect(record.status == .cancelled && record.failureCode == .publication)
        #expect(f.model.body == "Content changed during inference")
    }

    @Test @MainActor func topicCreationAndInitialPageNamingGroupTheirLocalHelpers() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        injectComposition(f.model)
        #expect(await f.model.createPageFromTopic("Fixture topic"))
        let draft = try #require(f.model.aiPageDraft)
        #expect(await f.model.publishAIPageDraft(title: try #require(draft.enrichment.title)))
        let topicRecords = try await f.store.query(.init(action: .composePage))
        #expect(topicRecords.count == 1 && topicRecords.first?.outcome == .published)
        f.model.newPage()
        try await waitUntil { f.model.currentNote?.title == "Untitled" }
        f.model.body = "An article needing its first topic title and initial classification"
        f.model.edited()
        #expect(await f.model.finishCurrentPage(waitForTitles: true))
        let titles = try await f.store.query(.init(action: .suggestTitle))
        #expect(titles.count == 1 && titles.first?.executionMode == .automatic)
        #expect(titles.first?.status == .completed && titles.first?.outcome == .published)
        #expect(f.model.currentNote?.title == "Generated Title" && f.model.currentNote?.lcc == "QA")
        #expect(try await f.store.count() == 2)
    }

    @MainActor private func injectComposition(_ model: AppModel) {
        model.aiClient.enrich = { _, mode in
            try ExternalAIEnrichment(title: mode == .regenerate ? nil : "Generated Title",
                summary: "Generated summary", classification: ExternalAILCCSuggestion(code: "QA", rationale: "Mathematics"),
                body: mode == .compose ? "Generated article" : nil, mode: mode)
        }
        model.aiClient.researchTopic = { _ in
            [WebTopicResult(title: "Evidence", url: URL(string: "https://example.com/evidence")!, text: "Selected evidence")]
        }
        model.aiPageFetch = { _ in WebSourceFetch(data: Data("Fetched evidence".utf8), filename: "page.txt") }
    }

    @Test @MainActor func reviewedCompositionRecordsOneOperationForEveryInputAndProvider() async throws {
        for provider in AIProvider.allCases {
            for inputIndex in 0..<3 {
                let f = try await fixture(); defer { f.cleanup() }
                injectComposition(f.model)
                f.model.aiProviderPreferences.setDefaultProvider(provider)
                let recorder = f.recorder
                f.model.cloudSummaryOverride = { request, consent in
                    #expect(consent.approves(request))
                    await recorder.recordDispatch(request.id)
                    await recorder.recordUsage(request.id, usage: .init(inputTokens: 15, outputTokens: 20))
                    let enrichment = try ExternalAIEnrichment(title: "Generated Title", summary: "Generated summary",
                        classification: ExternalAILCCSuggestion(code: "QA", rationale: "Mathematics"),
                        body: "Generated article", mode: .compose)
                    return try ExternalAISummaryResult(request: request, enrichment: enrichment,
                        provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
                }
                f.model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
                let input: AIPageInput
                if inputIndex == 0 {
                    let source = try await f.repository.importSource(data: Data("Source evidence".utf8),
                        filename: "evidence.txt", title: "Source", originURL: nil)
                    await f.model.refresh()
                    input = .source(source.id)
                } else if inputIndex == 1 { input = .topic("Fixture topic") }
                else { input = .url("https://example.com/article", retainSource: true) }
                #expect(await f.model.prepareAIPage(input))
                if provider == .openAI { await f.model.generateCloudAIPage() }
                let draft = try #require(f.model.aiPageDraft)
                let suggested = try #require(try await f.store.query().first)
                #expect(try await f.store.count() == 1)
                #expect(suggested.action == .composePage && suggested.status == .completed && suggested.outcome == .suggested)
                #expect(suggested.target == AIActivityTarget(type: .page, id: draft.id))
                #expect(try await f.repository.scan().notes.count == 1)
                #expect(await f.model.publishAIPageDraft(title: "Reviewed Title"))
                let published = try #require(try await f.store.query().first)
                #expect(published.id == suggested.id && published.outcome == .published)
                #expect(try await f.store.count() == 1)
                #expect(published.requestCount == (provider == .openAI ? 1 : 0))
                #expect(published.usage?.inputTokens == (provider == .openAI ? 15 : nil))
            }
        }
    }

    @Test @MainActor func cancelledCompositionConsentAndDismissedDraftFinalizeExistingRecords() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        injectComposition(f.model)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.cloudSummaryOverride = { _, _ in throw ExternalAIError.invalidResponse }
        #expect(await f.model.prepareAIPage(.topic("Fixture topic")))
        let request = try #require(f.model.aiPageSubmission?.request)
        f.model.cancelAIPage()
        try await waitUntil { try await f.store.query().first?.status == .cancelled }
        let cancelled = try #require(try await f.store.query().first)
        #expect(cancelled.id == request.id && cancelled.requestCount == 0)
        f.model.aiProviderPreferences.setDefaultProvider(.onDevice)
        #expect(await f.model.prepareAIPage(.topic("Fixture topic")))
        let suggested = try #require(try await f.store.query().first)
        f.model.cancelAIPage()
        try await waitUntil { try await f.store.query().first?.outcome == .rejected }
        let rejected = try #require(try await f.store.query().first)
        #expect(rejected.id == suggested.id && rejected.status == .completed)
        #expect(try await f.store.count() == 2 && f.model.aiPageDraft == nil)
        #expect(try await f.repository.scan().notes.count == 1)
    }

    @Test @MainActor func compositionCancelledDuringDelayedFinishNeverExposesDraft() async throws {
        let gate = ActivityInferenceGate()
        let f = try await fixture(finishGate: gate); defer { f.cleanup() }
        injectComposition(f.model)
        let worker = Task { await f.model.prepareAIPage(.topic("Fixture topic")) }
        try await waitUntil { await gate.entered }
        f.model.cancelAIPage()
        await gate.release()
        #expect(await worker.value == false)
        let record = try #require(try await f.store.query().first)
        #expect(record.status == .completed && record.outcome == .rejected)
        #expect(f.model.aiPageDraft == nil && f.model.aiPageSubmission == nil)
    }

    @Test @MainActor func modelChangeDuringCompositionBeginCancelsBeforeConsent() async throws {
        let gate = ActivityInferenceGate()
        let f = try await fixture(beginGate: gate); defer { f.cleanup() }
        injectComposition(f.model)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.cloudSummaryOverride = { _, _ in throw ExternalAIError.invalidResponse }
        let originalModel = f.model.externalAIService.configuration.model
        let worker = Task { await f.model.prepareAIPage(.topic("Fixture topic")) }
        try await waitUntil { await gate.entered }
        try f.model.externalAIService.setModel(originalModel == "gpt-4.1-mini" ? "gpt-4.1" : "gpt-4.1-mini")
        await gate.release()
        #expect(await worker.value == false)
        let record = try #require(try await f.store.query().first)
        #expect(record.status == .cancelled && record.failureCode == .publication)
        #expect(record.modelID == originalModel && record.requestCount == 0)
        #expect(f.model.aiPageSubmission == nil && f.model.aiPageDraft == nil)
    }

    @Test @MainActor func automaticCloudCompositionConsentStillUsesOneRequestBoundRecord() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        injectComposition(f.model)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.externalAIService.setConsentPolicy(.neverAsk)
        let recorder = f.recorder
        f.model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            await recorder.recordDispatch(request.id)
            let enrichment = try ExternalAIEnrichment(title: "Generated Title", summary: "Generated summary",
                classification: nil, body: "Generated article", mode: .compose)
            return try ExternalAISummaryResult(request: request, enrichment: enrichment,
                provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
        }
        f.model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
        #expect(await f.model.prepareAIPage(.topic("Fixture topic")))
        #expect(f.model.aiPageSubmission == nil && f.model.aiPageDraft != nil)
        let record = try #require(try await f.store.query().first)
        #expect(try await f.store.count() == 1 && record.requestCount == 1)
        #expect(record.action == .composePage && record.outcome == .suggested)
        f.model.cancelAIPage()
    }
}
}

private enum ActivityFixtureError: Error { case timedOut }
@MainActor private struct ActivityFixture {
    let root: URL
    let repository: FileVaultRepository
    let note: NoteRecord
    let model: AppModel
    let recorder: AIActivityRecorder
    let store: SQLiteAIActivityStore
    let defaults: UserDefaults
    let domain: String
    func cleanup() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
private actor ActivityInferenceGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

/// Delays selected first writes to exercise caller reentrancy.
private actor ActivityDelayedFinishStore: AIActivityStore {
    let store: SQLiteAIActivityStore
    let gate: ActivityInferenceGate?
    let beginGate: ActivityInferenceGate?
    private var delayed = false
    private var beginDelayed = false
    init(store: SQLiteAIActivityStore, gate: ActivityInferenceGate?, beginGate: ActivityInferenceGate? = nil) {
        self.store = store; self.gate = gate; self.beginGate = beginGate
    }
    func insert(_ record: AIActivityRecord) async throws {
        if !beginDelayed, let beginGate { beginDelayed = true; await beginGate.wait() }
        try await store.insert(record)
    }
    func recordDispatch(_ id: UUID) async throws { try await store.recordDispatch(id) }
    func recordUsage(_ id: UUID, usage: AIActivityUsage, estimatedCostUSD: Double?) async throws {
        try await store.recordUsage(id, usage: usage, estimatedCostUSD: estimatedCostUSD)
    }
    func finish(_ id: UUID, at: Date, status: AIActivityStatus, outcome: AIActivityOutcome,
                failureCode: AIActivityFailureCode?) async throws {
        if !delayed, status == .completed, outcome == .suggested, let gate { delayed = true; await gate.wait() }
        try await store.finish(id, at: at, status: status, outcome: outcome, failureCode: failureCode)
    }
    func updateOutcome(_ id: UUID, outcome: AIActivityOutcome) async throws { try await store.updateOutcome(id, outcome: outcome) }
    func query(_ query: AIActivityQuery) async throws -> [AIActivityRecord] { try await store.query(query) }
    func count(_ query: AIActivityQuery) async throws -> Int { try await store.count(query) }
    func retentionDays() async throws -> Int? { try await store.retentionDays() }
    func setRetentionDays(_ days: Int?) async throws { try await store.setRetentionDays(days) }
    func prune(before now: Date) async throws { try await store.prune(before: now) }
    func clearHistory() async throws { try await store.clearHistory() }
}
