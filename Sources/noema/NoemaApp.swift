import SwiftUI
import AppKit
import NoemaBrand

@main struct NoemaApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("noema", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .systemNoemaTheme()
                .task { delegate.model = model; await model.restore() }
                .onOpenURL { model.openBlockURL($0) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About noema") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "noema",
                        .credits: NSAttributedString(string: "A personal atlas of thought.")
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Wiki Page") { model.newPage() }.keyboardShortcut("n").disabled(model.root == nil)
                Button("New Personal Page") { model.newPage(template: true) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.root == nil)
                Divider()
                Button("Open Vault…") { model.chooseVault(create: false) }.keyboardShortcut("o")
                Button("Create Vault…") { model.chooseVault(create: true) }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Page") { model.saveNow() }.keyboardShortcut("s").disabled(model.currentNote == nil)
            }
            CommandMenu("Vault") {
                Button("Find in Vault") { model.searchFocusToken += 1 }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Quick Open") { model.searchFocusToken += 1 }.keyboardShortcut("p")
                Divider()
                Button("Import Sources…") { model.importFiles() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(model.root == nil)
                Button("Paste a Source…") { model.showPasteSource = true }.disabled(model.root == nil)
                Button("Reveal Vault in Finder") { model.revealVault() }.disabled(model.root == nil)
                Button("Refresh from Files") { Task { await model.refresh() } }.disabled(model.root == nil)
                Button("Recover Drafts…") { model.showRecovery = true }.disabled(model.recoveredDrafts.isEmpty)
            }
            CommandMenu("Format") {
                Button("Block Actions…") { model.format("block-actions", "") }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(model.currentNote == nil || model.reading)
                Button("Bold") { model.format("**", "**") }.keyboardShortcut("b").disabled(model.currentNote == nil || model.reading)
                Button("Italic") { model.format("*", "*") }.keyboardShortcut("i").disabled(model.currentNote == nil || model.reading)
                Button("Underline") { model.format("underline", "") }.keyboardShortcut("u").disabled(model.currentNote == nil || model.reading)
                Button("Strikethrough") { model.format("strike", "") }.disabled(model.currentNote == nil || model.reading)
                Button("Inline Code") { model.format("code", "") }.disabled(model.currentNote == nil || model.reading)
                Button("Highlight") { model.format("highlight", "") }.disabled(model.currentNote == nil || model.reading)
                Button("Hyperlink…") { model.format("link", "") }.keyboardShortcut("k").disabled(model.currentNote == nil || model.reading)
                Button("Wiki Link") { model.format("[[", "]]") }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.currentNote == nil || model.reading)
            }
        }
        Settings {
            AppearanceSettings()
                .systemNoemaTheme()
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidResignActive(_ notification: Notification) { model?.saveNow() }
    func applicationDidBecomeActive(_ notification: Notification) { model?.scheduleRefresh() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.dirty else { return .terminateNow }
        Task {
            if await model.saveCurrent() { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert()
                alert.messageText = "Your draft has been preserved"
                alert.informativeText = "Saving to the vault failed. You can keep working or quit and recover the local draft next time."
                alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Quit with Draft")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
    }
}
