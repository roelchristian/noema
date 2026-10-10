import SwiftUI
import AppKit
import NoemaBrand

struct NoemaTheme: Equatable, Sendable {
    var palette: MidnightIrisPalette
    init(dark: Bool = false, increasedContrast: Bool = false) {
        palette = MidnightIrisPalette(dark: dark, increasedContrast: increasedContrast)
    }
    func color(_ role: ThemeRole) -> Color { Color(nsColor: native(role)) }
    func native(_ role: ThemeRole) -> NSColor {
        let value = palette.increasedContrast && role == .border
            ? palette.foreground(.border, minimumContrast: 3)
            : palette.token(role)
        return value.nsColor
    }
    func text(_ role: ThemeRole = .textMuted, on surface: ThemeRole = .surfaceElevated) -> Color {
        Color(nsColor: palette.foreground(role, on: surface).nsColor)
    }
    func nativeText(_ role: ThemeRole = .textPrimary) -> NSColor { palette.foreground(role).nsColor }
    var controlAccent: Color { Color(nsColor: palette.controlAccent.nsColor) }
}

extension ThemeRGB {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

private struct NoemaThemeKey: EnvironmentKey {
    static let defaultValue = NoemaTheme()
}

extension EnvironmentValues {
    var noemaTheme: NoemaTheme {
        get { self[NoemaThemeKey.self] }
        set { self[NoemaThemeKey.self] = newValue }
    }
}

private struct MidnightIrisThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let theme = NoemaTheme(dark: scheme == .dark, increasedContrast: contrast == .increased)
        content
            .environment(\.noemaTheme, theme)
            .foregroundStyle(theme.text(.textPrimary))
            .tint(theme.controlAccent)
            .background(theme.color(.background))
    }
}

extension View {
    func midnightIrisTheme() -> some View { modifier(MidnightIrisThemeModifier()) }
}

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct AppearanceSettings: View {
    @AppStorage(AppearancePreference.defaultsKey) private var appearance: AppearancePreference = .system
    @Environment(\.noemaTheme) private var theme
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text("System follows your Mac’s appearance. Midnight Iris colours adapt to light and dark mode.")
                .font(.callout).foregroundStyle(theme.text(on: .background))
        }.formStyle(.grouped).padding(16).frame(width: 460)
    }
}
