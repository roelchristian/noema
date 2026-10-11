import AppKit
import Testing
import NoemaBrand
@testable import noema

@Test @MainActor func semanticPaletteForegroundsMeetContrastOnTheirActualSurfaces() {
    let surfaces: [NoemaColorRole] = [.window, .sidebar, .canvas, .inspector, .elevated, .selection, .hover, .pressed]
    let foregrounds: [NoemaColorRole] = [.textPrimary, .textSecondary, .textTertiary, .textOnSelection, .accent, .destructive]
    for preference in ThemePreference.allCases where preference != .system {
        for dark in [false, true] {
            for increased in [false, true] {
                var theme = NoemaTheme(dark: dark, increasedContrast: increased)
                theme.preference = preference
                for active in [false, true] {
                    for surface in surfaces {
                        let backing = resolvedRGB(theme.native(for: surface, active: active), dark: dark)
                        for role in foregrounds {
                            let foreground = resolvedRGB(theme.nativeText(for: role, on: surface, active: active), dark: dark)
                            #expect(foreground.contrastRatio(against: backing) >= (increased ? 7 : 4.5),
                                    "\(preference), dark=\(dark), increased=\(increased), active=\(active), \(role) on \(surface)")
                        }
                    }
                }
            }
        }
    }
}

@Test @MainActor func semanticSelectionRemainsDistinctFromHoverAndPressedWhenInactive() {
    for preference in ThemePreference.allCases where preference != .system {
        for dark in [false, true] {
            for increased in [false, true] {
                var theme = NoemaTheme(dark: dark, increasedContrast: increased)
                theme.preference = preference
                let elevated = resolvedRGB(theme.native(for: .elevated), dark: dark)
                let hover = resolvedRGB(theme.native(for: .hover), dark: dark)
                let pressed = resolvedRGB(theme.native(for: .pressed), dark: dark)
                #expect(hover != elevated)
                #expect(hover != pressed)
                for active in [false, true] {
                    let selection = resolvedRGB(theme.native(for: .selection, active: active), dark: dark)
                    #expect(selection != elevated)
                    #expect(selection != hover)
                    #expect(selection != pressed)
                    let label = resolvedRGB(theme.native(for: .textOnSelection, active: active), dark: dark)
                    #expect(label.contrastRatio(against: selection) >= (increased ? 7 : 4.5))
                }
                if increased {
                    let separator = resolvedRGB(theme.native(for: .separator), dark: dark)
                    #expect(separator.contrastRatio(against: elevated) >= 3)
                    #expect(separator.contrastRatio(against: resolvedRGB(theme.native(for: .window), dark: dark)) >= 3)
                }
            }
        }
    }
}

@Test @MainActor func semanticSystemAndAccentOnlyModesKeepNativeControlColors() {
    for preference in ThemePreference.allCases {
        var theme = NoemaTheme()
        theme.preference = preference
        theme.fullPalette = false
        #expect(theme.native(for: .window) == .windowBackgroundColor)
        #expect(theme.native(for: .sidebar) == .windowBackgroundColor)
        #expect(theme.native(for: .inspector) == .windowBackgroundColor)
        #expect(theme.native(for: .canvas) == .textBackgroundColor)
        #expect(theme.native(for: .elevated) == .controlBackgroundColor)
        #expect(theme.native(for: .textPrimary) == .labelColor)
        #expect(theme.native(for: .textSecondary) == .secondaryLabelColor)
        #expect(theme.native(for: .disabledText) == .disabledControlTextColor)
        #expect(theme.native(for: .focusRing) == .keyboardFocusIndicatorColor)
        #expect(theme.native(for: .destructive) == .systemRed)
        #expect(theme.native(for: .accent) == (preference == .system ? .controlAccentColor : theme.palette.controlAccent.nsColor))
    }
}

@Test @MainActor func semanticSystemStatesStayDynamicAndSelectedTextStaysReadable() {
    for increased in [false, true] {
        var theme = NoemaTheme(increasedContrast: increased)
        theme.preference = .system
        // Hold the same color objects through both appearances to catch RGB snapshots.
        let hover = theme.native(for: .hover)
        #expect(resolvedRGB(hover, dark: false) != resolvedRGB(hover, dark: true))
        for active in [false, true] {
            let selection = theme.native(for: .selection, active: active)
            let label = theme.native(for: .textOnSelection, active: active)
            for dark in [false, true] {
                let backing = resolvedRGB(selection, dark: dark)
                #expect(resolvedRGB(label, dark: dark).contrastRatio(against: backing) >= (increased ? 7 : 4.5))
                #expect(backing != resolvedRGB(hover, dark: dark))
            }
        }
    }
}

@MainActor private func resolvedRGB(_ color: NSColor, dark: Bool) -> ThemeRGB {
    var result = ThemeRGB(hex: 0)
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let value = color.usingColorSpace(.sRGB)!
        result.red = Double(value.redComponent)
        result.green = Double(value.greenComponent)
        result.blue = Double(value.blueComponent)
    }
    return result
}
