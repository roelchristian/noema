import AppKit
import Foundation
import Testing
@testable import noema

@Suite("Workspace pane preferences and geometry") @MainActor
struct WorkspacePaneStateTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "WorkspacePaneStateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func visibilityRestoresIndependentlyAndSurvivesInspectorSessionReset() {
        withDefaults { defaults in
            let state = WorkspacePaneState(defaults: defaults)
            #expect(state.isSidebarVisible && state.isInspectorVisible)
            state.toggleSidebar(presented: true)
            let inspector = InspectorState(paneState: state)
            inspector.toggleVisibility()
            inspector.resetForSessionChange()
            let restored = WorkspacePaneState(defaults: defaults)
            #expect(!restored.isSidebarVisible && !restored.isInspectorVisible)
            restored.revealSidebar()
            #expect(restored.isSidebarVisible && !restored.isInspectorVisible)
        }
    }

    @Test func adaptiveCollapseRetainsIntentAndSourcesCanvasAtMinimumWindowWidth() {
        withDefaults { defaults in
            let state = WorkspacePaneState(defaults: defaults)
            let small = state.presentation(width: 720, mainMinimum: 520, inspectorAvailable: true)
            #expect(small == WorkspacePanePresentation(sidebar: true, inspector: false))
            let tiny = state.presentation(width: 600, mainMinimum: 520, inspectorAvailable: true)
            #expect(tiny == WorkspacePanePresentation(sidebar: false, inspector: false))
            #expect(state.isSidebarVisible && state.isInspectorVisible)
            #expect(defaults.object(forKey: WorkspacePaneState.sidebarVisibilityKey) == nil)
            #expect(defaults.object(forKey: WorkspacePaneState.inspectorVisibilityKey) == nil)
            let restored = state.presentation(width: 1280, mainMinimum: 520, inspectorAvailable: true)
            #expect(restored == WorkspacePanePresentation(sidebar: true, inspector: true))
        }
    }

    @Test func explicitPaneRequestsTakePriorityAndSearchRevealsSidebar() {
        withDefaults { defaults in
            let state = WorkspacePaneState(defaults: defaults)
            state.toggleInspector(presented: false)
            #expect(state.presentation(width: 820, mainMinimum: 520, inspectorAvailable: true) == WorkspacePanePresentation(sidebar: false, inspector: true))
            state.revealSidebar()
            #expect(state.presentation(width: 820, mainMinimum: 520, inspectorAvailable: true) == WorkspacePanePresentation(sidebar: true, inspector: false))
            #expect(state.isSidebarVisible && state.isInspectorVisible)
            state.toggleSidebar(presented: true)
            #expect(state.presentation(width: 820, mainMinimum: 520, inspectorAvailable: true) == WorkspacePanePresentation(sidebar: false, inspector: true))
            #expect(state.presentation(width: 1280, mainMinimum: 420, inspectorAvailable: false) == WorkspacePanePresentation(sidebar: false, inspector: false))
            #expect(state.isInspectorVisible)
        }
    }

    @Test func documentAndSourcePaneThresholdsReserveNativeDividers() {
        for mainMinimum: CGFloat in [420, 520] {
            let bothThreshold = mainMinimum + WorkspacePaneState.sidebarMinimum + InspectorState.minWidth + 2
            let below = WorkspacePanePresentation.resolve(width: bothThreshold - 1, mainMinimum: mainMinimum, sidebarRequested: true, inspectorRequested: true, priority: .sidebar)
            #expect(below.sidebar && !below.inspector)
            let enough = WorkspacePanePresentation.resolve(width: bothThreshold, mainMinimum: mainMinimum, sidebarRequested: true, inspectorRequested: true, priority: .sidebar)
            #expect(enough.sidebar && enough.inspector)
        }
    }

    @Test func widthsRestoreClampAndRejectInvalidMeasurements() {
        withDefaults { defaults in
            defaults.set(Double.nan, forKey: WorkspacePaneState.sidebarWidthKey)
            defaults.set(900.0, forKey: WorkspacePaneState.inspectorWidthKey)
            let state = WorkspacePaneState(defaults: defaults)
            #expect(state.sidebarWidth == WorkspacePaneState.sidebarIdeal)
            #expect(state.inspectorWidth == InspectorState.maxWidth)
            state.rememberWidths(sidebar: 290, inspector: 360)
            state.rememberWidths(sidebar: 0, inspector: .infinity)
            let restored = WorkspacePaneState(defaults: defaults)
            #expect(restored.sidebarWidth == 290)
            #expect(restored.inspectorWidth == 360)
        }
    }
}
