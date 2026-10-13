import AppKit
import Observation
import SwiftUI

/// User preferences are independent from the panes temporarily hidden to fit a window.
@MainActor @Observable final class WorkspacePaneState {
    static let sidebarMinimum: CGFloat = 190
    static let sidebarIdeal: CGFloat = 220
    static let sidebarMaximum: CGFloat = 320
    static let collectionMinimum: CGFloat = 260
    static let collectionIdeal: CGFloat = 300
    static let collectionMaximum: CGFloat = 360
    static let contentMinimum: CGFloat = 420
    static let sidebarVisibilityKey = "workspace.sidebar.visible"
    static let collectionVisibilityKey = "workspace.collection.visible"
    static let inspectorVisibilityKey = "workspace.inspector.visible"
    static let sidebarWidthKey = "workspace.sidebar.width"
    static let collectionWidthKey = "workspace.collection.width"
    static let inspectorWidthKey = "workspace.inspector.width"

    @ObservationIgnored private let defaults: UserDefaults
    var isSidebarVisible: Bool { didSet { defaults.set(isSidebarVisible, forKey: Self.sidebarVisibilityKey) } }
    var isCollectionVisible: Bool { didSet { defaults.set(isCollectionVisible, forKey: Self.collectionVisibilityKey) } }
    var isInspectorVisible: Bool { didSet { defaults.set(isInspectorVisible, forKey: Self.inspectorVisibilityKey) } }
    private(set) var sidebarWidth: CGFloat
    private(set) var collectionWidth: CGFloat
    private(set) var inspectorWidth: CGFloat
    private(set) var priority: WorkspacePane = .sidebar

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSidebarVisible = defaults.object(forKey: Self.sidebarVisibilityKey) as? Bool ?? true
        isCollectionVisible = defaults.object(forKey: Self.collectionVisibilityKey) as? Bool ?? true
        isInspectorVisible = defaults.object(forKey: Self.inspectorVisibilityKey) as? Bool ?? true
        sidebarWidth = Self.validWidth(defaults.double(forKey: Self.sidebarWidthKey), minimum: Self.sidebarMinimum, maximum: Self.sidebarMaximum, fallback: Self.sidebarIdeal)
        collectionWidth = Self.validWidth(defaults.double(forKey: Self.collectionWidthKey), minimum: Self.collectionMinimum, maximum: Self.collectionMaximum, fallback: Self.collectionIdeal)
        inspectorWidth = Self.validWidth(defaults.double(forKey: Self.inspectorWidthKey), minimum: InspectorState.minWidth, maximum: InspectorState.maxWidth, fallback: InspectorState.idealWidth)
    }

    func revealSidebar() {
        priority = .sidebar
        isSidebarVisible = true
    }

    func revealCollection() {
        priority = .collection
        isCollectionVisible = true
    }

    func toggleSidebar(presented: Bool) {
        priority = .sidebar
        isSidebarVisible = !presented
    }

    func toggleCollection(presented: Bool) {
        priority = .collection
        isCollectionVisible = !presented
    }

    func toggleInspector(presented: Bool) {
        priority = .inspector
        isInspectorVisible = !presented
    }

    func rememberWidths(sidebar: CGFloat?, collection: CGFloat? = nil, inspector: CGFloat?) {
        if let sidebar, sidebar.isFinite, sidebar >= Self.sidebarMinimum {
            sidebarWidth = min(sidebar, Self.sidebarMaximum)
            defaults.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
        }
        if let collection, collection.isFinite, collection >= Self.collectionMinimum {
            collectionWidth = min(collection, Self.collectionMaximum)
            defaults.set(Double(collectionWidth), forKey: Self.collectionWidthKey)
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
            collectionRequested: isCollectionVisible,
            inspectorRequested: isInspectorVisible && inspectorAvailable,
            priority: priority
        )
    }

    private static func validWidth(_ value: Double, minimum: CGFloat, maximum: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(CGFloat(value), minimum), maximum)
    }
}

enum WorkspacePane { case sidebar, collection, inspector }

struct WorkspacePanePresentation: Equatable {
    let sidebar: Bool
    let collection: Bool
    let inspector: Bool

    init(sidebar: Bool, collection: Bool = false, inspector: Bool) {
        self.sidebar = sidebar
        self.collection = collection
        self.inspector = inspector
    }

