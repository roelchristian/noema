import AppKit
import NoemaBrand
import Testing
@testable import noema

@Suite("Custom chrome interaction (UI.TK06)")
struct ChromeInteractionTests {
    @Test func selectionSurvivesPointerAndDisabledTransitions() {
        for hovered in [false, true] {
            for pressed in [false, true] {
                for enabled in [false, true] {
                    let state = NoemaChromePresentation(selected: true, hovered: hovered,
                                                        pressed: pressed, enabled: enabled)
                    #expect(state.backgroundRole == .selection)
                    #expect(state.surface(on: .sidebar) == .selection)
                    #expect(state.foreground(for: .textTertiary) == (enabled ? .textOnSelection : .disabledText))
                    #expect(state.showsSelectedPress == (enabled && pressed))
                }
            }
        }
    }

    @Test func pressEndsInHoverAndDisabledControlsSuppressTransientFeedback() {
        var state = NoemaChromePresentation(hovered: true, pressed: true)
        #expect(state.backgroundRole == .pressed)
        state.pressed = false
        #expect(state.backgroundRole == .hover)
        state.hovered = false
        #expect(state.backgroundRole == nil)
        #expect(state.surface(on: .elevated) == .elevated)
        state.hovered = true
        state.pressed = true
        state.focused = true
        state.enabled = false
        #expect(state.backgroundRole == nil)
        #expect(!state.showsFocusRing)
        #expect(state.foreground(for: .textPrimary) == .disabledText)
    }

    @Test func focusAddsAnOutlineWithoutChangingSelectionOrTextEmphasis() {
        for selected in [false, true] {
            for hovered in [false, true] {
                var state = NoemaChromePresentation(selected: selected, hovered: hovered)
                let surface = state.surface(on: .elevated)
                let text = state.foreground(for: .textSecondary)
                state.focused = true
                #expect(state.showsFocusRing)
                #expect(state.surface(on: .elevated) == surface)
                #expect(state.foreground(for: .textSecondary) == text)
                #expect(state.foreground(for: .destructive) == .destructive)
            }
        }
    }

    @Test func editingLockRemainsDiscoverableWithoutPointerHover() {
        #expect(!NoemaChromePresentation.lockActionVisible(locked: false, revealed: false,
                                                           pending: false, focused: false, voiceOver: false))
        // Each independent route must reveal the action; keyboard focus and
        // VoiceOver cannot depend on the pointer or on a pre-existing lock.
        for route in 0..<5 {
            #expect(NoemaChromePresentation.lockActionVisible(locked: route == 0, revealed: route == 1,
                                                              pending: route == 2, focused: route == 3,
                                                              voiceOver: route == 4))
        }
    }

    @Test @MainActor func actualStateForegroundPairsRemainReadableAndInactiveSelectionVisible() {
        let states = [NoemaChromePresentation(), NoemaChromePresentation(hovered: true),
                      NoemaChromePresentation(hovered: true, pressed: true),
                      NoemaChromePresentation(selected: true, hovered: true, pressed: true),
                      NoemaChromePresentation(selected: true, enabled: false)]
        for preference in [ThemePreference.system, .midnightIris] {
            for dark in [false, true] {
                for increased in [false, true] {
                    var theme = NoemaTheme(dark: dark, increasedContrast: increased)
                    theme.preference = preference
                    for active in [false, true] {
                        for state in states {
                            let surface = state.surface(on: .elevated)
                            let backing = rgb(theme.native(for: surface, active: active), dark: dark)
                            for role in [NoemaColorRole.textPrimary, .textSecondary, .textTertiary] {
                                let foreground = rgb(theme.nativeText(for: state.foreground(for: role),
                                                                      on: surface, active: active), dark: dark)
                                #expect(foreground.contrastRatio(against: backing) >= (increased ? 7 : 4.5))
                            }
                            if state.selected {
                                #expect(backing != rgb(theme.native(for: .elevated), dark: dark))
                                #expect(backing != rgb(theme.native(for: .hover), dark: dark))
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor private func rgb(_ color: NSColor, dark: Bool) -> ThemeRGB {
        var result = ThemeRGB(hex: 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let value = color.usingColorSpace(.sRGB)!
            result.red = Double(value.redComponent)
            result.green = Double(value.greenComponent)
            result.blue = Double(value.blueComponent)
        }
        return result
    }
}
