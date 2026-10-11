import SwiftUI
import AppKit
import VaultCore

struct ContentView: View {
    enum PageSortOrder: String, CaseIterable, Identifiable {
        case updated = "Recently Updated"
        case title = "Title"
        var id: String { rawValue }
    }
    @Bindable var model: AppModel
    @Environment(\.noemaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var activeWindow
    @FocusState private var searchFocused: Bool
    @State private var searchFocusPending = false
    @State private var sidebarSearchMounted = false
    @FocusState private var sidebarTabFocused: String?
    @FocusState private var sidebarPageFocused: UUID?
    @FocusState private var sidebarItemFocused: String?
    @FocusState private var sidebarFooterFocused: String?
    @State private var showTrashConfirmation = false
    @State private var hoveredSidebarPageID: UUID?
    @State private var trashPageID: UUID?
    @State private var permanentDeletion: TrashedItem?
    @State private var showPermanentDeletion = false
    @State private var showEmptyTrash = false
    @State private var emptyTrashPages: [TrashedItem] = []
    @State private var dismissedExternalChange = false
    @State private var sourceOriginal = false
    @State private var inspectorState: InspectorState
    @State private var paneState: WorkspacePaneState
    @State private var workspaceWidth: CGFloat = 1280
    @State private var recentSectionExpanded = true
    @State private var allPagesSectionExpanded = true
    @State private var pageSortOrder: PageSortOrder = .updated
    private var sourceSelection: UUID? { model.librarySourceSelection }
    private var sourceSelectionBinding: Binding<UUID?> {
        Binding(get: { model.librarySourceSelection }, set: { model.setLibrarySourceSelection($0) })
    }
    @State private var sourceTablePresentation = SourcesTablePresentation()
    @State private var renamingSource: SourceRecord?
    @State private var sourceName = ""
    @State private var deletingSource: SourceRecord?
    @AppStorage(EditorPreferences.aiSummaryPlacementKey) private var aiSummaryPlacement = AISummaryPlacement.defaultValue.rawValue
    init(model: AppModel, paneState: WorkspacePaneState? = nil) {
        self.model = model
        let panes = paneState ?? WorkspacePaneState()
        _paneState = State(initialValue: panes)
        _inspectorState = State(initialValue: InspectorState(paneState: panes))
    }
    private var workspaceMinimum: CGFloat {
        model.scope == .sources && model.currentNote == nil && model.currentSource == nil ? 520 : 420
    }
    private var panePresentation: WorkspacePanePresentation {
        paneState.presentation(width: workspaceWidth, mainMinimum: workspaceMinimum, inspectorAvailable: inspectorContext.isInspectable)
    }
    private var isInspectorPresented: Bool { model.isVaultAvailable && panePresentation.inspector }
    private var paneActions: WorkspacePaneActions {
        WorkspacePaneActions(
            toggleSidebar: toggleSidebarPane,
            toggleInspector: toggleInspectorPane,
            sidebarPresented: model.isVaultAvailable && panePresentation.sidebar,
            inspectorPresented: isInspectorPresented,
            canToggleSidebar: model.isVaultAvailable && workspaceWidth >= workspaceMinimum + WorkspacePaneState.sidebarMinimum + 1,
            canToggleInspector: model.isVaultAvailable && inspectorContext.isInspectable && workspaceWidth >= workspaceMinimum + InspectorState.minWidth + 1
        )
    }
    private func toggleSidebarPane() {
        guard paneActions.canToggleSidebar else { return }
        paneState.toggleSidebar(presented: panePresentation.sidebar)
        if !paneState.isSidebarVisible { searchFocused = false; searchFocusPending = false }
    }
    private func toggleInspectorPane() {
        guard paneActions.canToggleInspector else { return }
        paneState.toggleInspector(presented: isInspectorPresented)
    }
    private func revealSidebarSearch() {
        guard model.isVaultAvailable else { return }
        searchFocusPending = true
        paneState.revealSidebar()
        // Wait for SwiftUI to mount a previously hidden sidebar before requesting focus.
        Task { @MainActor in
            await Task.yield()
            guard model.isVaultAvailable && panePresentation.sidebar && sidebarSearchMounted else { return }
            searchFocused = true
            searchFocusPending = false
        }
    }
    private var inspectorContext: InspectorContext {
        InspectorContext.resolve(model: model, librarySourceSelection: sourceSelection)
    }
    private var tabAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84, blendDuration: 0.1)
    }
    private func switchSidebarScope(_ scope: LibraryScope) {
        // Tab chrome animates via `.animation(_, value: activeSidebarTab)`; wrapping the whole scope
        // change in withAnimation also animated the heavy Table/workspace and made switches jitter.
        SourcesPerformance.event("SidebarScopeChange")
        model.changeScope(scope)
    }
    private func resetLocalWorkspaceState() {
        model.setLibrarySourceSelection(nil)
        sourceTablePresentation.clear()
        inspectorState.resetForSessionChange()
        renamingSource = nil
        sourceName = ""
        deletingSource = nil
        showPermanentDeletion = false
        permanentDeletion = nil
        showEmptyTrash = false
        emptyTrashPages = []
        showTrashConfirmation = false
        trashPageID = nil
        hoveredSidebarPageID = nil
        dismissedExternalChange = false
        sourceOriginal = false
        searchFocused = false
        searchFocusPending = false
    }
    private var workspacePresentation: some View {
        Group {
            if model.isLocked {
                lockedVaultView
            } else if !model.isVaultAvailable {
                welcome
            } else {
                GeometryReader { geometry in
                    let presentation = paneState.presentation(width: geometry.size.width, mainMinimum: workspaceMinimum, inspectorAvailable: inspectorContext.isInspectable)
                    HSplitView {
                        if presentation.sidebar {
                            sidebar.frame(minWidth: WorkspacePaneState.sidebarMinimum, idealWidth: paneState.sidebarWidth, maxWidth: WorkspacePaneState.sidebarMaximum, maxHeight: .infinity)
                        }
                        mainWorkspace
                            .frame(minWidth: workspaceMinimum, maxHeight: .infinity)
                            .transaction { $0.animation = nil }
                            .background(WorkspaceSplitViewPersistence(state: paneState, presentation: presentation, mainMinimum: workspaceMinimum))
                        if presentation.inspector {
                            InspectorContainer(
                                model: model,
                                state: inspectorState,
                                context: inspectorContext,
                                onCloseSourceSelection: { model.setLibrarySourceSelection(nil) }
                            )
                            .transaction { $0.animation = nil }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .transaction { $0.animation = nil }
                }
                // Measure the available container, not the split's aggregate pane minimum.
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { workspaceWidth = $0 }
            }
        }
    }
    private var titledWorkspace: some View {
        workspacePresentation
        .navigationTitle(model.windowTitle.title)
        .navigationSubtitle(model.windowTitle.subtitle)
        .focusedSceneValue(\.workspacePaneActions, paneActions)
        .toolbar(removing: .sidebarToggle)
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { AISummaryProviderNotice(model: model) }
    }
    private var workspaceSheets: some View {
        titledWorkspace
        .sheet(item: $model.cloudSummaryConfirmation, onDismiss: {
            if model.cloudSummaryTarget == nil { model.cloudSummaryConfirmation = nil }
        }) { confirmation in
            CloudSummaryConsentSheet(model: model, confirmation: confirmation)
        }
        .sheet(item: $model.pendingAISuggestion, onDismiss: { model.didDismissAISuggestionReview() }) { suggestion in
            AISuggestionReviewSheet(model: model, suggestion: suggestion)
        }
        .alert("OpenAI Request", isPresented: Binding(get: { model.cloudSummaryError != nil }, set: { if !$0 { model.cloudSummaryError = nil } })) {
            Button("OK") { model.cloudSummaryError = nil }
        } message: { Text(model.cloudSummaryError ?? "") }
        .sheet(isPresented: $model.showVaultCreation) {
            VaultCreationSheet(model: model).systemNoemaTheme()
        }
        .sheet(isPresented: Binding(get: { model.isVaultAvailable && model.showTopicPage }, set: { model.showTopicPage = $0 })) { TopicPageSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.isVaultAvailable && model.showURLSource }, set: { model.showURLSource = $0 })) { URLSourceSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.isVaultAvailable && model.showPasteSource }, set: { model.showPasteSource = $0 })) { PasteSourceSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.isVaultAvailable && model.showRecovery }, set: { model.showRecovery = $0 })) { recoverySheet }
        .sheet(isPresented: Binding(get: { model.isVaultAvailable && model.showIssues }, set: { model.showIssues = $0 })) { noticesSheet }
        .sheet(isPresented: Binding(get: { model.isVaultAvailable && !model.ambiguousMatches.isEmpty }, set: { if !$0 { model.ambiguousMatches = [] } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose a page").font(.title2.bold())
                Text("More than one page matches this title or alias.").foregroundStyle(theme.text())
                ForEach(model.ambiguousMatches) { note in
                    Button { model.ambiguousMatches = []; model.select(note.id) } label: { VStack(alignment: .leading) { Text(note.title); Text(note.relativePath).font(.caption).foregroundStyle(theme.text()) } }
                }
                Button("Cancel") { model.ambiguousMatches = [] }.keyboardShortcut(.cancelAction)
            }.padding(28).frame(width: 440)
        }
    }
    private var workspaceConfirmations: some View {
        workspaceSheets
        .alert("Create this page?", isPresented: Binding(get: { model.isVaultAvailable && model.unresolvedTarget != nil }, set: { if !$0 { model.unresolvedTarget = nil } })) {
            Button("Create") { if let name = model.unresolvedTarget { model.newPage(named: name) }; model.unresolvedTarget = nil }
            Button("Cancel", role: .cancel) { model.unresolvedTarget = nil }
        } message: { Text("‘\(model.unresolvedTarget ?? "")’ does not exist yet.") }
        .confirmationDialog("Move this page to vault trash?", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) { model.trashPage(trashPageID) }
        } message: { Text("The Markdown file stays recoverable in the vault’s Removed Pages folder for 15 days, unless you restore or permanently delete it sooner.") }
        .alert("Rename Source", isPresented: Binding(get: { model.isVaultAvailable && renamingSource != nil }, set: { if !$0 { renamingSource = nil } })) {
            TextField("File Name", text: $sourceName)
            Button("Rename") {
                if let source = renamingSource { model.renameSource(source, title: sourceName) }
                renamingSource = nil
            }.disabled(sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingSource = nil }
        } message: { Text("Changes the source name stored in the vault. The original file name and file stay unchanged.") }
        .alert("Delete Source?", isPresented: Binding(get: { model.isVaultAvailable && deletingSource != nil }, set: { if !$0 { deletingSource = nil } })) {
            Button("Delete", role: .destructive) {
                if let source = deletingSource { model.deleteSource(source) }
                deletingSource = nil
            }
            Button("Cancel", role: .cancel) { deletingSource = nil }
        } message: {
            Text(deletingSource?.metadata.isLinked == true
                 ? "Move ‘\(deletingSource?.title ?? "")’ to Trash for 15 days? Its linked original will remain on your filesystem."
                 : "Move ‘\(deletingSource?.title ?? "")’ and its imported original to Trash? Restore them within 15 days.")
        }
    }
    var body: some View {
        workspaceConfirmations
        .onChange(of: model.searchText) {
            if searchFocused && !model.searchText.isEmpty && (model.currentNote != nil || model.currentSource != nil) {
                model.changeScope(model.scope)
            } else {
                model.queryChanged()
            }
        }
        .onChange(of: model.body) { if model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.title) { if model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.searchFocusToken) { revealSidebarSearch() }
        .onChange(of: panePresentation.sidebar) { if !panePresentation.sidebar { searchFocused = false } }
        .onChange(of: model.selectedID) { sourceOriginal = false; dismissedExternalChange = false }
        .onChange(of: model.externalChange) { dismissedExternalChange = false }
        // UI.R.REM02: Reconcile even while the inspector is hidden or unmounted.
        .onChange(of: inspectorContext.targetID, initial: true) {
            inspectorState.reconcile(with: inspectorContext)
        }
        .onChange(of: inspectorContext.targetKind) {
            inspectorState.reconcile(with: inspectorContext)
        }
        .onChange(of: model.root) { resetLocalWorkspaceState() }
        .onChange(of: model.sessionState) {
            if !model.isVaultAvailable {
                resetLocalWorkspaceState()
            }
        }
    }
    @ViewBuilder private var mainWorkspace: some View {
        if model.currentNote != nil || model.currentSource != nil {
            detail
        } else {
            library
        }
    }
    private var lockedVaultView: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(theme.text(for: .textSecondary, on: .window))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(model.vaultName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(theme.text(for: .textPrimary, on: .window))
                Text("This vault session is locked. Unlock to view or edit its pages and sources.")
                    .font(.callout)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .window))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            GlassEffectContainer(spacing: NoemaSpacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NoemaSpacing.lg) { lockedVaultActions }
                    VStack(spacing: NoemaSpacing.md) { lockedVaultActions }
                }
                .controlSize(.large)
            }
            if model.busy { NoemaLoadingStatus("Unlocking vault…") }
            if let error = model.errorMessage {
                DismissibleNotice(message: error) {
                    model.errorMessage = nil
                    model.needsPermissionReauthorization = false
                }
                .frame(maxWidth: 560)
            }
        }
        .padding(NoemaSpacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color(for: .window))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Locked vault: \(model.vaultName)")
    }
    @ViewBuilder private var lockedVaultActions: some View {
        workspaceCommandButton("Unlock Vault", .unlock).buttonStyle(.glassProminent)
        if model.needsPermissionReauthorization {
            workspaceCommandButton("Reselect Vault Folder…", .openVault).buttonStyle(.glass).tint(nil)
        }
        workspaceCommandButton("Open Another Vault…", .openVault).buttonStyle(.glass).tint(nil)
        workspaceCommandButton("Close Vault", .close).buttonStyle(.glass).tint(nil)
    }
    private func workspaceCommandButton(_ title: String, _ command: WorkspaceCommand) -> some View {
        Button(title) { model.performWorkspaceCommand(command) }
            .disabled(!model.canPerformWorkspaceCommand(command))
    }
    private var welcome: some View {
        VStack(spacing: 24) {
            NoemaMark(presentation: .identity).frame(width: 116, height: 116).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Noema").font(.system(size: 38, weight: .medium))
                    .foregroundStyle(theme.text(for: .textPrimary, on: .window))
                Text("A personal atlas of thought.")
                    .font(.title3).foregroundStyle(theme.text(for: .textSecondary, on: .window))
            }
            GlassEffectContainer(spacing: NoemaSpacing.sm) {
                HStack(spacing: NoemaSpacing.lg) {
                    workspaceCommandButton("Create a vault…", .createVault).buttonStyle(.glassProminent)
                    workspaceCommandButton(model.needsPermissionReauthorization ? "Reselect Vault Folder…" : "Open a vault…", .openVault).buttonStyle(.glass).tint(nil)
                }.controlSize(.large)
            }
            Text("Choose a folder on your Mac or in iCloud Drive. Your files stay yours.")
                .font(.callout).foregroundStyle(theme.text(for: .textSecondary, on: .window))
            if model.busy { NoemaLoadingStatus("Opening vault…") }
            if let error = model.errorMessage {
                DismissibleNotice(message: error) {
                    model.errorMessage = nil
                    model.needsPermissionReauthorization = false
                }
                .frame(maxWidth: 560)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var isPagesScope: Bool {
        if case .wiki = model.scope { return true }
        if case .tag = model.scope { return true }
        return false
    }
    private var activeSidebarTab: LibraryScope {
        switch model.scope {
        case .sources: return .sources
        case .semantic: return .semantic
        case .trash: return .trash
        case .wiki, .tag: return .wiki
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                HStack(spacing: NoemaSpacing.sm) {
                    NoemaMark(presentation: .glyph).frame(width: 20, height: 20).accessibilityHidden(true)
                    Text("Noema").font(NoemaTypography.navigationEmphasis).foregroundStyle(theme.text(for: .textPrimary, on: .sidebar))
                    Spacer()
                }
                HStack(spacing: NoemaSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(NoemaTypography.navigation)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                    ZStack(alignment: .leading) {
                        TextField("", text: $model.searchText)
                            .accessibilityLabel("Search")
                            .textFieldStyle(.plain)
                            .font(NoemaTypography.interface)
                            .foregroundStyle(theme.text(for: .textPrimary, on: .elevated))
                            .focused($searchFocused)
                            .onAppear {
                                sidebarSearchMounted = true
                                if searchFocusPending { revealSidebarSearch() }
                            }
                            .onDisappear { sidebarSearchMounted = false }
                        if model.searchText.isEmpty {
                            Text("Search")
                                .font(NoemaTypography.interface)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Label("Clear search", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(NoemaTypography.caption)
                                .noemaChromeForeground(.textSecondary)
                                .frame(minWidth: NoemaMetrics.toolbarControlHeight,
                                       minHeight: NoemaMetrics.toolbarControlHeight)
                        }.buttonStyle(NoemaChromeButtonStyle(surface: .elevated))
                            .help("Clear search")
                    } else {
                        Text("⇧⌘F")
                            .font(NoemaTypography.caption)
                            .foregroundStyle(theme.text(for: .textTertiary, on: .elevated))
                    }
                }
                .padding(.horizontal, NoemaSpacing.sm)
                .frame(minHeight: NoemaMetrics.searchHeight)
                .background(
                    RoundedRectangle(cornerRadius: NoemaMetrics.radiusStandard, style: .continuous)
                        .fill(theme.color(for: .elevated))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: NoemaMetrics.radiusStandard, style: .continuous)
                        .strokeBorder(theme.color(for: .separator), lineWidth: NoemaMetrics.borderWidth)
                )
                .noemaFocusRing(searchFocused, radius: NoemaMetrics.radiusStandard)
                if !model.isSearching {
                    HStack(spacing: NoemaSpacing.xs) {
                        sidebarTabButton(
                            title: "Pages",
                            symbol: "book.closed",
                            count: model.notes.count,
                            showLabel: activeSidebarTab == .wiki
                        ) {
                            switchSidebarScope(.wiki)
                        }
                        sidebarTabButton(
                            title: "Sources",
                            symbol: "tray.full",
                            count: model.sources.count,
                            showLabel: activeSidebarTab == .sources
                        ) {
                            switchSidebarScope(.sources)
                        }
                        sidebarTabButton(
                            title: "Semantic Blocks",
                            symbol: "tag",
                            count: nil,
                            showLabel: activeSidebarTab == .semantic
                        ) {
                            switchSidebarScope(.semantic)
                        }
                    }
                    .padding(NoemaMetrics.controlGroupInset)
                    .background(
                        RoundedRectangle(cornerRadius: NoemaMetrics.radiusStandard, style: .continuous)
                            .fill(theme.color(for: .elevated))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: NoemaMetrics.radiusStandard, style: .continuous)
                            .strokeBorder(theme.color(for: .separator), lineWidth: NoemaMetrics.borderWidth)
                    )
                    .animation(tabAnimation, value: activeSidebarTab)
                }
            }
            .padding(.horizontal, NoemaMetrics.sidebarInset)
            .padding(.top, NoemaSpacing.md)
            .padding(.bottom, NoemaSpacing.sm)

            List {
                if model.isSearching {
                    searchResultSections
                } else if model.scope == .trash {
                    Section("TRASH") {
                        Label(model.trashedPages.count == 1 ? "1 deleted item" : "\(model.trashedPages.count) deleted items", systemImage: "trash")
                        Text("Deleted pages and sources stay recoverable for 15 days.")
                            .font(NoemaTypography.metadata)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Section(isExpanded: $recentSectionExpanded) {
                        if activeSidebarTab == .sources {
                            ForEach(model.recentSources) { source in
                                sidebarItemRow(
                                    title: source.title,
                                    symbol: source.metadata.isLinked ? "link" : "doc.text",
                                    active: sourceSelection == source.id || model.currentSource?.id == source.id
                                ) {
                                    model.setLibrarySourceSelection(source.id)
                                    if model.currentNote != nil || model.currentSource != nil || model.scope != .sources {
                                        switchSidebarScope(.sources)
                                    }
                                }
                            }
                            sidebarFooterLink("View all sources") {
                                model.setLibrarySourceSelection(nil)
                                switchSidebarScope(.sources)
                            }
                        } else if activeSidebarTab == .semantic {
                            ForEach(model.semanticRows.prefix(10)) { hit in
                                let presentation = SemanticPresentation.find(hit.semantic)
                                sidebarItemRow(
                                    title: hit.preview.isEmpty ? hit.pageTitle : hit.preview,
                                    symbol: presentation?.symbol ?? "tag",
                                    active: model.selectedSemanticID == hit.id
                                ) {
                                    model.select(hit.pageID, block: hit.blockID)
                                }
                            }
                            sidebarFooterLink("View all blocks") {
                                switchSidebarScope(.semantic)
                            }
                        } else {
                            ForEach(model.recentPages) { note in
                                sidebarPageRow(note)
                            }
                        }
                    } header: {
                        Text(activeSidebarTab == .sources ? "RECENT SOURCES" : activeSidebarTab == .semantic ? "RECENT BLOCKS" : "RECENT PAGES")
                            .font(NoemaTypography.sidebarSection)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                            .contentTransition(.opacity)
                    }
                    if activeSidebarTab == .wiki {
                        Section(isExpanded: $allPagesSectionExpanded) {
                            ForEach(model.allPagesByUpdated) { note in
                                sidebarPageRow(note, showRelativeEditTime: true)
                            }
                        } header: {
                            Text("ALL PAGES")
                                .font(NoemaTypography.sidebarSection)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                Divider().overlay(theme.color(for: .separator))
                Menu {
                    Button { model.performWorkspaceCommand(.revealVault) } label: {
                        Label("Open Vault in Finder", systemImage: "folder")
                    }.disabled(!model.canPerformWorkspaceCommand(.revealVault))
                    Button { model.performWorkspaceCommand(.refresh) } label: {
                        Label("Refresh from Files", systemImage: "arrow.clockwise")
                    }.disabled(!model.canPerformWorkspaceCommand(.refresh))
                    Button { model.performWorkspaceCommand(.showTrash) } label: {
                        Label(model.trashedPages.isEmpty ? "Trash" : "Trash (\(model.trashedPages.count.formatted()))", systemImage: "trash")
                    }.disabled(!model.canPerformWorkspaceCommand(.showTrash))
                    if model.hasRecoveryEntries {
                        Button { model.performWorkspaceCommand(.recovery) } label: {
                            Label("\(model.recoveredDrafts.count) recoverable draft(s)" + (model.damagedRecoveryEntries.isEmpty ? "" : " · \(model.damagedRecoveryEntries.count) damaged"), systemImage: "clock.arrow.circlepath")
                        }.disabled(!model.canPerformWorkspaceCommand(.recovery))
                    }
                    if !model.issues.isEmpty {
                        Button { model.performWorkspaceCommand(.notices) } label: {
                            Label("\(model.issues.count) vault notice(s)", systemImage: "info.circle")
                        }.disabled(!model.canPerformWorkspaceCommand(.notices))
                    }
                    Divider()
                    Button { model.performWorkspaceCommand(.lock) } label: {
                        Label("Lock Vault", systemImage: "lock")
                    }.disabled(!model.canPerformWorkspaceCommand(.lock))
                    Button { model.performWorkspaceCommand(.close) } label: {
                        Label("Close Vault", systemImage: "xmark.circle")
                    }.disabled(!model.canPerformWorkspaceCommand(.close))
                    Divider()
                    Button { model.performWorkspaceCommand(.openVault) } label: {
                        Label("Open Vault…", systemImage: "folder")
                    }.disabled(!model.canPerformWorkspaceCommand(.openVault))
                    Button { model.performWorkspaceCommand(.createVault) } label: {
                        Label("Create Vault…", systemImage: "folder.badge.plus")
                    }.disabled(!model.canPerformWorkspaceCommand(.createVault))
                } label: {
                    HStack(spacing: NoemaSpacing.sm) {
                        Image(systemName: "folder")
                            .font(NoemaTypography.navigation)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                            .frame(width: NoemaMetrics.iconWidth)
                        Text(model.vaultName)
                            .font(NoemaTypography.navigationEmphasis)
                            .foregroundStyle(theme.text(for: .textPrimary, on: .sidebar))
                            .lineLimit(1)
                        Spacer(minLength: NoemaSpacing.sm)
                        Image(systemName: "chevron.down")
                            .font(NoemaTypography.caption)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                    }
                    .padding(.horizontal, NoemaSpacing.sm)
                    .padding(.vertical, NoemaSpacing.sm)
                    .frame(maxWidth: .infinity, minHeight: NoemaMetrics.comfortableRowHeight)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Vault options")
                .accessibilityLabel("Vault menu. Current vault: \(model.vaultName)")
            }
            .padding(.horizontal, NoemaMetrics.sidebarInset)
            .padding(.top, NoemaSpacing.sm)
            .padding(.bottom, 10)
        }
        .background {
            if theme.usesFullPalette { theme.color(for: .sidebar).ignoresSafeArea() }
            else { SidebarMaterialView().ignoresSafeArea() }
        }
    }
    @ViewBuilder private var searchResultSections: some View {
        if model.sidebarSearchResults.query != model.searchText {
            if let error = model.errorMessage {
                DismissibleNotice(message: error, surface: .sidebar) { model.errorMessage = nil }
            } else {
                ProgressView("Searching…")
            }
        } else if model.sidebarSearchResults.isEmpty {
            Text("No matches").foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
        } else {
            if !model.sidebarSearchResults.pages.isEmpty {
                Section("Pages") {
                    ForEach(model.sidebarSearchResults.pages) { note in
                        sidebarPageRow(note)
                    }
                }
            }
            if !model.sidebarSearchResults.sources.isEmpty {
                Section("Sources") {
                    ForEach(model.sidebarSearchResults.sources) { source in
                        sidebarItemRow(title: source.title,
                                       symbol: source.metadata.isLinked ? "link" : "doc.text",
                                       active: model.currentSource?.id == source.id) {
                            model.select(source.id)
                        }
                    }
                }
            }
            if !model.sidebarSearchResults.blocks.isEmpty {
                Section("Semantic Blocks") {
                    ForEach(model.sidebarSearchResults.blocks) { hit in
                        sidebarItemRow(title: hit.preview.isEmpty ? hit.pageTitle : hit.preview,
                                       symbol: SemanticPresentation.find(hit.semantic)?.symbol ?? "tag",
                                       active: model.selectedSemanticID == hit.id) {
                            model.select(hit.pageID, block: hit.blockID)
                        }
                        .help("\(hit.pageTitle) · \(hit.semantic)")
                        .accessibilityLabel("\(hit.pageTitle), \(hit.semantic), \(hit.preview)")
                    }
                }
            }
        }
    }
    private func sidebarTabButton(title: String, symbol: String, count: Int?, showLabel: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: NoemaSpacing.sm) {
                Image(systemName: symbol)
                    .font(showLabel ? NoemaTypography.navigationEmphasis : NoemaTypography.navigation)
                    .noemaChromeForeground(.textSecondary)
                if showLabel {
                    HStack(spacing: NoemaSpacing.sm) {
                        Text(title)
                            .font(NoemaTypography.navigationEmphasis)
                            .noemaChromeForeground()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 2)
                        if let count {
                            Text(count.formatted())
                                .font(NoemaTypography.metadata)
                                .noemaChromeForeground()
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                }
            }
            .padding(.horizontal, showLabel ? NoemaSpacing.sm : 0)
            .frame(maxWidth: showLabel ? .infinity : NoemaMetrics.compactRowHeight, minHeight: NoemaMetrics.compactRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoemaChromeButtonStyle(selected: showLabel, surface: .elevated,
                                            focused: sidebarTabFocused == title))
        .focused($sidebarTabFocused, equals: title)
        .accessibilityAddTraits(showLabel ? [.isSelected] : [])
        .accessibilityValue(showLabel ? "Selected" : "")
        .help(title)
        .accessibilityLabel(title)
    }
    private func relativeEditTime(_ value: String) -> String {
        guard let date = LibraryRow.date(value) else { return "" }
        let now = Date()
        if abs(now.timeIntervalSince(date)) < 45 {
            return "now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
    private func sidebarPageRow(_ note: NoteRecord, showRelativeEditTime: Bool = false) -> some View {
        let active = model.currentNote?.id == note.id
        return HStack(spacing: NoemaSpacing.sm) {
            SidebarPageIcon(unread: model.unseenRenamedPages.contains(note.id), active: active, title: note.title) {
                model.select(note.id)
            }
            Button { model.select(note.id) } label: {
                HStack(spacing: NoemaSpacing.sm) {
                    Text(note.title)
                        .font(NoemaTypography.navigation)
                        .noemaChromeForeground()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if showRelativeEditTime {
                        let relative = relativeEditTime(note.updatedAt)
                        if !relative.isEmpty {
                            Text(relative)
                                .font(NoemaTypography.metadata)
                                .noemaChromeForeground(.textTertiary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .help("Last edited \(metadataDate(note.updatedAt))")
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(NoemaChromeButtonStyle(selected: active, drawsSelection: false,
                                                focused: sidebarPageFocused == note.id))
            .focused($sidebarPageFocused, equals: note.id)
            .help(note.title)
            SidebarEditingLockControl(locked: note.isEditingLocked,
                                      selected: active,
                                      visible: active || hoveredSidebarPageID == note.id,
                                      pending: model.editingLockOperations.contains(note.id)) {
                model.toggleEditingLock(note.id)
            }
        }
        .onHover { hovering in
            if hovering { hoveredSidebarPageID = note.id }
            else if hoveredSidebarPageID == note.id { hoveredSidebarPageID = nil }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(minHeight: NoemaMetrics.compactRowHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: NoemaMetrics.radiusSmall, style: .continuous)
                .fill(active ? theme.color(for: .selection, active: activeWindow) : Color.clear)
        )
        .listRowInsets(EdgeInsets(top: 0.5, leading: 0, bottom: 0.5, trailing: 4))
        .listRowSeparator(.hidden)
        .contextMenu {
            AISummaryMenuCommands(model: model, target: .page(note.id))
            Button(note.isEditingLocked ? "Unlock Editing" : "Lock Editing") {
                model.toggleEditingLock(note.id)
            }
            .disabled(model.editingLockOperations.contains(note.id))
            Button("Delete…", role: .destructive) { trashPageID = note.id; showTrashConfirmation = true }
        }
    }
    private func sidebarItemRow(title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: NoemaSpacing.sm) {
                Image(systemName: symbol)
                    .font(NoemaTypography.navigation)
                    .noemaChromeForeground(.textSecondary)
                    .frame(width: NoemaMetrics.iconWidth)
                Text(title)
                    .font(NoemaTypography.navigation)
                    .noemaChromeForeground()
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, 2)
            .padding(.trailing, 8)
            .frame(minHeight: NoemaMetrics.compactRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoemaChromeButtonStyle(selected: active, focused: sidebarItemFocused == title))
        .focused($sidebarItemFocused, equals: title)
        .listRowInsets(EdgeInsets(top: 0.5, leading: 0, bottom: 0.5, trailing: 4))
        .listRowSeparator(.hidden)
    }
    private func sidebarFooterLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(NoemaTypography.navigation)
                .noemaChromeForeground(.textSecondary)
                .padding(.leading, 2)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: NoemaMetrics.toolbarControlHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(NoemaChromeButtonStyle(focused: sidebarFooterFocused == title))
        .focused($sidebarFooterFocused, equals: title)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 4))
        .listRowSeparator(.hidden)
    }
    private var sortedPageRows: [LibraryRow] {
        switch pageSortOrder {
        case .updated:
            return model.rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .title:
            return model.rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
    @ViewBuilder private var library: some View {
        if model.isSearching {
            VStack(alignment: .leading, spacing: 0) {
                Text("Search Results").font(NoemaTypography.libraryTitle)
                    .foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
                    .padding(.horizontal, NoemaSpacing.lg).padding(.vertical, NoemaSpacing.md)
                List { searchResultSections }.listStyle(.inset)
            }
        } else if model.scope == .trash { trashLibrary } else { pageLibrary }
    }
    @ViewBuilder private var pageLibrary: some View {
        if model.scope == .sources {
            SourcesLibraryView(
                model: model,
                presentation: sourceTablePresentation,
                selection: sourceSelectionBinding,
                rename: { source in sourceName = source.title; renamingSource = source },
                delete: { deletingSource = $0 }
            )
            .background(theme.color(for: .canvas))
            .safeAreaBar(edge: .top) {
                VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                    HStack(spacing: NoemaSpacing.md) {
                        Text("Sources").font(NoemaTypography.libraryTitle).foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
                        Spacer()
                        Menu {
                            Button("Check Availability of All Sources") { model.checkSourceAvailability(model.sources) }
                                .disabled(model.sources.isEmpty || !model.checkingSourceAvailability.isEmpty)
                        } label: { Label("Source Actions", systemImage: "ellipsis.circle") }
                        headerActions
                        if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating library").accessibilityValue("In progress") }
                    }
                    if let error = model.errorMessage {
                        DismissibleNotice(message: error, surface: .canvas) { model.errorMessage = nil }
                    }
                }
                .padding(.horizontal, NoemaSpacing.lg)
                .padding(.top, NoemaSpacing.md)
                .padding(.bottom, NoemaSpacing.md)
            }
        } else {
            pageLibraryContent
        }
    }
    private var pageLibraryContent: some View {
        VStack(spacing: 0) {
            if model.scope == .semantic {
                semanticBlockList
            } else if model.rows.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "\(model.scopeTitle) is empty" : "No matches", systemImage: model.scope == .sources ? "tray" : "doc.text.magnifyingglass", description: Text(model.searchText.isEmpty ? (model.scope == .sources ? "Import a text file or paste a source to begin." : "Create a page to start building your wiki.") : "Try another word or topic."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(sortedPageRows) { row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                if row.kind == .wiki, model.unseenRenamedPages.contains(row.id) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Color(nsColor: .systemBlue))
                                        .help("Page renamed since you last viewed it")
                                        .accessibilityLabel("Unread title change")
                                }
                                Text(row.title).font(NoemaTypography.interfaceEmphasis).lineLimit(1)
                                if row.kind == .wiki, model.notes.first(where: { $0.id == row.id })?.isEditingLocked == true {
                                    Image(systemName: "lock.fill")
                                        .font(NoemaTypography.metadata)
                                        .help("Page locked against editing")
                                        .accessibilityLabel("Page locked against editing")
                                }
                                Spacer(minLength: 8)
                                if let date = row.updatedAt {
                                    Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().year())
                                        .font(NoemaTypography.metadata).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                        .help(date.formatted(date: .long, time: .shortened))
                                        .accessibilityLabel("\(row.kind == .wiki ? "Last updated" : "Captured") \(date.formatted(date: .long, time: .shortened))")
                                }
                            }
                            HStack(alignment: .top, spacing: 5) {
                                if row.hasAISummary {
                                    Image(systemName: "sparkles").accessibilityLabel("AI-generated summary")
                                }
                                Text(row.excerpt.replacingOccurrences(of: "\n", with: " ")).lineLimit(2)
                            }.font(NoemaTypography.interface)
                                .foregroundStyle(.secondary)
                            if !row.tags.isEmpty {
                                Text(row.tags.prefix(3).map { "#" + $0 }.joined(separator: "  ")).font(NoemaTypography.metadata)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.horizontal, NoemaSpacing.md).padding(.vertical, NoemaSpacing.sm).tag(row.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.kind == .wiki {
                                Button(role: .destructive) { trashPageID = row.id; showTrashConfirmation = true } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if row.kind == .wiki, let note = model.notes.first(where: { $0.id == row.id }) {
                                Button { model.toggleEditingLock(row.id) } label: {
                                    Label(note.isEditingLocked ? "Unlock Editing" : "Lock Editing", systemImage: note.isEditingLocked ? "lock.open" : "lock")
                                }.disabled(model.editingLockOperations.contains(note.id))
                            }
                        }
                        .contextMenu {
                            if row.kind == .wiki, let note = model.notes.first(where: { $0.id == row.id }) {
                                AISummaryMenuCommands(model: model, target: .page(note.id))
                                Button(note.isEditingLocked ? "Unlock Editing" : "Lock Editing") { model.toggleEditingLock(row.id) }
                                    .disabled(model.editingLockOperations.contains(note.id))
                                Button("Delete…", role: .destructive) { trashPageID = row.id; showTrashConfirmation = true }
                            }
                        }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack {
                Text(libraryCount)
                if model.scope == .sources, !model.downloadingSources.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Downloading from iCloud")
                    }
                } else if model.scope == .sources, model.sourceRenameTotal > 0 {
                    Text("Renaming \(min(model.sourceRenameCompleted + 1, model.sourceRenameTotal)) of \(model.sourceRenameTotal) files…")
                }
                Spacer(); Text("⌘P")
            }.font(NoemaTypography.metadata).foregroundStyle(.secondary).padding(NoemaSpacing.md)
        }
        .background(theme.color(for: .canvas))
        .safeAreaBar(edge: .top) {
            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                HStack(spacing: NoemaSpacing.md) {
                    Text(model.scopeTitle).font(NoemaTypography.libraryTitle).foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
                    if model.activeTagFilter != nil {
                        Button("Clear filter") { model.changeScope(.wiki) }
                            .font(NoemaTypography.metadata)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer()
                    if isPagesScope {
                        Picker("Sort", selection: $pageSortOrder) {
                            ForEach(PageSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }
                    if model.scope == .sources {
                        Menu {
                            Button("Check Availability of All Sources") { model.checkSourceAvailability(model.sources) }
                                .disabled(model.sources.isEmpty || !model.checkingSourceAvailability.isEmpty)
                        } label: { Label("Source Actions", systemImage: "ellipsis.circle") }
                    } else {
                        headerActions
                    }
                    if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating library").accessibilityValue("In progress") }
                }
                if model.scope == .sources, let error = model.errorMessage {
                    DismissibleNotice(message: error, surface: .canvas) { model.errorMessage = nil }
                }
                if isPagesScope && !model.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button("All Pages") { model.changeScope(.wiki) }
                                .font(NoemaTypography.metadata)
                                .buttonStyle(.bordered)
                                .tint(model.activeTagFilter == nil ? .accentColor : nil)
                                .controlSize(.small)
                            ForEach(model.tags, id: \.self) { tag in
                                Button("#" + tag) {
                                    model.changeScope(model.activeTagFilter == tag ? .wiki : .tag(tag))
                                }
                                .font(NoemaTypography.metadata)
                                .buttonStyle(.bordered)
                                .tint(model.activeTagFilter == tag ? theme.color(.graphHighlight) : nil)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }.padding(.horizontal, NoemaSpacing.lg).padding(.top, NoemaSpacing.md).padding(.bottom, NoemaSpacing.md)
        }
    }
    private func metadataDate(_ value: String) -> String {
        InspectorFormatting.metadataDate(value)
    }
    private var trashLibrary: some View {
        VStack(spacing: 0) {
            if model.trashedPages.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Deleted pages and sources stay recoverable for 15 days."))
            } else {
                List {
                    ForEach(model.trashedPages) { page in
                        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                            Text(page.title).font(NoemaTypography.interfaceEmphasis)
                            Text(page.kindLabel).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                            if let issue = page.readIssue {
                                Text(issue).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                                Text("Restore is unavailable until the file is repaired.").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                            } else {
                                if !page.excerpt.isEmpty {
                                    Text(page.excerpt).lineLimit(2).font(NoemaTypography.interface).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button("Restore") { model.restoreTrashedPage(page) }
                                    .disabled(!page.canRestore)
                                Button("Delete Permanently…", role: .destructive) { permanentDeletion = page; showPermanentDeletion = true }
                                    .disabled(!page.canPermanentlyDelete)
                            }.buttonStyle(.bordered)
                        }.padding(.vertical, 7)
                        .contextMenu {
                            Button("Restore") { model.restoreTrashedPage(page) }
                                .disabled(!page.canRestore)
                            Button("Delete Permanently…", role: .destructive) { permanentDeletion = page; showPermanentDeletion = true }
                                .disabled(!page.canPermanentlyDelete)
                        }
                        .disabled(model.trashOperationInProgress)
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text(model.trashedPages.count == 1 ? "1 deleted item" : "\(model.trashedPages.count) deleted items")
                if model.trashOperationInProgress { NoemaLoadingStatus("Updating Trash…", surface: .canvas) }
            }.font(NoemaTypography.metadata).foregroundStyle(.secondary).padding(NoemaSpacing.md)
            if let error = model.errorMessage { DismissibleNotice(message: error, surface: .canvas) { model.errorMessage = nil }.padding(NoemaSpacing.md) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) {
            HStack {
                Text("Trash").font(NoemaTypography.libraryTitle).foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
                Text("Automatically deleted after 15 days").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                Spacer()
                Button { model.performWorkspaceCommand(.refresh) } label: { Label("Refresh Trash", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .help("Refresh Trash").disabled(model.trashOperationInProgress || !model.canPerformWorkspaceCommand(.refresh))
                Button("Empty Trash…", role: .destructive) { emptyTrashPages = model.trashedPages; showEmptyTrash = true }
                    .disabled(model.trashedPages.isEmpty || model.trashOperationInProgress)
            }.padding(.horizontal, NoemaSpacing.lg).padding(.top, NoemaSpacing.md).padding(.bottom, NoemaSpacing.md)
        }
        .alert("Permanently delete this item?", isPresented: $showPermanentDeletion, presenting: permanentDeletion) { page in
            Button("Delete permanently", role: .destructive) {
                model.permanentlyDeleteTrashedPage(page)
            }
            Button("Cancel", role: .cancel) { }
        } message: { page in Text("‘\(page.title)’ will be removed from the vault. This cannot be undone.") }
        .alert("Empty Trash?", isPresented: $showEmptyTrash, presenting: emptyTrashPages) { pages in
            Button("Empty Trash", role: .destructive) { model.emptyTrash(pages) }
            Button("Cancel", role: .cancel) { }
        } message: { pages in
            Text("Permanently delete \(pages.count) deleted item(s)? This cannot be undone. Changed, unreadable, or conflicted files will be kept and reported.")
        }
    }
    @ViewBuilder private var detail: some View {
        if model.currentNote != nil || model.currentSource != nil {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        DismissibleNotice(message: message, surface: .elevated) {
                            model.errorMessage = nil; dismissedExternalChange = model.externalChange
                        }.font(.callout)
                        if model.externalChange {
                            HStack {
                                Button("Reload disk version") { model.reloadDiskVersion() }
                                Button("Save draft as new page") { model.saveDraftAsNewPage() }
                            }
                        } else if model.currentNote != nil { Button("Try saving again") { model.saveNow() } }

                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.color(for: .elevated))
                } else if model.externalChange, !dismissedExternalChange {
                    HStack {
                        Label("This page changed or moved outside the app.", systemImage: "arrow.triangle.2.circlepath")
                        Spacer(); Button("Reload") { model.reloadDiskVersion() }
                        Button("Save a copy") { model.saveDraftAsNewPage() }
                        Button("Dismiss") { dismissedExternalChange = true }
                    }.font(.callout).padding(12).background(.orange.opacity(0.12))
                }
                if let notice = model.editorNotice, model.currentNote != nil {
                    DismissibleNotice(message: notice, isError: false, surface: .canvas) { model.editorNotice = nil }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.color(for: .canvas))
                }
                pageHeader
                Divider().overlay(theme.color(for: .separator))
                ZStack(alignment: .topLeading) {
                    if let source = model.currentSource, sourceOriginal || source.metadata.storedFilename.hasSuffix(".txt") {
                        MarkdownEditor(text: .constant(model.body), action: nil, onWikiQuery: { _ in }, editable: false)
                    } else if model.currentNote != nil {
                        SummarizedArticleView(model: model, showsSummary: (AISummaryPlacement(rawValue: aiSummaryPlacement) ?? .defaultValue).showsInEditor(sidebarVisible: isInspectorPresented))
                            .id(model.selectedID)
                    } else { MarkdownPreview(blocks: model.preview, onWikiLink: model.followWikiLink) }
                    if !model.reading, model.currentNote != nil, model.wikiQuery != nil, !model.linkSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Link a page").font(.caption).foregroundStyle(theme.text()).padding(8)
                            ForEach(model.linkSuggestions) { note in
                                Button { model.suggestLink(note.title) } label: { Label(note.title, systemImage: "link").frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.plain)
                            }
                        }.padding(6).frame(width: 270).glassEffect(.regular, in: .rect(cornerRadius: 16)).padding(16)
                    }
                }.frame(maxWidth: model.currentNote != nil ? .infinity : 980).frame(maxWidth: .infinity)
                if model.currentNote != nil { pageFooter }
            }
            .background(theme.color(for: .canvas))
            .onChange(of: model.body) { model.edited() }
            .onChange(of: model.title) { model.edited() }
            .onChange(of: model.tagInput) { model.edited() }
            .onChange(of: model.reading) { if model.reading { model.generatePreview() } }
        } else {
            VStack(spacing: 18) {
                NoemaMark(presentation: .identity).frame(width: 76, height: 76).accessibilityHidden(true)
                Text(model.scope == .sources ? "Keep the original. Find your meaning." : "A personal atlas of thought.").font(.title2.weight(.medium))
                Text(model.scope == .sources ? "Browse raw material here. Your interpretations belong in the wiki." : "Choose a page, or start with a thought you want to connect.").foregroundStyle(theme.text())
                if model.scope != .sources { Button("New personal page") { model.newPage(template: true) }.buttonStyle(.glass) }
                if let error = model.errorMessage { DismissibleNotice(message: error, surface: .canvas) { model.errorMessage = nil }.frame(maxWidth: 500) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top) { HStack { Spacer(); headerActions }.padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6) }
        }
    }
    private var semanticBlockList: some View {
        Group {
            if model.semanticRows.isEmpty {
                ContentUnavailableView(model.searchText.isEmpty ? "No semantic blocks" : "No matches",
                    systemImage: "tag", description: Text("Search block text, semantic type, or page title."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedSemanticID }, set: { id in
                    if let hit = model.semanticRows.first(where: { $0.id == id }) {
                        model.select(hit.pageID, block: hit.blockID)
                    }
                })) {
                    ForEach(model.semanticRows) { hit in
                        let presentation = SemanticPresentation.find(hit.semantic)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: presentation?.symbol ?? "tag")
                                .font(.headline)
                                .foregroundStyle(Color(nsColor: presentation?.accent ?? .secondaryLabelColor))
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(presentation?.title ?? hit.semantic.capitalized).font(.headline)
                                Text(hit.preview.isEmpty ? "Empty block" : hit.preview).lineLimit(1)
                                Text(hit.pageTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 8).tag(hit.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }
    private var libraryCount: String {
        if model.scope == .semantic { return "\(model.semanticRows.count) semantic blocks" }
        let count = model.rows.count
        let noun = model.scope == .sources ? (count == 1 ? "source" : "sources") : (count == 1 ? "page" : "pages")
        return "\(count) \(noun)"
    }
    private var inspectorToolbarToggle: some View {
        Button {
            toggleInspectorPane()
        } label: {
            Label(
                isInspectorPresented ? "Hide Inspector" : "Show Inspector",
                systemImage: "sidebar.right"
            )
        }
        .disabled(!paneActions.canToggleInspector)
        .help(isInspectorPresented ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        .accessibilityLabel(isInspectorPresented ? "Hide Inspector" : "Show Inspector")
        .accessibilityValue(isInspectorPresented ? "Shown" : "Hidden")
    }
    // Native toolbar buttons/menus keep platform sizing and state drawing.
    // The scene supplies NoemaTheme tint; custom chrome tokens stay in pane content.
    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        if model.isVaultAvailable {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebarPane) {
                    Label(panePresentation.sidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
                .disabled(!paneActions.canToggleSidebar)
                .help(panePresentation.sidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
                .accessibilityLabel(panePresentation.sidebar ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityValue(panePresentation.sidebar ? "Shown" : "Hidden")
            }
            ToolbarItem(placement: .navigation) {
                Button { model.performWorkspaceCommand(.returnToLibrary) } label: {
                    Label("Return to Library", systemImage: "chevron.backward")
                }
                .disabled(!model.canPerformWorkspaceCommand(.returnToLibrary))
                .help("Return to Library (⌘[)")
                .accessibilityLabel("Return to Library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.performWorkspaceCommand(.search) } label: {
                    Label("Find in Vault", systemImage: "magnifyingglass")
                }
                .disabled(!model.canPerformWorkspaceCommand(.search))
                .help("Find in Vault (⇧⌘F)")
                .accessibilityLabel("Find in Vault")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    workspaceCommandButton("Blank Page", .newPage)
                    workspaceCommandButton("Personal Page", .newPersonalPage)
                    workspaceCommandButton("Page from Topic with AI…", .newTopicPage)
                        .disabled(model.generatingTopicPage)
                    Divider()
                    workspaceCommandButton("Source from Files…", .addSource)
                    workspaceCommandButton("Source by URL…", .addURLSource)
                    workspaceCommandButton("Paste a Source…", .pasteSource)
                } label: { Label("Add Page or Source", systemImage: "plus") }
                .disabled(!model.canPerformWorkspaceCommand(.newPage))
                .help("Add a page or source")
                .accessibilityLabel("Add Page or Source")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    workspaceCommandButton("Open Another Vault…", .openVault)
                    workspaceCommandButton("Reveal Vault in Finder", .revealVault)
                    workspaceCommandButton("Refresh from Files", .refresh)
                    workspaceCommandButton("Trash", .showTrash)
                    workspaceCommandButton("Vault Notices (\(model.issues.count))", .notices)
                    workspaceCommandButton("Recover Drafts (\(model.recoveredDrafts.count))" + (model.damagedRecoveryEntries.isEmpty ? "" : " · \(model.damagedRecoveryEntries.count) damaged"), .recovery)
                    Divider()
                    workspaceCommandButton("Lock Vault", .lock)
                    workspaceCommandButton("Close Vault", .close)
                } label: { Label("Vault Options", systemImage: "ellipsis.circle") }
                .help("Vault options")
                .accessibilityLabel("Vault Options")
            }
            ToolbarItem(placement: .primaryAction) { inspectorToolbarToggle }
        }
    }
    // Document actions stay with the document heading; window actions live in the native toolbar.
    private var headerActions: some View {
        HStack(spacing: NoemaSpacing.sm) {
            if model.isVaultAvailable, model.currentNote != nil {
                if let id = model.currentNote?.id {
                    AISummaryControls(model: model, target: .page(id))
                    AIProviderBadge(provider: model.preferredAIProvider(for: .summarizePage))
                    AISummaryStatus(model: model, target: .page(id))
                }
                Button { if model.reading { model.beginEditing() } else { model.finishEditing() } } label: {
                    Label(model.reading ? "Edit" : "Done", systemImage: model.reading ? "pencil" : "checkmark")
                }.disabled(model.editingLocked)
                Button { model.toggleEditingLock() } label: {
                    Label(model.currentNote?.isEditingLocked == true ? "Unlock Editing" : "Lock Editing", systemImage: model.currentNote?.isEditingLocked == true ? "lock.fill" : "lock.open")
                }.help(model.currentNote?.isEditingLocked == true ? "Unlock Editing" : "Lock Editing")
                .disabled(model.currentNote.map { model.editingLockOperations.contains($0.id) } ?? true)
                Button { trashPageID = model.currentNote?.id; showTrashConfirmation = true } label: {
                    Label("Move page to vault trash", systemImage: "trash")
                }.help("Move page to vault trash")
            } else if model.isVaultAvailable, model.currentSource?.metadata.storedFilename.hasSuffix(".md") == true {
                Picker("Source view", selection: $sourceOriginal) {
                    Text("Read").tag(false)
                    Text("Original").tag(true)
                }.pickerStyle(.segmented).frame(minWidth: 160)
            }
        }.labelStyle(.iconOnly).buttonStyle(.glass).fixedSize(horizontal: true, vertical: false)
    }
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            if let notice = model.aiSummaryNotice { DismissibleNotice(message: notice, isError: false, surface: .canvas) { model.aiSummaryNotice = nil }.font(NoemaTypography.metadata) }
            if model.currentSource != nil || model.editingHint != nil {
                HStack {
                    if model.currentSource != nil {
                        Label("Raw source", systemImage: "tray.full")
                            .font(NoemaTypography.metadataEmphasis).foregroundStyle(theme.text(for: .textSecondary, on: .canvas))
                    }
                    Spacer()
                    if model.currentNote != nil, let hint = model.editingHint {
                        Text(hint).font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .canvas))
                    }
                    if model.currentSource != nil {
                        Label("Read only", systemImage: "lock").font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .canvas))
                    }
                }
            }
            if model.currentNote != nil {
                if model.reading && !isInspectorPresented {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: NoemaSpacing.lg) {
                            pageTitle.fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            headerActions
                        }
                        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
                            pageTitle
                            headerActions
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: NoemaSpacing.lg) {
                        pageTitle
                        if !isInspectorPresented {
                            Spacer()
                            headerActions
                        }
                    }
                    if isInspectorPresented {
                        headerActions
                    }
                }
                if model.reading, let note = model.currentNote, !note.allTags.isEmpty {
                    HStack { ForEach(note.allTags.prefix(8), id: \.self) { tag in Button("#" + tag) { model.changeScope(.tag(tag)) }.font(NoemaTypography.metadata).buttonStyle(.bordered).tint(theme.color(.graphHighlight)).controlSize(.small) } }
                }
            } else {
                HStack(alignment: .center, spacing: NoemaSpacing.lg) {
                    Text(model.title).foregroundStyle(theme.text(for: .textPrimary, on: .canvas)).font(NoemaTypography.documentTitle).textSelection(.enabled)
                    Spacer()
                    headerActions
                }
                if let source = model.currentSource {
                    HStack {
                        Text(source.metadata.originalFilename)
                        Text((source.metadata.isLinked ? "· Linked " : "· Imported ") + String(source.metadata.capturedAt.prefix(10)))
                        if let address = source.metadata.originURL, let url = URL(string: address) { Link("Original URL", destination: url).foregroundStyle(theme.text(.accentSecondary)) }
                    }.font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .canvas))
                }
            }
        }
        .padding(.top, 14).padding(.bottom, 12)
        .readingColumn(reservesEditorGutter: true)
    }
    private var pageTitle: some View {
        Group {
            if model.reading {
                Text(model.title).foregroundStyle(theme.text(for: .textPrimary, on: .canvas)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { model.beginEditing() }
            } else {
                TextField("Page title", text: $model.title).textFieldStyle(.plain)
                    .foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
            }
        }.font(NoemaTypography.documentTitle)
    }
    private var pageFooter: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            if !model.backlinks.isEmpty {
                HStack(alignment: .top) {
                    Text("Linked from").font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(model.backlinks) { note in Button(note.title) { model.select(note.id) }.buttonStyle(.link).foregroundStyle(theme.text(.accentSecondary)).tint(theme.color(.accentSecondary)).font(NoemaTypography.metadata) } }
                    }
                }
            }
            HStack {
                Label(model.saveStatus, systemImage: model.dirty ? "circle.dotted" : "checkmark.circle").font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                Spacer()
                Text("\(model.wordCount) words").font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                if !model.reading {
                    Text("/ commands · Esc to finish").font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                    HStack(spacing: NoemaSpacing.md) {
                        Button { model.format("**", "**") } label: { Label("Bold", systemImage: "bold").labelStyle(.iconOnly) }.help("Bold · ⌘B")
                        Button { model.format("*", "*") } label: { Label("Italic", systemImage: "italic").labelStyle(.iconOnly) }.help("Italic · ⌘I")
                        Button { model.format("[[", "]]") } label: { Label("Wiki link", systemImage: "link").labelStyle(.iconOnly) }.help("Wiki link")
                    }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }.padding(.horizontal, 28).padding(.vertical, 14).background(theme.color(for: .elevated))
    }
    private var recoverySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recoverable drafts").font(.title2.bold())
            Text("Create a new page from a draft to keep the disk version intact.").foregroundStyle(theme.text())
            List {
                ForEach(model.recoveredDrafts) { draft in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(draft.title).font(.headline)
                        Text(draft.body.prefix(240)).font(.caption).foregroundStyle(theme.text()).textSelection(.enabled)
                        HStack {
                            Button("Recover as new page") { model.saveDraftAsNewPage(draft) }
                            Button("Discard draft", role: .destructive) { model.discardRecovery(draft) }
                        }
                    }.padding(.vertical, 8)
                }
                ForEach(model.damagedRecoveryEntries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Damaged recovery entry", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(entry.fileName).font(.caption).textSelection(.enabled)
                        Text(entry.message).font(.caption).foregroundStyle(theme.text())
                        Text("The original file is preserved. Other drafts can still be recovered.").font(.caption)
                        Button("Show preserved file") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
                    }.padding(.vertical, 8)
                }
            }
            Button("Done") { model.showRecovery = false }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 580, height: 480)
    }
    private var noticesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vault notices").font(.title2.bold())
            if model.issues.isEmpty { Text("No active vault notices.").foregroundStyle(theme.text()) }
            List(model.issues, id: \.self) { issue in
                DismissibleNotice(message: issue, isError: false) { model.dismissVaultNotice(issue) }.font(.callout)
            }
            if !model.issues.isEmpty { Button("Dismiss All") { model.dismissAllVaultNotices() } }
            HStack { Button("Reveal vault") { model.revealVault() }; Spacer(); Button("Done") { model.showIssues = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580, height: 420)
    }
}

