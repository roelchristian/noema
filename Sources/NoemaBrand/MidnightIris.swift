import Foundation

public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public static let defaultsKey = "noema.appearance"
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum ThemeRole: CaseIterable, Sendable {
    case background, surfaceElevated, accentPrimary, accentSecondary, graphHighlight
    case textPrimary, textMuted, border
}

public struct ThemeRGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(hex: UInt32) {
        red = Double((hex >> 16) & 255) / 255
        green = Double((hex >> 8) & 255) / 255
        blue = Double(hex & 255) / 255
    }
    public var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    public func mixed(with other: Self, fraction: Double) -> Self {
        var result = self
        let t = min(max(fraction, 0), 1)
        result.red += (other.red - red) * t
        result.green += (other.green - green) * t
        result.blue += (other.blue - blue) * t
        return result
    }
    public func contrastRatio(against other: Self) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
    private var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return linear(red) * 0.2126 + linear(green) * 0.7152 + linear(blue) * 0.0722
    }
}

public struct MidnightIrisPalette: Equatable, Sendable {
    public let dark: Bool
    public let increasedContrast: Bool
    public init(dark: Bool, increasedContrast: Bool = false) {
        self.dark = dark
        self.increasedContrast = increasedContrast
    }
    public func token(_ role: ThemeRole) -> ThemeRGB {
        let hex: UInt32
        switch role {
        case .background: hex = dark ? 0x101827 : 0xF7F8FC
        case .surfaceElevated: hex = dark ? 0x1C2943 : 0xFFFFFF
        case .accentPrimary: hex = dark ? 0x6478E8 : 0x485CC4
        case .accentSecondary: hex = dark ? 0x61C6DF : 0x187F9B
        case .graphHighlight: hex = dark ? 0xA49AF4 : 0x7964CD
        case .textPrimary: hex = dark ? 0xE9EDF9 : 0x202A40
        case .textMuted: hex = dark ? 0xA6B3CE : 0x63718B
        case .border: hex = dark ? 0x30405C : 0xDAE0ED
        }
        return ThemeRGB(hex: hex)
    }
    /// Preserve the supplied tokens; derive a readable foreground for its actual surface.
    public func foreground(_ role: ThemeRole, on surface: ThemeRole = .surfaceElevated,
                           minimumContrast: Double = 4.5) -> ThemeRGB {
        let target = increasedContrast ? max(minimumContrast, 7) : minimumContrast
        let original = token(role)
        let background = token(surface)
        for step in 0...100 {
            let candidate = original.mixed(with: token(.textPrimary), fraction: Double(step) / 100)
            if candidate.contrastRatio(against: background) >= target { return candidate }
        }
        return token(.textPrimary)
    }

    /// Native prominent and selected controls use white/off-white labels.
    /// Darken only their fill, retaining the original accent for icons and graphics.
    public var controlAccent: ThemeRGB {
        let label = MidnightIrisPalette(dark: true).token(.textPrimary)
        let target = increasedContrast ? 7.0 : 4.8
        let original = token(.accentPrimary)
        let darker = dark ? token(.background) : token(.textPrimary)
        for step in 0...100 {
            let candidate = original.mixed(with: darker, fraction: Double(step) / 100)
            if label.contrastRatio(against: candidate) >= target { return candidate }
        }
        return darker
    }
}
