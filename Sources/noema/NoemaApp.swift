import SwiftUI
import AppKit
import NoemaBrand

@main struct NoemaApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Noema", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .systemNoemaTheme()
                .task { delegate.model = model; await model.restore() }
                .onOpenURL { model.openBlockURL($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Noema") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Page from Topic with AI…") { model.showTopicPage = true }.disabled(!model.isVaultAvailable)
                Button("New Page") { model.newPage() }.keyboardShortcut("n").disabled(!model.isVaultAvailable)
                Button("New Personal Page") { model.newPage(template: true) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.isVaultAvailable)
                Divider()
                Button("Open Vault…") { model.chooseVault(create: false) }.keyboardShortcut("o")
                Button("Create Vault…") { model.chooseVault(create: true) }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Page") { model.savePage() }.keyboardShortcut("s").disabled(!model.isVaultAvailable || model.currentNote == nil)
            }
            CommandMenu("Vault") {
                Button("Find in Vault") { model.searchFocusToken += 1 }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(!model.isVaultAvailable)
                Button("Quick Open") { model.searchFocusToken += 1 }.keyboardShortcut("p").disabled(!model.isVaultAvailable)
                Divider()
                Button("Add Source…") { model.addSource() }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!model.isVaultAvailable)
                Button("Add Sources by URL…") { model.showURLSource = true }.disabled(!model.isVaultAvailable)
                Button("Paste a Source…") { model.showPasteSource = true }.disabled(!model.isVaultAvailable)
                Button("Reveal Vault in Finder") { model.revealVault() }.disabled(!model.isVaultAvailable)
                Button("Refresh from Files") { Task { await model.refresh() } }.disabled(!model.isVaultAvailable)
                Button("Recover Drafts…") { model.showRecovery = true }.disabled(!model.isVaultAvailable || model.recoveredDrafts.isEmpty)
                Divider()
                if model.isLocked {
                    Button("Unlock Vault") { Task { await model.unlockVault() } }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        .disabled(model.busy)
                } else {
                    Button("Lock Vault") { Task { await model.lockVault() } }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        .disabled(!model.isVaultAvailable || model.busy)
                }
                Button("Close Vault") { Task { _ = await model.closeVault() } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled((!model.isVaultAvailable && !model.isLocked) || model.busy)
            }
            CommandMenu("Format") {
                Button("Block Actions…") { model.format("block-actions", "") }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Bold") { model.format("**", "**") }.keyboardShortcut("b").disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Italic") { model.format("*", "*") }.keyboardShortcut("i").disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Underline") { model.format("underline", "") }.keyboardShortcut("u").disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Strikethrough") { model.format("strike", "") }.disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Inline Code") { model.format("code", "") }.disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Inline Math") { model.format("math", "") }.disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Highlight") { model.format("highlight", "") }.disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Hyperlink…") { model.format("link", "") }.keyboardShortcut("k").disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
                Button("Wiki Link") { model.format("[[", "]]") }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!model.isVaultAvailable || model.currentNote == nil || model.reading)
            }
        }
        Window("About Noema", id: "about") {
            NoemaAboutView()
                .frame(width: 660, height: 560)
                .background(AboutWindowConstraints())
                .systemNoemaTheme()
        }
        .defaultSize(width: 660, height: 560)
        .windowResizability(.contentSize)
        Settings {
            NoemaSettings()
                .systemNoemaTheme()
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidResignActive(_ notification: Notification) {
        model?.appIsActive = false
        guard let model, model.isVaultAvailable else { return }
        model.saveNow()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        model?.appIsActive = true
        guard let model, model.isVaultAvailable else { return }
        if let id = model.currentNote?.id { model.markPageViewed(id) }
        model.scheduleRefresh()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            SourceReader.closeAll()
            return .terminateNow
        }
        guard model.isVaultAvailable, model.dirty || model.needsTitle || model.hasPendingTitles else {
            SourceReader.closeAll()
            return .terminateNow
        }
        Task {
            if await model.flushPendingEdits(waitForTitles: true) {
                SourceReader.closeAll()
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "Your draft has been preserved"
                alert.informativeText = "Saving to the vault failed. You can keep working or quit and recover the local draft next time."
                alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Quit with Draft")
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                if shouldQuit { SourceReader.closeAll() }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }
}
