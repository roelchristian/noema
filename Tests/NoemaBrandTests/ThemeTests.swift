import Foundation
import Testing
@testable import NoemaBrand

@Test func textAndInteractiveForegroundsMeetAAInBothAppearances() {
    for dark in [false, true] {
        let palette = MidnightIrisPalette(dark: dark)
        for surface in [ThemeRole.background, .surfaceElevated] {
            for role in [ThemeRole.textPrimary, .textMuted, .accentPrimary, .accentSecondary, .graphHighlight] {
                let foreground = palette.foreground(role, on: surface)
                #expect(foreground.contrastRatio(against: palette.token(surface)) >= 4.5)
                // A derived foreground stays in the palette's tonal range.
                #expect(foreground.red >= 0 && foreground.red <= 1)
                #expect(foreground.green >= 0 && foreground.green <= 1)
                #expect(foreground.blue >= 0 && foreground.blue <= 1)
            }
        }
    }
}

@Test func increasedContrastStrengthensMetadataAndColourIndicators() {
    for dark in [false, true] {
        let palette = MidnightIrisPalette(dark: dark, increasedContrast: true)
        for surface in [ThemeRole.background, .surfaceElevated] {
            for role in [ThemeRole.textMuted, .accentPrimary, .accentSecondary, .graphHighlight, .border] {
                #expect(palette.foreground(role, on: surface).contrastRatio(against: palette.token(surface)) >= 7)
            }
        }
    }
}

@Test func contrastUsesSRGBRelativeLuminance() {
    #expect(abs(ThemeRGB(hex: 0xFFFFFF).contrastRatio(against: ThemeRGB(hex: 0x000000)) - 21) < 0.00001)
    // This original pairing is below AA; the derived foreground must correct it.
    let dark = MidnightIrisPalette(dark: true)
    #expect(dark.token(.accentPrimary).contrastRatio(against: dark.token(.surfaceElevated)) < 4.5)
    #expect(dark.foreground(.accentPrimary).contrastRatio(against: dark.token(.surfaceElevated)) >= 4.5)
}

@Test func filledControlsKeepReadableNativeLabels() {
    let white = MidnightIrisPalette(dark: false).token(.surfaceElevated)
    let offWhite = MidnightIrisPalette(dark: true).token(.textPrimary)
    for dark in [false, true] {
        for increased in [false, true] {
            let palette = MidnightIrisPalette(dark: dark, increasedContrast: increased)
            let minimum = increased ? 7.0 : 4.8
            #expect(white.contrastRatio(against: palette.controlAccent) >= minimum)
            #expect(offWhite.contrastRatio(against: palette.controlAccent) >= minimum)
        }
    }
}
