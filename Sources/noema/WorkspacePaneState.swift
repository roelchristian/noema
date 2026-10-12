import AppKit
import Observation
import SwiftUI

/// User preferences are independent from the panes temporarily hidden to fit a window.
@MainActor @Observable final class WorkspacePaneState {
    static let sidebarMinimum: CGFloat = 190
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMaximum: CGFloat = 320
    static let sidebarVisibilityKey = "workspace.sidebar.visible"
    static let inspectorVisibilityKey = "workspace.inspector.visible"
    static let sidebarWidthKey = "workspace.sidebar.width"
    static let inspectorWidthKey = "workspace.inspector.width"

    @ObservationIgnored private let defaults: UserDefaults
    var isSidebarVisible: Bool { didSet { defaults.set(isSidebarVisible, forKey: Self.sidebarVisibilityKey) } }
    var isInspectorVisible: Bool { didSet { defaults.set(isInspectorVisible, forKey: Self.inspectorVisibilityKey) } }
    private(set) var sidebarWidth: CGFloat
    private(set) var inspectorWidth: CGFloat
    private(set) var priority: WorkspacePane = .sidebar

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSidebarVisible = defaults.object(forKey: Self.sidebarVisibilityKey) as? Bool ?? true
        isInspectorVisible = defaults.object(forKey: Self.inspectorVisibilityKey) as? Bool ?? true
        sidebarWidth = Self.validWidth(defaults.double(forKey: Self.sidebarWidthKey), minimum: Self.sidebarMinimum, maximum: Self.sidebarMaximum, fallback: Self.sidebarIdeal)
        inspectorWidth = Self.validWidth(defaults.double(forKey: Self.inspectorWidthKey), minimum: InspectorState.minWidth, maximum: InspectorState.maxWidth, fallback: InspectorState.idealWidth)
    }

    func revealSidebar() {
        priority = .sidebar
        isSidebarVisible = true
    }

    func toggleSidebar(presented: Bool) {
        priority = .sidebar
        isSidebarVisible = !presented
    }

    func toggleInspector(presented: Bool) {
        priority = .inspector
        isInspectorVisible = !presented
    }

    func rememberWidths(sidebar: CGFloat?, inspector: CGFloat?) {
        if let sidebar, sidebar.isFinite, sidebar >= Self.sidebarMinimum {
            sidebarWidth = min(sidebar, Self.sidebarMaximum)
            defaults.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
        }
        if let inspector, inspector.isFinite, inspector >= InspectorState.minWidth {
            inspectorWidth = min(inspector, InspectorState.maxWidth)
            defaults.set(Double(inspectorWidth), forKey: Self.inspectorWidthKey)
        }
    }

    func presentation(width: CGFloat, mainMinimum: CGFloat, inspectorAvailable: Bool) -> WorkspacePanePresentation {
        WorkspacePanePresentation.resolve(
            width: width, mainMinimum: mainMinimum,
            sidebarRequested: isSidebarVisible,
            inspectorRequested: isInspectorVisible && inspectorAvailable,
            priority: priority
        )
    }

    private static func validWidth(_ value: Double, minimum: CGFloat, maximum: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(CGFloat(value), minimum), maximum)
    }
}

enum WorkspacePane { case sidebar, inspector }

struct WorkspacePanePresentation: Equatable {
    let sidebar: Bool
    let inspector: Bool

    @MainActor static func resolve(width: CGFloat, mainMinimum: CGFloat, sidebarRequested: Bool, inspectorRequested: Bool, priority: WorkspacePane) -> Self {
        // Reserve a point per native divider. Do not change persisted intent during resize.
        let available = max(0, width - mainMinimum)
        let sidebarCost = WorkspacePaneState.sidebarMinimum + 1
        let inspectorCost = InspectorState.minWidth + 1
        if sidebarRequested && inspectorRequested && available >= sidebarCost + inspectorCost {
            return Self(sidebar: true, inspector: true)
        }
        if priority == .inspector, inspectorRequested, available >= inspectorCost {
            return Self(sidebar: false, inspector: true)
        }
        if sidebarRequested, available >= sidebarCost {
            return Self(sidebar: true, inspector: false)
        }
        return Self(sidebar: false, inspector: inspectorRequested && available >= inspectorCost)
    }
}