struct PasteSourceSheet: View {
    @Bindable var model: AppModel
    @Environment(\.noemaTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var url = ""
    @State private var importing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preserve a source").font(.title2.bold())
            Text("Store the original text here. Write your understanding in the wiki.").foregroundStyle(theme.text())
            TextField("Source title", text: $title)
            TextField("Original URL (optional)", text: $url)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).background(theme.color(.surfaceElevated)).border(theme.color(.border))
            if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil }.font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if importing { NoemaLoadingStatus("Saving source…") }
                Button("Save source") {
                    importing = true
                    Task { if await model.pasteSource(title: title, text: text, originURL: url) { dismiss() }; importing = false }
                }.buttonStyle(.glassProminent).disabled(text.isEmpty || importing).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660, height: 540)
    }
}

struct DismissibleNotice: View {
    @Environment(\.noemaTheme) private var theme
    var message: String
    var isError = true
    var surface: NoemaColorRole = .window
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: NoemaSpacing.sm) {
            Text(message).foregroundStyle(theme.text(for: isError ? .destructive : .textSecondary, on: surface))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Label("Dismiss message", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
            }.buttonStyle(.borderless).help("Dismiss message")
        }
    }
}

struct URLSourceSheet: View {
    @Environment(\.noemaTheme) private var theme
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var importing = false
    @State private var failures: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Sources by URL").font(.title2.bold())
            Text("Enter up to 5 http or https URLs, one per line. This Mac fetches each page and keeps a local copy.").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
                .accessibilityLabel("Source URLs, one per line").disabled(importing)
            if !failures.isEmpty {
                ScrollView { Text(failures.joined(separator: "\n")).foregroundStyle(theme.text(for: .destructive, on: .window)).textSelection(.enabled) }.frame(maxHeight: 120)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(importing)
                Spacer()
                if importing { NoemaLoadingStatus("Fetching sources…") }
                Button("Add Sources") {
                    importing = true; failures = []
                    Task { failures = await model.addURLSources(text); importing = false; if failures.isEmpty { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(importing || (try? WebSourceFetcher.lines(text)) == nil)
            }
        }.padding(24).frame(width: 600, height: 400).interactiveDismissDisabled(importing)
    }
}

struct TopicPageSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @FocusState private var topicFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Page from Topic").font(.title2.bold())
            Text("Searches the web with Bing and reads up to three top results. Apple Intelligence summarizes them on this Mac and adds web references. Your topic is sent to the search service.").font(.callout).foregroundStyle(.secondary)
            TextField("Topic", text: $topic).textFieldStyle(.roundedBorder).focused($topicFocused)
                .disabled(model.generatingTopicPage)
            if model.generatingTopicPage { NoemaLoadingStatus("Searching web and creating page…") }
            if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil } }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.generatingTopicPage)
                Button("Create with AI") {
                    Task { if await model.createPageFromTopic(topic) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
                .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || topic.trimmingCharacters(in: .whitespacesAndNewlines).count > 120 || model.generatingTopicPage)
            }
        }.padding(24).frame(width: 460).interactiveDismissDisabled(model.generatingTopicPage)
        .onAppear { topicFocused = true }
    }
}