    @MainActor static func resolve(
        width: CGFloat,
        mainMinimum: CGFloat,
        sidebarRequested: Bool,
        collectionRequested: Bool = false,
        inspectorRequested: Bool,
        priority: WorkspacePane
    ) -> Self {
        if !collectionRequested {
            return resolveOuterPanes(
                width: width, mainMinimum: mainMinimum,
                sidebarRequested: sidebarRequested, inspectorRequested: inspectorRequested, priority: priority
            )
        }
        return resolveInbox(
            width: width, mainMinimum: mainMinimum,
            sidebarRequested: sidebarRequested, inspectorRequested: inspectorRequested, priority: priority
        )
    }

    /// Sidebar and inspector only. Collection is not part of this budget.
    @MainActor private static func resolveOuterPanes(
        width: CGFloat, mainMinimum: CGFloat, sidebarRequested: Bool, inspectorRequested: Bool, priority: WorkspacePane
    ) -> Self {
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

    /// Content keeps `mainMinimum`. The collection list collapses before that width is reduced.
    @MainActor private static func resolveInbox(
        width: CGFloat, mainMinimum: CGFloat, sidebarRequested: Bool, inspectorRequested: Bool, priority: WorkspacePane
    ) -> Self {
        if fits(width: width, contentMinimum: mainMinimum, sidebar: sidebarRequested, collection: true, inspector: inspectorRequested) {
            return Self(sidebar: sidebarRequested, collection: true, inspector: inspectorRequested)
        }
        switch priority {
        case .collection:
            if fits(width: width, contentMinimum: mainMinimum, sidebar: false, collection: true, inspector: false) {
                let sidebar = sidebarRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: true, collection: true, inspector: false)
                let inspector = inspectorRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: sidebar, collection: true, inspector: true)
                return Self(sidebar: sidebar, collection: true, inspector: inspector)
            }
            return resolveOuterPanes(
                width: width, mainMinimum: mainMinimum,
                sidebarRequested: sidebarRequested, inspectorRequested: inspectorRequested, priority: .sidebar
            )
        case .inspector:
            if inspectorRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: sidebarRequested, collection: false, inspector: true) {
                return Self(sidebar: sidebarRequested, collection: false, inspector: true)
            }
            if inspectorRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: false, collection: false, inspector: true) {
                return Self(sidebar: false, collection: false, inspector: true)
            }
            if fits(width: width, contentMinimum: mainMinimum, sidebar: sidebarRequested, collection: true, inspector: false) {
                return Self(sidebar: sidebarRequested, collection: true, inspector: false)
            }
            if sidebarRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: true, collection: false, inspector: false) {
                return Self(sidebar: true, collection: false, inspector: false)
            }
            if fits(width: width, contentMinimum: mainMinimum, sidebar: false, collection: true, inspector: false) {
                return Self(sidebar: false, collection: true, inspector: false)
            }
            return Self(sidebar: false, collection: false, inspector: false)
        case .sidebar:
            if sidebarRequested && inspectorRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: true, collection: false, inspector: true) {
                return Self(sidebar: true, collection: false, inspector: true)
            }
            if sidebarRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: true, collection: true, inspector: false) {
                return Self(sidebar: true, collection: true, inspector: false)
            }
            if sidebarRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: true, collection: false, inspector: false) {
                return Self(sidebar: true, collection: false, inspector: false)
            }
            if inspectorRequested && fits(width: width, contentMinimum: mainMinimum, sidebar: false, collection: false, inspector: true) {
                return Self(sidebar: false, collection: false, inspector: true)
            }
            if fits(width: width, contentMinimum: mainMinimum, sidebar: false, collection: true, inspector: false) {
                return Self(sidebar: false, collection: true, inspector: false)
            }
            return Self(sidebar: false, collection: false, inspector: false)
        }
    }

    @MainActor private static func fits(width: CGFloat, contentMinimum: CGFloat, sidebar: Bool, collection: Bool, inspector: Bool) -> Bool {
        let available = max(0, width - contentMinimum)
        var cost: CGFloat = 0
        if sidebar { cost += WorkspacePaneState.sidebarMinimum + 1 }
        if collection { cost += WorkspacePaneState.collectionMinimum + 1 }
        if inspector { cost += InspectorState.minWidth + 1 }
        return cost <= available
    }
}

