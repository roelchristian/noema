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
    @State private var showAllSearchResults = false
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
    @State private var pageSortOrder: PageSortOrder = .updated
    @State private var selectedSemanticStatus: String?
    @State private var selectedSemanticFilter: String?
    private var sourceSelection: UUID? { model.librarySourceSelection }
    private var sourceSelectionBinding: Binding<UUID?> {
        Binding(get: { model.librarySourceSelection }, set: { model.setLibrarySourceSelection($0) })
    }
    @State private var sourceTablePresentation = SourcesTablePresentation()
    @State private var renamingSource: SourceRecord?
    @State private var sourceName = ""
    @State private var renamingPageID: UUID?
    @State private var pageName = ""
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
            canToggleSidebar: model.canInteractWithWorkspace && model.isVaultAvailable && workspaceWidth >= workspaceMinimum + WorkspacePaneState.sidebarMinimum + 1,
            canToggleInspector: model.canInteractWithWorkspace && model.isVaultAvailable && inspectorContext.isInspectable && workspaceWidth >= workspaceMinimum + InspectorState.minWidth + 1
        )
    }
    private func toggleSidebarPane() {
        guard paneActions.canToggleSidebar else { return }
        paneState.toggleSidebar(presented: panePresentation.sidebar)
    }
    private func toggleInspectorPane() {
        guard paneActions.canToggleInspector else { return }
        paneState.toggleInspector(presented: isInspectorPresented)
    }
    private var inspectorContext: InspectorContext {
        InspectorContext.resolve(model: model, librarySourceSelection: sourceSelection)
    }
    private func switchSidebarScope(_ scope: LibraryScope) {
        showAllSearchResults = false
        SourcesPerformance.event("SidebarScopeChange")
        model.changeScope(scope)
    }
    private func resetLocalWorkspaceState() {
        model.setLibrarySourceSelection(nil)
        sourceTablePresentation.clear()
        inspectorState.resetForSessionChange()
        renamingSource = nil
        sourceName = ""
        renamingPageID = nil
        pageName = ""
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
        showAllSearchResults = false
        selectedSemanticFilter = nil; selectedSemanticStatus = nil
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
        .disabled(!model.canInteractWithWorkspace)
        .navigationTitle(model.windowTitle.title)
        .navigationSubtitle(model.windowTitle.hasSubtitle ? model.windowTitle.subtitle : "")
        .focusedSceneValue(\.workspacePaneActions, paneActions)
        .toolbar(removing: .sidebarToggle)
        .toolbar { workspaceToolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { AISummaryProviderNotice(model: model) }
    }
    private var workspaceSheets: some View {
        titledWorkspace
        .sheet(isPresented: $model.showSettings) {
            NoemaSettings(
                externalAIService: model.externalAIService,
                aiProviderPreferences: model.aiProviderPreferences,
                model: model
            )
            .systemNoemaTheme()
        }
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
        .alert("Rename Page", isPresented: Binding(get: { model.isVaultAvailable && renamingPageID != nil }, set: { if !$0 { renamingPageID = nil } })) {
            TextField("Page title", text: $pageName)
            Button("Rename") {
                if model.currentNote?.id == renamingPageID, !model.editingLocked, !model.externalChange {
                    model.title = pageName.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.edited()
                    model.savePage()
                }
                renamingPageID = nil
            }
            .disabled(pageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.currentNote?.id != renamingPageID || model.editingLocked || model.externalChange)
            Button("Cancel", role: .cancel) { renamingPageID = nil }
        } message: { Text("Existing links continue to resolve using the previous title as an alias.") }
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
        .onChange(of: model.semanticInspectionOpenRequest) {
            guard case .page = inspectorContext else { return }
            inspectorState.isVisible = true
            inspectorState.selectTab(.insights, for: inspectorContext)
        }
        .onChange(of: model.searchText) { model.queryChanged() }
        .onChange(of: model.editorDocument) { if model.isSearching || model.searchMode == .quickOpen || model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.title) { if model.isSearching || model.searchMode == .quickOpen || model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.selectedID) { sourceOriginal = false; dismissedExternalChange = false; showAllSearchResults = false }
        .onChange(of: model.scope) { showAllSearchResults = false; selectedSemanticFilter = nil; selectedSemanticStatus = nil }
        .onChange(of: model.workspaceNavigationToken) { showAllSearchResults = false }
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
        if showAllSearchResults {
            fullSearchResults
        } else if model.currentNote != nil || model.currentSource != nil {
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
            if model.isVaultAuthenticationPending {
                VaultAuthenticationProgress(model: model)
            } else if model.busy {
                NoemaLoadingStatus("Unlocking vault…")
            }
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
            .disabled(model.isVaultAuthenticationPending || !model.canPerformWorkspaceCommand(command))
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
            if model.isVaultAuthenticationPending {
                VaultAuthenticationProgress(model: model)
            } else if model.busy {
                NoemaLoadingStatus("Opening vault…")
            }
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
    private enum SidebarSelection: Hashable {
        case destination(LibraryScope)
        case recent(RecentItemID)
    }
    private var sidebarSelection: SidebarSelection? {
        if let id = model.selectedSidebarRecentItemID,
           model.currentNote != nil || model.currentSource != nil {
            return .recent(id)
        }
        if model.currentSource != nil { return .destination(.sources) }
        if let note = model.currentNote { return .recent(.page(note.id)) }
        switch model.scope {
        case .wiki, .tag: return .destination(.wiki)
        case .sources: return .destination(.sources)
        case .semantic: return .destination(.semantic)
        case .trash: return nil
        }
    }
    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(get: { sidebarSelection }, set: { selection in
            guard let selection else { return }
            showAllSearchResults = false
            switch selection {
            case .destination(let scope):
                model.setLibrarySourceSelection(nil)
                switchSidebarScope(scope)
            case .recent(let id):
                model.openSidebarRecentItem(id)
            }
        })
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: sidebarSelectionBinding) {
                Section {
                    sidebarNavigationRow("Pages", symbol: "book.closed", scope: .wiki)
                    sidebarNavigationRow("Sources", symbol: "tray.full", scope: .sources)
                    sidebarNavigationRow("Knowledge", symbol: KnowledgeTypePresentation.knowledgeSymbol, scope: .semantic)
                }
                Section {
                    if model.sidebarRecentItems.isEmpty {
                        Text("No recently opened items")
                            .font(NoemaTypography.metadata)
                            .foregroundStyle(.secondary)
                            .frame(minHeight: NoemaMetrics.compactRowHeight)
                            .listRowInsets(NoemaSidebarLayout.rowInsets)
                    } else {
                        ForEach(model.sidebarRecentItems) { item in
                            sidebarRecentRow(item)
                                .tag(SidebarSelection.recent(item.id))
                        }
                    }
                } header: {
                    NoemaSidebarSectionHeader(title: "RECENT ITEMS")
                        .listRowInsets(NoemaSidebarLayout.sectionHeaderInsets)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Workspace navigation")

            VStack(alignment: .leading, spacing: 6) {
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
                    NoemaSidebarVaultSelectorLabel(vaultName: model.vaultName)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help("Vault options")
                .accessibilityLabel("Vault menu. Current vault: \(model.vaultName)")
            }
            .padding(.horizontal, NoemaSidebarLayout.footerHorizontalPadding)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .noemaSidebarBackground(theme: theme)
    }
    @ViewBuilder private var searchResultSections: some View {
        let results = model.visibleSearchResults
        switch model.searchStatus {
        case .idle:
            Text("Search pages, sources and semantic blocks.").foregroundStyle(.secondary)
        case .searching:
            ProgressView("Searching…")
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
            Button("Retry search") { model.queryChanged() }
        case .results:
            if results.isEmpty {
                Text("No matches in \(model.searchScope.title)").foregroundStyle(.secondary)
                if model.searchScope != .all {
                    Button("Search all categories") { model.setSearchScope(.all) }
                }
            } else {
                if !results.pages.isEmpty {
                    Section("Pages") {
                        ForEach(results.pages) { note in
                            searchResultRow(title: note.title,
                                            excerpt: results.pageExcerpts[note.id] ?? LibraryRow(note: note).excerpt,
                                            symbol: "doc.text") {
                                openSearchResult(note.id, scope: .wiki)
                            }
                        }
                    }
                }
                if !results.sources.isEmpty {
                    Section("Sources") {
                        ForEach(results.sources) { source in
                            searchResultRow(title: source.title,
                                            excerpt: results.sourceExcerpts[source.id] ?? "",
                                            symbol: source.metadata.isLinked ? "link" : "tray") {
                                openSearchResult(source.id, scope: .sources)
                            }
                        }
                    }
                }
                if !results.blocks.isEmpty {
                    Section("Semantic Blocks") {
                        ForEach(results.blocks) { hit in
                            searchResultRow(title: hit.pageTitle,
                                            excerpt: "\(hit.semantic.capitalized) · \(hit.preview)",
                                            symbol: SemanticPresentation.find(hit.semantic)?.symbol ?? "tag") {
                                openSearchResult(hit.pageID, scope: .wiki, block: hit.blockID)
                            }
                        }
                    }
                }
            }
        }
    }
    private func openSearchResult(_ id: UUID, scope: LibraryScope, block: UUID? = nil) {
        showAllSearchResults = false
        model.select(id, scope: scope, block: block)
    }
    private func searchResultRow(title: String, excerpt: String, symbol: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NoemaSpacing.sm) {
                Image(systemName: symbol).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
                    Text(title).font(NoemaTypography.interfaceEmphasis).lineLimit(1)
                    if !excerpt.isEmpty {
                        Text(excerpt).font(NoemaTypography.metadata).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, NoemaSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(excerpt)")
        .help(title)
    }
    private func sidebarNavigationRow(_ title: String, symbol: String, scope: LibraryScope) -> some View {
        let isSelected = sidebarSelection == .destination(scope)
        return NoemaSidebarRowLabel(title: title, symbol: symbol, isSelected: isSelected)
            .tag(SidebarSelection.destination(scope))
            .listRowInsets(NoemaSidebarLayout.rowInsets)
            .listRowSeparator(.hidden)
            .accessibilityLabel(title)
            .help(title)
    }
    private func sidebarRecentRow(_ item: SidebarRecentItem) -> some View {
        let note = item.pageID.flatMap { id in model.notes.first { $0.id == id } }
        let active = sidebarSelection == .recent(item.id)
        return HStack(spacing: 2) {
            NoemaSidebarRowLabel(title: item.title, symbol: item.symbol, isSelected: active)
            if let note {
                SidebarEditingLockControl(locked: note.isEditingLocked,
                                          selected: active,
                                          visible: active || hoveredSidebarPageID == note.id,
                                          pending: model.editingLockOperations.contains(note.id)) {
                    model.toggleEditingLock(note.id)
                }
            }
        }
        .frame(minHeight: NoemaMetrics.compactRowHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredSidebarPageID = item.pageID }
            else if hoveredSidebarPageID == item.pageID { hoveredSidebarPageID = nil }
        }
        .listRowInsets(NoemaSidebarLayout.rowInsets)
        .listRowSeparator(.hidden)
        .help(item.accessibilityLabel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.accessibilityLabel)
        .contextMenu {
            if let note {
                AISummaryMenuCommands(model: model, target: .page(note.id))
                Button(note.isEditingLocked ? "Unlock Editing" : "Lock Editing") {
                    model.toggleEditingLock(note.id)
                }
                .disabled(model.editingLockOperations.contains(note.id))
                Button("Delete…", role: .destructive) { trashPageID = note.id; showTrashConfirmation = true }
                    .disabled(!Self.canTrashPage(note, model: model))
            }
        }
    }
    static func canTrashPage(_ note: NoteRecord, model: AppModel) -> Bool {
        !note.isEditingLocked && !model.editingLocked && !model.externalChange && !model.editingLockOperations.contains(note.id)
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
        if model.scope == .trash { trashLibrary } else { pageLibrary }
    }
    private var fullSearchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NoemaSpacing.md) {
                VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
                    Text(model.searchMode == .quickOpen ? "Quick Open" : "Search Results")
                        .font(NoemaTypography.sectionHeader)
                    Text(model.searchText.isEmpty
                         ? "\(model.visibleSearchResults.totalCount) results · \(model.searchScope.title)"
                         : "“\(model.searchText)” · \(model.visibleSearchResults.totalCount) results · \(model.searchScope.title)")
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Return to workspace") { showAllSearchResults = false }
                    .help("Return to the previously open document or library")
            }
            .padding(.horizontal, NoemaSpacing.lg).padding(.vertical, NoemaSpacing.md)
            List { searchResultSections }.listStyle(.inset)
        }
        .foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
        .background(theme.color(for: .canvas))
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
                if model.busy || model.errorMessage != nil {
                    VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                        if model.busy {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small).accessibilityLabel("Updating library").accessibilityValue("In progress")
                            }
                        }
                        if let error = model.errorMessage {
                            DismissibleNotice(message: error, surface: .canvas) { model.errorMessage = nil }
                        }
                    }
                    .padding(.horizontal, NoemaSpacing.lg)
                    .padding(.vertical, NoemaSpacing.sm)
                }
            }
        } else {
            pageLibraryContent
        }
    }
    private var pageLibraryContent: some View {
        VStack(spacing: 0) {
            if model.scope == .semantic {
                KnowledgeLibraryView(model: model) { semanticBlockList }
            } else if model.rows.isEmpty {
                ContentUnavailableView("\(model.scopeTitle) is empty", systemImage: model.scope == .sources ? "tray" : "doc.text.magnifyingglass", description: Text(model.scope == .sources ? "Import a text file or paste a source to begin." : "Create a page to start building your wiki."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(sortedPageRows) { row in
                        let note = row.kind == .wiki ? model.notes.first(where: { $0.id == row.id }) : nil
                        let deleteDisabled = note.map { !Self.canTrashPage($0, model: model) } ?? true
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if row.kind == .wiki, model.unseenRenamedPages.contains(row.id) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Color(nsColor: .systemBlue))
                                        .help("Page renamed since you last viewed it")
                                        .accessibilityLabel("Unread title change")
                                }
                                Text(row.title).font(NoemaTypography.interfaceEmphasis).lineLimit(1)
                                if note?.isEditingLocked == true {
                                    Image(systemName: "lock.fill")
                                        .font(NoemaTypography.metadata)
                                        .foregroundStyle(.secondary)
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
                            if !row.excerpt.isEmpty {
                                Text(row.excerpt.replacingOccurrences(of: "\n", with: " "))
                                    .font(NoemaTypography.metadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .padding(.horizontal, NoemaSpacing.sm)
                        .padding(.vertical, 4)
                        .tag(row.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if row.kind == .wiki {
                                Button(role: .destructive) { trashPageID = row.id; showTrashConfirmation = true } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(deleteDisabled)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if let note {
                                Button { model.toggleEditingLock(row.id) } label: {
                                    Label(note.isEditingLocked ? "Unlock Editing" : "Lock Editing", systemImage: note.isEditingLocked ? "lock.open" : "lock")
                                }.disabled(model.editingLockOperations.contains(note.id))
                            }
                        }
                        .contextMenu {
                            if let note {
                                AISummaryMenuCommands(model: model, target: .page(note.id))
                                Button(note.isEditingLocked ? "Unlock Editing" : "Lock Editing") { model.toggleEditingLock(row.id) }
                                    .disabled(model.editingLockOperations.contains(note.id))
                                Button("Delete…", role: .destructive) { trashPageID = row.id; showTrashConfirmation = true }
                                    .disabled(deleteDisabled)
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
            if model.scope == .semantic, model.knowledgeFamily == .blocks, (!model.semanticRows.isEmpty || model.busy) {
                VStack(spacing: 0) {
                    SemanticBlocksFilterBar(options: semanticFilterOptions, selectedSemantic: $selectedSemanticFilter, busy: model.busy)
                    Picker("Block status", selection: $selectedSemanticStatus) {
                        Text("All statuses").tag(nil as String?)
                        ForEach(Array(Set(model.semanticRows.compactMap(\.status))).sorted(), id: \.self) { status in
                            Text(status.capitalized).tag(status as String?)
                        }
                    }.pickerStyle(.menu).controlSize(.small).padding(.horizontal, NoemaSpacing.md).padding(.bottom, NoemaSpacing.sm)
                }
            } else if (isPagesScope && !model.tags.isEmpty) || model.busy {
                HStack(spacing: NoemaSpacing.sm) {
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
                                if model.activeTagFilter != nil {
                                    Button("Clear filter") { model.changeScope(.wiki) }
                                        .font(NoemaTypography.metadata)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if model.busy {
                        ProgressView().controlSize(.small).accessibilityLabel("Updating library").accessibilityValue("In progress")
                    }
                }
                .padding(.horizontal, NoemaSpacing.md)
                .padding(.vertical, 6)
            }
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
                Text("Automatically deleted after 15 days").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                Spacer()
                Button { model.performWorkspaceCommand(.refresh) } label: { Label("Refresh Trash", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .help("Refresh Trash").disabled(model.trashOperationInProgress || !model.canPerformWorkspaceCommand(.refresh))
                Button("Empty Trash…", role: .destructive) { emptyTrashPages = model.trashedPages; showEmptyTrash = true }
                    .disabled(model.trashedPages.isEmpty || model.trashOperationInProgress)
            }.padding(.horizontal, NoemaSpacing.lg).padding(.vertical, NoemaSpacing.sm)
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
                if let notice = model.aiSummaryNotice {
                    DismissibleNotice(message: notice, isError: false, surface: .canvas) { model.aiSummaryNotice = nil }
                        .font(NoemaTypography.metadata)
                        .padding(.vertical, NoemaSpacing.md)
                        .readingColumn(reservesEditorGutter: true)
                }
                // Native text views already provide the document's 24 pt top inset.
                ZStack(alignment: .topLeading) {
                    if let source = model.currentSource, sourceOriginal || source.metadata.storedFilename.hasSuffix(".txt") {
                        MarkdownEditor(text: .constant(model.body), action: nil, onWikiQuery: { _ in }, editable: false)
                    } else if model.currentNote != nil {
                        SummarizedArticleView(model: model, showsSummary: (AISummaryPlacement(rawValue: aiSummaryPlacement) ?? .defaultValue).showsInEditor(sidebarVisible: isInspectorPresented))
                            .id(model.selectedID)
                    } else { MarkdownPreview(blocks: model.preview, onWikiLink: model.followWikiLink) }
                    if model.canEditPage, model.currentNote != nil, model.wikiQuery != nil, !model.linkSuggestions.isEmpty {
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
            .onChange(of: model.editorDocument) { model.edited() }
            .onChange(of: model.title) { model.edited() }
            .onChange(of: model.tagInput) { model.edited() }
        } else {
            VStack(spacing: 18) {
                NoemaMark(presentation: .identity).frame(width: 76, height: 76).accessibilityHidden(true)
                Text(model.scope == .sources ? "Keep the original. Find your meaning." : "A personal atlas of thought.").font(.title2.weight(.medium))
                Text(model.scope == .sources ? "Browse raw material here. Your interpretations belong in the wiki." : "Choose a page, or start with a thought you want to connect.").foregroundStyle(theme.text())
                if model.scope != .sources { Button("New personal page") { model.newPage(template: true) }.buttonStyle(.glass) }
                if let error = model.errorMessage { DismissibleNotice(message: error, surface: .canvas) { model.errorMessage = nil }.frame(maxWidth: 500) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var semanticFilterOptions: [SemanticTypeFilterOption] {
        SemanticCollectionPresentation.availableFilters(from: model.semanticRows)
    }
    private var filteredSemanticRows: [SemanticBlockHit] {
        SemanticCollectionPresentation.filteredRows(model.semanticRows, selectedSemantic: selectedSemanticFilter, selectedStatus: selectedSemanticStatus)
    }
    private var semanticBlockList: some View {
        Group {
            if model.semanticRows.isEmpty {
                ContentUnavailableView("No semantic blocks",
                    systemImage: "tag", description: Text("Search block text, semantic type, or page title."))
                    .frame(maxHeight: .infinity)
            } else if filteredSemanticRows.isEmpty {
                ContentUnavailableView("No matching semantic blocks",
                    systemImage: "line.3.horizontal.decrease.circle", description: Text("Try clearing the semantic type filter or adjusting your search."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { model.selectedSemanticID }, set: { id in
                    if let hit = filteredSemanticRows.first(where: { $0.id == id }) {
                        model.select(hit.pageID, block: hit.blockID)
                    }
                })) {
                    ForEach(filteredSemanticRows) { hit in
                        SemanticBlockCollectionRow(hit: hit)
                            .tag(hit.id)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
    }
    private var libraryCount: String {
        if model.scope == .semantic {
            if model.knowledgeFamily != .blocks { return model.knowledgeFamily.rawValue }
            return SemanticCollectionPresentation.countLabel(
                filteredCount: filteredSemanticRows.count,
                totalCount: model.semanticRows.count,
                selectedSemantic: selectedSemanticFilter ?? selectedSemanticStatus
            )
        }
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
            ToolbarItem(id: "workspace.search", placement: .primaryAction) {
                ToolbarSearchView(model: model, availableWidth: workspaceWidth) {
                    showAllSearchResults = true
                }
            }
            if isPagesScope && model.currentNote == nil && model.currentSource == nil && !showAllSearchResults {
                ToolbarItem(id: "pages.sort", placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $pageSortOrder) {
                            ForEach(PageSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort pages (\(pageSortOrder.rawValue))")
                    .accessibilityLabel("Sort Pages")
                    .accessibilityValue(pageSortOrder.rawValue)
                }
            }
            ToolbarItem(id: "workspace.add", placement: .primaryAction) {
                Menu {
                    workspaceCommandButton("Blank Page", .newPage)
                    workspaceCommandButton("Personal Page", .newPersonalPage)
                    workspaceCommandButton("Create Page with AI…", .newTopicPage)
                        .disabled(model.generatingTopicPage)
                    Divider()
                    workspaceCommandButton("Source from Files…", .addSource)
                    workspaceCommandButton("Source by URL…", .addURLSource)
                    workspaceCommandButton("Paste a Source…", .pasteSource)
                } label: {
                    Label("Add Page or Source", systemImage: "plus")
                } primaryAction: {
                    model.performWorkspaceCommand(.newPage)
                }
                .disabled(!model.canPerformWorkspaceCommand(.newPage))
                .help("Add a page or source")
                .accessibilityLabel("Add Page or Source")
            }
            if let note = model.currentNote {
                ToolbarItem(id: "document.lock", placement: .primaryAction) {
                    Button { model.toggleEditingLock() } label: {
                        Label(note.isEditingLocked ? "Unlock Editing" : "Lock Editing", systemImage: note.isEditingLocked ? "lock.fill" : "lock.open")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.editingLockOperations.contains(note.id))
                    .help(note.isEditingLocked ? "Unlock Editing" : "Lock Editing")
                    .accessibilityLabel(note.isEditingLocked ? "Unlock Editing" : "Lock Editing")
                    .accessibilityValue(note.isEditingLocked ? "Locked" : "Unlocked")
                }
                ToolbarItem(id: "document.trash", placement: .primaryAction) {
                    Button {
                        trashPageID = note.id
                        showTrashConfirmation = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!Self.canTrashPage(note, model: model))
                    .help("Move to Trash")
                    .accessibilityLabel("Move to Trash")
                }
            }
            trailingWorkspaceToolbar
        }
    }
    @ToolbarContentBuilder private var trailingWorkspaceToolbar: some ToolbarContent {
        ToolbarItem(id: "workspace.more", placement: .primaryAction) {
            Menu {
                if let note = model.currentNote {
                    Button {
                        pageName = model.title
                        renamingPageID = note.id
                    } label: { Label("Rename Page…", systemImage: "pencil") }
                    .disabled(model.editingLocked || model.externalChange)
                    AISummaryMenuCommands(model: model, target: .page(note.id))
                    Divider()
                    Button(role: .destructive) {
                        trashPageID = note.id
                        showTrashConfirmation = true
                    } label: { Label("Move Page to Trash…", systemImage: "trash") }
                    .disabled(!Self.canTrashPage(note, model: model))
                    Divider()
                } else if let source = model.currentSource {
                    Button {
                        sourceName = source.title
                        renamingSource = source
                    } label: { Label("Rename Source…", systemImage: "pencil") }
                    AISummaryMenuCommands(model: model, target: .source(source.id))
                    if source.metadata.storedFilename.hasSuffix(".md") {
                        Picker("Source View", selection: $sourceOriginal) {
                            Text("Read").tag(false)
                            Text("Original").tag(true)
                        }
                    }
                    Divider()
                    Button(role: .destructive) { deletingSource = source } label: {
                        Label("Delete Source…", systemImage: "trash")
                    }
                    Divider()
                } else if model.scope == .sources {
                    Button("Check Availability of All Sources") { model.checkSourceAvailability(model.sources) }
                        .disabled(model.sources.isEmpty || !model.checkingSourceAvailability.isEmpty)
                    Divider()
                }
                workspaceCommandButton("Open Another Vault…", .openVault)
                workspaceCommandButton("Reveal Vault in Finder", .revealVault)
                workspaceCommandButton("Refresh from Files", .refresh)
                workspaceCommandButton("Trash", .showTrash)
                workspaceCommandButton("Vault Notices (\(model.issues.count))", .notices)
                workspaceCommandButton("Recover Drafts (\(model.recoveredDrafts.count))" + (model.damagedRecoveryEntries.isEmpty ? "" : " · \(model.damagedRecoveryEntries.count) damaged"), .recovery)
                Divider()
                workspaceCommandButton("Lock Vault", .lock)
                workspaceCommandButton("Close Vault", .close)
            } label: {
                Label("Document and Vault Options", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Document and vault options")
            .accessibilityLabel("Document and Vault Options")
        }
        ToolbarItem(id: "workspace.inspector", placement: .primaryAction) { inspectorToolbarToggle }
    }
    private var pageFooter: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            if let hint = model.editingHint {
                Text(hint)
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
            }
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
                if model.canEditPage {
                    Text("/ commands · ⌘-click to open links").font(NoemaTypography.metadata).foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
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
                        Text(draft.contentBody.prefix(240)).font(.caption).foregroundStyle(theme.text()).textSelection(.enabled)
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
    @State private var mode = "topic"
    @State private var input = ""
    @State private var sourceID: UUID?
    @State private var retainSource = true
    @State private var reviewedTitle = ""

    private func launch(_ operation: @escaping @MainActor () async -> Void) {
        model.aiPageTask = Task { await operation() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Page with AI").font(.title2.bold())
            if let submission = model.aiPageSubmission {
                Text("Send this selected text to OpenAI? It leaves your device and API charges may apply.")
                Text("OpenAI · \(submission.model) · \(submission.request.contentByteCount) bytes").font(.caption)
                ScrollView { Text(submission.request.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelAIPage(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Send to OpenAI") { launch { await model.generateCloudAIPage() } }.keyboardShortcut(.defaultAction)
                }
            } else if let draft = model.aiPageDraft {
                TextField("Page title", text: $reviewedTitle).textFieldStyle(.roundedBorder)
                Text(draft.enrichment.summary).font(.callout).foregroundStyle(.secondary)
                if let classification = draft.enrichment.classification {
                    Text(classification.code + " · " + classification.caption).font(.caption)
                } else { Text("Classification unavailable").font(.caption).foregroundStyle(.secondary) }
                ScrollView { Text((draft.enrichment.body ?? "") + draft.context.references).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 300)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelAIPage(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Publish Page") { launch { if await model.publishAIPageDraft(title: reviewedTitle) { dismiss() } } }
                        .keyboardShortcut(.defaultAction).disabled(reviewedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.generatingTopicPage)
                }
            } else {
                Picker("Input", selection: $mode) {
                    Text("Source").tag("source")
                    Text("Topic").tag("topic")
                    Text("URL").tag("url")
                }.pickerStyle(.segmented).disabled(model.generatingTopicPage)
                Text("Provider: " + model.preferredAIProvider(for: .composePage, temporaryOverride: model.aiPageProviderOverride).displayName)
                    .font(.caption).foregroundStyle(.secondary)
                if mode == "source" {
                    Picker("Source", selection: $sourceID) {
                        Text("Choose a source").tag(nil as UUID?)
                        ForEach(model.sources) { source in Text(source.title).tag(Optional(source.id)) }
                    }
                } else {
                    TextField(mode == "topic" ? "Topic" : "https://example.com/article", text: $input).textFieldStyle(.roundedBorder)
                    Text(mode == "topic" ? "Your topic is sent to Bing. Up to three readable results form the draft's evidence." : "The document is fetched locally. Its extracted text is used to generate the draft.")
                        .font(.callout).foregroundStyle(.secondary)
                    if mode == "url" { Toggle("Retain fetched document as a linked source", isOn: $retainSource) }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelAIPage(); dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Generate Draft") {
                        launch {
                            let request: AIPageInput
                            if mode == "source", let sourceID { request = .source(sourceID) }
                            else if mode == "url" { request = .url(input, retainSource: retainSource) }
                            else { request = .topic(input) }
                            _ = await model.prepareAIPage(request)
                        }
                    }.keyboardShortcut(.defaultAction)
                    .disabled(model.generatingTopicPage || (mode == "source" ? sourceID == nil : input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            if model.generatingTopicPage { NoemaLoadingStatus("Preparing draft…") }
            if let error = model.errorMessage { DismissibleNotice(message: error) { model.errorMessage = nil } }
        }.padding(24).frame(width: 580).interactiveDismissDisabled(model.generatingTopicPage)
        .onAppear {
            sourceID = model.aiPageSourceID
            if sourceID != nil { mode = "source" }
        }
        .onChange(of: model.aiPageDraft?.id) { _, _ in reviewedTitle = model.aiPageDraft?.enrichment.title ?? "" }
        .onDisappear { model.cancelAIPage(); model.aiPageSourceID = nil; model.aiPageProviderOverride = nil }
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
    private var isVisible: Bool {
        NoemaChromePresentation.lockActionVisible(locked: locked, revealed: visible, pending: pending, focused: focused, voiceOver: voiceOver)
    }
    var body: some View {
        Button(action: toggle) {
            Image(systemName: locked ? "lock.fill" : "lock.open")
                .font(NoemaTypography.caption)
                .noemaChromeForeground(.textSecondary)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace, options: .speed(3)))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: locked)
                .opacity(isVisible ? 1 : 0)
                .frame(width: isVisible ? NoemaMetrics.iconWidth : 0)
                .frame(minWidth: isVisible ? 20 : 0, minHeight: NoemaMetrics.compactRowHeight)
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

@MainActor enum ToolbarSplitMenuPresenter {
    static func findSegmentedControl(forSymbol symbolName: String, in window: NSWindow?) -> NSSegmentedControl? {
        guard let root = window?.contentView?.superview else { return nil }
        let controls = segmentedControls(in: root).filter {
            $0.segmentCount == 2 && $0.menu(forSegment: 1) != nil
        }
        if let event = NSApp.currentEvent, event.window === window {
            for control in controls {
                let point = control.convert(event.locationInWindow, from: nil)
                if control.bounds.contains(point) {
                    return control
                }
            }
        }
        return controls.first {
            $0.image(forSegment: 0)?.description.contains("symbol = \(symbolName)") == true
        }
    }

    @discardableResult
    static func presentMenu(forSymbol symbolName: String, in window: NSWindow? = nil) -> Bool {
        let targetWindow = window ?? NSApp.currentEvent?.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let control = findSegmentedControl(forSymbol: symbolName, in: targetWindow),
              let menu = control.menu(forSegment: 1) else {
            return false
        }
        let origin = NSPoint(x: 0, y: control.isFlipped ? control.bounds.maxY + 4 : control.bounds.minY - 4)
        menu.popUp(positioning: nil, at: origin, in: control)
        return true
    }

    private static func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        var result: [NSSegmentedControl] = []
        if let segmented = view as? NSSegmentedControl {
            result.append(segmented)
        }
        for subview in view.subviews {
            result.append(contentsOf: segmentedControls(in: subview))
        }
        return result
    }
}

