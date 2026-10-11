import Foundation

/// Permanent identity roles, separate from the application's selectable theme roles.
public enum NoemaBrandRole: CaseIterable, Sendable {
    case identityBackground, orbit, satellites, nucleus
}

/// Noema's fixed Porcelain Iris (light) and Midnight Iris (dark) identity.
/// Appearance and accessibility are explicit inputs; application settings are never read.
public struct NoemaBrandPalette: Equatable, Sendable {
    public let dark: Bool
    public let increasedContrast: Bool

    public init(dark: Bool, increasedContrast: Bool = false) {
        self.dark = dark
        self.increasedContrast = increasedContrast
    }

    /// Canonical artwork tokens remain unchanged by accessibility adjustments.
    public func token(_ role: NoemaBrandRole) -> ThemeRGB {
        let hex: UInt32
        switch role {
        case .identityBackground: hex = dark ? 0x101827 : 0xF4F5FA
        case .orbit: hex = dark ? 0x6478E8 : 0x4358A8
        case .satellites: hex = dark ? 0x61C6DF : 0x287F9E
        case .nucleus: hex = dark ? 0xA49AF4 : 0x7767C2
        }
        return ThemeRGB(hex: hex)
    }

    /// Derive a legible component for the actual backing surface without changing its token.
    /// Increase Contrast requests at least 7:1. An unattainable request returns the
    /// strongest possible black/white foreground for that surface.
    public func foreground(_ role: NoemaBrandRole, against background: ThemeRGB? = nil,
                           minimumContrast: Double = 3) -> ThemeRGB {
        let background = background ?? token(.identityBackground)
        let original = token(role)
        let requested = minimumContrast.isNaN ? 3 : max(1, minimumContrast)
        let target = increasedContrast ? max(7, requested) : requested
        if original.contrastRatio(against: background) >= target { return original }

        let black = ThemeRGB(hex: 0x000000)
        let white = ThemeRGB(hex: 0xFFFFFF)
        let endpoint = black.contrastRatio(against: background) >= white.contrastRatio(against: background)
            ? black : white
        guard endpoint.contrastRatio(against: background) > target else { return endpoint }

        // Find the smallest tonal correction whose contrast meets the target.
        // The upper bound always meets it, so rounding never returns a failing colour.
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<24 {
            let fraction = (lower + upper) / 2
            let candidate = original.mixed(with: endpoint, fraction: fraction)
            if candidate.contrastRatio(against: background) >= target {
                upper = fraction
            } else {
                lower = fraction
            }
        }
        return original.mixed(with: endpoint, fraction: upper)
    }
}
