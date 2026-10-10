import SwiftUI
import AppKit
import NoemaBrand

// System retains dynamic AppKit colors; selected palettes share semantic brand roles.
struct NoemaTheme: Equatable, Sendable {
    var dark: Bool
    var increasedContrast: Bool
    var revision: Int = 0
    var preference: ThemePreference = .system
    var fullPalette = true
    var usesFullPalette: Bool { preference != .system && fullPalette }
    var palette: MidnightIrisPalette { MidnightIrisPalette(dark: dark, increasedContrast: increasedContrast, theme: preference) }
    var accent: Color? { preference == .system ? nil : Color(nsColor: palette.controlAccent.nsColor) }
    init(dark: Bool = false, increasedContrast: Bool = false) { self.dark = dark; self.increasedContrast = increasedContrast }
    func color(_ role: ThemeRole) -> Color { Color(nsColor: native(role)) }
    func native(_ role: ThemeRole) -> NSColor {
        if usesFullPalette {
            if role == .border && increasedContrast { return palette.foreground(role).nsColor }
            return palette.token(role).nsColor
        }
        if preference != .system, [.accentPrimary, .accentSecondary, .graphHighlight].contains(role) {
            return palette.controlAccent.nsColor
        }
        return switch role {
        case .background: .windowBackgroundColor
        case .surfaceElevated: .textBackgroundColor
        case .accentPrimary, .graphHighlight: .controlAccentColor
        case .accentSecondary: .linkColor
        case .textPrimary: .labelColor
        case .textMuted: .secondaryLabelColor
        case .border: .separatorColor
        }
    }
    func text(_ role: ThemeRole = .textMuted, on surface: ThemeRole = .surfaceElevated) -> Color {
        Color(nsColor: usesFullPalette ? palette.foreground(role, on: surface).nsColor : native(role))
    }
    func nativeText(_ role: ThemeRole = .textPrimary) -> NSColor {
        usesFullPalette ? palette.foreground(role).nsColor : native(role)
    }

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
    @AppStorage(ThemePreference.defaultsKey) private var preference = ThemePreference.system.rawValue
    @AppStorage(ThemePreference.fullPaletteKey) private var fullPalette = true
    @State private var revision = 0
    func body(content: Content) -> some View {
        var theme = NoemaTheme(dark: scheme == .dark, increasedContrast: contrast == .increased); theme.revision = revision
        theme.preference = ThemePreference(rawValue: preference) ?? .system
        theme.fullPalette = fullPalette
        return content.environment(\.noemaTheme, theme)
            .tint(theme.accent)
            .accentColor(theme.accent)
            .modifier(PaletteSurfaceModifier(theme: theme))
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in revision += 1 }
            .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in revision += 1 }
    }
}
extension View { func systemNoemaTheme() -> some View { modifier(SystemNoemaThemeModifier()) } }

private struct PaletteSurfaceModifier: ViewModifier {
    let theme: NoemaTheme
    func body(content: Content) -> some View {
        content
            .foregroundStyle(theme.text(.textPrimary, on: .background), theme.text(.textMuted, on: .background))
            .scrollContentBackground(theme.usesFullPalette ? .hidden : .automatic)
            .background(theme.color(.background).ignoresSafeArea())
    }
}
