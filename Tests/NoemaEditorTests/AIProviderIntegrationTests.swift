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
        let repository = try await openCanonicalAppFixture(root: root, create: true)
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
        try configureVaultAI(model)
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
            pageTitle: { text in try await probe.generateTitle(text) },
            pageFromTopic: { topic, _ in await probe.record("pageFromTopic", topic); return "Native topic" },
            pageFromSource: { text in await probe.record("pageFromSource", text); return "Native source article" },
            researchTopic: { text in await probe.record("researchTopic", text); return [] }
        )
        model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            await probe.record("cloud", request.content)
            let output: String
            switch request.action {
            case .composePage: throw ExternalAIError.unsupportedAction
            case .summarizePage, .summarizeSource: output = "Cloud fixture summary"
            case .suggestTitle: output = "Cloud Fixture Title"
            case .lccClassification: output = "{\"code\":\"QA\",\"rationale\":\"The document concerns mathematics.\"}"
            }
            return try ExternalAISummaryResult(request: request, summary: output,
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
        try configureVaultAI(f.model, provider: .openAI)
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

    @Test @MainActor func vaultProviderWinsOverLegacyAndTemporaryOverrides() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        try configureVaultAI(f.model, provider: .onDevice, enabled: false)
        f.model.aiProviderPreferences.setDefaultProvider(.openAI)
        f.model.aiProviderPreferences.setOverride(.specific(.openAI), for: .summarizeSource)
        let policy = f.model.activeVaultAIConfiguration
        f.model.requestSourceSummary(selected, provider: .openAI)
        let native = try #require(f.model.nativeSourceSummaryTaskForTesting(id: selected.id))
        await native.value
        #expect(await probe.count("summarize") == 1)
        #expect(await probe.count("cloud") == 0)
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(f.model.activeVaultAIConfiguration == policy)
        #expect(f.model.preferredAIProvider(for: .summarizeSource) == .onDevice)
        try configureVaultAI(f.model, provider: .openAI)
        f.model.requestSourceSummary(selected, provider: .onDevice)
        try await waitUntil { f.model.cloudSummaryConfirmation != nil }
        f.model.cancelSummary(target: .source(selected.id))
        #expect(await probe.count("cloud") == 0)
    }

    @Test @MainActor func sourceDraftingOpensScopedWorkflowBeforeAnyProviderExecutes() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.createPageFromSource(selected, provider: .openAI)
        #expect(f.model.showTopicPage)
        #expect(f.model.aiPageSourceID == selected.id)
        #expect(f.model.aiPageProviderOverride == .openAI)
        #expect(f.model.generatingSourcePages.isEmpty)
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(await probe.total == 0)
        #expect(try await f.repository.scan().notes.count == 1)
    }

    @Test @MainActor func unavailableNativeChoiceNeverFallsBackToCloudOrChangesPreferences() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        try configureVaultAI(f.model, provider: .onDevice)
        let saved = f.model.activeVaultAIConfiguration
        f.model.aiClient.unavailabilityReason = { "Unavailable native model" }
        f.model.requestPageSummary(id: f.note.id, provider: .onDevice)
        #expect(f.model.aiProviderNotice == AIProviderUnavailableReason.localModelUnavailable.errorMessage)
        #expect(!f.model.isSummarizing(target: .page(f.note.id)))
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(await probe.total == 0)
        #expect(f.model.activeVaultAIConfiguration == saved)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func missingCloudKeyRejectsBeforeConsentWithoutNativeFallback() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.cloudSummaryOverride = nil
        f.model.cloudCredentialAvailabilityOverride = { false }
        try configureVaultAI(f.model, provider: .openAI)
        let saved = f.model.activeVaultAIConfiguration
        f.model.requestPageSummary(id: f.note.id)
        try await waitUntil { !f.model.isSummarizing(target: .page(f.note.id)) }
        #expect(f.model.aiProviderNotice == "Configure an OpenAI API key in Intelligence settings, then try again.")
        #expect(f.model.cloudSummaryConfirmation == nil)
        #expect(f.model.cloudSummaryTaskForTesting == nil)
        #expect(await probe.total == 0)
        #expect(f.model.activeVaultAIConfiguration == saved)
        #expect(f.model.preferredAIProvider(for: .summarizePage) == .openAI)
        #expect(BlockDocumentCodec.decode(f.model.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func vaultNativeProviderExecutesReviewedTitleClassificationAndSourcePage() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        try configureVaultAI(f.model, provider: .onDevice)
        let saved = f.model.activeVaultAIConfiguration
        f.model.suggestPageTitle(provider: .onDevice)
        try await waitUntil { !f.model.generatingPageTitle }
        #expect(f.model.title == "Fixture")
        #expect(f.model.pendingAISuggestion?.value == "Native Fixture Title")
        f.model.acceptAISuggestion()
        await f.model.aiSuggestionAcceptanceTaskForTesting?.value
        #expect(f.model.title == "Native Fixture Title")
        f.model.refreshPageLCC(provider: .onDevice)
        try await waitUntil { !f.model.generatingPageLCC }
        #expect(f.model.currentNote?.lcc == nil)
        #expect(f.model.pendingAISuggestion?.value == "QA76")
        f.model.acceptAISuggestion()
        await f.model.aiSuggestionAcceptanceTaskForTesting?.value
        #expect(f.model.currentNote?.lcc == "QA76")
        f.model.refreshSourceLCC(selected, provider: .onDevice)
        try await waitUntil { !f.model.generatingSourceLCCs.contains(selected.id) }
        #expect(try await f.repository.loadSource(id: selected.id).metadata.lcc == nil)
        f.model.acceptAISuggestion()
        await f.model.aiSuggestionAcceptanceTaskForTesting?.value
        #expect(try await f.repository.loadSource(id: selected.id).metadata.lcc == "QA76")
        f.model.aiClient.enrich = { text, mode in
            await probe.record("enrich", text)
            return try ExternalAIEnrichment(title: "Native Source Draft", summary: "Source summary",
                classification: ExternalAILCCSuggestion(code: "QA76", rationale: "Computer science"),
                body: "Native source article", mode: mode)
        }
        f.model.createPageFromSource(selected, provider: .onDevice)
        #expect(await f.model.prepareAIPage(.source(selected.id)))
        #expect(try await f.repository.scan().notes.count == 1)
        #expect(await f.model.publishAIPageDraft(title: "Native Source Draft"))
        let created = try #require(try await f.repository.scan().notes.first { $0.id != f.note.id })
        #expect(created.body.contains("Native source article"))
        #expect(created.linkedSourceIDs.contains(selected.id))
        #expect(await probe.count("enrich") == 1)
        #expect(await probe.count("lccCode") == 2)
        #expect(await probe.count("cloud") == 0)
        #expect(f.model.activeVaultAIConfiguration == saved)
    }

    @Test @MainActor func cloudMetadataSuggestionsRequireReviewAndPreserveUnrelatedArtifactsOnReopen() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        _ = try await f.repository.renameSource(selected, title: selected.title, summary: "Prior source summary", lcc: "DG299")
        f.model.setPageLCC("DG299")
        try await waitUntil { (try? await f.repository.scan().notes.first { $0.id == f.note.id }?.lcc) == "DG299" }
        await f.model.refresh()
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        try configureVaultAI(f.model, provider: .openAI)
        for target in [ExternalAISummaryTarget.page(f.note.id), .source(selected.id)] {
            for action in [AIAction.suggestTitle, .classifyLCC] {
                if action == .suggestTitle {
                    if case .page = target { f.model.suggestPageTitle() }
                    else { f.model.suggestSourceTitle(try await f.repository.loadSource(id: target.id)) }
                } else {
                    if case .page = target { f.model.refreshPageLCC() }
                    else { f.model.refreshSourceLCC(try await f.repository.loadSource(id: target.id)) }
                }
                try await waitUntil { f.model.cloudSummaryConfirmation != nil }
                let confirmation = try #require(f.model.cloudSummaryConfirmation)
                #expect(confirmation.request.action == (action == .suggestTitle ? .suggestTitle : .lccClassification))
                f.model.confirmCloudSummary()
                await f.model.cloudSummaryTaskForTesting?.value
                #expect(f.model.pendingAISuggestion?.action == action)
                if case .page = target {
                    #expect(f.model.title == (action == .suggestTitle ? "Fixture" : "Cloud Fixture Title"))
                    #expect(f.model.currentNote?.lcc == "DG299")
                } else {
                    let before = try await f.repository.loadSource(id: target.id)
                    #expect(before.title == (action == .suggestTitle ? "Source fixture" : "Cloud Fixture Title"))
                    #expect(before.metadata.lcc == "DG299")
                }
                f.model.acceptAISuggestion()
                // Native sheet dismissal must not cancel the accepted canonical write.
                f.model.didDismissAISuggestionReview()
                await f.model.aiSuggestionAcceptanceTaskForTesting?.value
                #expect(f.model.aiProviderNotice == nil)
            }
        }
        try configureVaultAI(f.model, provider: .onDevice)
        await f.model.open(f.root, create: false)
        let stored = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(stored.title == "Cloud Fixture Title")
        #expect(stored.relativePath == f.note.relativePath)
        #expect(stored.lcc == "QA")
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Prior summary")
        #expect(stored.aiTitleProvenance?.provider == "OpenAI")
        #expect(stored.aiLCCProvenance?.sourceRevision != nil)
        let storedSource = try await f.repository.loadSource(id: selected.id)
        #expect(storedSource.metadata.aiSummary == "Prior source summary")
        #expect(storedSource.title == "Cloud Fixture Title" && storedSource.metadata.lcc == "QA")
        #expect(await probe.count("cloud") == 4)
        #expect(await probe.count("summarize") == 0)
    }

    @Test @MainActor func delayedCloudTitleKeepsCapturedProviderAndRejectsStaleAcceptance() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let probe = ProviderProbe(holdSummary: true); mock(f.model, probe: probe)
        f.model.cloudSummaryOverride = { request, consent in
            #expect(consent.approves(request))
            _ = try await probe.summarize(request.content)
            return try ExternalAISummaryResult(request: request, summary: "Cloud Fixture Title",
                provenance: ExternalAIProvenance(model: "gpt-4.1-mini"))
        }
        try configureVaultAI(f.model, provider: .openAI)
        f.model.suggestPageTitle()
        try await waitUntil { f.model.cloudSummaryConfirmation != nil }
        f.model.confirmCloudSummary()
        let worker = try #require(f.model.cloudSummaryTaskForTesting)
        try await waitUntil { await probe.count("summarize") == 1 }
        try configureVaultAI(f.model, provider: .onDevice)
        try await probe.releaseSummary()
        await worker.value
        #expect(f.model.pendingAISuggestion?.provider == .openAI)
        f.model.title = "Manual correction"
        f.model.acceptAISuggestion()
        await f.model.aiSuggestionAcceptanceTaskForTesting?.value
        #expect(f.model.title == "Manual correction")
        #expect(f.model.aiProviderNotice == ExternalAIError.staleContent.localizedDescription)
        let stored = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
        #expect(stored.title == "Fixture")
        #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Prior summary")
    }

    @Test @MainActor func pageTitleSuggestionWaitsForPendingManualClassification() async throws {
        for provider in AIProvider.allCases {
            let f = try await fixture(); defer { f.cleanup() }
            let probe = ProviderProbe(); mock(f.model, probe: probe)
            try configureVaultAI(f.model, provider: provider)
            f.model.setPageLCC("DG299")
            f.model.suggestPageTitle()
            if provider == .openAI {
                try await waitUntil { f.model.cloudSummaryConfirmation != nil || f.model.cloudSummaryError != nil }
                #expect(f.model.cloudSummaryError == nil)
                f.model.confirmCloudSummary()
                await f.model.cloudSummaryTaskForTesting?.value
            } else { await f.model.aiSuggestionTaskForTesting?.value }
            #expect(f.model.pendingAISuggestion != nil)
            f.model.acceptAISuggestion()
            await f.model.aiSuggestionAcceptanceTaskForTesting?.value
            let stored = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
            #expect(stored.lcc == "DG299")
            #expect(stored.title == (provider == .openAI ? "Cloud Fixture Title" : "Native Fixture Title"))
            #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Prior summary")
        }
    }

    @Test @MainActor func debouncedSourceCorrectionCannotBeOverwrittenByAcceptedTitle() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.suggestSourceTitle(selected)
        await f.model.aiSuggestionTaskForTesting?.value
        #expect(f.model.pendingAISuggestion?.value == "Native Fixture Title")
        f.model.updateSourceLCC(selected, lcc: "DG299")
        f.model.acceptAISuggestion()
        await f.model.aiSuggestionAcceptanceTaskForTesting?.value
        #expect(f.model.aiProviderNotice == ExternalAIError.staleContent.localizedDescription)
        try await waitUntil { (try? await f.repository.loadSource(id: selected.id).metadata.lcc) == "DG299" }
        let stored = try await f.repository.loadSource(id: selected.id)
        #expect(stored.title == selected.title)
        #expect(stored.metadata.lcc == "DG299")
    }

    @Test @MainActor func metadataFailureAndCancellationPreserveAllStoredArtifacts() async throws {
        for action in [AIAction.suggestTitle, .classifyLCC] {
            let f = try await fixture(); defer { f.cleanup() }
            let probe = ProviderProbe(); mock(f.model, probe: probe)
            f.model.cloudSummaryOverride = { _, _ in throw ExternalAIError.providerUnavailable }
            try configureVaultAI(f.model, provider: .openAI)
            if action == .suggestTitle { f.model.suggestPageTitle() } else { f.model.refreshPageLCC() }
            try await waitUntil { f.model.cloudSummaryConfirmation != nil }
            f.model.confirmCloudSummary()
            await f.model.cloudSummaryTaskForTesting?.value
            #expect(f.model.cloudSummaryError == ExternalAIError.providerUnavailable.localizedDescription)
            #expect(f.model.pendingAISuggestion == nil)
            f.model.cancelCloudSummary()
            if action == .suggestTitle { f.model.suggestPageTitle() } else { f.model.refreshPageLCC() }
            try await waitUntil { f.model.cloudSummaryConfirmation != nil }
            f.model.cancelCloudSummary()
            f.model.confirmCloudSummary()
            let stored = try #require(try await f.repository.scan().notes.first { $0.id == f.note.id })
            #expect(stored.title == "Fixture" && stored.lcc == nil)
            #expect(BlockDocumentCodec.decode(stored.body).aiSummary?.text == "Prior summary")
            #expect(stored.aiTitleProvenance == nil && stored.aiLCCProvenance == nil)
            #expect(await probe.total == 0)
        }
    }

    @Test @MainActor func legacyNativeSummaryClientMarksUnavailableClassificationWithoutSeparateInference() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        f.model.setPageLCC("DG299")
        try await waitUntil { (try? await f.repository.scan().notes.first { $0.id == f.note.id }?.lcc) == "DG299" }
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.requestPageSummary(id: f.note.id)
        await f.model.nativePageSummaryTaskForTesting?.value
        #expect(await f.model.saveCurrent())
        #expect(f.model.currentNote?.lcc == nil)
        #expect(f.model.currentNote?.lccClassification == nil)
        #expect(await probe.count("inferLCC") == 0)
        #expect(await probe.count("lccCode") == 0)
    }

    @Test(arguments: [AIProvider.onDevice, .openAI])
    @MainActor func disabledVaultImportsSourceWithoutAutomaticInference(provider: AIProvider) async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try configureVaultAI(f.model, provider: provider, enabled: false)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        let imported = try await source(f)
        f.model.enqueueSourceTitle(imported)
        #expect(f.model.generatingSourceTitles.isEmpty)
        #expect(await probe.total == 0)
        #expect(try await f.repository.loadSource(id: imported.id).metadata == imported.metadata)
        #expect(try FileVaultRepository.readSourceOriginal(imported, root: f.root,
            contentStore: f.repository.contentStore) == Data("Selected source content".utf8))
    }

    @Test @MainActor func enabledLocalVaultNamesPageAndSourceAndPreservesArtifactsOnProviderChange() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        try configureVaultAI(f.model, provider: .onDevice)
        f.model.enqueueSourceTitle(selected)
        try await waitUntil { !f.model.generatingSourceTitles.contains(selected.id) }
        let stored = try await f.repository.loadSource(id: selected.id)
        #expect(stored.title == "Native Fixture Title")
        #expect(stored.metadata.aiSummary == "Native fixture summary")
        #expect(stored.metadata.aiTitleProvenance?.provider == "On-device")
        #expect(stored.metadata.aiSummaryProvenance?.model == "Apple Intelligence")
        #expect(stored.metadata.aiTitleProvenance?.generationID == stored.metadata.aiSummaryProvenance?.generationID)
        #expect(stored.metadata.aiLCCProvenance?.sourceRevision == stored.metadata.sha256)
        let reopened = try await openCanonicalAppFixture(root: f.root)
        #expect(try await reopened.loadSource(id: stored.id).metadata == stored.metadata)
        #expect(try FileVaultRepository.readSourceOriginal(stored, root: f.root, contentStore: reopened.contentStore) == Data("Selected source content".utf8))
        f.model.newPage()
        try await waitUntil { f.model.currentNote?.id != f.note.id }
        f.model.body = "New page content for automatic naming"; f.model.edited()
        #expect(await f.model.finishCurrentPage(waitForTitles: true))
        #expect(f.model.title == "Native Fixture Title")
        #expect(await probe.count("pageTitle") == 2)
        #expect(await probe.count("cloud") == 0)
        #expect(f.model.activeVaultAIConfiguration?.provider == .onDevice)
        let calls = await probe.total
        try configureVaultAI(f.model, provider: .openAI)
        #expect(try await f.repository.loadSource(id: stored.id).metadata == stored.metadata)
        #expect(await f.model.closeVault())
        await f.model.open(f.root, create: false)
        try await waitUntil { f.model.sources.contains { $0.id == stored.id } }
        #expect(try await f.repository.loadSource(id: stored.id).metadata == stored.metadata)
        #expect(f.model.sources.first { $0.id == stored.id }?.metadata == stored.metadata)
        #expect(await probe.total == calls)
    }

    @Test @MainActor func automaticNamingPreservesExistingAndPendingManualClassifications() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let corrected = try await f.repository.updateSourceLCC(selected, lcc: "DG299")
        await f.model.refresh()
        let probe = ProviderProbe(); mock(f.model, probe: probe)
        f.model.enqueueSourceTitle(corrected)
        try await waitUntil { !f.model.generatingSourceTitles.contains(selected.id) }
        #expect(try await f.repository.loadSource(id: selected.id).metadata.lcc == "DG299")
        f.model.newPage()
        try await waitUntil { f.model.currentNote?.id != f.note.id }
        let id = try #require(f.model.currentNote?.id)
        f.model.body = "New content"; f.model.edited()
        f.model.setPageLCC("DG299")
        try await waitUntil { (try? await f.repository.scan().notes.first { $0.id == id }?.lcc) == "DG299" }
        #expect(await f.model.finishCurrentPage(waitForTitles: true))
        #expect(f.model.title == "Native Fixture Title")
        #expect(f.model.currentNote?.lcc == "DG299")

        let delayedSource = try await f.repository.importSource(data: Data("Fresh source content".utf8),
            filename: "second.txt", title: "Second source", originURL: nil)
        await f.model.refresh()
        let delayed = ProviderProbe(holdTitle: true); mock(f.model, probe: delayed)
        f.model.enqueueSourceTitle(delayedSource)
        try await waitUntil { await delayed.count("pageTitle") == 1 }
        f.model.updateSourceLCC(delayedSource, lcc: "DG299")
        try await delayed.releaseTitle()
        try await waitUntil { !f.model.generatingSourceTitles.contains(delayedSource.id) }
        try await waitUntil { (try? await f.repository.loadSource(id: delayedSource.id).metadata.lcc) == "DG299" }
        let stored = try await f.repository.loadSource(id: delayedSource.id)
        #expect(stored.title == "Second source")
        #expect(stored.metadata.aiSummary == nil)
    }

    @Test @MainActor func automaticSourceProcessingRejectsMetadataChangedBackToItsPreviousValue() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let selected = try await source(f)
        let probe = ProviderProbe(holdTitle: true); mock(f.model, probe: probe)
        f.model.enqueueSourceTitle(selected)
        try await waitUntil { await probe.count("pageTitle") == 1 }
        let corrected = try await f.repository.updateSourceLCC(selected, lcc: "DG299")
        let restored = try await f.repository.updateSourceLCC(corrected, lcc: nil)
        #expect(restored.metadata == selected.metadata)
        await f.model.refresh()
        try await probe.releaseTitle()
        try await waitUntil { !f.model.generatingSourceTitles.contains(selected.id) }
        #expect(try await f.repository.loadSource(id: selected.id).metadata == selected.metadata)
        let reopened = try await openCanonicalAppFixture(root: f.root)
        #expect(try await reopened.loadSource(id: selected.id).metadata == selected.metadata)
        #expect(try FileVaultRepository.readSourceOriginal(selected, root: f.root, contentStore: reopened.contentStore) == Data("Selected source content".utf8))
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
    private let holdTitle: Bool
    private var pendingTitle: CheckedContinuation<String?, any Error>?
    private var pendingSummary: CheckedContinuation<String, any Error>?
    init(holdSummary: Bool = false, holdTitle: Bool = false) {
        self.holdSummary = holdSummary; self.holdTitle = holdTitle
    }
    var total: Int { calls.values.reduce(0) { $0 + $1.count } }
    func count(_ action: String) -> Int { calls[action]?.count ?? 0 }
    func record(_ action: String, _ text: String) { calls[action, default: []].append(text) }
    func generateTitle(_ text: String) async throws -> String? {
        record("pageTitle", text)
        if holdTitle { return try await withCheckedThrowingContinuation { pendingTitle = $0 } }
        return "Native Fixture Title"
    }
    func releaseTitle() throws {
        guard let pendingTitle else { throw ProviderFixtureFailure.timedOut }
        self.pendingTitle = nil
        pendingTitle.resume(returning: "Native Fixture Title")
    }
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
