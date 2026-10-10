import SwiftUI
import AppKit

/// Keeps the standard close/minimize/zoom buttons present on the main window, which uses a
/// full-size content view with the toolbar and title hidden.
struct TrafficLightEnforcer: NSViewRepresentable {
    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { return }
            DispatchQueue.main.async { TrafficLightEnforcer.apply(window) }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didExposeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    if let w = note.object as? NSWindow { MainActor.assumeIsolated { TrafficLightEnforcer.apply(w) } }
                })
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {
        DispatchQueue.main.async { [weak nsView] in nsView?.window.map(TrafficLightEnforcer.apply) }
    }
    @MainActor static func apply(_ window: NSWindow) {
        window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = false
        }
    }
}
