import AppKit
import SwiftUI
import Observation
import NoemaBrand

/// Hover state is shared by windows but never written to UserDefaults.
@MainActor @Observable final class ThemePreviewState {
    static let shared = ThemePreviewState()
    private(set) var preference: ThemePreference?
    private(set) var isTracking = false
    private var selection: ThemePreference?

    func begin() { isTracking = true; selection = nil }
    func highlight(_ theme: ThemePreference?) { preference = theme }
    func select(_ theme: ThemePreference) { selection = theme }
    func finish() -> ThemePreference? {
        let result = selection
        preference = nil; selection = nil; isTracking = false
        return result
    }
}

struct ThemePalettePicker: NSViewRepresentable {
    @Binding var selection: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.noemaTheme) private var theme

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel("Theme")
        button.setAccessibilityHelp("Preview a theme by highlighting it. Select to save; Escape cancels the preview.")
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.menu?.delegate = context.coordinator
        for preference in ThemePreference.allCases {
            button.addItem(withTitle: preference.title)
            button.lastItem?.representedObject = preference.rawValue
        }
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // A live preview must not rebuild the menu or change its tracked selection.
        guard !ThemePreviewState.shared.isTracking else { return }
        for item in button.itemArray {
            guard let raw = item.representedObject as? String,
                  let preference = ThemePreference(rawValue: raw) else { continue }
            item.image = swatches(preference)
            if raw == selection { button.select(item) }
        }
    }
    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        button.menu?.delegate = nil
        _ = ThemePreviewState.shared.finish()
    }
    private func swatches(_ preference: ThemePreference) -> NSImage {
        let roles: [ThemeRole] = [.background, .surfaceElevated, .accentPrimary, .accentSecondary, .graphHighlight, .textPrimary]
        var preview = NoemaTheme(dark: scheme == .dark, increasedContrast: theme.increasedContrast)
        preview.preference = preference
        let colors = roles.map { preview.native($0) }
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return NSImage(size: NSSize(width: 84, height: 14), flipped: false) { rect in
            appearance?.performAsCurrentDrawingAppearance {
                for (index, color) in colors.enumerated() {
                    let swatch = NSRect(x: CGFloat(index) * 14, y: 1, width: 12, height: 12)
                    color.setFill()
                    let path = NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2)
                    path.fill()
                    NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
                }
            }
            return true
        }
    }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var parent: ThemePalettePicker
        init(_ parent: ThemePalettePicker) { self.parent = parent }
        func menuWillOpen(_ menu: NSMenu) { ThemePreviewState.shared.begin() }
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            let preference = (item?.representedObject as? String).flatMap(ThemePreference.init(rawValue:))
            ThemePreviewState.shared.highlight(preference)
        }
        @objc func choose(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let preference = ThemePreference(rawValue: raw) else { return }
            if ThemePreviewState.shared.isTracking { ThemePreviewState.shared.select(preference) }
            else { parent.selection = raw } // Keyboard changes after menu dismissal.
        }
        func menuDidClose(_ menu: NSMenu) {
            // AppKit dispatches the selection action as tracking ends. Commit on the
            // next main-loop turn so hover alone and cancellation never persist.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let selected = ThemePreviewState.shared.finish() {
                    self.parent.selection = selected.rawValue
                }
            }
        }
    }
}
