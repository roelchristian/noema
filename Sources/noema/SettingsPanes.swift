import SwiftUI
import AppKit
import VaultCore
import NoemaBrand

struct AppearanceSettingsPane: View {
    @AppStorage(ThemePreference.defaultsKey) private var themePreference = ThemePreference.defaultValue.rawValue
    @AppStorage(ThemePreference.fullPaletteKey) private var fullPalette = true

    var body: some View {
        Section("Theme") {
            LabeledContent("Theme") {
                ThemePalettePicker(selection: $themePreference)
                    .frame(width: 245, height: 24)
            }
            Text("Hover over a theme to preview its colors. Select to save when the menu closes; Escape cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Apply full palette to the app", isOn: $fullPalette)
                .disabled(themePreference == ThemePreference.system.rawValue)

            Text(themePreference == ThemePreference.system.rawValue
                 ? "System follows macOS appearance and accent colors."
                 : "Applies theme surface, text, and accent colors across the workspace. Unchecked uses the theme’s accent color with standard macOS surfaces.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("All palettes follow macOS Light and Dark appearances and accessibility contrast settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ReadingEditorSettingsPane: View {
    @Binding var showCustomCommandsModal: Bool

    init(showCustomCommandsModal: Binding<Bool> = .constant(false)) {
        self._showCustomCommandsModal = showCustomCommandsModal
    }

    @AppStorage(EditorPreferences.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorPreferences.fontSizeKey) private var fontSize = EditorTypography.defaultSize
    @AppStorage(EditorPreferences.showSemanticHeadingsKey) private var showSemanticHeadings = false
    @AppStorage(EditorPreferences.texMacrosKey) private var texMacrosStorage = ""

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
        Section("Typography") {
            Picker("Document font", selection: $fontFamily) {
                Text("System (macOS)").tag("")
                if !typography.isFamilyAvailable {
                    Text("\(fontFamily) — unavailable").tag(fontFamily)
                }
                ForEach(NSFontManager.shared.availableFontFamilies.sorted(), id: \.self) { family in
                    Text(family)
                        .tag(family)
                }
            }
            Stepper(value: validatedFontSize, in: EditorTypography.sizeRange, step: 1) {
                Text("Document text size: \(Int(typography.size)) pt")
            }
            if !typography.isFamilyAvailable {
                Label("\(fontFamily) is unavailable. Documents use the system font until it is installed again, or you choose another font.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GroupBox("Preview") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A place for ideas")
                        .font(Font(typography.font(for: .heading2)))
                    Text("Read, connect, and develop your knowledge across pages and readable sources.")
                        .font(Font(typography.font(for: .body)))
                        .lineSpacing(typography.lineMetrics(for: .body).extraLeading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("let idea = \"Something new\"")
                        .font(Font(typography.font(for: .code)))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            Text("Applies to pages and readable sources. Interface controls keep standard macOS typography.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Semantic Blocks") {
            Toggle("Show semantic block headings", isOn: $showSemanticHeadings)
            Text("Display labels such as Idea and Question above block text. Margin icons are always shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Math & TeX") {
            LabeledContent {
                Button("Custom Commands…") {
                    showCustomCommandsModal = true
                }
                .accessibilityIdentifier("customTeXCommandsButton")
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom TeX commands")
                    Text(macros.isEmpty ? "No custom commands configured." : "\(macros.count) custom command\(macros.count == 1 ? "" : "s") configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Define reusable \\newcommand macros (0–3 arguments) for inline ($...$) and display ($$...$$) math.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
