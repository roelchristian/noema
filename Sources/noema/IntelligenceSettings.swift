import SwiftUI
import VaultCore

/// Vault preferences select processing intent; cloud request authority remains separate.
struct IntelligenceSettings: View {
    let preferences: AIProviderPreferences
    var appModel: AppModel? = nil
    var showingActivity: Binding<Bool>? = nil

    @State private var localShowingActivity = false
    @State private var approvalLease: VaultSessionLease?
    @State private var approvalVaultName = ""
    @State private var showingCloudApproval = false
    @State private var showingEmbeddingApproval = false
    @State private var embeddingApprovalLease: VaultSessionLease?
    @State private var embeddingApprovalModel = ""
    private struct HistoricalPrompt: Identifiable {
        let id = UUID()
        let lease: VaultSessionLease
        let configuration: VaultAIConfiguration
        let pageCount: Int
        let sourceCount: Int
        let modelName: String
        let isRebuild: Bool
        var batchID: UUID? = nil
    }
    @State private var historicalPrompt: HistoricalPrompt?
    @State private var grantFeedback: String?
    @State private var grantBusy = false
    @State private var displayedLease: VaultSessionLease?
    @State private var grantCleanupLease: VaultSessionLease?
    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false
    @AppStorage(EditorPreferences.aiSummaryPlacementKey) private var aiSummaryPlacement = AISummaryPlacement.defaultValue.rawValue

    init(
        preferences: AIProviderPreferences,
        appModel: AppModel? = nil,
        showingActivity: Binding<Bool>? = nil
    ) {
        self.preferences = preferences
        self.appModel = appModel
        self.showingActivity = showingActivity
    }

