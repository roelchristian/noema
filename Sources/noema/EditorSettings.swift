import SwiftUI
import VaultCore
import NoemaBrand

enum EditorPreferences {
    static let fontFamilyKey = "editorFontFamily"
    static let fontSizeKey = "editorFontSize"
    static let aiSummariesKey = "enableOnDeviceAISummaries"
    static let aiSummaryPlacementKey = "aiSummaryPlacement"
    static let showSemanticHeadingsKey = "showSemanticBlockHeadings"
    static let texMacrosKey = TeXMacroStore.defaultsKey
}

enum AISummaryPlacement: String, CaseIterable {
    case editorWhenSidebarClosed
    case sidebarOnly

    static let defaultValue = Self.editorWhenSidebarClosed

    var title: String {
        switch self {
        case .editorWhenSidebarClosed: "Editor when sidebar is closed"
        case .sidebarOnly: "Sidebar only"
        }
    }

    func showsInEditor(sidebarVisible: Bool) -> Bool {
        self == .editorWhenSidebarClosed && !sidebarVisible
    }
}

struct NoemaSettings: View {
    let externalAIService: ExternalAIService
    let aiProviderPreferences: AIProviderPreferences
    let appModel: AppModel?

    init(externalAIService: ExternalAIService, aiProviderPreferences: AIProviderPreferences? = nil, appModel: AppModel? = nil) {
        self.externalAIService = externalAIService
        self.aiProviderPreferences = aiProviderPreferences ?? AIProviderPreferences()
        self.appModel = appModel
    }

    @AppStorage(EditorPreferences.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorPreferences.fontSizeKey) private var fontSize = EditorTypography.defaultSize
    @AppStorage(EditorPreferences.showSemanticHeadingsKey) private var showSemanticHeadings = false
    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false
    @AppStorage(EditorPreferences.aiSummaryPlacementKey) private var aiSummaryPlacement = AISummaryPlacement.defaultValue.rawValue
    @AppStorage(EditorPreferences.texMacrosKey) private var texMacrosStorage = ""

    @AppStorage(ThemePreference.defaultsKey) private var themePreference = ThemePreference.defaultValue.rawValue
    @AppStorage(ThemePreference.fullPaletteKey) private var fullPalette = true

    @State private var showCustomCommandsModal = false

    private var macros: [TeXMacro] {
        _ = texMacrosStorage
        return TeXMacroStore.load()
    }

    private var typography: EditorTypography {
        EditorTypography(family: fontFamily, size: fontSize)
    }

    // Validate for display without rewriting a saved value merely by opening
    // Settings. A deliberate stepper change saves a compatible 10–32 pt value.
    private var validatedFontSize: Binding<Double> {
        Binding(get: { typography.size }, set: { fontSize = EditorTypography(size: $0).size })
    }

