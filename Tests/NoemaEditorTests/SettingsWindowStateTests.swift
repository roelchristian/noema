import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@Suite(.serialized)
struct SettingsWindowStateTests {
    @MainActor private func settingsWindow(
        phase: VaultSessionPhase,
        onLockDismiss: (() -> Void)? = nil
    ) -> (NSWindow, SettingsModalBridge.ModalStateView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsModalMetrics.idealWidth, height: SettingsModalMetrics.idealHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let view = SettingsModalBridge.ModalStateView(phase: phase, onLockDismiss: onLockDismiss)
        window.contentView = view
        window.orderFront(nil)
        return (window, view)
    }

    @Test @MainActor func successfulLockClosesSettingsAndLeavesOtherWindowsOpen() {
        var didDismiss = false
        let (settings, view) = settingsWindow(phase: .open, onLockDismiss: { didDismiss = true })
        let (other, _) = settingsWindow(phase: .open)
        defer { settings.close(); other.close() }
        #expect(settings.isVisible)
        view.update(phase: .locking)
        #expect(settings.isVisible && !didDismiss)
        view.update(phase: .locked)
        #expect(!settings.isVisible && didDismiss)
        #expect(other.isVisible)
    }

    @Test @MainActor func failedLockKeepsSettingsOpen() {
        var didDismiss = false
        let (settings, view) = settingsWindow(phase: .open, onLockDismiss: { didDismiss = true })
        defer { settings.close() }
        view.update(phase: .locking)
        view.update(phase: .open)
        #expect(settings.isVisible && !didDismiss)
    }

    @Test @MainActor func settingsCanReopenWhileLockedAndCloseOnNextLock() {
        var dismissCount = 0
        let (settings, view) = settingsWindow(phase: .locked, onLockDismiss: { dismissCount += 1 })
        defer { settings.close() }
        view.update(phase: .locked)
        #expect(settings.isVisible && dismissCount == 0)
        view.update(phase: .unlocking)
        view.update(phase: .open)
        view.update(phase: .locking)
        view.update(phase: .locked)
        #expect(!settings.isVisible && dismissCount == 1)
    }

    @Test @MainActor func lockingClosesAttachedSettingsSheetAndParentSheet() {
        let workspace = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        workspace.isReleasedWhenClosed = false
        workspace.orderFront(nil)

        var didDismiss = false
        let settingsSheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsModalMetrics.idealWidth, height: SettingsModalMetrics.idealHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        settingsSheet.isReleasedWhenClosed = false
        let view = SettingsModalBridge.ModalStateView(phase: .open, onLockDismiss: { didDismiss = true })
        settingsSheet.contentView = view

        let nestedSheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        nestedSheet.isReleasedWhenClosed = false
        defer {
            nestedSheet.close()
            settingsSheet.close()
            workspace.close()
        }

        workspace.beginSheet(settingsSheet)
        settingsSheet.beginSheet(nestedSheet)
        #expect(workspace.attachedSheet === settingsSheet)
        #expect(settingsSheet.attachedSheet === nestedSheet)

        view.update(phase: .locked)
        #expect(didDismiss)
        #expect(!nestedSheet.isVisible)
        #expect(!settingsSheet.isVisible)
        #expect(workspace.attachedSheet == nil)
        #expect(workspace.isVisible)
    }

    @Test func sidebarHierarchyAndModalMetricsMatchSystemSettingsSpecification() {
        #expect(SettingsGroup.allCases == [.personalisation, .intelligence, .security])
        #expect(SettingsGroup.personalisation.title == "Personalisation")
        #expect(SettingsGroup.personalisation.categories == [.appearance, .readingAndEditor])
        #expect(SettingsGroup.intelligence.title == "Intelligence")
        #expect(SettingsGroup.intelligence.categories == [.intelligence, .openAI])
        #expect(SettingsGroup.security.title == "Security")
        #expect(SettingsGroup.security.categories == [.vaultAccess])

        #expect(SettingsCategory.defaultCategory == .appearance)
        #expect(SettingsCategory.appearance.symbol == "paintpalette")
        #expect(SettingsCategory.readingAndEditor.symbol == "textformat")
        #expect(SettingsCategory.intelligence.symbol == "brain.head.profile")
        #expect(SettingsCategory.openAI.symbol == "cloud")
        #expect(SettingsCategory.vaultAccess.symbol == "lock.shield")

        let standard = SettingsModalMetrics.resolvedSize(for: CGSize(width: 1440, height: 900))
        #expect(standard.width == 840 && standard.height == 600)
        #expect(SettingsModalMetrics.sidebarWidth == 200)

        let compact = SettingsModalMetrics.resolvedSize(for: CGSize(width: 720, height: 500))
        #expect(compact.width == 720 && compact.height == 500)
    }

    @Test @MainActor func openSettingsIsIdempotentRetainsSelectionAndRestoresInteractionOnDismiss() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSettingsModal-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let created = try await repository.create(title: "Settings Test Page", body: "Initial body")
        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        let note = try #require(model.notes.first { $0.id == created.id })
        model.currentNote = note
        model.selectedID = note.id

