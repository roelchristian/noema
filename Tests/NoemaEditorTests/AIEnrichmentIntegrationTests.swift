import Foundation
import Testing
import ExternalAI
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct AIEnrichmentIntegrationTests {
    @MainActor private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-enrichment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let note = try await repository.create(title: "Chosen Human Title", body: "Computer science evidence")
        let domain = "noema-enrichment-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: EditorPreferences.aiSummariesKey)
        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = root.appendingPathComponent("local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.select(note.id)
        for _ in 0..<300 {
            if model.currentNote?.id == note.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.currentNote?.id == note.id)
        return Fixture(root: root, repository: repository, model: model, defaults: defaults, domain: domain, note: note)
    }

    @MainActor private func inject(_ model: AppModel, probe: Probe) {
        model.aiClient.unavailabilityReason = { nil }
        model.aiClient.enrich = { text, mode in
            await probe.record(text, mode: mode)
            return try ExternalAIEnrichment(title: mode == .regenerate ? nil : "Generated Computer Page",
                summary: "A computer science summary.",
                classification: ExternalAILCCSuggestion(code: "QA76", rationale: "Computer science evidence."),
                body: mode == .compose ? "An article grounded in selected evidence." : nil, mode: mode)
        }
        model.aiClient.researchTopic = { _ in
            [WebTopicResult(title: "Evidence", url: URL(string: "https://example.com/evidence")!, text: "Computer evidence")]
        }
        model.aiPageFetch = { _ in WebSourceFetch(data: Data("URL evidence".utf8), filename: "page.txt") }
        model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            await probe.record(request.content, mode: request.mode)
            let enrichment = try ExternalAIEnrichment(title: request.mode == .regenerate ? nil : "Generated Computer Page",
                summary: "A computer science summary.", classification: ExternalAILCCSuggestion(code: "QA76", rationale: "Computer science evidence."),
                body: request.mode == .compose ? "An article grounded in selected evidence." : nil, mode: request.mode)
            return try ExternalAISummaryResult(request: request, enrichment: enrichment, provenance: ExternalAIProvenance(model: "gpt-6-luna"))
        }
        model.cloudPublicationOverride = { _ in { try Task.checkCancellation() } }
    }

    @Test @MainActor func nativeInitialAndRegenerationPublishTogetherPreservingTitleAndContent() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = Probe(); inject(f.model, probe: probe)
        for mode in [ExternalAIEnrichmentMode.initial, .regenerate] {
            f.model.requestPageSummary(id: f.note.id)
            let task = try #require(f.model.nativePageSummaryTaskForTesting)
            await task.value
            let saved = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
            #expect(saved.title == f.note.title)
            #expect(BlockDocumentCodec.readable(BlockDocumentCodec.decode(saved.body).withoutAISummary) == "Computer science evidence")
            #expect(saved.lcc == "QA76")
            #expect(saved.lccClassification?.caption == LCCClassificationVocabulary.caption(for: "QA76"))
            #expect(BlockDocumentCodec.decode(saved.body).aiSummary?.text == "A computer science summary.")
            #expect(await probe.modes.last == mode)
        }
        #expect(await probe.modes.count == 2)
    }

    @Test @MainActor func allCompositionInputsUseOneInferenceAndRequireReviewForBothProviders() async throws {
        for provider in AIProvider.allCases {
            for index in 0..<3 {
                let f = try await fixture(); defer { f.cleanup() }
                let probe = Probe(); inject(f.model, probe: probe)
                f.model.aiProviderPreferences.setDefaultProvider(provider)
                let input: AIPageInput
                if index == 0 {
                    let source = try await f.repository.importSource(data: Data("Source evidence".utf8), filename: "evidence.txt", title: "Human Source", originURL: nil)
                    await f.model.refresh()
                    input = .source(source.id)
                } else if index == 1 { input = .topic("Computer science") }
                else { input = .url("https://example.com/article", retainSource: true) }
                #expect(await f.model.prepareAIPage(input))
                if provider == .openAI {
                    #expect(await probe.modes.isEmpty)
                    #expect(f.model.aiPageSubmission?.request.mode == .compose)
                    await f.model.generateCloudAIPage()
                }
                let draft = try #require(f.model.aiPageDraft)
                #expect(try await f.repository.scan().notes.count == 1)
                #expect(await probe.modes == [.compose])
                #expect(await f.model.publishAIPageDraft(title: try #require(draft.enrichment.title)))
                let saved = try #require(try await f.repository.scan().notes.first { $0.id == draft.id })
                #expect(saved.lcc == "QA76")
                #expect(saved.aiTitleProvenance?.generationID == saved.aiLCCProvenance?.generationID)
                #expect(BlockDocumentCodec.decode(saved.body).aiSummary != nil)
                if index != 1 { #expect(saved.sourceIDs?.count == 1) }
                else { #expect(saved.body.contains("https://example.com/evidence")) }
            }
        }
    }

    @Test @MainActor func cancellationOrEditPreservesVaultBeforeDraftPublication() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = Probe(); inject(f.model, probe: probe)
        #expect(await f.model.prepareAIPage(.topic("Computer science")))
        f.model.cancelAIPage()
        #expect(await f.model.publishAIPageDraft(title: "Cancelled") == false)
        #expect(try await f.repository.scan().notes.count == 1)
        #expect(await f.model.prepareAIPage(.topic("Computer science")))
        f.model.body += " changed"
        f.model.edited()
        #expect(await f.model.publishAIPageDraft(title: "Stale") == false)
        #expect(try await f.repository.scan().notes.count == 1)
    }

    @Test @MainActor func urlPrivateDestinationNeverReachesFetcherOrInference() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = Probe(); inject(f.model, probe: probe)
        f.model.aiPageFetch = { _ in Issue.record("Private address reached fetcher"); throw ExternalAIError.invalidResponse }
        #expect(await f.model.prepareAIPage(.url("http://127.0.0.1", retainSource: false)) == false)
        #expect(await probe.modes.isEmpty)
        #expect(try await f.repository.scan().notes.count == 1)
    }

    actor Probe {
        var modes: [ExternalAIEnrichmentMode] = []
        func record(_ text: String, mode: ExternalAIEnrichmentMode) { modes.append(mode) }
    }
    @MainActor struct Fixture {
        let root: URL
        let repository: FileVaultRepository
        let model: AppModel
        let defaults: UserDefaults
        let domain: String
        let note: NoteRecord
        func cleanup() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
    }
}
}
