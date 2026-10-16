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
    @State private var showFavourites = false
    @State private var showRecentItems = false
    @State private var organisationSelection: UUID?
    @State private var organisationName = ""
    @State private var organisationKind: OrganisationContainerKind = .collection
    @State private var organisationParent: UUID?
    @State private var renamingContainer: OrganisationContainer?
    @State private var showOrganisationName = false
    @State private var deletingContainer: OrganisationContainer?
    @State private var showDeleteContainer = false
    @State private var organisationKnowledgeSelection: KnowledgeCatalogueSelection?
    @State private var inboxSelection: RecentItemID?
    @State private var inboxDragSelection: Set<OrganisationItemReference> = []
    @State private var pageDragSelection: Set<UUID> = []
    @State private var semanticDragSelection: Set<String> = []
    @State private var folderDragSelection: Set<UUID> = []
    @State private var collapsedOrganisationContainers: Set<UUID> = []
    @State private var organisationDropTarget: UUID?
    @State private var rootDropTarget = false
    @State private var organisationHeaderHovered = false
    @State private var showTrashConfirmation = false
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
    @State private var pageListScroll = ScrollPosition(idType: UUID.self)
    @State private var semanticListScroll = ScrollPosition(idType: String.self)
    @State private var sourceListScroll = ScrollPosition(idType: UUID.self)
    @State private var knowledgeQuery = ""
    @State private var knowledgeSelection: KnowledgeCatalogueSelection?
    @FocusState private var collectionListFocused: Bool
    @State private var pendingLibraryFocus = false
    private var sourceSelection: UUID? { model.librarySourceSelection }
    private var sourceSelectionBinding: Binding<UUID?> {
        Binding(get: { model.librarySourceSelection }, set: { model.setLibrarySourceSelection($0) })
    }
    @State private var sourceTablePresentation: SourcesTablePresentation = {
        let presentation = SourcesTablePresentation()
        presentation.setInboxSortOrder(.captured)
        return presentation
    }()
    @State private var renamingSource: SourceRecord?
    @State private var sourceName = ""
    @State private var renamingPageID: UUID?
    @State private var pageName = ""
    @State private var deletingSource: SourceRecord?
    @AppStorage(EditorPreferences.aiSummaryPlacementKey) private var aiSummaryPlacement = AISummaryPlacement.defaultValue.rawValue
    init(model: AppModel, paneState: WorkspacePaneState? = nil, collapsedContainers: Set<UUID> = [], organisationSelection: UUID? = nil) {
        self.model = model
        _organisationSelection = State(initialValue: organisationSelection)
        _collapsedOrganisationContainers = State(initialValue: collapsedContainers)
        let panes = paneState ?? WorkspacePaneState()
        _paneState = State(initialValue: panes)
        _inspectorState = State(initialValue: InspectorState(paneState: panes))
    }
    private var contentMinimum: CGFloat { WorkspacePaneState.contentMinimum }
    private var panePresentation: WorkspacePanePresentation {
        paneState.presentation(
            width: workspaceWidth, mainMinimum: contentMinimum,
            inspectorAvailable: inspectorContext.isInspectable,
            contentPreferred: WorkspacePaneState.contentPreferred
        )
    }
    private var isInspectorPresented: Bool {
        model.isVaultAvailable && (panePresentation.inspector || panePresentation.inspectorOverlay)
    }
    private var paneActions: WorkspacePaneActions {
        WorkspacePaneActions(
            toggleSidebar: toggleSidebarPane,
            toggleCollection: toggleCollectionPane,
            toggleInspector: toggleInspectorPane,
            sidebarPresented: model.isVaultAvailable && panePresentation.sidebar,
            collectionPresented: model.isVaultAvailable && panePresentation.collection,
            inspectorPresented: isInspectorPresented,
            canToggleSidebar: model.canInteractWithWorkspace && model.isVaultAvailable && workspaceWidth >= contentMinimum + WorkspacePaneState.sidebarMinimum + 1,
            canToggleCollection: model.canInteractWithWorkspace && model.isVaultAvailable && workspaceWidth >= contentMinimum + WorkspacePaneState.collectionMinimum + 1,
            canToggleInspector: model.canInteractWithWorkspace && model.isVaultAvailable && inspectorContext.isInspectable
        )
    }
    private func toggleSidebarPane() {
        guard paneActions.canToggleSidebar else { return }
        paneState.toggleSidebar(presented: panePresentation.sidebar)
    }
    private func toggleCollectionPane() {
        guard paneActions.canToggleCollection else { return }
        paneState.toggleCollection(presented: panePresentation.collection)
    }
    private func toggleInspectorPane() {
        guard paneActions.canToggleInspector else { return }
        paneState.toggleInspector(presented: isInspectorPresented)
    }
    private var inspectorContext: InspectorContext {
        InspectorContext.resolve(model: model, librarySourceSelection: sourceSelection)
    }
    private func switchSidebarScope(_ scope: LibraryScope) {
        showFavourites = false
        organisationKnowledgeSelection = nil
        organisationSelection = nil
        showRecentItems = false
        inboxSelection = nil
        inboxDragSelection = []; pageDragSelection = []; semanticDragSelection = []
        folderDragSelection = []
        showAllSearchResults = false
        SourcesPerformance.event("SidebarScopeChange")
        model.changeScope(scope)
    }
    private func resetLocalWorkspaceState() {
        showFavourites = false
        organisationSelection = nil
        inboxDragSelection = []; pageDragSelection = []; semanticDragSelection = []; folderDragSelection = []
        collapsedOrganisationContainers = []
        organisationDropTarget = nil
        rootDropTarget = false
        organisationHeaderHovered = false
        showOrganisationName = false
        renamingContainer = nil
        organisationParent = nil
        organisationName = ""
        showDeleteContainer = false
        deletingContainer = nil
        organisationKnowledgeSelection = nil
        showRecentItems = false
        inboxSelection = nil
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
        dismissedExternalChange = false
        sourceOriginal = false
        showAllSearchResults = false
        selectedSemanticFilter = nil; selectedSemanticStatus = nil
        knowledgeQuery = ""
        knowledgeSelection = nil
        pageListScroll = ScrollPosition(idType: UUID.self)
        semanticListScroll = ScrollPosition(idType: String.self)
        sourceListScroll = ScrollPosition(idType: UUID.self)
        pendingLibraryFocus = false
    }
    private var workspacePresentation: some View {
        Group {
            if model.isLocked {
                lockedVaultView
            } else if !model.isVaultAvailable {
                welcome
            } else {
                GeometryReader { geometry in
                    let presentation = paneState.presentation(
                        width: geometry.size.width, mainMinimum: contentMinimum,
                        inspectorAvailable: inspectorContext.isInspectable,
                        contentPreferred: WorkspacePaneState.contentPreferred
                    )
                    HSplitView {
                        if presentation.sidebar {
                            sidebar.frame(minWidth: WorkspacePaneState.sidebarMinimum, idealWidth: paneState.sidebarWidth, maxWidth: WorkspacePaneState.sidebarMaximum, maxHeight: .infinity)
                        }
                        if presentation.collection {
                            collectionPane
                                .frame(minWidth: WorkspacePaneState.collectionMinimum, idealWidth: paneState.collectionWidth, maxWidth: WorkspacePaneState.collectionMaximum, maxHeight: .infinity)
                        }
                        contentColumn(presentation: presentation, availableWidth: geometry.size.width)
                        if presentation.inspector {
                            inspectorColumn(flexibleWidth: false)
                                .frame(idealWidth: paneState.inspectorWidth)
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
        .focusedSceneValue(\.workspacePaneActions, paneActions)
        .toolbar(removing: .sidebarToggle)
        .toolbar { workspaceToolbar }
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
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
    private var workspaceContentObservers: some View {
        workspaceConfirmations
        .onChange(of: model.semanticInspectionOpenRequest) {
            guard case .page = inspectorContext else { return }
            inspectorState.isVisible = true
            inspectorState.selectTab(.insights, for: inspectorContext)
        }
        .onChange(of: model.searchText) { model.queryChanged() }
        .onChange(of: model.editorDocument) { if model.isSearching || model.searchMode == .quickOpen || model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.title) { if model.isSearching || model.searchMode == .quickOpen || model.scope == .semantic { model.queryChanged() } }
        .onChange(of: model.selectedID) {
            sourceOriginal = false; dismissedExternalChange = false; showAllSearchResults = false
            if pageDragSelection.count <= 1 { pageDragSelection = Set(model.selectedID.map { [$0] } ?? []) }
        }
        .onChange(of: model.scope) {
            showAllSearchResults = false
            selectedSemanticFilter = nil
            selectedSemanticStatus = nil
            if model.scope != .sources { model.setLibrarySourceSelection(nil) }
        }
    }
    private var workspaceNavigationObservers: some View {
        workspaceContentObservers
        .onChange(of: model.workspaceNavigationToken) {
            showAllSearchResults = false
            if model.currentNote == nil && model.currentSource == nil {
                pendingLibraryFocus = false
                revealCollectionList()
            } else {
                pendingLibraryFocus = true
            }
        }
        .onChange(of: model.currentNote) { completeLibraryFocus() }
        .onChange(of: model.currentSource) { completeLibraryFocus() }
        .onChange(of: model.librarySourceSelection) { _, id in
            guard model.scope == .sources, let id, model.currentSource?.id != id else { return }
            model.select(id)
        }
        .onChange(of: model.currentSource?.id) { _, id in
            guard model.scope == .sources, model.librarySourceSelection != id else { return }
            model.setLibrarySourceSelection(id)
        }
    }
    var body: some View {
        workspaceNavigationObservers
        .onChange(of: model.externalChange) { dismissedExternalChange = false }
        // UI.R.REM02: Reconcile even while the inspector is hidden or unmounted.
        .onChange(of: inspectorContext.targetID, initial: true) {
            inspectorState.reconcile(with: inspectorContext)
        }
        .onChange(of: inspectorContext.targetKind) {
            inspectorState.reconcile(with: inspectorContext)
        }
        .onChange(of: model.selectedSemanticID) {
            if semanticDragSelection.count <= 1 { semanticDragSelection = Set(model.selectedSemanticID.map { [$0] } ?? []) }
        }
        .onChange(of: sortedPageRows.map(\.id)) { pageDragSelection.formIntersection(Set(sortedPageRows.map(\.id))) }
        .onChange(of: model.organisationContainers) {
            collapsedOrganisationContainers.formIntersection(Set(model.organisationContainers.map(\.id)))
            folderDragSelection.formIntersection(Set(model.organisationContainers.filter { $0.kind == .folder }.map(\.id)))
            if let id = organisationSelection, !model.organisationContainers.contains(where: { $0.id == id }) {
                organisationSelection = nil
                organisationKnowledgeSelection = nil
                inboxSelection = nil
            }
        }
        .onChange(of: model.organisationMemberships) {
            if let container = selectedOrganisation {
                inboxDragSelection.formIntersection(Set(model.organisationMemberships.filter { $0.containerID == container.id }.map(\.reference)))
            }
            if selectedOrganisation != nil, let id = inboxSelection, !inboxItems.contains(where: { $0.id == id }) {
                inboxSelection = nil
            }
        }
        .onChange(of: model.root) { resetLocalWorkspaceState() }
        .onChange(of: model.sessionState) {
            if !model.isVaultAvailable {
                resetLocalWorkspaceState()
            }
        }
        .onChange(of: panePresentation.inspector) { _, inline in
            if inline { paneState.clearInspectorOverlayDismissal() }
        }
    }
    private func contentColumn(presentation: WorkspacePanePresentation, availableWidth: CGFloat) -> some View {
        let minimum = presentation.contentMinimum(
            in: availableWidth, floor: contentMinimum, preferred: WorkspacePaneState.contentPreferred
        )
        return contentPane
            .frame(minWidth: minimum, maxHeight: .infinity)
            .transaction { $0.animation = nil }
            .background(WorkspaceSplitViewPersistence(state: paneState, presentation: presentation, mainMinimum: minimum))
            .overlay(alignment: .trailing) {
                if presentation.inspectorOverlay {
                    inspectorColumn(flexibleWidth: true)
                        .frame(width: inspectorOverlayWidth(in: availableWidth))
                        .background(theme.color(for: .inspector))
                        .overlay(alignment: .leading) { Divider().overlay(theme.color(for: .separator)) }
                        .accessibilityHint("Temporary overlay. Press Escape to dismiss.")
                        .onExitCommand { paneState.dismissInspectorOverlay() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.currentNote != nil || model.currentSource != nil ? "Editor" : "Content")
    }
    private func inspectorOverlayWidth(in availableWidth: CGFloat) -> CGFloat {
        let preferred = min(paneState.inspectorWidth, InspectorState.maxWidth)
        let ceiling = max(160, availableWidth - 48)
        return min(preferred, ceiling)
    }
    private func inspectorColumn(flexibleWidth: Bool) -> some View {
        InspectorContainer(
            model: model,
            state: inspectorState,
            context: inspectorContext,
            flexibleWidth: flexibleWidth,
            onCloseSourceSelection: { model.setLibrarySourceSelection(nil) }
        )
    }
    private func completeLibraryFocus() {
        guard pendingLibraryFocus else { return }
        pendingLibraryFocus = false
        if model.currentNote == nil && model.currentSource == nil {
            revealCollectionList()
        }
    }
    private func revealCollectionList() {
        paneState.revealCollection()
        collectionListFocused = false
        Task { @MainActor in collectionListFocused = true }
    }
    private var collectionTitle: String {
        if let container = selectedOrganisation { return container.name }
        if showFavourites { return "Favorites" }
        if showRecentItems { return "Recent Items" }
        return switch model.scope {
        case .wiki, .tag: "Pages"
        case .sources: "Sources"
        case .semantic: "Knowledge"
        case .trash: "Trash"
        }
    }
    private var emptySelectionDescription: String {
        switch model.scope {
        case .sources: "Select a source to read it."
        case .semantic: "Select a semantic block to open its page."
        case .trash: "Restore an item from the list, or return to a collection."
        default: "Select a page to edit it."
        }
    }
    @ViewBuilder private var collectionPane: some View {
        VStack(spacing: 0) {
            if showsCollectionHeader { collectionHeader }
            if selectedOrganisation != nil || showFavourites || showRecentItems {
                sharedInbox
                    .dropDestination(for: String.self) { values, _ in
                        guard let container = selectedOrganisation else { return false }
                        return model.receiveOrganisationDrop(values, into: container.id)
                    }
            } else if model.scope == .trash {
                trashLibrary
            } else {
                pageLibrary
            }
        }
        .background(theme.color(for: .canvas))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(collectionTitle)
    }
    private var collectionChromeTitle: String? {
        WorkspaceTitleOwnership.collectionChromeTitle(window: model.windowTitle, collectionName: collectionTitle)
    }
    private var showsCollectionHeader: Bool {
        selectedOrganisation != nil || collectionChromeTitle != nil || isPagesScope || isSourcesScope
    }
    private var collectionHeader: some View {
        HStack(spacing: NoemaSpacing.sm) {
            if let title = selectedOrganisation?.name ?? collectionChromeTitle {
                Text(title)
                    .font(NoemaTypography.sectionHeader)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            if let container = selectedOrganisation {
                Menu {
                    Button("New Folder…") { beginOrganisationName(kind: .folder, parent: container.id) }
                    Button("Rename…") { beginOrganisationName(container: container) }
                    Divider()
                    Button("Delete…", role: .destructive) { deletingContainer = container; showDeleteContainer = true }
                } label: { Label("Container Options", systemImage: "ellipsis").labelStyle(.iconOnly) }
                .menuIndicator(.hidden)
                .help("Collection or folder options")
                .disabled(!model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress)
            } else if isPagesScope { pagesSortMenu }
            else if isSourcesScope { sourcesSortMenu }
        }
        .padding(.horizontal, NoemaSpacing.md)
        .padding(.vertical, NoemaSpacing.sm)
    }
    private var pagesSortMenu: some View {
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
    private var sourcesSortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { sourceTablePresentation.inboxSortOrder },
                set: { sourceTablePresentation.setInboxSortOrder($0) }
            )) {
                ForEach(SourceInboxSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort sources (\(sourceTablePresentation.inboxSortOrder.rawValue))")
        .accessibilityLabel("Sort Sources")
        .accessibilityValue(sourceTablePresentation.inboxSortOrder.rawValue)
    }
    @ViewBuilder private var contentPane: some View {
        if showAllSearchResults {
            fullSearchResults
        } else if model.currentNote != nil || model.currentSource != nil {
            detail
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: model.scope == .sources ? "tray" : "doc.text",
                description: Text(emptySelectionDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color(for: .canvas))
        }
    }
    private var lockedVaultView: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill")
                .font(.largeTitle.weight(.medium))
                .foregroundStyle(theme.text(for: .textSecondary, on: .window))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(model.vaultName)
                    .font(.largeTitle.weight(.semibold))
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
                Text("Noema").font(.largeTitle.weight(.medium))
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
    private var isSourcesScope: Bool {
        selectedOrganisation == nil && !showFavourites && !showRecentItems && model.scope == .sources
    }
    private var isPagesScope: Bool {
        if selectedOrganisation != nil { return false }
        if showFavourites { return true }
        if showRecentItems { return false }
        if case .wiki = model.scope { return true }
        if case .tag = model.scope { return true }
        return false
    }
    private var sidebarSelection: WorkspaceSidebarSelection? {
        if selectedOrganisation != nil { return nil }
        if showFavourites { return .favorites }
        if showRecentItems { return .recentItems }
        return WorkspaceSidebarSelection.resolve(scope: model.scope, explicitRecentItem: nil)
    }
    private var sidebarSelectionBinding: Binding<WorkspaceSidebarSelection?> {
        Binding(get: { sidebarSelection }, set: { selection in
            guard let selection else { return }
            showAllSearchResults = false
            showFavourites = false
            inboxDragSelection = []; folderDragSelection = []
            organisationSelection = nil
            organisationKnowledgeSelection = nil
            showRecentItems = false
            switch selection {
            case .collection(let scope):
                model.setLibrarySourceSelection(nil)
                switchSidebarScope(scope)
            case .favorites:
                openInbox(favorites: true)
            case .recentItems:
                openInbox(favorites: false)
            case .recent(let id):
                model.openSidebarRecentItem(id)
            }
        })
    }
    private func openInbox(favorites: Bool) {
        organisationKnowledgeSelection = nil
        organisationSelection = nil
        showAllSearchResults = false
        showFavourites = favorites
        showRecentItems = !favorites
        inboxSelection = nil
        inboxDragSelection = []; folderDragSelection = []
        model.setLibrarySourceSelection(nil)
        revealCollectionList()
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
                    Divider()
                        .overlay(theme.color(for: .separator).opacity(0.5))
                        .listRowInsets(NoemaSidebarLayout.rowInsets)
                        .listRowSeparator(.hidden)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    NoemaSidebarRowLabel(title: "Favorites", symbol: "star", isSelected: showFavourites)
                        .tag(WorkspaceSidebarSelection.favorites)
                        .listRowInsets(NoemaSidebarLayout.rowInsets)
                        .listRowSeparator(.hidden)
                    NoemaSidebarRowLabel(title: "Recent Items", symbol: "clock", isSelected: showRecentItems)
                        .tag(WorkspaceSidebarSelection.recentItems)
                        .listRowInsets(NoemaSidebarLayout.rowInsets)
                        .listRowSeparator(.hidden)
                }
                organisationSidebarSection
            }
            .alert(renamingContainer == nil ? "New \(organisationKind == .folder ? "Folder" : "Collection")" : "Rename", isPresented: $showOrganisationName) {
                TextField("Name", text: $organisationName)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let container = renamingContainer {
                        model.editOrganisation(.renameContainer(container, organisationName))
                    } else {
                        model.editOrganisation(.create(organisationKind, organisationName, organisationParent))
                    }
                }.disabled(organisationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress)
            }
            .alert("Delete \(deletingContainer?.name ?? "Container")?", isPresented: $showDeleteContainer) {
                Button("Cancel", role: .cancel) { deletingContainer = nil }
                Button("Delete", role: .destructive) {
                    if let container = deletingContainer { model.editOrganisation(.delete(container)) }
                    deletingContainer = nil
                }.disabled(!model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress)
            } message: {
                Text("This removes the collection or folder, its subfolders, and their memberships. Pages, sources, and knowledge items are kept in the vault.")
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
                                            symbol: "doc.text",
                                            relevance: results.relevance["page:\(note.id)"]?.rawValue) {
                                openSearchResult(note.id, scope: .wiki, block: results.pageBlocks[note.id])
                            }
                        }
                    }
                }
                if !results.sources.isEmpty {
                    Section("Sources") {
                        ForEach(results.sources) { source in
                            searchResultRow(title: source.title,
                                            excerpt: results.sourceExcerpts[source.id] ?? "",
                                            symbol: source.metadata.isLinked ? "link" : "tray",
                                            relevance: results.relevance["source:\(source.id)"]?.rawValue) {
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
                                            symbol: SemanticPresentation.find(hit.semantic)?.symbol ?? "tag",
                                            relevance: results.relevance["block:\(hit.id)"]?.rawValue) {
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
        model.openSearchResult(entryID: id, blockID: block, isSource: scope == .sources)
    }
    private func searchResultRow(title: String, excerpt: String, symbol: String, relevance: String? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NoemaSpacing.sm) {
                Image(systemName: symbol).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
                    Text(title).font(NoemaTypography.interfaceEmphasis).lineLimit(1)
                    if let relevance {
                        Text(relevance).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                    }
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
        .accessibilityLabel("\(title), \(relevance ?? ""), \(excerpt)")
        .help(title)
    }
    private func sidebarNavigationRow(_ title: String, symbol: String, scope: LibraryScope) -> some View {
        let isSelected = sidebarSelection == .collection(scope)
        return NoemaSidebarRowLabel(title: title, symbol: symbol, isSelected: isSelected)
            .tag(WorkspaceSidebarSelection.collection(scope))
            .listRowInsets(NoemaSidebarLayout.rowInsets)
            .listRowSeparator(.hidden)
            .accessibilityLabel(title)
            .help(title)
    }
    private var organisationSidebarSection: some View {
        Section {
            ForEach(organisationSidebarRows) { row in
                organisationSidebarContainer(row)
            }
        } header: {
            HStack {
                Text(rootDropTarget ? "Move to Vault Root" : "Collections")
                    .lineLimit(1)
                Spacer(minLength: NoemaSpacing.xs)
                Menu {
                    Button("New Collection…") { beginOrganisationName(kind: .collection) }
                    Button("New Folder…") { beginOrganisationName(kind: .folder) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(organisationHeaderHovered ? 1 : 0.65)
                .accessibilityLabel("New collection or folder")
                .help("New collection or folder")
            }
            .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight)
            .contentShape(Rectangle())
            .background(rootDropTarget ? theme.color(for: .selection) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                if rootDropTarget {
                    RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .onHover { organisationHeaderHovered = $0 }
            .help("Drop folders here to move them to the vault root")
            .dropDestination(for: String.self) { values, _ in
                model.receiveOrganisationDrop(values, into: nil)
            } isTargeted: { rootDropTarget = $0 }
        }
        .disabled(!model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress)
    }
    private func organisationSidebarContainer(_ row: OrganisationSidebarRow) -> some View {
        let selected = organisationSelection == row.container.id || folderDragSelection.contains(row.container.id)
        return NoemaOrganisationSidebarRow(
            title: row.container.name,
            symbol: row.container.kind == .folder ? "folder" : "square.stack",
            depth: row.depth,
            isExpanded: !collapsedOrganisationContainers.contains(row.container.id),
            isSelected: organisationSelection == row.container.id || folderDragSelection.contains(row.container.id),
            onExpansionChange: { expanded in
                if expanded { collapsedOrganisationContainers.remove(row.container.id) }
                else { collapsedOrganisationContainers.insert(row.container.id) }
            },
            onSelect: {
                if row.container.kind == .folder, NSEvent.modifierFlags.contains(.command) {
                    inboxDragSelection = []
                    inboxSelection = nil
                    organisationKnowledgeSelection = nil
                    if folderDragSelection.contains(row.container.id) { folderDragSelection.remove(row.container.id) }
                    else { folderDragSelection.insert(row.container.id) }
                    return
                }
                browseOrganisationContainer(row.container)
            }
        )
        .modifier(OrganisationDragModifier(value: row.container.kind == .folder
            ? model.organisationDragBatch(organisationSidebarRows.filter {
                folderDragSelection.contains(row.container.id) ? folderDragSelection.contains($0.container.id) : $0.container.id == row.container.id
            }.map { OrganisationDrag.container($0.container.id) }) : nil))
        .dropDestination(for: String.self) { values, _ in
            let accepted = model.receiveOrganisationDrop(values, into: row.container.id)
            if accepted { collapsedOrganisationContainers.remove(row.container.id) }
            return accepted
        } isTargeted: { targeted in
            if targeted { organisationDropTarget = row.container.id }
            else if organisationDropTarget == row.container.id { organisationDropTarget = nil }
        }
        .listRowInsets(NoemaSidebarLayout.rowInsets)
        .listRowSeparator(.hidden)
        .noemaOrganisationSidebarRowSurface(selected: selected, targeted: organisationDropTarget == row.container.id)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button(collapsedOrganisationContainers.contains(row.container.id) ? "Expand" : "Collapse") {
                if !collapsedOrganisationContainers.insert(row.container.id).inserted {
                    collapsedOrganisationContainers.remove(row.container.id)
                }
            }
            Divider()
            Button("Rename…") { beginOrganisationName(container: row.container) }
            Button("New Subfolder…") { beginOrganisationName(kind: .folder, parent: row.container.id) }
            if row.container.kind == .folder {
                Menu("Move To") {
                    if row.container.parentID != nil {
                        Button("Vault Root") { model.editOrganisation(.move(row.container, nil)) }
                    }
                    ForEach(organisationDestinations(for: row.container)) { destination in
                        Button(destination.name) { model.editOrganisation(.move(row.container, destination.id)) }
                    }
                }
            }
            if let reference = model.currentFavouriteReference {
                let contains = model.organisationMemberships.contains { $0.containerID == row.container.id && $0.reference == reference }
                Button(contains ? "Remove Current Document" : "Add Current Document") {
                    model.editOrganisation(.membership(row.container.id, reference, !contains))
                }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                deletingContainer = row.container
                showDeleteContainer = true
            }
        }
    }
    private func organisationDestinations(for container: OrganisationContainer) -> [OrganisationContainer] {
        NoemaOrganisationSidebarTree.destinations(for: container, in: model.organisationContainers)
    }
    private var selectedOrganisation: OrganisationContainer? {
        model.organisationContainers.first { $0.id == organisationSelection }
    }
    private typealias OrganisationSidebarRow = NoemaOrganisationSidebarEntry
    private var organisationSidebarRows: [OrganisationSidebarRow] {
        NoemaOrganisationSidebarTree.rows(model.organisationContainers, collapsed: collapsedOrganisationContainers)
    }
    private func beginOrganisationName(kind: OrganisationContainerKind = .collection, parent: UUID? = nil, container: OrganisationContainer? = nil) {
        organisationKind = kind
        organisationParent = parent
        renamingContainer = container
        organisationName = container?.name ?? ""
        showOrganisationName = true
    }
    private var inboxItems: [SidebarRecentItem] {
        if let container = selectedOrganisation {
            return organisationSidebarItems(in: container.id)
        }
        if showRecentItems { return model.sidebarRecentItems }
        return sortedPageRows.map { row in
            SidebarRecentItem(
                id: row.kind == .wiki ? .page(row.id) : .source(row.id),
                title: row.title, symbol: row.kind == .wiki ? "doc.text" : "doc",
                accessibilityLabel: "\(row.kind == .wiki ? "Page" : "Source"), \(row.title)",
                pageID: row.kind == .wiki ? row.id : nil
            )
        }
    }
    private func organisationSidebarItems(in containerID: UUID) -> [SidebarRecentItem] {
        return model.organisationMemberships.filter { $0.containerID == containerID }.compactMap { membership in
            let reference = membership.reference
            switch reference.kind {
            case .page:
                guard let note = model.notes.first(where: { $0.id == reference.itemID }) else { return nil }
                return SidebarRecentItem(id: .page(note.id), title: note.title, symbol: "doc.text", accessibilityLabel: note.title, pageID: note.id)
            case .source:
                guard let source = model.sources.first(where: { $0.id == reference.itemID }) else { return nil }
                return SidebarRecentItem(id: .source(source.id), title: source.title, symbol: "tray", accessibilityLabel: source.title, pageID: nil)
            case .semanticBlock:
                guard let pageID = reference.pageID else { return nil }
                guard let note = model.notes.first(where: { $0.id == pageID }) else { return nil }
                let content = model.currentNote?.id == pageID ? model.body : note.body
                guard let block = BlockDocumentCodec.decode(content).block(reference.itemID) else { return nil }
                let label = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let semantic = SemanticPresentation.find(block.metadata.semantic)
                return SidebarRecentItem(id: .semanticBlock(pageID: pageID, blockID: reference.itemID),
                    title: label.isEmpty ? "Untitled block" : label, symbol: semantic?.symbol ?? "square.stack",
                    accessibilityLabel: "\(semantic?.title ?? "Knowledge block"), \(label), in \(note.title)", pageID: pageID)
            case .knowledgeEntity, .semanticObject:
                // Rendered below with their dedicated catalogue detail sheet.
                return nil
            }
        }
    }
    private func organisationReference(for id: RecentItemID) -> OrganisationItemReference {
        OrganisationContentsRowPresentation.reference(for: id)
    }
    private func organisationItemDrag(_ reference: OrganisationItemReference) -> String {
        let visible = inboxItems.map { organisationReference(for: $0.id) } + organisationKnowledgeMembers.map(\.reference)
        let references = inboxDragSelection.contains(reference) ? visible.filter { inboxDragSelection.contains($0) } : [reference]
        return model.organisationDragBatch(references.map { value in
            selectedOrganisation.map { OrganisationDrag.movingItem(value, from: $0.id) } ?? OrganisationDrag.item(value)
        })
    }
    private var organisationKnowledgeMembers: [OrganisationMembership] {
        guard let container = selectedOrganisation else { return [] }
        return model.organisationMemberships.filter {
            $0.containerID == container.id && ($0.reference.kind == .knowledgeEntity || $0.reference.kind == .semanticObject)
        }
    }
    private func organisationKnowledgeDetail(_ reference: OrganisationItemReference) -> KnowledgeCatalogueSelection? {
        switch reference.kind {
        case .knowledgeEntity:
            return model.knowledgeCatalogue?.entities.first { $0.entity.id == reference.itemID }.map { .entity($0) }
        case .semanticObject:
            return model.knowledgeCatalogue?.objects.first { $0.object.id == reference.itemID }.map { .object($0) }
        case .page, .source, .semanticBlock: return nil
        }
    }
    private func organisationKnowledgeTitle(_ reference: OrganisationItemReference) -> String {
        switch organisationKnowledgeDetail(reference) {
        case .entity(let value): return value.entity.label
        case .object(let value): return SemanticInspectionTarget.object(value).title
        default: return model.knowledgeCatalogueLoading ? "Loading knowledge item…" : "Knowledge item unavailable"
        }
    }
    private func browseOrganisationContainer(_ container: OrganisationContainer) {
        folderDragSelection = container.kind == .folder ? [container.id] : []
        inboxDragSelection = []
        organisationSelection = container.id
        organisationKnowledgeSelection = nil
        showFavourites = false
        showRecentItems = false
        showAllSearchResults = false
        inboxSelection = nil
        model.setLibrarySourceSelection(nil)
        revealCollectionList()
    }

    private func openOrganisationItem(_ id: RecentItemID) {
        switch id {
        case .page(let pageID): model.select(pageID, scope: .wiki)
        case .source(let sourceID): model.select(sourceID, scope: .sources)
        case .semanticBlock(let pageID, let blockID): model.select(pageID, scope: .wiki, block: blockID)
        }
    }
    private var sharedInbox: some View {
        let items = inboxItems
        let knowledgeMembers = organisationKnowledgeMembers
        let childFolders = model.organisationContainers.filter { $0.parentID == selectedOrganisation?.id && selectedOrganisation != nil }
        let summary = OrganisationContentsSummary(itemCount: items.count + knowledgeMembers.count, folderCount: childFolders.count)
        return VStack(spacing: 0) {
            if summary.isEmpty {
                ContentUnavailableView(
                    "No items yet",
                    systemImage: selectedOrganisation.map { $0.kind == .folder ? "folder" : "square.stack" } ?? (showFavourites ? "star" : "clock"),
                    description: Text(selectedOrganisation != nil ? "Add a document from its menu, or drag items and folders here." : showFavourites
                        ? "Use the star in the document toolbar to add favorites."
                        : "Pages, sources, and knowledge blocks you open appear here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { inboxDragSelection }, set: { references in
                    inboxDragSelection = references
                    if !references.isEmpty { folderDragSelection = [] }
                    guard let reference = OrganisationContentsSelection.itemToOpen(in: references,
                        extendingSelection: NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)) else { return }
                    if let item = items.first(where: { organisationReference(for: $0.id) == reference }) {
                        inboxSelection = item.id
                        if selectedOrganisation != nil { openOrganisationItem(item.id) }
                        else { model.openSidebarRecentItem(item.id) }
                    } else {
                        inboxSelection = nil
                        organisationKnowledgeSelection = organisationKnowledgeDetail(reference)
                    }
                })) {
                    ForEach(childFolders) { folder in
                        Button { browseOrganisationContainer(folder) } label: {
                            HStack(spacing: NoemaSpacing.sm) {
                                OrganisationContentsRowLabel(title: folder.name, symbol: "folder", subtitle: "Folder")
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.plain)
                        .draggable(model.organisationDragBatch([OrganisationDrag.container(folder.id)]))
                        .dropDestination(for: String.self) { values, _ in return model.receiveOrganisationDrop(values, into: folder.id) }
                        .accessibilityLabel("Folder, \(folder.name)")
                        .accessibilityHint("Open folder contents")
                        .contextMenu {
                            Button("Open Folder") { browseOrganisationContainer(folder) }
                            Button("Rename…") { beginOrganisationName(container: folder) }
                            Button("New Subfolder…") { beginOrganisationName(kind: .folder, parent: folder.id) }
                        }
                    }
                    ForEach(items) { item in
                        let note = item.pageID.flatMap { id in model.notes.first { $0.id == id } }
                        OrganisationContentsRowLabel(title: item.title, symbol: item.symbol,
                            subtitle: OrganisationContentsRowPresentation(kind: organisationReference(for: item.id).kind,
                                parentTitle: note?.title).subtitle,
                            isLocked: note?.isEditingLocked == true)
                        .tag(organisationReference(for: item.id))
                        .draggable(organisationItemDrag(organisationReference(for: item.id)))
                        .accessibilityLabel(item.accessibilityLabel)
                        .contextMenu {
                            organisationItemContextMenu(organisationReference(for: item.id), sourceContainerID: selectedOrganisation?.id)
                        }
                    }

                    ForEach(knowledgeMembers) { membership in
                        let reference = membership.reference
                        OrganisationContentsRowLabel(title: organisationKnowledgeTitle(reference),
                            symbol: reference.kind == .knowledgeEntity ? "person.text.rectangle" : "square.stack",
                            subtitle: OrganisationContentsRowPresentation(kind: reference.kind, parentTitle: nil).subtitle,
                            isUnavailable: !model.knowledgeCatalogueLoading && organisationKnowledgeDetail(reference) == nil)
                            .tag(reference)
                            .draggable(organisationItemDrag(reference))
                            .accessibilityHint(organisationKnowledgeDetail(reference) == nil ? "Details unavailable. Use the context menu to remove this membership." : "Open knowledge details")
                        .contextMenu {
                            organisationItemContextMenu(reference, sourceContainerID: selectedOrganisation?.id)
                        }
                    }

                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($collectionListFocused)
            }
            HStack {
                Text(summary.label)
                Spacer()
                Text("⌘P")
            }
            .font(NoemaTypography.metadata)
            .foregroundStyle(.secondary)
            .padding(NoemaSpacing.md)
        }
        .background(theme.color(for: .canvas))
        .task(id: organisationKnowledgeMembers.map(\.reference)) {
            if !organisationKnowledgeMembers.isEmpty { await model.refreshKnowledgeCatalogue() }
        }
        .sheet(item: $organisationKnowledgeSelection) { selected in
            KnowledgeCatalogueDetail(model: model, selection: selected)
        }
    }
    @ViewBuilder private func organisationItemContextMenu(_ reference: OrganisationItemReference, sourceContainerID: UUID?) -> some View {
        if reference.kind == .source {
            SourceTableContextMenu(model: model, sourceID: reference.itemID, sourceContainerID: sourceContainerID,
                rename: { source in sourceName = source.title; renamingSource = source },
                delete: { source in deletingSource = source })
        } else if reference.kind == .page, let note = model.notes.first(where: { $0.id == reference.itemID }) {
            DocumentOrganisationMenuCommands(model: model, reference: reference, sourceContainerID: sourceContainerID)
            DocumentFavouriteMenuCommand(model: model, reference: reference)
            Divider()
            Button("Rename Page…") { pageName = note.title; renamingPageID = note.id }
                .disabled(note.isEditingLocked || (model.currentNote?.id == note.id && model.externalChange))
            AISummaryMenuCommands(model: model, target: .page(note.id))
            Button(note.isEditingLocked ? "Unlock Editing" : "Lock Editing") { model.toggleEditingLock(note.id) }
                .disabled(model.editingLockOperations.contains(note.id))
            Divider()
            Button("Move Page to Trash…", role: .destructive) { trashPageID = note.id; showTrashConfirmation = true }
                .disabled(!Self.canTrashPage(note, model: model))
        } else if let sourceContainerID, let container = model.organisationContainers.first(where: { $0.id == sourceContainerID }) {
            Button("Remove from \(container.name)") { model.editOrganisation(.membership(sourceContainerID, reference, false)) }
                .disabled(!model.canInteractWithWorkspace || model.organisationMutationInProgress || model.favouriteMutationInProgress)
        }
    }
    static func canTrashPage(_ note: NoteRecord, model: AppModel) -> Bool {
        !note.isEditingLocked && !model.editingLocked && !model.externalChange && !model.editingLockOperations.contains(note.id)
    }
    private var sortedPageRows: [LibraryRow] {
        let rows = showFavourites ? model.favouriteRows : model.rows
        switch pageSortOrder {
        case .updated:
            return rows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        case .title:
            return rows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
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
            SemanticSearchControls(model: model)
                .padding(.horizontal, NoemaSpacing.lg)
                .padding(.bottom, NoemaSpacing.md)
            List { searchResultSections }.listStyle(.inset)
        }
        .foregroundStyle(theme.text(for: .textPrimary, on: .canvas))
        .background(theme.color(for: .canvas))
    }
    @ViewBuilder private var pageLibrary: some View {
        if model.scope == .sources && !showFavourites {
            VStack(spacing: 0) {
                SourcesLibraryView(
                    model: model,
                    presentation: sourceTablePresentation,
                    selection: sourceSelectionBinding,
                    scrollPosition: $sourceListScroll,
                    listFocus: $collectionListFocused,
                    rename: { source in sourceName = source.title; renamingSource = source },
                    delete: { deletingSource = $0 }
                )
                libraryFooter
            }
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
            if model.scope == .semantic && !showFavourites {
                KnowledgeLibraryView(model: model, query: $knowledgeQuery, selection: $knowledgeSelection) { semanticBlockList }
            } else if sortedPageRows.isEmpty {
                ContentUnavailableView("\(showFavourites ? "Favorites" : model.scopeTitle) is empty", systemImage: model.scope == .sources ? "tray" : "doc.text.magnifyingglass", description: Text(showFavourites ? "Use the star in the document toolbar to add favorites." : (model.scope == .sources ? "Import a text file or paste a source to begin." : "Create a page to start building your wiki.")))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: Binding(get: { pageDragSelection }, set: { ids in
                    pageDragSelection = ids
                    guard ids.count == 1, let id = ids.first,
                          !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) else { return }
                    let row = sortedPageRows.first { $0.id == id }
                    model.select(id, scope: showFavourites ? (row?.kind == .wiki ? .wiki : .sources) : nil, previewSource: showFavourites && row?.kind != .wiki)
                })) {
                    ForEach(sortedPageRows) { row in
                        let note = row.kind == .wiki ? model.notes.first(where: { $0.id == row.id }) : nil
                        let deleteDisabled = note.map { !Self.canTrashPage($0, model: model) } ?? true
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if row.kind == .wiki, model.unseenRenamedPages.contains(row.id) {
                                    Image(systemName: "circle.fill")
                                        .font(.caption2)
                                        .imageScale(.small)
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
                        .draggable(model.organisationDragBatch(sortedPageRows.filter {
                            pageDragSelection.contains(row.id) ? pageDragSelection.contains($0.id) : $0.id == row.id
                        }.map { OrganisationDrag.item(.init(kind: $0.kind == .wiki ? .page : .source, itemID: $0.id)) }))
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
                                DocumentOrganisationMenuCommands(model: model, reference: .init(kind: .page, itemID: note.id))
                                DocumentFavouriteMenuCommand(model: model, reference: .init(kind: .page, itemID: note.id))
                                Divider()
                                AISummaryMenuCommands(model: model, target: .page(note.id))
                                Button(note.isEditingLocked ? "Unlock Editing" : "Lock Editing") { model.toggleEditingLock(row.id) }
                                    .disabled(model.editingLockOperations.contains(note.id))
                                Button("Delete…", role: .destructive) { trashPageID = row.id; showTrashConfirmation = true }
                                    .disabled(deleteDisabled)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollPosition($pageListScroll)
                .focused($collectionListFocused)
            }
            libraryFooter
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
            } else if (isPagesScope && !showFavourites && !model.tags.isEmpty) || model.busy {
                HStack(spacing: NoemaSpacing.sm) {
                    if isPagesScope && !showFavourites && !model.tags.isEmpty {
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
                            .id(source.id)
                    } else if model.currentNote != nil {
                        SummarizedArticleView(model: model, showsSummary: (AISummaryPlacement(rawValue: aiSummaryPlacement) ?? .defaultValue).showsInEditor(sidebarVisible: isInspectorPresented))
                            .id(model.selectedID)
                    } else {
                        MarkdownPreview(blocks: model.preview, onWikiLink: model.followWikiLink)
                            .id(model.currentSource?.id)
                    }
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
                List(selection: Binding(get: { semanticDragSelection }, set: { ids in
                    semanticDragSelection = ids
                    guard ids.count == 1, let id = ids.first,
                          !NSEvent.modifierFlags.contains(.command), !NSEvent.modifierFlags.contains(.shift) else { return }
                    if let hit = filteredSemanticRows.first(where: { $0.id == id }) {
                        model.select(hit.pageID, block: hit.blockID)
                    }
                })) {
                    ForEach(filteredSemanticRows) { hit in
                        SemanticBlockCollectionRow(hit: hit)
                            .tag(hit.id)
                            .draggable(model.organisationDragBatch(filteredSemanticRows.filter {
                                semanticDragSelection.contains(hit.id) ? semanticDragSelection.contains($0.id) : $0.id == hit.id
                            }.map { OrganisationDrag.item(.init(kind: .semanticBlock, itemID: $0.blockID, pageID: $0.pageID)) }))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollPosition($semanticListScroll)
                .onAppear { if semanticDragSelection.isEmpty { semanticDragSelection = Set(model.selectedSemanticID.map { [$0] } ?? []) } }
                .onChange(of: filteredSemanticRows.map(\.id)) { semanticDragSelection.formIntersection(Set(filteredSemanticRows.map(\.id))) }
                .focused($collectionListFocused)
            }
        }
    }
    private var libraryFooter: some View {
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
            Spacer()
            Text("⌘P")
        }
        .font(NoemaTypography.metadata)
        .foregroundStyle(.secondary)
        .padding(NoemaSpacing.md)
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
                Button(action: toggleCollectionPane) {
                    Label(panePresentation.collection ? "Hide Collection List" : "Show Collection List", systemImage: "list.bullet")
                }
                .disabled(!paneActions.canToggleCollection)
                .help(panePresentation.collection ? "Hide Collection List (⌃⌘L)" : "Show Collection List (⌃⌘L)")
                .accessibilityLabel(panePresentation.collection ? "Hide Collection List" : "Show Collection List")
                .accessibilityValue(panePresentation.collection ? "Shown" : "Hidden")
            }
            ToolbarItem(placement: .navigation) {
                Button { model.performWorkspaceCommand(.returnToLibrary) } label: {
                    Label("Return to Library", systemImage: "chevron.backward")
                }
                .disabled(!model.canPerformWorkspaceCommand(.returnToLibrary))
                .help("Return to Library (⌘[)")
                .accessibilityLabel("Return to Library")
            }
            ToolbarItem(id: "workspace.embeddingQueue", placement: .primaryAction) {
                EmbeddingQueueIndicator(model: model)
            }
            ToolbarItem(id: "workspace.search", placement: .primaryAction) {
                ToolbarSearchView(model: model, availableWidth: workspaceWidth) {
                    showAllSearchResults = true
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
        ToolbarItem(id: "document.favorite", placement: .primaryAction) {
            if model.currentFavouriteReference != nil {
                Button { model.toggleCurrentFavourite() } label: {
                    Label(model.currentDocumentIsFavourite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: model.currentDocumentIsFavourite ? "star.fill" : "star")
                }
                .labelStyle(.iconOnly)
                .disabled(!model.canInteractWithWorkspace || model.favouriteMutationInProgress)
                .help(model.currentDocumentIsFavourite ? "Remove from Favorites" : "Add to Favorites")
            }
        }
        ToolbarItem(id: "workspace.more", placement: .primaryAction) {
            Menu {
                if let reference = model.currentFavouriteReference {
                    DocumentOrganisationMenuCommands(model: model, reference: reference, sourceContainerID: selectedOrganisation?.id)
                    Divider()
                }
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


private struct OrganisationDragModifier: ViewModifier {
    let value: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let value { content.draggable(value) }
        else { content }
    }
}
