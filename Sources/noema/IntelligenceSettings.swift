import SwiftUI

/// Preferences choose a provider for an explicit action. They never authorize a
/// request, read credentials, or change automatic on-device work.
struct IntelligenceSettings: View {
    let preferences: AIProviderPreferences
    var appModel: AppModel? = nil
    @State private var showingActivity = false

    var body: some View {
        Section("Artificial Intelligence") {
            Button("Activity History…") { showingActivity = true }
                .sheet(isPresented: $showingActivity) {
                    AIActivityHistoryView(model: appModel)
                }
            Picker("Default AI provider", selection: Binding(
                get: { preferences.settings.defaultProvider },
                set: { preferences.setDefaultProvider($0) }
            )) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            Text(preferences.settings.defaultProvider == .onDevice
                 ? "Process supported actions privately on this Mac."
                 : "Use the configured OpenAI connection for supported actions. Submitted content leaves this Mac and API usage may incur charges.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Changes affect future requests only. Existing summaries, accepted titles and classifications remain unchanged. Provider preferences apply to explicit actions. OpenAI uses your content submission confirmation policy and requires authenticated session access.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Per-action preferences") {
            ForEach(AIAction.configurableActions) { action in
                Picker(selection: overrideBinding(for: action)) {
                    Text("Use Default (\(preferences.settings.defaultProvider.displayName))")
                        .tag(AIProviderPreference.inheritDefault)
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(AIProviderPreference.specific(provider))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.displayName)
                        Text(detail(for: action)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.menu)
                if let explanation = capabilityExplanation(for: action) {
                    Label(explanation, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Reset overrides") { preferences.resetOverrides() }
                .disabled(!hasOverrides)
            Text("Actions use the default unless overridden. An unavailable or unsupported provider reports the reason; Noema never switches providers automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Content enrichment generates the summary and classification together. Legacy summary choices take precedence over a former classification override; when no summary override exists, the classification choice is retained for enrichment.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Automatic titles, classification and source processing remain on-device regardless of these preferences.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasOverrides: Bool {
        preferences.settings.overrides.values.contains { preference in
            if case .specific = preference { return true }
            return false
        }
    }

    private func overrideBinding(for action: AIAction) -> Binding<AIProviderPreference> {
        Binding(
            get: { preferences.settings.overrides[action.preferenceAction] ?? .inheritDefault },
            set: { preferences.setOverride($0, for: action) }
        )
    }

    private func capabilityExplanation(for action: AIAction) -> String? {
        let provider = preferences.settings.preferredProvider(for: action)
        return switch AIProviderCapabilities.capability(for: action, provider: provider).support {
        case .supported: nil
        case .unsupported: AIProviderUnavailableReason.unsupportedAction.errorMessage
        case .unauthorized: AIProviderUnavailableReason.unauthorizedAction.errorMessage
        case .future: AIProviderUnavailableReason.futureAction.errorMessage
        }
    }

    private func detail(for action: AIAction) -> String {
        switch action {
        case .summarizePage: "Generate or refresh a summary and its LCC classification together."
        case .summarizeSource: "Generate a source summary and classification together."
        case .suggestTitle: "Suggest a descriptive page or source title."
        case .classifyLCC: "Classify the selected page or source."
        case .processSource: "Process source content or draft a linked page."
        case .composePage: "Create a reviewable page from a source, topic or URL."
        }
    }
}
