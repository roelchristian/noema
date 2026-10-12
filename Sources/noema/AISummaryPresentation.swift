import AppKit
import ExternalAI
import SwiftUI
import VaultCore

/// One summary command presentation for pages and sources. Provider choice is resolved by
/// AppModel from Intelligence settings when the action starts.
@MainActor
struct AISummaryPresentation {
    let model: AppModel
    let target: ExternalAISummaryTarget

    var action: AIAction {
        switch target {
        case .page: .summarizePage
        case .source: .summarizeSource
        }
    }
    var provider: AIProvider { model.preferredAIProvider(for: action) }
    var summaryText: String? {
        switch target {
        case .page(let id):
            let body = model.currentNote?.id == id ? model.body : model.notes.first(where: { $0.id == id })?.body
            return body.flatMap { BlockDocumentCodec.decode($0).aiSummary?.text }
        case .source(let id):
            return model.sources.first(where: { $0.id == id })?.metadata.aiSummary
        }
    }
    var hasSummary: Bool { summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    var commandTitle: String { hasSummary ? "Regenerate Summary" : "Summarize" }
    var isBusy: Bool { model.isSummarizing(target: target) }
    var canCancel: Bool {
        if model.activeSummaryProvider(for: target) == .openAI { return true }
        switch target {
        case .page: return isBusy
        case .source(let id): return model.generatingSourceSummaries.contains(id)
        }
    }
    var disabled: Bool {
        guard model.isVaultAvailable else { return true }
        if model.hasPendingCloudSummary || isBusy { return true }
        switch target {
        case .page(let id):
            guard let note = model.notes.first(where: { $0.id == id }) else { return true }
            return note.isEditingLocked || model.editingLockOperations.contains(id)
        case .source(let id):
            return !model.sources.contains(where: { $0.id == id })
                || model.downloadingSources.contains(id) || model.generatingSourceTitles.contains(id)
        }
    }
    func request() {
        switch target {
        case .page(let id): model.requestPageSummary(id: id)
        case .source(let id):
            if let source = model.sources.first(where: { $0.id == id }) {
                model.requestSourceSummary(source)
            }
        }
    }
    func copy() {
        guard let summaryText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summaryText, forType: .string)
    }
}

func aiProviderLabel(_ provider: AIProvider) -> String {
    provider.displayName
}

struct AIProviderBadge: View {
    let provider: AIProvider
    var body: some View {
        Label(aiProviderLabel(provider), systemImage: provider == .onDevice ? "desktopcomputer" : "network")
            .labelStyle(.titleAndIcon)
            .font(NoemaTypography.metadata)
            .foregroundStyle(.secondary)
            .help(provider == .onDevice ? "Runs locally on this Mac" : "Selected text is sent to OpenAI using your submission confirmation policy")
            .accessibilityLabel("AI provider: \(aiProviderLabel(provider))")
    }
}

