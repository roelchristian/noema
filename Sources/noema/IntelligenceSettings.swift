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
            }
            await appModel?.externalAIService.refreshStatus()
            guard !Task.isCancelled, appModel?.vaultAISettingsContext?.lease == lease else { return }
            await appModel?.externalAIService.refreshVaultGrant(for: lease)
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
        return "\(context.lease.sessionID)-\(context.lease.generation)-\(appModel.vaultAIConfigurationStore.revision)-\(String(describing: appModel.externalAIService.credentialStatus))"
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
