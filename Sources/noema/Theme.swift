import SwiftUI
import AppKit
import NoemaBrand

/// Interface purpose, independent of permanent brand artwork and document styling.
enum NoemaColorRole: CaseIterable, Sendable {
    case window, sidebar, canvas, inspector, elevated
    case selection, hover, pressed, separator
    case textPrimary, textSecondary, textTertiary, textOnSelection, disabledText
    case accent, destructive, focusRing
}

// System retains dynamic AppKit colors; selected palettes share semantic brand roles.
struct NoemaTheme: Equatable, Sendable {
    var dark: Bool
    var increasedContrast: Bool
    var revision: Int = 0
    var preference: ThemePreference = .defaultValue
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

    func color(for role: NoemaColorRole, active: Bool = true) -> Color {
        Color(nsColor: native(for: role, active: active))
    }

    func native(for role: NoemaColorRole, active: Bool = true) -> NSColor {
        if usesFullPalette {
            switch role {
            case .window, .sidebar, .canvas, .inspector: return palette.token(.background).nsColor
            case .elevated: return palette.token(.surfaceElevated).nsColor
            case .selection, .hover, .pressed: return paletteState(role, active: active).nsColor
            case .separator:
                let border = palette.token(.border)
                return (increasedContrast
                        ? readable(border, on: palette.token(dark ? .surfaceElevated : .background), minimum: 3)
                        : border).nsColor
            case .accent: return palette.controlAccent.nsColor
            case .focusRing: return .keyboardFocusIndicatorColor
            case .destructive: return .systemRed
            case .textPrimary, .textSecondary, .textTertiary, .disabledText:
                return nativeText(for: role, on: .canvas, active: active)
            case .textOnSelection:
                return nativeText(for: role, on: .selection, active: active)
            }
        }
        switch role {
        case .window, .sidebar, .inspector: return .windowBackgroundColor
        case .canvas: return .textBackgroundColor
        case .elevated: return .controlBackgroundColor
        case .textPrimary: return .labelColor
        case .textSecondary: return .secondaryLabelColor
        case .textTertiary:
            return increasedContrast ? nativeText(for: role, on: .canvas, active: active) : .tertiaryLabelColor
        case .disabledText: return .disabledControlTextColor
        case .textOnSelection: return nativeText(for: role, on: .selection, active: active)
        case .accent: return preference == .system ? .controlAccentColor : palette.controlAccent.nsColor
        case .destructive: return .systemRed
        case .focusRing: return .keyboardFocusIndicatorColor
        case .separator:
            guard increasedContrast else { return .separatorColor }
            return dynamic { [self] in readable(rgb(.separatorColor, on: rgb(.windowBackgroundColor)),
                                      on: rgb(.windowBackgroundColor), minimum: 3).nsColor }
        case .selection:
            // Native active/inactive colors remain dynamic, including the user's accent.
            return dynamic { [self] in
                let original = rgb(active ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
                return selectionSurface(original, base: rgb(.controlBackgroundColor)).nsColor
            }
        case .hover, .pressed:
            return dynamic { [self] in
                let base = rgb(.controlBackgroundColor)
                let emphasis = rgb(role == .pressed ? .controlAccentColor : .labelColor, on: base)
                let fraction = role == .hover ? (increasedContrast ? 0.09 : 0.045) : (increasedContrast ? 0.20 : 0.13)
                return selectionSurface(base.mixed(with: emphasis, fraction: fraction), base: base).nsColor
            }
        }
    }

    func text(for role: NoemaColorRole = .textSecondary,
              on surface: NoemaColorRole = .canvas, active: Bool = true) -> Color {
        Color(nsColor: nativeText(for: role, on: surface, active: active))
    }

    /// Also available to AppKit chrome. Resolve against the final opaque state fill,
    /// rather than the palette's generic elevated surface or an uncomposited alpha.
    func nativeText(for role: NoemaColorRole = .textSecondary,
                    on surface: NoemaColorRole = .canvas, active: Bool = true) -> NSColor {
        if usesFullPalette {
            let backing = rgb(native(for: surface, active: active))
            let original: ThemeRGB
            switch role {
            case .textPrimary, .textOnSelection: original = palette.token(.textPrimary)
            case .textSecondary, .disabledText: original = palette.token(.textMuted)
            case .textTertiary:
                original = palette.token(.textMuted).mixed(with: backing, fraction: 0.18)
            case .accent: original = palette.controlAccent
            case .destructive: return dynamic { [self] in readable(rgb(.systemRed, on: backing), on: backing).nsColor }
            default: original = rgb(native(for: role, active: active), on: backing)
            }
            return readable(original, on: backing).nsColor
        }
        return dynamic { [self] in
            let backing = rgb(native(for: surface, active: active))
            let foreground: NSColor
            switch role {
            case .textPrimary: foreground = .labelColor
            case .textSecondary: foreground = .secondaryLabelColor
            case .textTertiary: foreground = .tertiaryLabelColor
            case .disabledText: foreground = .disabledControlTextColor
            case .textOnSelection:
                foreground = active ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor
            default: foreground = native(for: role, active: active)
            }
            return readable(rgb(foreground, on: backing), on: backing).nsColor
        }
    }

    private func paletteState(_ role: NoemaColorRole, active: Bool) -> ThemeRGB {
        let base = palette.token(.surfaceElevated)
        let emphasis = role == .hover ? palette.token(.textPrimary) : palette.token(.accentPrimary)
        let fraction: Double
        switch role {
        case .selection: fraction = active ? (increasedContrast ? 0.28 : 0.22) : (increasedContrast ? 0.22 : 0.17)
        case .pressed: fraction = increasedContrast ? 0.18 : 0.13
        default: fraction = increasedContrast ? 0.09 : 0.045
        }
        return selectionSurface(base.mixed(with: emphasis, fraction: fraction), base: base)
    }

    /// In increased contrast a mid-luminance fill may support neither black nor
    /// white at 7:1. Keep state fills near their surface until that target is possible.
    private func selectionSurface(_ original: ThemeRGB, base: ThemeRGB) -> ThemeRGB {
        let target = increasedContrast ? 7.0 : 4.5
        for step in 0...100 {
            let candidate = original.mixed(with: base, fraction: Double(step) / 100)
            if max(candidate.contrastRatio(against: ThemeRGB(hex: 0)),
                   candidate.contrastRatio(against: ThemeRGB(hex: 0xFFFFFF))) >= target { return candidate }
        }
        return base
    }

    private func readable(_ original: ThemeRGB, on background: ThemeRGB, minimum: Double? = nil) -> ThemeRGB {
        let target = minimum ?? (increasedContrast ? 7.0 : 4.5)
        if original.contrastRatio(against: background) >= target { return original }
        let black = ThemeRGB(hex: 0), white = ThemeRGB(hex: 0xFFFFFF)
        let endpoint = black.contrastRatio(against: background) > white.contrastRatio(against: background) ? black : white
        for step in 1...100 {
            let candidate = original.mixed(with: endpoint, fraction: Double(step) / 100)
            if candidate.contrastRatio(against: background) >= target { return candidate }
        }
        return endpoint
    }

    private func rgb(_ color: NSColor, on background: ThemeRGB? = nil) -> ThemeRGB {
        guard let resolved = color.usingColorSpace(.sRGB) else { return background ?? palette.token(.background) }
        var value = ThemeRGB(hex: 0)
        value.red = Double(resolved.redComponent)
        value.green = Double(resolved.greenComponent)
        value.blue = Double(resolved.blueComponent)
        if let background { return background.mixed(with: value, fraction: Double(resolved.alphaComponent)) }
        return value
    }

    private func dynamic(_ resolve: @escaping @Sendable () -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.clear
            appearance.performAsCurrentDrawingAppearance { result = resolve() }
            return result
        }
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
    @AppStorage(ThemePreference.defaultsKey) private var preference = ThemePreference.defaultValue.rawValue
    @AppStorage(ThemePreference.fullPaletteKey) private var fullPalette = true
    @State private var revision = 0
    func body(content: Content) -> some View {
        var theme = NoemaTheme(dark: scheme == .dark, increasedContrast: contrast == .increased); theme.revision = revision
        theme.preference = ThemePreviewState.shared.preference ?? ThemePreference(rawValue: preference) ?? .defaultValue
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
            .scrollContentBackground(theme.usesFullPalette ? .hidden : .automatic)
            .background(theme.color(for: .window).ignoresSafeArea())
    }
}
