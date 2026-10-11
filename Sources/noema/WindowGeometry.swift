import Foundation
import VaultCore

enum WindowGeometryProfile: String {
    case welcome
    case workspace

    var frameSaveName: String { "Noema.\(rawValue.capitalized)" }
    var defaultContentSize: CGSize {
        switch self {
        case .welcome: CGSize(width: 680, height: 480)
        case .workspace: CGSize(width: 1280, height: 820)
        }
    }
    var minimumContentSize: CGSize {
        switch self {
        case .welcome: CGSize(width: 560, height: 400)
        // Optional split panes collapse at narrow widths; the document remains usable.
        case .workspace: CGSize(width: 720, height: 540)
        }
    }

    static func resolve(_ phase: VaultSessionPhase, previous: Self) -> Self {
        switch phase {
        case .open, .locking: .workspace
        case .closed, .locked, .unlocking: .welcome
        case .opening: previous
        }
    }
}

/// Tracks the requested session presentation while the native window is in full screen.
struct WindowGeometryState {
    private(set) var phase: VaultSessionPhase
    private(set) var profile: WindowGeometryProfile = .welcome

    mutating func request(_ phase: VaultSessionPhase) { self.phase = phase }

    @discardableResult mutating func applyPending(canResize: Bool) -> Bool {
        guard canResize else { return false }
        let next = WindowGeometryProfile.resolve(phase, previous: profile)
        guard next != profile else { return false }
        profile = next
        return true
    }
}

enum WindowGeometry {
    /// Prefer the screen containing most of the window, including displays left of the primary.
    /// A disconnected display's frame falls back to the closest remaining screen.
    static func visibleFrame(for frame: CGRect, screens: [CGRect]) -> CGRect? {
        let screens = screens.filter { isUsable($0) }
        return screens.max { lhs, rhs in
            let leftArea = area(frame.intersection(lhs))
            let rightArea = area(frame.intersection(rhs))
            if leftArea != rightArea { return leftArea < rightArea }
            return distance(frame, lhs) > distance(frame, rhs)
        }
    }

    static func clamped(_ frame: CGRect, to visibleFrame: CGRect, minimumSize: CGSize) -> CGRect {
        guard isUsable(visibleFrame) else { return frame }
        let requested = isUsable(frame) ? frame : CGRect(origin: visibleFrame.origin, size: minimumSize)
        let width = min(visibleFrame.width, max(minimumSize.width, requested.width))
        let height = min(visibleFrame.height, max(minimumSize.height, requested.height))
        return CGRect(
            x: min(max(requested.minX, visibleFrame.minX), visibleFrame.maxX - width),
            y: min(max(requested.minY, visibleFrame.minY), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return dx * dx + dy * dy
    }
}