    var body: some View {
        Form {
            Section("Document reading and editing") {
                Picker("Document font", selection: $fontFamily) {
                    Text("System (macOS)").tag("")
                    if !typography.isFamilyAvailable {
                        Text("\(fontFamily) — unavailable").tag(fontFamily)
                    }
                    ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                        Text(family)
                            .font(Font(EditorTypography(family: family, size: 13).font(for: .body)))
                            .tag(family)
                    }
                }
                Stepper(value: validatedFontSize, in: EditorTypography.sizeRange, step: 1) {
                    Text("Document text size: \(Int(typography.size)) pt")
                }
                if !typography.isFamilyAvailable {
                    Label("\(fontFamily) is unavailable. Documents use the system font until it is installed again, or you choose another font.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("Document preview") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A place for ideas")
                            .font(Font(typography.font(for: .heading2)))
                        Text("Read, connect, and develop your knowledge. Your chosen font follows you through articles and readable sources.")
                            .font(Font(typography.font(for: .body)))
                            .lineSpacing(typography.lineMetrics(for: .body).extraLeading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("let idea = \"Something new\"")
                            .font(Font(typography.font(for: .code)))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                Text("Applies to document reading and editing. Headings scale with the text; code stays monospaced. Navigation, menus, and other app controls keep their native macOS typography. Changes are saved automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Block display") {
                Toggle("Show semantic block headings", isOn: $showSemanticHeadings)
                Text("Show names such as Idea and Question above block text. Icons are always shown.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Math & TeX") {
                LabeledContent {
                    Button("View or Edit Custom Commands…") {
                        showCustomCommandsModal = true
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom TeX commands")
                        Text(macros.isEmpty ? "No custom commands configured." : "\(macros.count) custom command\(macros.count == 1 ? "" : "s") configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Manage custom \\newcommand definitions (0–3 arguments) for inline ($...$) and display ($$...$$) math.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            IntelligenceSettings(preferences: aiProviderPreferences, appModel: appModel)
            Section("On-device intelligence") {
                Toggle("Enable on-device AI summaries", isOn: $aiSummaries)
                Picker("Show page summaries", selection: $aiSummaryPlacement) {
                    ForEach(AISummaryPlacement.allCases, id: \.rawValue) { placement in
                        Text(placement.title).tag(placement.rawValue)
                    }
                }
                Text("Summaries are always available in the page sidebar. By default, they also appear above the editor when the sidebar is closed.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Enable local page summaries, then choose On-device for Summarize. Requires Apple Intelligence enabled in System Settings. This switch does not enable OpenAI or authorize external requests.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(OnDeviceSummary.unavailabilityReason ?? "On-device model is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ExternalAISettings(service: externalAIService)
            Section("Appearance") {
                LabeledContent("Theme") {
                    ThemePalettePicker(selection: $themePreference)
                        .frame(width: 245, height: 24)
                }
                Text("Hover over a theme to preview its colors. Select to save when the dropdown closes; Escape cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Apply full palette to the app", isOn: $fullPalette)
                    .toggleStyle(.checkbox)
                    .disabled(themePreference == ThemePreference.system.rawValue)
                Text(themePreference == ThemePreference.system.rawValue
                     ? "System follows macOS appearance and accent colors."
                     : "Checked: theme colors for app surfaces, text, and accents. Unchecked: the theme’s main color as the accent, with macOS surfaces and text.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("All palettes follow macOS Light/Dark appearance and accessibility settings. Your choices are saved automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).padding(16).frame(width: 540, height: 760)
        .sheet(isPresented: $showCustomCommandsModal) {
            CustomTeXCommandsModal()
        }
    }
}

struct CustomTeXCommandsModal: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(EditorPreferences.texMacrosKey) private var texMacrosStorage = ""

    @State private var editingOriginalName: String?
    @State private var rawNewcommand = ""
    @State private var macroName = ""
    @State private var macroArgs = 0
    @State private var macroBody = ""
    @State private var macroError: String?

    private var macros: [TeXMacro] {
        _ = texMacrosStorage
        return TeXMacroStore.load()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom TeX Commands")
                        .font(.headline)
                    Text("View, add, edit, or delete custom TeX commands for inline ($...$) and display ($$...$$) math with up to 3 arguments (#1, #2, #3).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            GroupBox("Configured Commands (\(macros.count))") {
                if macros.isEmpty {
                    Text("No custom TeX commands configured yet. Add one below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(macros) { macro in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(macro.newcommandString)
                                            .font(.system(.body, design: .monospaced))
                                            .textSelection(.enabled)
                                        Text("Preview: \( previewSample(for: macro) ) → \(TeXMath.render(previewSample(for: macro), macros: macros))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if editingOriginalName == macro.name {
                                        Text("Editing")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tint)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.tint.opacity(0.12), in: Capsule())
                                    }
                                    Button {
                                        beginEditing(macro)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Edit \(macro.command)")
                                    .accessibilityLabel("Edit \(macro.command)")

                                    Button(role: .destructive) {
                                        deleteMacro(macro)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Delete \(macro.command)")
                                    .accessibilityLabel("Delete \(macro.command)")
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(editingOriginalName == macro.name ? Color.accentColor.opacity(0.08) : Color.clear)
                                )
                            }
                        }
                        .padding(4)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }

            GroupBox(editingOriginalName == nil ? "Add Custom Command" : "Edit Custom Command (\\\(editingOriginalName ?? ""))") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command builder").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField(#"\cmd"#, text: $macroName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 110)
                            Picker("Args", selection: $macroArgs) {
                                ForEach(0...TeXMacro.maxArguments, id: \.self) { count in
                                    Text("\(count) arg\(count == 1 ? "" : "s")").tag(count)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 95)
                            TextField(macroArgs == 0 ? #"\mathbb{R}"# : #"TeX body (#1..\#(macroArgs))"#, text: $macroBody)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit(saveFromBuilder)
                            Button(editingOriginalName == nil ? "Add Command" : "Save Changes", action: saveFromBuilder)
                                .disabled(macroName.trimmingCharacters(in: .whitespaces).isEmpty || macroBody.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Or enter \\newcommand directly").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField(#"\newcommand{\cmd}[2]{\frac{#1}{#2}}"#, text: $rawNewcommand)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit(saveFromRawNewcommand)
                            Button(editingOriginalName == nil ? "Add \\newcommand" : "Save \\newcommand", action: saveFromRawNewcommand)
                                .disabled(rawNewcommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if editingOriginalName != nil {
                        HStack {
                            Spacer()
                            Button("Cancel Edit", action: clearEditor)
                        }
                    }

                    if let macroError {
                        Text(macroError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(6)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    private func previewSample(for macro: TeXMacro) -> String {
        let sampleArgs = (1...max(1, macro.argCount)).prefix(macro.argCount).map { "{x_\($0)}" }.joined()
        return macro.command + sampleArgs
    }

    private func beginEditing(_ macro: TeXMacro) {
        macroError = nil
        editingOriginalName = macro.name
        macroName = macro.command
        macroArgs = macro.argCount
        macroBody = macro.body
        rawNewcommand = macro.newcommandString
    }

    private func deleteMacro(_ macro: TeXMacro) {
        TeXMacroStore.remove(name: macro.name)
        if editingOriginalName == macro.name {
            clearEditor()
        }
    }

    private func clearEditor() {
        editingOriginalName = nil
        macroName = ""
        macroArgs = 0
        macroBody = ""
        rawNewcommand = ""
        macroError = nil
    }

    private func saveFromRawNewcommand() {
        macroError = nil
        if let editingOriginalName {
            if TeXMacroStore.updateFromNewcommand(originalName: editingOriginalName, rawNewcommand) != nil {
                clearEditor()
            } else {
                macroError = "Enter a single valid \\newcommand{\\name}[0..3]{body} using only #1..#n up to 3 arguments."
            }
        } else {
            if TeXMacroStore.addFromNewcommand(rawNewcommand) != nil {
                rawNewcommand = ""
            } else {
                macroError = "Enter a valid \\newcommand{\\name}[0..3]{body} using only #1..#n up to 3 arguments."
            }
        }
    }

    private func saveFromBuilder() {
        macroError = nil
        if let macro = TeXMacro(name: macroName, argCount: macroArgs, body: macroBody) {
            if let editingOriginalName {
                TeXMacroStore.update(originalName: editingOriginalName, with: macro)
            } else {
                TeXMacroStore.upsert(macro)
            }
            clearEditor()
        } else {
            macroError = "Command name must be ASCII letters, arguments 0–3, and body placeholders within #1..#\(macroArgs)."
        }
    }
}
