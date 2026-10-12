import AppKit
import SwiftUI
import VaultCore

/// Settings has its own native window, outside the main workspace's locked presentation.
struct SettingsWindowState: NSViewRepresentable {
    let phase: VaultSessionPhase

    func makeNSView(context: Context) -> WindowStateView { WindowStateView(phase: phase) }
    func updateNSView(_ view: WindowStateView, context: Context) { view.update(phase: phase) }

    final class WindowStateView: NSView {
        private var phase: VaultSessionPhase

        init(phase: VaultSessionPhase) {
            self.phase = phase
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(phase nextPhase: VaultSessionPhase) {
            let previousPhase = phase
            phase = nextPhase
            // Close only after locking succeeds. Global preferences can still be opened
            // while locked, and a failed lock must leave the existing window alone.
            guard nextPhase == .locked, previousPhase != .locked, let window else { return }
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                sheet.close()
            }
            window.close()
        }
    }
}