private struct SidebarPageIcon: View {
    let unread: Bool
    let active: Bool
    let title: String
    let select: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: select) {
            Image(systemName: "doc.text")
                .font(NoemaTypography.navigation)
                .noemaChromeForeground(.textSecondary)
                .overlay(alignment: .topTrailing) {
                    if unread {
                        Circle().fill(Color(nsColor: .systemBlue)).frame(width: 4, height: 4)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: NoemaMetrics.iconWidth)
                .frame(minWidth: NoemaMetrics.toolbarControlHeight, minHeight: NoemaMetrics.compactRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(NoemaChromeButtonStyle(selected: active, drawsSelection: false, focused: focused))
        .focused($focused)
        .help("Open page")
        .accessibilityLabel("Open \(title)")
        .accessibilityValue(unread ? "Unread title change" : "")
    }
}

private struct SidebarEditingLockControl: View {
    let locked: Bool
    let selected: Bool
    let visible: Bool
    let pending: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @FocusState private var focused: Bool
    private var actionTitle: String { locked ? "Unlock Editing" : "Lock Editing" }
    var body: some View {
        Button(action: toggle) {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(NoemaTypography.caption)
                .noemaChromeForeground(.textSecondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(3)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: locked)
                .opacity(NoemaChromePresentation.lockActionVisible(locked: locked, revealed: visible, pending: pending, focused: focused, voiceOver: voiceOver) ? 1 : 0)
                .frame(width: NoemaMetrics.iconWidth)
                .frame(minWidth: NoemaMetrics.toolbarControlHeight, minHeight: NoemaMetrics.compactRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(NoemaChromeButtonStyle(selected: selected, drawsSelection: false, focused: focused))
        .focused($focused)
        .disabled(pending)
        .help(actionTitle)
        .accessibilityLabel(actionTitle)
        .accessibilityValue(pending ? "Saving" : locked ? "Editing locked" : "Editing unlocked")
    }
}

private struct SidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

