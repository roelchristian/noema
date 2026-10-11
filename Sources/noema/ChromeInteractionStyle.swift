import SwiftUI

/// Presentation only: Button and the existing model continue to own interaction
/// and actions. Selection wins over transient pointer states, including while
/// the window is inactive. Focus adds an outline without changing the backing.
struct NoemaChromePresentation: Equatable {
    var selected = false
    var hovered = false
    var pressed = false
    var enabled = true
    var focused = false

    var backgroundRole: NoemaColorRole? {
        if selected { return .selection }
        guard enabled else { return nil }
        if pressed { return .pressed }
        return hovered ? .hover : nil
    }

    func surface(on normal: NoemaColorRole) -> NoemaColorRole {
        backgroundRole ?? normal
    }

    func foreground(for normal: NoemaColorRole) -> NoemaColorRole {
        guard enabled else { return .disabledText }
        if normal == .destructive { return .destructive }
        return selected ? .textOnSelection : normal
    }

    var showsFocusRing: Bool { enabled && focused }
    var showsSelectedPress: Bool { enabled && selected && pressed }

    static func lockActionVisible(locked: Bool, revealed: Bool, pending: Bool,
                                  focused: Bool, voiceOver: Bool) -> Bool {
        locked || revealed || pending || focused || voiceOver
    }
}

private struct NoemaChromePresentationKey: EnvironmentKey {
    static let defaultValue: NoemaChromePresentation? = nil
}

private struct NoemaChromeSurfaceKey: EnvironmentKey {
    static let defaultValue: NoemaColorRole = .sidebar
}

extension EnvironmentValues {
    fileprivate var noemaChromePresentation: NoemaChromePresentation? {
        get { self[NoemaChromePresentationKey.self] }
        set { self[NoemaChromePresentationKey.self] = newValue }
    }

    fileprivate var noemaChromeSurface: NoemaColorRole {
        get { self[NoemaChromeSurfaceKey.self] }
        set { self[NoemaChromeSurfaceKey.self] = newValue }
    }
}

/// Leaf styling reads the button's current presentation. Applying a static
/// foreground inside a label would override ButtonStyle's pressed/hover text
/// and could resolve contrast against the wrong surface.
private struct NoemaChromeForeground: ViewModifier {
    let role: NoemaColorRole
    @Environment(\.noemaTheme) private var theme
    @Environment(\.appearsActive) private var active
    @Environment(\.noemaChromePresentation) private var presentation
    @Environment(\.noemaChromeSurface) private var surface

    func body(content: Content) -> some View {
        let state = presentation ?? NoemaChromePresentation()
        content.foregroundStyle(theme.text(for: state.foreground(for: role),
                                           on: state.surface(on: surface), active: active))
    }
}

extension View {
    func noemaChromeForeground(_ role: NoemaColorRole = .textPrimary) -> some View {
        modifier(NoemaChromeForeground(role: role))
    }

    func noemaFocusRing(_ focused: Bool, radius: CGFloat = NoemaMetrics.radiusSmall) -> some View {
        modifier(NoemaFocusRing(focused: focused, radius: radius))
    }
}

private struct NoemaFocusRing: ViewModifier {
    let focused: Bool
    let radius: CGFloat
    @Environment(\.noemaTheme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if focused {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.color(for: .focusRing), lineWidth: NoemaMetrics.focusRingWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Use only on custom plain chrome, leaving native buttons, menus, Table and
/// Form controls platform-owned. The style adds no gesture/action handling or
/// animations. SwiftUI supplies press, hover, focus and disabled state.
struct NoemaChromeButtonStyle: ButtonStyle {
    var selected = false
    var surface: NoemaColorRole = .sidebar
    var drawsSelection = true
    var focused = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, selected: selected,
                         surface: surface, drawsSelection: drawsSelection,
                         explicitlyFocused: focused)
    }

    private struct ChromeButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        let surface: NoemaColorRole
        let drawsSelection: Bool
        let explicitlyFocused: Bool
        @Environment(\.noemaTheme) private var theme
        @Environment(\.appearsActive) private var active
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovered = false

        var body: some View {
            let state = NoemaChromePresentation(selected: selected, hovered: hovered,
                                                pressed: configuration.isPressed,
                                                enabled: enabled,
                                                focused: focused || explicitlyFocused)
            configuration.label
                .environment(\.noemaChromePresentation, state)
                .environment(\.noemaChromeSurface, surface)
                .foregroundStyle(theme.text(for: state.foreground(for: .textPrimary),
                                            on: state.surface(on: surface), active: active))
                .background {
                    if let role = state.backgroundRole, drawsSelection || role != .selection {
                        RoundedRectangle(cornerRadius: NoemaMetrics.radiusSmall, style: .continuous)
                            .fill(theme.color(for: role, active: active))
                    }
                }
                .overlay {
                    // A selected button keeps its navigation fill while pressed.
                    // A separate press outline retains visible down feedback.
                    if state.showsSelectedPress {
                        RoundedRectangle(cornerRadius: NoemaMetrics.radiusSmall, style: .continuous)
                            .strokeBorder(theme.color(for: .pressed, active: active),
                                          lineWidth: NoemaMetrics.focusRingWidth)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .noemaFocusRing(state.showsFocusRing)
                .onHover { hovered = $0 }
        }
    }
}

/// Native spinner with an explicit status, so a loading affordance conveys the
/// work underway to keyboard and VoiceOver users as well as visually.
struct NoemaLoadingStatus: View {
    let title: String
    var surface: NoemaColorRole = .window
    @Environment(\.noemaTheme) private var theme

    init(_ title: String, surface: NoemaColorRole = .window) {
        self.title = title
        self.surface = surface
    }

    var body: some View {
        HStack(spacing: NoemaSpacing.sm) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(title).font(NoemaTypography.metadata)
                .foregroundStyle(theme.text(for: .textSecondary, on: surface))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("In progress")
    }
}
