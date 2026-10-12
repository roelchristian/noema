import AppKit
import SwiftUI
import VaultCore

enum SettingsGroup: String, CaseIterable, Identifiable, Sendable {
    case personalisation
    case intelligence
    case security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personalisation: "Personalisation"
        case .intelligence: "Intelligence"
        case .security: "Security"
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .personalisation: [.appearance, .readingAndEditor]
        case .intelligence: [.intelligence, .openAI]
        case .security: [.vaultAccess]
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance
    case readingAndEditor
    case intelligence
    case openAI
    case vaultAccess

    static let defaultCategory: Self = .appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .readingAndEditor: "Reading & Editor"
        case .intelligence: "Intelligence"
        case .openAI: "OpenAI"
        case .vaultAccess: "Vault Access"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .readingAndEditor: "textformat"
        case .intelligence: "brain.head.profile"
        case .openAI: "cloud"
        case .vaultAccess: "lock.shield"
        }
    }

    var group: SettingsGroup {
        switch self {
        case .appearance, .readingAndEditor: .personalisation
        case .intelligence, .openAI: .intelligence
        case .vaultAccess: .security
        }
    }
}

enum SettingsModalMetrics {
    static let idealWidth: CGFloat = 840
    static let idealHeight: CGFloat = 600
    static let minWidth: CGFloat = 680
    static let minHeight: CGFloat = 460
    static let maxWidth: CGFloat = 860
    static let maxHeight: CGFloat = 620
    static let sidebarWidth: CGFloat = 210

    static func resolvedSize(for availableSize: CGSize) -> CGSize {
        let targetWidth = min(max(idealWidth, minWidth), maxWidth)
        let targetHeight = min(max(idealHeight, minHeight), maxHeight)
        let width = availableSize.width > 0
            ? min(max(min(targetWidth, availableSize.width), min(minWidth, availableSize.width)), maxWidth)
            : targetWidth
        let height = availableSize.height > 0
            ? min(max(min(targetHeight, availableSize.height), min(minHeight, availableSize.height)), maxHeight)
            : targetHeight
        return CGSize(width: width, height: height)
    }
}

struct NoemaSettings: View {
    let externalAIService: ExternalAIService
    let aiProviderPreferences: AIProviderPreferences
    let model: AppModel?
    @Environment(\.dismiss) private var dismiss
    @State private var localCategory: SettingsCategory
    @State private var localCustomCommandsModal = false
    @State private var localActivityHistory = false

    init(
        externalAIService: ExternalAIService,
        aiProviderPreferences: AIProviderPreferences? = nil,
        model: AppModel? = nil,
        initialCategory: SettingsCategory = .defaultCategory
    ) {
        self.externalAIService = externalAIService
        self.aiProviderPreferences = aiProviderPreferences ?? AIProviderPreferences()
        self.model = model
        _localCategory = State(initialValue: model?.selectedSettingsCategory ?? initialCategory)
    }

    private var selectedCategory: SettingsCategory {
        model?.selectedSettingsCategory ?? localCategory
    }

    private var categoryBinding: Binding<SettingsCategory> {
        Binding(
            get: { selectedCategory },
            set: { newValue in
                localCategory = newValue
                model?.selectedSettingsCategory = newValue
            }
        )
    }

    private var customCommandsBinding: Binding<Bool> {
        Binding(
            get: { model?.showCustomTeXCommandsModal ?? localCustomCommandsModal },
            set: { newValue in
                localCustomCommandsModal = newValue
                model?.showCustomTeXCommandsModal = newValue
            }
        )
    }

    private var activityHistoryBinding: Binding<Bool> {
        Binding(
            get: { model?.showAIActivityHistory ?? localActivityHistory },
            set: { newValue in
                localActivityHistory = newValue
                model?.showAIActivityHistory = newValue
            }
        )
    }

    private func dismissSettings() {
        guard model?.isVaultAuthenticationPending != true else { return }
        localCustomCommandsModal = false
        localActivityHistory = false
        model?.dismissSettings()
        dismiss()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailColumn
        }
        .frame(
            minWidth: SettingsModalMetrics.minWidth,
            idealWidth: SettingsModalMetrics.idealWidth,
            maxWidth: SettingsModalMetrics.maxWidth,
            minHeight: SettingsModalMetrics.minHeight,
            idealHeight: SettingsModalMetrics.idealHeight,
            maxHeight: SettingsModalMetrics.maxHeight
        )
        .interactiveDismissDisabled(model?.isVaultAuthenticationPending == true)
        .sheet(isPresented: customCommandsBinding) {
            CustomTeXCommandsModal()
                .systemNoemaTheme()
        }
        .sheet(isPresented: activityHistoryBinding) {
            AIActivityHistoryView(model: model)
                .systemNoemaTheme()
        }
        .background(
            SettingsModalBridge(
                phase: model?.sessionPhase ?? .closed,
                onLockDismiss: { model?.dismissSettings(force: true) }
            )
        )
    }

    private var sidebar: some View {
        List(selection: categoryBinding) {
            ForEach(SettingsGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.categories) { category in
                        Label(category.title, systemImage: category.symbol)
                            .tag(category)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: SettingsModalMetrics.sidebarWidth)
        .accessibilityLabel("Settings categories")
    }

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: NoemaSpacing.md) {
                Text(selectedCategory.title)
                    .font(NoemaTypography.libraryTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") {
                    dismissSettings()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model?.isVaultAuthenticationPending == true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Form {
                switch selectedCategory {
                case .appearance:
                    AppearanceSettingsPane()
                case .readingAndEditor:
                    ReadingEditorSettingsPane(showCustomCommandsModal: customCommandsBinding)
                case .intelligence:
                    IntelligenceSettings(
                        preferences: aiProviderPreferences,
                        appModel: model,
                        showingActivity: activityHistoryBinding
                    )
                case .openAI:
                    ExternalAISettings(service: externalAIService)
                case .vaultAccess:
                    VaultAccessSettings(model: model)
                }
            }
            .formStyle(.grouped)
            .id(selectedCategory)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Coordinates modal Settings sheet teardown when the vault transitions into `.locked`.
struct SettingsModalBridge: NSViewRepresentable {
    let phase: VaultSessionPhase
    var onLockDismiss: (() -> Void)? = nil

    func makeNSView(context: Context) -> ModalStateView {
        ModalStateView(phase: phase, onLockDismiss: onLockDismiss)
    }

    func updateNSView(_ view: ModalStateView, context: Context) {
        view.update(phase: phase, onLockDismiss: onLockDismiss)
    }

    final class ModalStateView: NSView {
        private var phase: VaultSessionPhase
        private var onLockDismiss: (() -> Void)?

        init(phase: VaultSessionPhase, onLockDismiss: (() -> Void)? = nil) {
            self.phase = phase
            self.onLockDismiss = onLockDismiss
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(phase nextPhase: VaultSessionPhase, onLockDismiss: (() -> Void)? = nil) {
            if let onLockDismiss {
                self.onLockDismiss = onLockDismiss
            }
            let previousPhase = phase
            phase = nextPhase
            // Close only after locking succeeds. Global preferences can still be opened
            // while locked, and a failed lock must leave the existing modal sheet alone.
            guard nextPhase == .locked, previousPhase != .locked else { return }
            self.onLockDismiss?()
            guard let window else { return }
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.close()
            }
            if let parent = window.sheetParent {
                parent.endSheet(window)
                window.close()
            } else {
                window.close()
            }
        }
    }
}