        #expect(model.canOpenSettings)
        #expect(!model.showSettings)
        #expect(model.canInteractWithWorkspace)
        #expect(!model.canFormatDocument) // No semantic editor has established authority.

        model.openSettings()
        #expect(model.showSettings)
        #expect(model.selectedSettingsCategory == .appearance)
        #expect(!model.canInteractWithWorkspace)
        #expect(!model.canFormatDocument)

        // Selecting another category persists across repeated ⌘, invocations during the same presentation.
        model.selectedSettingsCategory = .readingAndEditor
        model.openSettings()
        #expect(model.showSettings)
        #expect(model.selectedSettingsCategory == .readingAndEditor)

        // Explicit category deep-link switches the active category without opening a second sheet.
        model.openSettings(category: .intelligence)
        #expect(model.showSettings)
        #expect(model.selectedSettingsCategory == .intelligence)

        model.showCustomTeXCommandsModal = true
        model.showAIActivityHistory = true
        model.dismissSettings()
        #expect(!model.showSettings)
        #expect(!model.showCustomTeXCommandsModal)
        #expect(!model.showAIActivityHistory)
        #expect(model.canInteractWithWorkspace)
        #expect(!model.canFormatDocument) // No semantic editor has established authority.

        // A fresh presentation defaults back to Appearance unless a specific category is requested.
        model.openSettings()
        #expect(model.showSettings)
        #expect(model.selectedSettingsCategory == .appearance)
        model.dismissSettings()

        let close = try #require(model.performWorkspaceCommand(.close))
        await close.value
    }

    @Test @MainActor func vaultLockingDismissesSettingsAndAllowsReopeningWhileLocked() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSettingsLock-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        _ = try await openCanonicalAppFixture(root: root, create: true)
        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        #expect(model.isVaultAvailable)

        model.openSettings(category: .vaultAccess)
        model.showCustomTeXCommandsModal = true
        model.showAIActivityHistory = true
        #expect(model.showSettings)

        await model.lockVault()
        #expect(model.isLocked)
        #expect(!model.showSettings)
        #expect(!model.showCustomTeXCommandsModal)
        #expect(!model.showAIActivityHistory)

        // Settings remains accessible while the workspace is locked.
        #expect(model.canOpenSettings)
        model.openSettings(category: .vaultAccess)
        #expect(model.showSettings)
        #expect(model.selectedSettingsCategory == .vaultAccess)
        model.dismissSettings()
        #expect(!model.showSettings)

        let close = try #require(model.performWorkspaceCommand(.close))
        await close.value
    }

    @Test @MainActor func allSettingsCategoryPanesRenderWithinTargetModalBounds() async throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSettingsRender-\(UUID())")
        let root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let created = try await repository.create(
            title: "Architecture & Design Notes",
            body: "## System Settings Redesign\n\nSettings is now a native modal sheet attached to the workspace."
        )
        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        let note = try #require(model.notes.first { $0.id == created.id })
        model.currentNote = note
        model.selectedID = note.id

        let screenshotDir = ProcessInfo.processInfo.environment["NOEMA_SETTINGS_SCREENSHOT_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let screenshotDir {
            try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
        }

        for category in SettingsCategory.allCases {
            model.openSettings(category: category)
            #expect(model.selectedSettingsCategory == category)
            let view = NSHostingView(
                rootView: NoemaSettings(
                    externalAIService: model.externalAIService,
                    aiProviderPreferences: model.aiProviderPreferences,
                    model: model,
                    initialCategory: category
                )
                .systemNoemaTheme()
                .environment(\.colorScheme, .light)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: SettingsModalMetrics.idealWidth, height: SettingsModalMetrics.idealHeight),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(80))
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(view.bounds.width == SettingsModalMetrics.idealWidth)
            #expect(view.bounds.height == SettingsModalMetrics.idealHeight)

            if let screenshotDir,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: screenshotDir.appendingPathComponent("settings-\(category.rawValue).png"), options: .atomic)
                }
            }
            window.close()
        }

        if let screenshotDir {
            model.openSettings(category: .appearance)
            let workspaceView = NSHostingView(
                rootView: ZStack {
                    ContentView(model: model)
                        .disabled(true)
                    Color.black.opacity(0.18)
                    NoemaSettings(
                        externalAIService: model.externalAIService,
                        aiProviderPreferences: model.aiProviderPreferences,
                        model: model,
                        initialCategory: .appearance
                    )
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)
                }
                .systemNoemaTheme()
                .environment(\.colorScheme, .light)
            )
            let workspaceWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            workspaceWindow.isReleasedWhenClosed = false
            workspaceWindow.appearance = NSAppearance(named: .aqua)
            workspaceWindow.contentView = workspaceView
            workspaceWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(120))
            workspaceView.layoutSubtreeIfNeeded()
            workspaceWindow.displayIfNeeded()
            if let rep = workspaceView.bitmapImageRepForCachingDisplay(in: workspaceView.bounds) {
                workspaceView.cacheDisplay(in: workspaceView.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: screenshotDir.appendingPathComponent("settings-modal-presentation.png"), options: .atomic)
                }
            }
            workspaceWindow.close()
        }

        model.dismissSettings()
        let close = try #require(model.performWorkspaceCommand(.close))
        await close.value
    }
}