    var body: some View {
        Section("Current Vault") {
            if let appModel, let context = appModel.vaultAISettingsContext {
                let lease = context.lease
                let configuration = context.configuration
                LabeledContent("Vault", value: context.vaultName)
                Toggle("Enable AI in this Vault", isOn: Binding(
                    get: { appModel.vaultAIConfiguration(for: lease)?.enabled ?? configuration.enabled },
                    set: { enabled in
                        updateVaultAI(appModel, lease: lease) { $0.enabled = enabled }
                    }))
                Picker("AI Provider", selection: Binding(
                    get: { appModel.vaultAIConfiguration(for: lease)?.provider ?? configuration.provider },
                    set: { provider in
                        updateVaultAI(appModel, lease: lease) { $0.provider = provider }
                    })) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(configuration.provider == .onDevice
                     ? "Uses supported local AI capabilities on this Mac. No cloud model submission."
                     : "Uses the configured OpenAI connection. Content may leave this Mac and API charges may apply.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Provider readiness", value: readiness(appModel, context: context))
                Text("The toggle controls automatic intelligence. Manual AI commands remain available through their existing consent path. Preferences are saved for this vault on this Mac. Enabling AI does not start a backfill or submit content.")
                    .font(.caption).foregroundStyle(.secondary)
                if configuration.provider == .openAI {
                    LabeledContent("Embedding model", value: appModel.externalAIService.embeddingConfiguration.modelIdentifier)
                    LabeledContent("Embedding dimensions", value: String(appModel.externalAIService.embeddingConfiguration.dimensions))
                    LabeledContent("Semantic index", value: appModel.semanticIndexCompatibility.label)
                    if let issue = appModel.semanticIndexIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                    LabeledContent("Embedding approval", value: appModel.externalAIService.embeddingDocumentsApproved(for: lease)
                        ? "New and changed content, this session" : "Approval required")
                    Button("Allow New and Changed Embeddings…") {
                        embeddingApprovalLease = lease
                        embeddingApprovalModel = appModel.externalAIService.embeddingConfiguration.modelIdentifier
                        showingEmbeddingApproval = true
                    }
                    .disabled(!configuration.enabled || grantBusy)
                    .accessibilityIdentifier("embeddings.approveNewAndChanged")
                    LabeledContent("Vault processing approval", value: appModel.externalAIService.isVaultProcessingApproved(for: lease)
                        ? "Approved on this Mac" : "Approval required")
                    if !appModel.externalAIService.vaultGrants.supportsDurableGrants {
                        Text("This build cannot use device-only vault approval. Use a signed build with data-protection Keychain access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Approve OpenAI Processing…") {
                            approvalLease = lease
                            approvalVaultName = context.vaultName
                            showingCloudApproval = approvalLease != nil
                        }
                        .disabled(!configuration.enabled || grantBusy || !appModel.externalAIService.vaultGrants.supportsDurableGrants)
                        Button("Revoke Approval") {
                            retryGrantCleanup(appModel, lease: lease)
                        }
                        .disabled(grantBusy)
                    }
                }
                Button("Index Existing Content…") {
                    grantBusy = true
                    Task { @MainActor in
                        defer { grantBusy = false }
                        do {
                            let counts = try await appModel.backfillInventory(for: lease)
                            guard appModel.vaultAIConfiguration(for: lease) == configuration else { return }
                            let model = configuration.provider == .openAI
                                ? appModel.externalAIService.embeddingConfiguration.modelIdentifier
                                : try appModel.embeddingProviderFactory().descriptor.modelID
                            historicalPrompt = HistoricalPrompt(lease: lease, configuration: configuration,
                                pageCount: counts.pageCount, sourceCount: counts.sourceCount,
                                modelName: model, isRebuild: appModel.semanticIndexCompatibility == .requiresRebuild)
                        } catch {
                            guard appModel.vaultAIConfiguration(for: lease) != nil else { return }
                            grantFeedback = "Existing-content inventory is unavailable. Reopen the vault and try again."
                        }
                    }
                }
                .disabled(!configuration.enabled || grantBusy || appModel.semanticIndex == nil)
                .accessibilityIdentifier("embeddings.history.openPrompt")
                Button("Resume Existing Batch…") {
                    grantBusy = true
                    Task { @MainActor in
                        defer { grantBusy = false }
                        do {
                            guard let ledger = appModel.aiProcessingLedger else { throw AIWorkFailure.unavailable }
                            let batches = try await ledger.embeddingBatches(vaultID: lease.vaultID)
                            guard appModel.vaultAIConfiguration(for: lease) == configuration else { return }
                            guard let batch = batches.first(where: { [.active, .paused, .awaitingApproval].contains($0.state) }) else {
                                grantFeedback = "There is no resumable historical batch. Index Existing Content to begin."; return
                            }
                            var members: [EmbeddingBackfillMember] = []
                            var offset = 0
                            while true {
                                let page = try await ledger.embeddingBatchMembers(batchID: batch.id, limit: 128, offset: offset)
                                members += page; offset += page.count
                                if page.count < 128 { break }
                            }
                            guard appModel.vaultAIConfiguration(for: lease) == configuration else { return }
                            historicalPrompt = HistoricalPrompt(lease: lease, configuration: configuration,
                                pageCount: members.filter { $0.entityKind == .page }.count,
                                sourceCount: members.filter { $0.entityKind == .source }.count,
                                modelName: batch.generation.model.modelID, isRebuild: batch.mode == .rebuild, batchID: batch.id)
                        } catch {
                            guard appModel.vaultAIConfiguration(for: lease) != nil else { return }
                            grantFeedback = "Historical batch is unavailable. Reopen the vault and try again."
                        }
                    }
                }
                .disabled(!configuration.enabled || grantBusy)
                .accessibilityIdentifier("embeddings.history.resumePrompt")
                if let grantFeedback { Text(grantFeedback).font(.caption).foregroundStyle(.secondary) }
                if grantCleanupLease == lease {
                    Button("Retry Stored OpenAI Approval Cleanup") { retryGrantCleanup(appModel, lease: lease) }
                        .disabled(grantBusy)
                }
            } else {
                Text("Open and unlock a vault to configure its AI processing.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: refreshIdentity) {
            let lease = appModel?.vaultAISettingsContext?.lease
            if displayedLease != lease {
                displayedLease = lease
                grantFeedback = nil
                grantCleanupLease = nil
                approvalLease = nil
                showingCloudApproval = false
                showingEmbeddingApproval = false
                embeddingApprovalLease = nil
                historicalPrompt = nil
            }
            await appModel?.externalAIService.refreshStatus()
            guard !Task.isCancelled, appModel?.vaultAISettingsContext?.lease == lease else { return }
            await appModel?.externalAIService.refreshVaultGrant(for: lease)
            if let lease { await appModel?.refreshSemanticIndexCompatibility(for: lease) }
        }
        .sheet(item: $historicalPrompt) { prompt in
            EmbeddingBackfillPrompt(pageCount: prompt.pageCount, sourceCount: prompt.sourceCount,
                providerName: prompt.configuration.provider.displayName, modelName: prompt.modelName,
                isCloud: prompt.configuration.provider == .openAI, isRebuild: prompt.isRebuild,
                allowsScopeChanges: prompt.batchID == nil,
                onIndex: { scopes in
                    historicalPrompt = nil
                    guard let appModel, appModel.vaultAIConfiguration(for: prompt.lease) == prompt.configuration else { return }
                    if prompt.configuration.provider == .openAI,
                       appModel.externalAIService.embeddingConfiguration.modelIdentifier != prompt.modelName { return }
                    grantBusy = true
                    Task { @MainActor in
                        defer { grantBusy = false }
                        do {
                            if let batchID = prompt.batchID {
                                try await appModel.resumeEmbeddingBackfill(batchID: batchID, for: prompt.lease)
                            } else {
                                _ = try await appModel.startEmbeddingBackfill(for: prompt.lease, scopes: scopes, rebuild: prompt.isRebuild)
                            }
                            guard appModel.vaultAIConfiguration(for: prompt.lease) != nil else { return }
                            grantFeedback = "Existing-content indexing admitted. Canonical content is preserved."
                        } catch {
                            guard appModel.vaultAIConfiguration(for: prompt.lease) != nil else { return }
                            grantFeedback = "Indexing could not start. Check provider readiness or resume the existing batch."
                        }
                    }
                }, onNewAndChangedOnly: {
                    historicalPrompt = nil
                    guard let appModel, (try? appModel.declineEmbeddingBackfill(for: prompt.lease)) != nil else { return }
                    grantFeedback = "No historical indexing started. New and changed cloud content still needs separate approval."
                }, onNotNow: {
                    historicalPrompt = nil
                    try? appModel?.declineEmbeddingBackfill(for: prompt.lease)
                })
        }
        .confirmationDialog("Allow automatic OpenAI processing for \(approvalVaultName)?",
                            isPresented: $showingCloudApproval, titleVisibility: .visible) {
            Button("Approve Processing on This Mac") {
                guard let appModel, let lease = approvalLease else { return }
                grantBusy = true
                Task { @MainActor in
                    defer { grantBusy = false }
                    do {
                        try await appModel.externalAIService.approveVaultProcessing(for: lease)
                        guard appModel.vaultAIConfiguration(for: lease) != nil else { return }
                        grantFeedback = "Vault processing approved on this Mac."
                    } catch {
                        guard appModel.vaultAIConfiguration(for: lease) != nil else { return }
                        grantFeedback = "Approval was cancelled or unavailable. No new processing was authorised."
                    }
                }
            }
            Button("Cancel", role: .cancel) { approvalLease = nil }
        } message: {
            Text("Page and source text in \(approvalVaultName) may be sent to OpenAI automatically after future content changes. API charges may apply. Permission covers summaries, LCC classification and filling unset titles during enrichment; it excludes replacing human-authored titles, page composition and writing assistance. Revoke this approval here, disable AI, change provider, or replace/remove the API key. Approval stays on this Mac. Enabling approval does not start processing.")
        }
        .confirmationDialog("Allow OpenAI embeddings for new and changed content?",
                            isPresented: $showingEmbeddingApproval, titleVisibility: .visible) {
            Button("Allow Embeddings This Session") {
                guard let appModel, let lease = embeddingApprovalLease,
                      appModel.externalAIService.embeddingConfiguration.modelIdentifier == embeddingApprovalModel,
                      appModel.vaultAIConfiguration(for: lease) != nil else { return }
                grantBusy = true
                Task { @MainActor in
                    defer { grantBusy = false }
                    do {
                        guard appModel.externalAIService.embeddingConfiguration.modelIdentifier == embeddingApprovalModel,
                              appModel.vaultAIConfiguration(for: lease) != nil else { return }
                        try await appModel.approveIncrementalEmbeddingDocuments(for: lease)
                        guard appModel.vaultAIConfiguration(for: lease) != nil else { return }
                        grantFeedback = "New and changed content may now be embedded in this unlocked session."
                    } catch {
                        guard appModel.vaultAIConfiguration(for: lease) != nil else { return }
                        grantFeedback = "Embedding approval was cancelled or unavailable. Try again to authorize embeddings."
                    }
                }
            }
            Button("Cancel", role: .cancel) { embeddingApprovalLease = nil }
        } message: {
            Text("Committed Page and Source text may be sent to OpenAI using \(embeddingApprovalModel) after changes. API charges may apply; cost is unknown. This session-only permission excludes existing-content backfill, search queries and enrichment. Locking, changing provider/model, revoking approval or replacing credentials retires this permission. Pending editor drafts are excluded.")
        }
        Section("Manual AI") {
            Toggle("Allow manual on-device page summaries", isOn: $aiSummaries)
            Picker("Summary placement", selection: $aiSummaryPlacement) {
                ForEach(AISummaryPlacement.allCases, id: \.rawValue) { placement in
                    Text(placement.title).tag(placement.rawValue)
                }
            }
            Text("An open vault’s selected provider takes precedence over legacy defaults and overrides.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("On-device availability", value: onDeviceStatusText)
            Text("Changes apply to future explicit requests only. Existing summaries, titles, and classifications are never regenerated automatically. Automatic titles and source processing require this vault’s enabled On-device policy.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("AI Activity") {
            LabeledContent("Activity History") {
                Button("AI Activity…") {
                    openActivityHistory()
                }
                .sheet(isPresented: $localShowingActivity) {
                    AIActivityHistoryView(model: appModel)
                }
            }
            Text("Inspect local technical metadata, token usage, and retention settings for past AI operations.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var refreshIdentity: String {
        guard let appModel, let context = appModel.vaultAISettingsContext else { return "unavailable" }
        return "\(context.lease.sessionID)-\(context.lease.generation)-\(appModel.vaultAIConfigurationStore.revision)-\(String(describing: appModel.externalAIService.credentialStatus))-\(appModel.externalAIService.embeddingConfiguration.modelIdentifier)"
    }

    private func updateVaultAI(_ model: AppModel, lease: VaultSessionLease,
                               change: (inout VaultAIConfiguration) -> Void) {
        guard var updated = model.vaultAIConfiguration(for: lease) else { return }
        change(&updated)
        do {
            try model.setVaultAIConfiguration(updated, for: lease)
            grantFeedback = nil
            grantCleanupLease = nil
        } catch VaultAIConfigurationChangeError.cloudGrantCleanupFailed {
            guard model.vaultAIConfiguration(for: lease) != nil else { return }
            grantCleanupLease = lease
            grantFeedback = "AI preference saved. Automatic work under the previous policy is blocked, but stored OpenAI approval cleanup needs a retry."
        } catch {
            guard model.vaultAIConfiguration(for: lease) != nil else { return }
            grantFeedback = "AI preferences could not be changed. Try again."
        }
    }

    private func retryGrantCleanup(_ model: AppModel, lease: VaultSessionLease) {
        guard model.vaultAIConfiguration(for: lease) != nil else { return }
        do {
            try model.externalAIService.revokeVaultProcessing(for: lease)
            grantCleanupLease = nil
            grantFeedback = "Stored OpenAI approval removed."
        } catch {
            guard model.vaultAIConfiguration(for: lease) != nil else { return }
            grantCleanupLease = lease
            grantFeedback = "Automatic OpenAI processing is blocked. Stored approval cleanup still needs a retry."
        }
    }

    private func readiness(_ model: AppModel, context: VaultAISettingsContext) -> String {
        guard model.vaultAIConfiguration(for: context.lease) != nil else { return "Vault unavailable" }
        guard context.configuration.enabled else { return "Automatic AI disabled" }
        if context.configuration.provider == .onDevice { return model.aiClient.unavailabilityReason() ?? "Ready on this Mac" }
        let service = model.externalAIService
        if let unavailable = service.openAIReadinessDescription { return unavailable }
        guard service.vaultGrants.supportsDurableGrants else { return "Automatic approval unavailable in this build" }
        return service.isVaultProcessingApproved(for: context.lease)
            ? "Ready for authorised automatic processing" : "Connection configured; vault processing approval required"
    }

    private var onDeviceStatusText: String {
        if let appModel {
            return appModel.aiClient.unavailabilityReason() ?? "Available"
        }
        return OnDeviceSummary.unavailabilityReason ?? "Available"
    }

    private func openActivityHistory() {
        if let showingActivity {
            showingActivity.wrappedValue = true
        } else {
            localShowingActivity = true
        }
    }

}