/// One focused action path for the native toolbar and the View menu.
struct WorkspacePaneActions {
    let toggleSidebar: () -> Void
    let toggleInspector: () -> Void
    let sidebarPresented: Bool
    let inspectorPresented: Bool
    let canToggleSidebar: Bool
    let canToggleInspector: Bool
}

private struct WorkspacePaneActionsKey: FocusedValueKey {
    typealias Value = WorkspacePaneActions
}

extension FocusedValues {
    var workspacePaneActions: WorkspacePaneActions? {
        get { self[WorkspacePaneActionsKey.self] }
        set { self[WorkspacePaneActionsKey.self] = newValue }
    }
}

/// Keeps HSplitView's native divider handling and delegate. Restore only when the pane
/// arrangement changes; remember widths only during divider drags, never window resize.
struct WorkspaceSplitViewPersistence: NSViewRepresentable {
    let state: WorkspacePaneState
    let presentation: WorkspacePanePresentation
    let mainMinimum: CGFloat

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.state = state
        view.presentation = presentation
        view.mainMinimum = mainMinimum
        view.scheduleConfiguration()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

    final class Probe: NSView {
        var state: WorkspacePaneState?
        var presentation = WorkspacePanePresentation(sidebar: false, inspector: false)
        var mainMinimum: CGFloat = 420
        private weak var splitView: NSSplitView?
        private var lastPresentation: WorkspacePanePresentation?
        private var lastMainMinimum: CGFloat?
        private var scheduled = false
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleConfiguration() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleConfiguration() }
        override func layout() { super.layout(); scheduleConfiguration() }

        func scheduleConfiguration() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.configure()
            }
        }

        func disconnect() {
            NotificationCenter.default.removeObserver(self)
            splitView = nil
            lastPresentation = nil
            lastMainMinimum = nil
        }

        func configure() {
            guard window != nil, let state else { return }
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let split = ancestor as? NSSplitView, split.isVertical else { return }
            if splitView !== split {
                disconnect()
                splitView = split
                NotificationCenter.default.addObserver(self, selector: #selector(dividerResized(_:)), name: NSSplitView.didResizeSubviewsNotification, object: split)
            }
            let expectedCount = 1 + (presentation.sidebar ? 1 : 0) + (presentation.inspector ? 1 : 0)
            guard split.arrangedSubviews.count == expectedCount, split.bounds.width > mainMinimum,
                  lastPresentation != presentation || lastMainMinimum != mainMinimum else { return }
            lastPresentation = presentation
            lastMainMinimum = mainMinimum
            // SwiftUI owns an NSSplitViewController. AppKit prohibits setting holding
            // priorities directly on its split view; preserve the controller's layout policy.
            let divider = split.dividerThickness
            if presentation.sidebar {
                let remaining = presentation.inspector ? InspectorState.minWidth + divider * 2 : divider
                let maximum = min(WorkspacePaneState.sidebarMaximum, split.bounds.width - mainMinimum - remaining)
                split.setPosition(min(state.sidebarWidth, max(WorkspacePaneState.sidebarMinimum, maximum)), ofDividerAt: 0)
            }
            if presentation.inspector {
                let sidebar = presentation.sidebar ? split.arrangedSubviews[0].frame.width + divider : 0
                let maximum = min(InspectorState.maxWidth, split.bounds.width - mainMinimum - sidebar - divider)
                let width = min(state.inspectorWidth, max(InspectorState.minWidth, maximum))
                split.setPosition(split.bounds.width - width - divider, ofDividerAt: expectedCount - 2)
            }
        }

        @objc private func dividerResized(_ notification: Notification) {
            guard let split = splitView, (notification.object as? NSSplitView) === split,
                  NSApp.currentEvent?.type == .leftMouseDragged,
                  split.arrangedSubviews.count == 1 + (presentation.sidebar ? 1 : 0) + (presentation.inspector ? 1 : 0) else { return }
            let sidebar = presentation.sidebar ? split.arrangedSubviews.first?.frame.width : nil
            let inspector = presentation.inspector ? split.arrangedSubviews.last?.frame.width : nil
            DispatchQueue.main.async { [weak self] in
                self?.state?.rememberWidths(sidebar: sidebar, inspector: inspector)
            }
        }
    }
}
