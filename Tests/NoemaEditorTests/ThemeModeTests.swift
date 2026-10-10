import AppKit
import Testing
import NoemaBrand
@testable import noema

@Test @MainActor func themeModesPreserveNativeSurfacesAndApplyPaletteRoles() {
    for preference in ThemePreference.allCases where preference != .system {
        for dark in [false, true] {
            var theme = NoemaTheme(dark: dark)
            theme.preference = preference
            theme.fullPalette = false
            #expect(theme.native(.background) == NSColor.windowBackgroundColor)
            #expect(theme.native(.surfaceElevated) == NSColor.textBackgroundColor)
            #expect(theme.nativeText() == NSColor.labelColor)
            #expect(theme.native(.accentPrimary) == theme.native(.accentSecondary))
            theme.fullPalette = true
            #expect(theme.native(.background) == theme.palette.token(.background).nsColor)
            #expect(theme.native(.surfaceElevated) == theme.palette.token(.surfaceElevated).nsColor)
            #expect(theme.nativeText() == theme.palette.foreground(.textPrimary).nsColor)
        }
    }
    let system = NoemaTheme()
    #expect(!system.usesFullPalette)
    #expect(system.accent == nil)
    #expect(system.native(.accentPrimary) == NSColor.controlAccentColor)
}
