import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

@Suite("Sidebar typography, row geometry, and shared chrome")
@MainActor
struct SidebarChromeTests {
    @Test func organisationOutlineCollapseHidesDescendantsButKeepsSiblingOrder() {
        let collection = organisationContainer("Research", kind: .collection)
        let folder = organisationContainer("Reading", parent: collection.id)
        let nested = organisationContainer("Papers", parent: folder.id)
        let sibling = organisationContainer("Ideas", parent: collection.id)
        let rootFolder = organisationContainer("Personal")
        let containers = [collection, folder, nested, sibling, rootFolder]
        let expanded = NoemaOrganisationSidebarTree.rows(containers, collapsed: [])
        #expect(expanded.map(\.id) == containers.map(\.id))
        #expect(expanded.map(\.depth) == [0, 1, 2, 1, 0])
        let collapsedFolder = NoemaOrganisationSidebarTree.rows(containers, collapsed: [folder.id])
        #expect(collapsedFolder.map(\.id) == [collection.id, folder.id, sibling.id, rootFolder.id])
        let collapsedCollection = NoemaOrganisationSidebarTree.rows(containers, collapsed: [collection.id])
        #expect(collapsedCollection.map(\.id) == [collection.id, rootFolder.id])
    }

    @Test func organisationMoveMenuRejectsSelfDescendantsCurrentParentAndCorruptCycles() {
        let collection = organisationContainer("Collection", kind: .collection)
        let folder = organisationContainer("Folder", parent: collection.id)
        let child = organisationContainer("Child", parent: folder.id)
        let grandchild = organisationContainer("Grandchild", parent: child.id)
        let other = organisationContainer("Other", kind: .collection)
        let rootFolder = organisationContainer("Root folder")
        var cycleA = organisationContainer("Cycle A")
        let cycleB = organisationContainer("Cycle B", parent: cycleA.id)
        cycleA.parentID = cycleB.id
        let containers = [collection, folder, child, grandchild, other, rootFolder, cycleA, cycleB]
        #expect(NoemaOrganisationSidebarTree.destinations(for: folder, in: containers).map(\.id) == [other.id, rootFolder.id])
        #expect(NoemaOrganisationSidebarTree.destinations(for: collection, in: containers).isEmpty)
    }

    @Test func hostedOrganisationRowsRemainCompactWithLongTitlesAndExpansionStates() {
        for dark in [false, true] {
            for expanded in [false, true] {
                let row = NoemaOrganisationSidebarRow(
                    title: "A collection with a long title that must truncate within the sidebar",
                    symbol: "square.stack", depth: 2, isExpanded: expanded, isSelected: true,
                    onExpansionChange: { _ in }, onSelect: {}
                )
                .frame(width: WorkspacePaneState.sidebarIdeal)
                .environment(\.noemaTheme, NoemaTheme(dark: dark, increasedContrast: false))
                let hosting = NSHostingView(rootView: row)
                hosting.frame = NSRect(x: 0, y: 0, width: WorkspacePaneState.sidebarIdeal, height: NoemaMetrics.compactRowHeight)
                hosting.layoutSubtreeIfNeeded()
                #expect(hosting.fittingSize.width <= WorkspacePaneState.sidebarIdeal + 1)
                #expect(abs(hosting.fittingSize.height - NoemaMetrics.compactRowHeight) <= 1)
            }
        }
    }

    private func organisationContainer(_ name: String, kind: OrganisationContainerKind = .folder, parent: UUID? = nil) -> OrganisationContainer {
        OrganisationContainer(id: UUID(), kind: kind, name: name, parentID: parent,
            sortOrder: 0, revision: BlockStoreRevision(token: Data()),
            createdAt: .distantPast, modifiedAt: .distantPast)
    }

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
        #expect(NoemaTypography.navigation == .body)
        #expect(NoemaTypography.navigationEmphasis == .body.weight(.medium))
        #expect(NoemaTypography.sidebarSection == .subheadline.weight(.medium))
        #expect(NoemaTypography.sidebarIcon == .body)
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

    @Test func hostedWorkspaceMeasuresCompactToolbarAndSidebarAcrossSizesAppearancesAndScopes() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("noema-ui02-\(UUID().uuidString)", isDirectory: true)
        let vaultRoot = tempRoot.appendingPathComponent("Vault", isDirectory: true)
        try fm.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let defaultsSuiteName = "noema.tests.ui02.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let repository = try await openCanonicalAppFixture(root: vaultRoot, create: true)
        _ = try await repository.create(title: "Architecture Overview", body: "Initial body")

        let model = AppModel(aiDefaults: defaults)
        model.localStorageRoot = tempRoot
        model.persistSecurityScopedBookmark = false
        await model.open(vaultRoot, create: false)

        let paneDefaults = try #require(UserDefaults(suiteName: "\(defaultsSuiteName).panes"))
        defer { paneDefaults.removePersistentDomain(forName: "\(defaultsSuiteName).panes") }
        let paneState = WorkspacePaneState(defaults: paneDefaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toolbar = NSToolbar(identifier: "noema.test.workspace.toolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        WorkspaceWindowState.configureToolbarStyle(for: window)

        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let theme = NoemaTheme(dark: dark, increasedContrast: false)
            let controller = NSHostingController(
                rootView: ContentView(model: model, paneState: paneState)
                    .environment(\.noemaTheme, theme)
            )
            window.contentViewController = controller

            for size in [NSSize(width: 1280, height: 800), NSSize(width: 720, height: 540)] {
                window.setContentSize(size)
                for scope in [LibraryScope.wiki, .sources, .semantic] {
                    model.changeScope(scope)
                    window.contentView?.layoutSubtreeIfNeeded()

                    #expect(window.toolbarStyle == .unified)
                    #expect(window.titleVisibility == .visible)
                    #expect(model.windowTitle.isCollectionScope)
                    #expect(!model.windowTitle.hasSubtitle)

                    let chromeHeight = WorkspaceWindowState.titlebarChromeHeight(for: window)
                    #expect(chromeHeight <= 56)

                    let presentation = paneState.presentation(
                        width: size.width,
                        mainMinimum: scope == .sources ? 520 : 420,
                        inspectorAvailable: true
                    )
                    if size.width >= 1280 {
                        #expect(presentation.sidebar)
                    } else if scope == .sources {
                        #expect(size.width >= 520)
                    }
                }
            }
        }
    }
}