/// One focused action path for the native toolbar and the View menu.
struct WorkspacePaneActions {
    let toggleSidebar: () -> Void
    let toggleCollection: () -> Void
    let toggleInspector: () -> Void
    let sidebarPresented: Bool
    let collectionPresented: Bool
    let inspectorPresented: Bool
    let canToggleSidebar: Bool
    let canToggleCollection: Bool
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
            let expectedCount = Self.arrangedCount(for: presentation)
            guard split.arrangedSubviews.count == expectedCount, split.bounds.width > mainMinimum,
                  lastPresentation != presentation || lastMainMinimum != mainMinimum else { return }
            lastPresentation = presentation
            lastMainMinimum = mainMinimum
            // SwiftUI owns an NSSplitViewController. AppKit prohibits setting holding
            // priorities directly on its split view; preserve the controller's layout policy.
            let divider = split.dividerThickness
            var positions: [(Int, CGFloat)] = []
            if presentation.sidebar {
                let collectionReserve = presentation.collection ? WorkspacePaneState.collectionMinimum + divider : 0
                let inspectorReserve = presentation.inspector ? InspectorState.minWidth + divider : 0
                let maximum = min(WorkspacePaneState.sidebarMaximum, split.bounds.width - mainMinimum - collectionReserve - inspectorReserve - divider)
                let position = min(state.sidebarWidth, max(WorkspacePaneState.sidebarMinimum, maximum))
                positions.append((0, position))
                split.setPosition(position, ofDividerAt: 0)
            }
            if presentation.collection {
                let sidebarSpan = presentation.sidebar ? split.arrangedSubviews[0].frame.width + divider : 0
                let inspectorReserve = presentation.inspector ? InspectorState.minWidth + divider : 0
                let maximum = min(WorkspacePaneState.collectionMaximum, split.bounds.width - sidebarSpan - mainMinimum - inspectorReserve - divider)
                let width = min(state.collectionWidth, max(WorkspacePaneState.collectionMinimum, maximum))
                let index = presentation.sidebar ? 1 : 0
                positions.append((index, sidebarSpan + width))
                split.setPosition(sidebarSpan + width, ofDividerAt: index)
            }
            if presentation.inspector {
                var leading: CGFloat = 0
                var index = 0
                if presentation.sidebar {
                    leading += split.arrangedSubviews[index].frame.width + divider
                    index += 1
                }
                if presentation.collection {
                    leading += split.arrangedSubviews[index].frame.width + divider
                }
                let maximum = min(InspectorState.maxWidth, split.bounds.width - mainMinimum - leading - divider)
                let width = min(state.inspectorWidth, max(InspectorState.minWidth, maximum))
                split.setPosition(split.bounds.width - width - divider, ofDividerAt: expectedCount - 2)
            }
            // A trailing divider can redistribute the preceding controller-owned panes.
            // Restore leading boundaries last, keeping the established trailing boundary.
            for (index, position) in positions.reversed() {
                split.setPosition(position, ofDividerAt: index)
            }
        }

        @objc private func dividerResized(_ notification: Notification) {
            guard let split = splitView, (notification.object as? NSSplitView) === split,
                  NSApp.currentEvent?.type == .leftMouseDragged,
                  split.arrangedSubviews.count == Self.arrangedCount(for: presentation) else { return }
            var index = 0
            let sidebar = presentation.sidebar ? split.arrangedSubviews[index].frame.width : nil
            if presentation.sidebar { index += 1 }
            let collection = presentation.collection ? split.arrangedSubviews[index].frame.width : nil
            if presentation.collection { index += 1 }
            index += 1
            let inspector = presentation.inspector && index < split.arrangedSubviews.count ? split.arrangedSubviews[index].frame.width : nil
            DispatchQueue.main.async { [weak self] in
                self?.state?.rememberWidths(sidebar: sidebar, collection: collection, inspector: inspector)
            }
        }

        private static func arrangedCount(for presentation: WorkspacePanePresentation) -> Int {
            1 + (presentation.sidebar ? 1 : 0) + (presentation.collection ? 1 : 0) + (presentation.inspector ? 1 : 0)
        }
    }
}

/// Sidebar highlight follows the collection. A recent row is selected only when the user chose it.
enum WorkspaceSidebarSelection: Hashable {
    case collection(LibraryScope)
    case recent(RecentItemID)

    static func resolve(scope: LibraryScope, explicitRecentItem: RecentItemID?) -> WorkspaceSidebarSelection? {
        if let explicitRecentItem { return .recent(explicitRecentItem) }
        switch scope {
        case .wiki, .tag: return .collection(.wiki)
        case .sources: return .collection(.sources)
        case .semantic: return .collection(.semantic)
        case .trash: return nil
        }
    }
}
