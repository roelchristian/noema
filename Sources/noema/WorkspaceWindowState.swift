import AppKit
import SwiftUI
import VaultCore

/// Uses AppKit's native frame storage, with a separate saved frame for each presentation.
/// Pane visibility and widths belong to the split-view state, not the window frame.
struct WorkspaceWindowState: NSViewRepresentable {
    let phase: VaultSessionPhase

    @MainActor static func configureToolbarStyle(for window: NSWindow) {
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
    }

    @MainActor static func titlebarChromeHeight(for window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentLayoutRect.height)
    }

    func makeNSView(context: Context) -> WindowStateView { WindowStateView(phase: phase) }
    func updateNSView(_ view: WindowStateView, context: Context) { view.update(phase: phase) }
    static func dismantleNSView(_ view: WindowStateView, coordinator: ()) { view.detach() }

    final class WindowStateView: NSView {
        private var state: WindowGeometryState
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var pendingTransition: Task<Void, Never>?
        private var changingFrame = false
        private var inFullScreenTransition = false

        init(phase: VaultSessionPhase) {
            state = WindowGeometryState(phase: phase)
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else { return }
            detach()
            guard let window else { return }
            observedWindow = window
            WorkspaceWindowState.configureToolbarStyle(for: window)
            state.applyPending(canResize: canChangeFrame)
            observe(window)
            applyProfile(restore: true)
        }

        func update(phase: VaultSessionPhase) {
            guard state.phase != phase else { return }
            state.request(phase)
            pendingTransition?.cancel()
            // Vault replacement can briefly publish closed before opening the next vault.
            // Coalesce that transition without changing the storage/session lifecycle.
            if phase == .closed {
                pendingTransition = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.transition()
                }
            } else {
                transition()
            }
        }

        func detach() {
            saveFrame()
            pendingTransition?.cancel()
            pendingTransition = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow = nil
        }

        private func observe(_ window: NSWindow) {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                observe(name, object: window) { $0.saveFrame() }
            }
            observe(NSWindow.willEnterFullScreenNotification, object: window) {
                $0.saveFrame()
                $0.inFullScreenTransition = true
            }
            observe(NSWindow.didEnterFullScreenNotification, object: window) { $0.inFullScreenTransition = true }
            observe(NSWindow.willExitFullScreenNotification, object: window) { $0.inFullScreenTransition = true }
            observe(NSWindow.didExitFullScreenNotification, object: window) {
                $0.inFullScreenTransition = false
                $0.transition()
                $0.applyProfile(restore: false)
            }
            observe(NSApplication.didChangeScreenParametersNotification, object: nil) { $0.applyProfile(restore: false) }
        }

        private func observe(_ name: Notification.Name, object: Any?, action: @escaping @MainActor (WindowStateView) -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
        }

        private var canChangeFrame: Bool {
            !inFullScreenTransition && observedWindow?.styleMask.contains(.fullScreen) == false
        }

        private func transition() {
            guard canChangeFrame else { return }
            let next = WindowGeometryProfile.resolve(state.phase, previous: state.profile)
            guard next != state.profile else { return }
            saveFrame()
            state.applyPending(canResize: true)
            applyProfile(restore: true)
        }

        private func saveFrame() {
            guard !changingFrame, canChangeFrame, let window = observedWindow else { return }
            window.saveFrame(usingName: state.profile.frameSaveName)
        }

        private func applyProfile(restore: Bool) {
            guard canChangeFrame, let window = observedWindow else { return }
            WorkspaceWindowState.configureToolbarStyle(for: window)
            changingFrame = true
            defer { changingFrame = false }
            let profile = state.profile
            // Lower the previous workspace minimum before restoring a compact frame.
            window.contentMinSize = .zero
            // Native restoration stores screen coordinates and handles standard macOS conventions.
            let didRestore = restore && window.setFrameUsingName(profile.frameSaveName)
            if restore && !didRestore {
                let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: profile.defaultContentSize)).size
                let previous = window.frame
                window.setFrame(CGRect(x: previous.midX - size.width / 2, y: previous.maxY - size.height,
                                       width: size.width, height: size.height), display: false)
            }
            let screens = NSScreen.screens.map(\.visibleFrame)
            guard let visible = WindowGeometry.visibleFrame(for: window.frame, screens: screens) else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let chrome = CGSize(width: window.frame.width - content.width, height: window.frame.height - content.height)
            // A smaller display must never inherit a minimum larger than its available bounds.
            let minContent = CGSize(width: min(profile.minimumContentSize.width, max(1, visible.width - chrome.width)),
                                    height: min(profile.minimumContentSize.height, max(1, visible.height - chrome.height)))
            window.contentMinSize = minContent
            let minFrame = CGSize(width: minContent.width + chrome.width, height: minContent.height + chrome.height)
            let frame = WindowGeometry.clamped(window.frame, to: visible, minimumSize: minFrame)
            if frame != window.frame { window.setFrame(frame, display: true) }
            window.saveFrame(usingName: profile.frameSaveName)
        }
    }
}
