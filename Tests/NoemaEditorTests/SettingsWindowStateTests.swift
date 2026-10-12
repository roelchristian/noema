import AppKit
import Testing
import VaultCore
@testable import noema

@Suite(.serialized)
struct SettingsWindowStateTests {
    @MainActor private func settingsWindow(phase: VaultSessionPhase) -> (NSWindow, SettingsWindowState.WindowStateView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SettingsWindowState.WindowStateView(phase: phase)
        window.contentView = view
        window.orderFront(nil)
        return (window, view)
    }

    @Test @MainActor func successfulLockClosesSettingsAndLeavesOtherWindowsOpen() {
        let (settings, view) = settingsWindow(phase: .open)
        let (other, _) = settingsWindow(phase: .open)
        defer { settings.close(); other.close() }
        #expect(settings.isVisible)
        view.update(phase: .locking)
        #expect(settings.isVisible)
        view.update(phase: .locked)
        #expect(!settings.isVisible)
        #expect(other.isVisible)
    }

    @Test @MainActor func failedLockKeepsSettingsOpen() {
        let (settings, view) = settingsWindow(phase: .open)
        defer { settings.close() }
        view.update(phase: .locking)
        view.update(phase: .open)
        #expect(settings.isVisible)
    }

    @Test @MainActor func settingsCanReopenWhileLockedAndCloseOnNextLock() {
        let (settings, view) = settingsWindow(phase: .locked)
        defer { settings.close() }
        view.update(phase: .locked)
        #expect(settings.isVisible)
        view.update(phase: .unlocking)
        view.update(phase: .open)
        view.update(phase: .locking)
        view.update(phase: .locked)
        #expect(!settings.isVisible)
    }

    @Test @MainActor func lockingClosesAttachedSettingsSheet() {
        let (settings, view) = settingsWindow(phase: .open)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { settings.close(); sheet.close() }
        settings.beginSheet(sheet)
        #expect(settings.attachedSheet === sheet)
        view.update(phase: .locked)
        #expect(!settings.isVisible)
        #expect(!sheet.isVisible)
    }
}
