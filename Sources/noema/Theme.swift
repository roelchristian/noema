import SwiftUI
import AppKit
import NoemaBrand

// Functional UI uses dynamic AppKit colors; brand palette values are reserved for the mark.
struct NoemaTheme: Equatable, Sendable {
    var dark: Bool
    var increasedContrast: Bool
    var revision: Int = 0
    init(dark: Bool = false, increasedContrast: Bool = false) { self.dark = dark; self.increasedContrast = increasedContrast }
    func color(_ role: ThemeRole) -> Color { Color(nsColor: native(role)) }
    func native(_ role: ThemeRole) -> NSColor {
        switch role {
        case .background: .windowBackgroundColor
        case .surfaceElevated: .textBackgroundColor
        case .accentPrimary, .graphHighlight: .controlAccentColor
        case .accentSecondary: .linkColor
        case .textPrimary: .labelColor
        case .textMuted: .secondaryLabelColor
        case .border: .separatorColor
        }
    }
    func text(_ role: ThemeRole = .textMuted, on surface: ThemeRole = .surfaceElevated) -> Color { color(role) }
    func nativeText(_ role: ThemeRole = .textPrimary) -> NSColor { native(role) }
}

extension ThemeRGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}
private struct NoemaThemeKey: EnvironmentKey { static let defaultValue = NoemaTheme() }
extension EnvironmentValues {
    var noemaTheme: NoemaTheme { get { self[NoemaThemeKey.self] } set { self[NoemaThemeKey.self] = newValue } }
}
private struct SystemNoemaThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var revision = 0
    func body(content: Content) -> some View {
        var theme = NoemaTheme(dark: scheme == .dark, increasedContrast: contrast == .increased); theme.revision = revision
        return content.environment(\.noemaTheme, theme)
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in revision += 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in revision += 1 }
    }
}
extension View { func systemNoemaTheme() -> some View { modifier(SystemNoemaThemeModifier()) } }
struct AppearanceSettings: View {
    var body: some View {
        Form { Text("Noema follows macOS appearance, accent and highlight colors, and accessibility settings. Change these in System Settings.").font(.callout) }
            .formStyle(.grouped).padding(16).frame(width: 460)
    }
}