struct AISummaryProviderDisclosure: View {
    let provider: AIProvider
    var body: some View {
        HStack(spacing: NoemaSpacing.sm) {
            AIProviderBadge(provider: provider)
            Text(provider == .onDevice ? "Runs locally" : "Sends selected text · confirmation policy applies")
                .font(NoemaTypography.metadata).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Primary command and a secondary native menu for stored summary actions.
struct AISummaryControls: View {
    @Bindable var model: AppModel
    let target: ExternalAISummaryTarget
    private var presentation: AISummaryPresentation { AISummaryPresentation(model: model, target: target) }

    var body: some View {
        HStack(spacing: NoemaSpacing.sm) {
            Button { presentation.request() } label: {
                Label(presentation.commandTitle, systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            .disabled(presentation.disabled)
            .help("\(presentation.commandTitle) using \(aiProviderLabel(presentation.provider)); classification updates with the summary")
            .accessibilityLabel("\(presentation.commandTitle) using \(aiProviderLabel(presentation.provider))")
            Menu {
                AISummaryOptionsCommands(model: model, target: target)
            } label: { Label("Summary options", systemImage: "ellipsis").labelStyle(.iconOnly) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Summary options")
        }
    }
}

struct AISummaryOptionsCommands: View {
    @Bindable var model: AppModel
    let target: ExternalAISummaryTarget
    private var presentation: AISummaryPresentation { AISummaryPresentation(model: model, target: target) }

    var body: some View {
        if presentation.hasSummary {
            Button("Copy Summary") { presentation.copy() }
            if case .page(let id) = target {
                Button("Delete Summary", role: .destructive) { model.deleteAISummary() }
                    .disabled(model.currentNote?.id != id || model.editingLocked || presentation.isBusy)
            }
        }
        if presentation.canCancel {
            Button("Cancel Summary") { model.cancelSummary(target: target) }
        }
        SettingsLink { Text("Intelligence Settings…") }
    }
}

/// Context menus use the same state and dispatch as the document and inspector controls.
struct AISummaryMenuCommands: View {
    @Bindable var model: AppModel
    let target: ExternalAISummaryTarget
    private var presentation: AISummaryPresentation { AISummaryPresentation(model: model, target: target) }

    var body: some View {
        Button("\(presentation.commandTitle) · \(aiProviderLabel(presentation.provider))") { presentation.request() }
            .disabled(presentation.disabled)
        AISummaryOptionsCommands(model: model, target: target)
    }
}

struct AISummaryStatus: View {
    @Bindable var model: AppModel
    let target: ExternalAISummaryTarget
    private var statusText: String {
        if model.cloudSummaryConfirmation?.request.target == target { return "Waiting for OpenAI approval…" }
        if model.activeSummaryProvider(for: target) == .openAI { return "Preparing or generating with OpenAI…" }
        if case .source(let id) = target, model.generatingSourceTitles.contains(id),
           !model.generatingSourceSummaries.contains(id) { return "Generating source title on this Mac…" }
        return "Generating summary on this Mac…"
    }
    var body: some View {
        if model.isSummarizing(target: target) {
            HStack(spacing: NoemaSpacing.sm) {
                ProgressView().controlSize(.mini).accessibilityLabel("Summary generation in progress")
                Text(statusText)
                    .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                if AISummaryPresentation(model: model, target: target).canCancel {
                    Button("Cancel") { model.cancelSummary(target: target) }
                        .accessibilityLabel("Cancel summary generation")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Summary generation status")
        }
    }
}

struct AISummaryProviderNotice: View {
    @Bindable var model: AppModel
    var body: some View {
        if let notice = model.aiProviderNotice {
            HStack(spacing: NoemaSpacing.sm) {
                Label(notice, systemImage: "info.circle").font(NoemaTypography.metadata)
                SettingsLink { Text("Intelligence Settings…") }
                Button("Dismiss") { model.aiProviderNotice = nil }
                    .accessibilityLabel("Dismiss AI provider notice")
            }
            .padding(NoemaSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("AI provider needs attention")
        }
    }
}

func aiSummaryProvenanceLabel(provider: String?, model: String?) -> String {
    guard let provider, !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "AI-generated · Provider unspecified"
    }
    let name = provider == "openAI" ? "OpenAI" : provider
    guard let model, !model.isEmpty else { return name }
    return "\(name) · \(model)"
}

/// A generated metadata suggestion stays transient until the user accepts it.
struct AISuggestionReviewSheet: View {
    @Bindable var model: AppModel
    let suggestion: AISuggestion

    private var title: String {
        suggestion.action == .suggestTitle ? "Suggested Title" : "Suggested LCC Classification"
    }

    private var targetTitle: String {
        switch suggestion.target {
        case .page(let id): model.notes.first(where: { $0.id == id })?.title ?? "Page"
        case .source(let id): model.sources.first(where: { $0.id == id })?.title ?? "Source"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.lg) {
            Text(title).font(.title2.bold())
            Text(targetTitle).foregroundStyle(.secondary)
            AIProviderBadge(provider: suggestion.provider)
            Text(suggestion.value).font(.headline).textSelection(.enabled)
            if let rationale = suggestion.rationale, !rationale.isEmpty {
                Text(rationale).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Applying this suggestion changes only the selected item's \(suggestion.action == .suggestTitle ? "title" : "classification"). Existing summaries remain unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Dismiss") { model.dismissAISuggestion() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.acceptAISuggestion() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
