import SwiftUI
import Observation
import VaultCore

/// Manages right inspector visibility, contextual tab selection, per-context tab memory, and state resets across vault session transitions.
@MainActor @Observable final class InspectorState {
    static let idealWidth: CGFloat = 340
    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 420

    private var localVisibility: Bool = false
    private let paneState: WorkspacePaneState?
    var isVisible: Bool {
        get { paneState?.isInspectorVisible ?? localVisibility }
        set {
            if let paneState { paneState.isInspectorVisible = newValue }
            else { localVisibility = newValue }
        }
    }
    private(set) var selectedPageTab: InspectorTab = .insights
    private(set) var selectedSourceTab: InspectorTab = .insights
    private(set) var collapsedSections: Set<String> = []
    let insightsCache = InsightsPresentationCache()
    let linksCache = LinksPresentationCache()

    init(
        isVisible: Bool = false,
        selectedPageTab: InspectorTab = .insights,
        selectedSourceTab: InspectorTab = .insights,
        paneState: WorkspacePaneState? = nil
    ) {
        self.paneState = paneState
        self.localVisibility = isVisible
        self.selectedPageTab = InspectorTab.pageTabs.contains(selectedPageTab) ? selectedPageTab : .insights
        self.selectedSourceTab = InspectorTab.sourceTabs.contains(selectedSourceTab) ? selectedSourceTab : .insights
    }

    /// Returns the active tab for the given inspector context, falling back to `.insights` if the stored tab is not applicable.
    func activeTab(for context: InspectorContext) -> InspectorTab {
        guard let kind = context.targetKind else { return .insights }
        return activeTab(for: kind)
    }

    /// Returns the active tab for a specific target kind, guaranteed to be in `InspectorTab.applicableTabs(for: kind)`.
    func activeTab(for kind: InspectorTargetKind) -> InspectorTab {
        let applicable = InspectorTab.applicableTabs(for: kind)
        let candidate: InspectorTab = switch kind {
        case .page: selectedPageTab
        case .source: selectedSourceTab
        }
        if applicable.contains(candidate) {
            return candidate
        }
        return applicable.first ?? .insights
    }

    /// Selects a tab for the current context if applicable.
    func selectTab(_ tab: InspectorTab, for context: InspectorContext) {
        guard let kind = context.targetKind else { return }
        selectTab(tab, for: kind)
    }

    /// Selects a tab for the given target kind if applicable. When a tab is shared across both page and source contexts
    /// (such as References, Properties, or Insights), both contexts remember the user's choice so navigating between
    /// pages and sources preserves an applicable tab selection.
    func selectTab(_ tab: InspectorTab, for kind: InspectorTargetKind) {
        let applicable = InspectorTab.applicableTabs(for: kind)
        guard applicable.contains(tab) else { return }
        switch kind {
        case .page:
            selectedPageTab = tab
            if InspectorTab.sourceTabs.contains(tab) {
                selectedSourceTab = tab
            }
        case .source:
            selectedSourceTab = tab
            if InspectorTab.pageTabs.contains(tab) {
                selectedPageTab = tab
            }
        }
    }

    /// Moves selection to the next or previous applicable tab for keyboard navigation.
    func stepTab(by delta: Int, for context: InspectorContext) {
        let tabs = context.applicableTabs
        guard !tabs.isEmpty else { return }
        let current = activeTab(for: context)
        let index = tabs.firstIndex(of: current) ?? 0
        let nextIndex = (index + delta % tabs.count + tabs.count) % tabs.count
        selectTab(tabs[nextIndex], for: context)
    }

    func toggleVisibility() {
        isVisible.toggle()
    }

    /// Determines whether the inspector pane should be mounted for the resolved context.
    func shouldPresent(for context: InspectorContext) -> Bool {
        isVisible && context.isInspectable
    }

    /// Reconciles cached presentation state when the inspected target changes.
    func reconcile(with context: InspectorContext) {
        if case .page(let note) = context {
            insightsCache.reconcileTarget(id: note.id)
            linksCache.reconcileTarget(id: note.id)
        } else {
            insightsCache.invalidate()
            linksCache.invalidate()
        }
    }

    /// Returns whether a disclosure section with the given identifier is currently expanded in this session.
    func isSectionExpanded(_ id: String) -> Bool {
        !collapsedSections.contains(id)
    }

    /// Updates the session-scoped expansion preference for a disclosure section.
    func setSectionExpanded(_ expanded: Bool, for id: String) {
        if expanded {
            collapsedSections.remove(id)
        } else {
            collapsedSections.insert(id)
        }
    }

    /// Returns a two-way binding for a disclosure section's expansion state in the current session.
    func sectionExpansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.isSectionExpanded(id) },
            set: { self.setSectionExpanded($0, for: id) }
        )
    }

    /// Resets transient selection state when a vault is locked, closed, or switched.
    func resetForSessionChange() {
        selectedPageTab = .insights
        selectedSourceTab = .insights
        collapsedSections.removeAll()
        insightsCache.invalidate()
        linksCache.invalidate()
    }
}
