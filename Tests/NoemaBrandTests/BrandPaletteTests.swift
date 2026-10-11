import Testing
@testable import NoemaBrand

@Test func brandTokensHaveExplicitCanonicalAppearanceVariants() {
    let light = NoemaBrandPalette(dark: false)
    let dark = NoemaBrandPalette(dark: true)
    #expect(light.token(.identityBackground) == ThemeRGB(hex: 0xF4F5FA))
    #expect(light.token(.orbit) == ThemeRGB(hex: 0x4358A8))
    #expect(light.token(.satellites) == ThemeRGB(hex: 0x287F9E))
    #expect(light.token(.nucleus) == ThemeRGB(hex: 0x7767C2))
    #expect(dark.token(.identityBackground) == ThemeRGB(hex: 0x101827))
    #expect(dark.token(.orbit) == ThemeRGB(hex: 0x6478E8))
    #expect(dark.token(.satellites) == ThemeRGB(hex: 0x61C6DF))
    #expect(dark.token(.nucleus) == ThemeRGB(hex: 0xA49AF4))
}

@Test func brandTokensRemainIndependentOfEveryInterfaceThemeAndContrastSetting() {
    for dark in [false, true] {
        let reference = NoemaBrandPalette(dark: dark)
        for theme in ThemePreference.allCases {
            let interface = MidnightIrisPalette(dark: dark, theme: theme)
            for increased in [false, true] {
                let brand = NoemaBrandPalette(dark: dark, increasedContrast: increased)
                for role in NoemaBrandRole.allCases {
                    #expect(brand.token(role) == reference.token(role))
                }
                // Selectable themes still have their own surface palette.
                if [.forest, .amber, .rose].contains(theme) {
                    #expect(interface.token(.background) != brand.token(.identityBackground))
                }
            }
        }
    }
}

@Test func brandComponentsMeetGraphicContrastOnTheirIdentityBackgrounds() {
    for dark in [false, true] {
        let brand = NoemaBrandPalette(dark: dark)
        for role in [NoemaBrandRole.orbit, .satellites, .nucleus] {
            #expect(brand.token(role).contrastRatio(against: brand.token(.identityBackground)) >= 3)
            #expect(brand.foreground(role) == brand.token(role))
        }
    }
}

@Test func increasedBrandContrastStrengthensComponentsWithoutMutatingTokens() {
    for dark in [false, true] {
        let normal = NoemaBrandPalette(dark: dark)
        let increased = NoemaBrandPalette(dark: dark, increasedContrast: true)
        for role in [NoemaBrandRole.orbit, .satellites, .nucleus] {
            let foreground = increased.foreground(role)
            #expect(foreground.contrastRatio(against: increased.token(.identityBackground)) >= 7)
            #expect(foreground.contrastRatio(against: increased.token(.identityBackground)) >=
                    normal.foreground(role).contrastRatio(against: normal.token(.identityBackground)))
            #expect(increased.token(role) == normal.token(role))
        }
    }
}

@Test func brandForegroundUsesItsActualSurfaceAndRequestedContrast() {
    // A compact glyph may sit on a theme surface instead of the identity background.
    for theme in ThemePreference.allCases {
        for dark in [false, true] {
            let interface = MidnightIrisPalette(dark: dark, theme: theme)
            for increased in [false, true] {
                let brand = NoemaBrandPalette(dark: dark, increasedContrast: increased)
                for surface in [ThemeRole.background, .surfaceElevated] {
                    let background = interface.token(surface)
                    for role in [NoemaBrandRole.orbit, .satellites, .nucleus] {
                        let foreground = brand.foreground(role, against: background, minimumContrast: 4.5)
                        #expect(foreground.contrastRatio(against: background) >= (increased ? 7 : 4.5))
                        for channel in [foreground.red, foreground.green, foreground.blue] {
                            #expect(channel.isFinite && channel >= 0 && channel <= 1)
                        }
                    }
                }
            }
        }
    }
}

@Test func fixedBrandGlyphColoursStayLegibleAcrossEveryInterfaceSurface() {
    for dark in [false, true] {
        let normal = NoemaBrandPalette(dark: dark)
        let increased = NoemaBrandPalette(dark: dark, increasedContrast: true)
        for role in [NoemaBrandRole.orbit, .satellites, .nucleus] {
            // A fixed margin lets the sidebar glyph preserve its identity across
            // interface themes while satisfying 7:1 on their slightly different surfaces.
            let strongerGlyph = increased.foreground(role, minimumContrast: 9)
            for theme in ThemePreference.allCases {
                let interface = MidnightIrisPalette(dark: dark, theme: theme)
                for surface in [ThemeRole.background, .surfaceElevated] {
                    let background = interface.token(surface)
                    #expect(normal.token(role).contrastRatio(against: background) >= 3)
                    #expect(strongerGlyph.contrastRatio(against: background) >= 7)
                }
            }
            // Representative native sidebar surfaces, not a claim about dynamic
            // material pixels (which vary with the wallpaper and macOS version).
            let systemSurfaces: [UInt32] = dark ? [0x242424, 0x2A2A2A] : [0xF2F2F2, 0xFFFFFF]
            for hex in systemSurfaces {
                let background = ThemeRGB(hex: hex)
                #expect(normal.token(role).contrastRatio(against: background) >= 3)
                #expect(strongerGlyph.contrastRatio(against: background) >= 7)
            }
        }
    }
}

@Test func brandTokensAndDerivedColoursContainValidSRGBValues() {
    for dark in [false, true] {
        for increased in [false, true] {
            let brand = NoemaBrandPalette(dark: dark, increasedContrast: increased)
            for role in NoemaBrandRole.allCases {
                for colour in [brand.token(role), brand.foreground(role)] {
                    for channel in [colour.red, colour.green, colour.blue] {
                        #expect(channel.isFinite && channel >= 0 && channel <= 1)
                    }
                }
            }
        }
    }
}

@Test func impossibleBrandContrastRequestsReturnTheStrongestAchievableForeground() {
    let background = ThemeRGB(hex: 0x777777)
    let brand = NoemaBrandPalette(dark: false, increasedContrast: true)
    let foreground = brand.foreground(.orbit, against: background)
    let bestContrast = max(ThemeRGB(hex: 0x000000).contrastRatio(against: background),
                           ThemeRGB(hex: 0xFFFFFF).contrastRatio(against: background))
    #expect(foreground.contrastRatio(against: background) == bestContrast)
    #expect(bestContrast < 7)
    #expect(brand.foreground(.orbit, minimumContrast: .infinity) == ThemeRGB(hex: 0x000000))
}
