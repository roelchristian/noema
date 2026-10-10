import SwiftUI
import VaultCore

enum EditorPreferences {
    static let aiSummariesKey = "enableOnDeviceAISummaries"
    static let showSemanticHeadingsKey = "showSemanticBlockHeadings"
    static let texMacrosKey = TeXMacroStore.defaultsKey
}

struct NoemaSettings: View {
    @AppStorage(EditorPreferences.showSemanticHeadingsKey) private var showSemanticHeadings = false
    @AppStorage(EditorPreferences.aiSummariesKey) private var aiSummaries = false
    @AppStorage(EditorPreferences.texMacrosKey) private var texMacrosStorage = ""

    @State private var showCustomCommandsModal = false

    private var macros: [TeXMacro] {
        _ = texMacrosStorage
        return TeXMacroStore.load()
    }

    var body: some View {
        Form {
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
            Section("Apple Intelligence") {
                Toggle("Enable on-device AI summaries", isOn: $aiSummaries)
                Text("Use Summarize on a page to generate a pinned Summary block on this Mac. Requires Apple Intelligence enabled in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(OnDeviceSummary.unavailabilityReason ?? "On-device model is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Text("Noema follows macOS appearance, accent and highlight colors, and accessibility settings. Change these in System Settings.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped).padding(16).frame(width: 540)
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
