import AppKit
import SwiftUI
import Testing
@testable import noema

@Suite("Sidebar typography, row geometry, and shared chrome")
@MainActor
struct SidebarChromeTests {
    @Test func sidebarMetricsMatchRefinedMacOSSpecification() {
        #expect((28.0...30.0).contains(NoemaMetrics.compactRowHeight))
        #expect((28.0...30.0).contains(NoemaMetrics.comfortableRowHeight))
        #expect((14.0...15.0).contains(NoemaMetrics.sidebarIconSize))
        #expect((7.0...8.0).contains(NoemaMetrics.sidebarIconSpacing))
        #expect((8.0...10.0).contains(NoemaMetrics.sidebarInset))
        #expect((2.0...4.0).contains(NoemaMetrics.sidebarRowHorizontalInset))
        #expect((10.0...14.0).contains(NoemaMetrics.sidebarSectionSpacing))
        #expect(NoemaMetrics.iconWidth == 16)
        #expect((210.0...230.0).contains(WorkspacePaneState.sidebarIdeal))
    }

    @Test func sidebarLayoutInsetsTightenHorizontalRowPadding() {
        // Legacy row insets added 6pt leading/trailing on top of List(.sidebar) native margins.
        #expect(NoemaSidebarLayout.rowInsets.leading < 6)
        #expect(NoemaSidebarLayout.rowInsets.trailing < 6)
        #expect(NoemaSidebarLayout.rowInsets.leading == NoemaMetrics.sidebarRowHorizontalInset)
        #expect(NoemaSidebarLayout.rowInsets.trailing == NoemaMetrics.sidebarRowHorizontalInset)
        #expect(NoemaSidebarLayout.sectionHeaderInsets.leading == NoemaMetrics.sidebarRowHorizontalInset)
        #expect(NoemaSidebarLayout.footerHorizontalPadding == NoemaMetrics.sidebarInset)
        #expect(NoemaSidebarLayout.footerRowHorizontalPadding == NoemaMetrics.sidebarRowHorizontalInset + 3)
    }

    @Test func sidebarTypographyUsesExpectedStylesAndWeights() {
        #expect(NoemaTypography.navigation == .callout)
        #expect(NoemaTypography.navigationEmphasis == .callout.weight(.medium))
        #expect(NoemaTypography.sidebarSection == .subheadline.weight(.medium))
        #expect(NoemaTypography.sidebarIcon == .system(size: 14, weight: .regular))
    }

    @Test func hostedSidebarPrimitivesFitWithinDefaultSidebarWidth() {
        let stack = VStack(alignment: .leading, spacing: 2) {
            NoemaSidebarRowLabel(title: "Pages", symbol: "book.closed", isSelected: true)
            NoemaSidebarRowLabel(title: "Sources", symbol: "tray.full", isSelected: false)
            NoemaSidebarRowLabel(title: "Semantic Blocks", symbol: "tag", isSelected: false)
            NoemaSidebarSectionHeader(title: "RECENT ITEMS")
            NoemaSidebarRowLabel(title: "Architecture & Storage Notes", symbol: "doc.text", isSelected: false)
            NoemaSidebarVaultSelectorLabel(vaultName: "Personal Knowledge Vault")
        }
        .frame(width: WorkspacePaneState.sidebarIdeal)
        .environment(\.noemaTheme, NoemaTheme(dark: false, increasedContrast: false))

        let hosting = NSHostingView(rootView: stack)
        hosting.frame = NSRect(x: 0, y: 0, width: WorkspacePaneState.sidebarIdeal, height: 260)
        hosting.layoutSubtreeIfNeeded()

        let fitting = hosting.fittingSize
        #expect(fitting.width <= WorkspacePaneState.sidebarIdeal + 1)
        #expect(fitting.height >= NoemaMetrics.compactRowHeight * 5)
    }
}
