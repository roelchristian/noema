import SwiftUI
import AppKit
import NoemaBrand
import VaultCore

@main struct NoemaApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspacePaneActions) private var paneActions
    var body: some Scene {
        Window("Noema", id: "main") {
            ContentView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkspaceWindowState(phase: model.sessionPhase))
                .systemNoemaTheme()
                .task { delegate.model = model; await model.restore() }
                .onOpenURL { model.openBlockURL($0) }
        }
        // Let macOS own the titlebar, traffic lights, and full-screen transitions.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 680, height: 480)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Noema") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(!model.canOpenSettings)
            }
            CommandGroup(replacing: .newItem) {
                Button("Create Page with AI…") { model.performWorkspaceCommand(.newTopicPage) }.disabled(!model.canPerformWorkspaceCommand(.newTopicPage))
                Button("New Page") { model.performWorkspaceCommand(.newPage) }.keyboardShortcut("n").disabled(!model.canPerformWorkspaceCommand(.newPage))
                Button("New Personal Page") { model.performWorkspaceCommand(.newPersonalPage) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.canPerformWorkspaceCommand(.newPersonalPage))
                Divider()
                Button("Open Vault…") { model.performWorkspaceCommand(.openVault) }.keyboardShortcut("o").disabled(!model.canPerformWorkspaceCommand(.openVault))
                Button("Create Vault…") { model.performWorkspaceCommand(.createVault) }.disabled(!model.canPerformWorkspaceCommand(.createVault))
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Page") { model.performWorkspaceCommand(.save) }.keyboardShortcut("s").disabled(!model.canPerformWorkspaceCommand(.save))
            }
            CommandGroup(replacing: .sidebar) {
                Button(paneActions?.sidebarPresented == true ? "Hide Sidebar" : "Show Sidebar") {
                    paneActions?.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(paneActions?.canToggleSidebar != true)
                Button(paneActions?.inspectorPresented == true ? "Hide Inspector" : "Show Inspector") {
                    paneActions?.toggleInspector()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(paneActions?.canToggleInspector != true)
                Divider()
                Button("Return to Library") { model.performWorkspaceCommand(.returnToLibrary) }
                    .keyboardShortcut("[")
                    .disabled(!model.canPerformWorkspaceCommand(.returnToLibrary))
            }
            CommandMenu("Vault") {
                ForEach(WorkspaceSearchMenuCommand.allCases, id: \.self) { item in
                    Button(item.title) { model.performWorkspaceCommand(item.command) }
                        .keyboardShortcut(item.shortcut)
                        .disabled(!model.canPerformWorkspaceCommand(item.command))
                }
                Divider()
                Button("Add Source…") { model.performWorkspaceCommand(.addSource) }.keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!model.canPerformWorkspaceCommand(.addSource))
                Button("Add Sources by URL…") { model.performWorkspaceCommand(.addURLSource) }.disabled(!model.canPerformWorkspaceCommand(.addURLSource))
                Button("Paste a Source…") { model.performWorkspaceCommand(.pasteSource) }.disabled(!model.canPerformWorkspaceCommand(.pasteSource))
                Button("Reveal Vault in Finder") { model.performWorkspaceCommand(.revealVault) }.disabled(!model.canPerformWorkspaceCommand(.revealVault))
                Button("Refresh from Files") { model.performWorkspaceCommand(.refresh) }.disabled(!model.canPerformWorkspaceCommand(.refresh))
                Button("Recover Drafts…") { model.performWorkspaceCommand(.recovery) }.disabled(!model.canPerformWorkspaceCommand(.recovery))
                Button("Vault Notices…") { model.performWorkspaceCommand(.notices) }.disabled(!model.canPerformWorkspaceCommand(.notices))
                Divider()
                if model.isLocked {
                    Button("Unlock Vault") { model.performWorkspaceCommand(.unlock) }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        .disabled(!model.canPerformWorkspaceCommand(.unlock))
                } else {
                    Button("Lock Vault") { model.performWorkspaceCommand(.lock) }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        .disabled(!model.canPerformWorkspaceCommand(.lock))
                }
                Button("Close Vault") { model.performWorkspaceCommand(.close) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.canPerformWorkspaceCommand(.close))
            }
            CommandMenu("Format") {
                Button("Block Actions…") { model.format("block-actions", "") }.keyboardShortcut("b", modifiers: [.command, .shift]).disabled(!model.canFormatDocument)
                Button("Bold") { model.format("**", "**") }.keyboardShortcut("b").disabled(!model.canFormatDocument)
                Button("Italic") { model.format("*", "*") }.keyboardShortcut("i").disabled(!model.canFormatDocument)
                Button("Underline") { model.format("underline", "") }.keyboardShortcut("u").disabled(!model.canFormatDocument)
                Button("Strikethrough") { model.format("strike", "") }.disabled(!model.canFormatDocument)
                Button("Inline Code") { model.format("code", "") }.disabled(!model.canFormatDocument)
                Button("Inline Math") { model.format("math", "") }.disabled(!model.canFormatDocument)
                Button("Highlight") { model.format("highlight", "") }.disabled(!model.canFormatDocument)
                Button("Hyperlink…") { model.format("link", "") }.keyboardShortcut("k").disabled(!model.canFormatDocument)
                Button("Wiki Link") { model.format("[[", "]]") }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!model.canFormatDocument)
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
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached(priority: .utility) {
            // Best effort and bounded; an unavailable temporary directory must not block launch.
            try? SourcePreviewDirectory.application.cleanupOrphans()
        }
    }
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
