import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VaultCore
import PDFKit
import ExternalAI
import CryptoKit

enum LibraryScope: Hashable, Sendable { case wiki, sources, semantic, trash, tag(String) }

struct SemanticBlockHit: Identifiable, Sendable {
    var pageID: UUID
    var blockID: UUID
    var pageTitle: String
    var semantic: String
    var preview: String
    var status: String? = nil
    var id: String { "\(pageID):\(blockID)" }
    func matches(_ query: String) -> Bool {
        let searchable = "\(semantic) \(preview) \(pageTitle)"
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            searchable.localizedCaseInsensitiveContains(String($0))
        }
    }
    static func search(_ notes: [NoteRecord], query: String) -> [Self] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.flatMap { note in
            BlockDocumentCodec.decode(note.body).semanticGroups.flatMap(\.blocks).compactMap { block in
                let tag = block.metadata.semantic ?? ""
                let preview = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let searchable = "\(tag) \(preview) \(note.title)"
                guard terms.allSatisfy({ searchable.localizedCaseInsensitiveContains($0) }) else { return nil }
                return Self(pageID: note.id, blockID: block.id, pageTitle: note.title, semantic: tag, preview: preview, status: block.metadata.status)
            }
        }
    }
}
struct SidebarSearchResults: Sendable {
    var query = ""
    var pages: [NoteRecord] = []
    var sources: [SourceRecord] = []
    var blocks: [SemanticBlockHit] = []
    var pageExcerpts: [UUID: String] = [:]
    var sourceExcerpts: [UUID: String] = [:]
    var isEmpty: Bool { pages.isEmpty && sources.isEmpty && blocks.isEmpty }

    static func search(_ query: String, notes: [NoteRecord], sources: [SourceRecord], index: any SearchIndex, semanticBlocks: [SemanticBlockHit]? = nil) async throws -> Self {
        let pageHits = try await index.search(query, kind: .wiki, tag: nil)
        let sourceHits = try await index.search(query, kind: .source, tag: nil)
        let blocks = await Task.detached {
            if let semanticBlocks { return semanticBlocks.filter { $0.matches(query) } }
            return SemanticBlockHit.search(notes, query: query)
        }.value
        let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self(query: query, pages: pageHits.compactMap { noteMap[$0.id] },
                    sources: sourceHits.compactMap { sourceMap[$0.id] }, blocks: blocks,
                    pageExcerpts: Dictionary(pageHits.map { ($0.id, $0.excerpt) }, uniquingKeysWith: { first, _ in first }),
                    sourceExcerpts: Dictionary(sourceHits.map { ($0.id, $0.excerpt) }, uniquingKeysWith: { first, _ in first }))
    }
}
struct LibraryRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var excerpt: String
    var tags: [String]
    var kind: EntryKind
    var updatedAt: Date?
    var hasAISummary = false
    var fileSize = 0
    var originalFilename = ""
    var fileKind = ""
    var sourceLocation = "In vault"
    var captureSortDate: Date { updatedAt ?? .distantPast }

    init(note: NoteRecord) {
        let document = BlockDocumentCodec.decode(note.body)
        let summary = document.aiSummary?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        hasAISummary = summary?.isEmpty == false
        id = note.id; title = note.title; tags = note.allTags; kind = .wiki
        excerpt = hasAISummary ? summary! : document.withoutAISummary.flattened.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        updatedAt = Self.date(note.updatedAt)
    }

    init(source: SourceRecord) {
        id = source.id; title = source.title; tags = []; kind = .source
        // Sources tables and search results display metadata; previews decode content on demand.
        excerpt = ""
        updatedAt = Self.date(source.metadata.capturedAt)
        fileSize = source.metadata.fileSize ?? source.body.utf8.count
        sourceLocation = source.metadata.isLinked ? "Linked" : "In vault"
        originalFilename = source.metadata.originalFilename
        fileKind = UTType(filenameExtension: URL(fileURLWithPath: source.metadata.originalFilename).pathExtension)?.localizedDescription ?? "File"
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
struct EditorAction: Equatable {
    enum Operation: Equatable { case wrap(String, String), wikiLink(String), block(UUID) }
    var id = UUID()
    var operation: Operation
}

/// A generated proposal is session-only until the user explicitly accepts it.
struct AISuggestion: Identifiable, Sendable {
    let id: UUID
    let action: AIAction
    let value: String
    let rationale: String?
    let provider: AIProvider
    let target: ExternalAISummaryTarget
}

@MainActor @Observable final class AppModel {
    var showSettings = false
    var selectedSettingsCategory: SettingsCategory = .defaultCategory
    var showCustomTeXCommandsModal = false
    var showAIActivityHistory = false
    var showVaultCreation = false

    var canInteractWithWorkspace: Bool { !showSettings }

    /// Native mutation admission: one page identity and established semantic authority.
    var canEditPage: Bool {
        guard canInteractWithWorkspace, isVaultAvailable, currentNote != nil, currentSource == nil,
              !editingLocked, !externalChange, !busy, !isLifecycleActionInProgress,
              !isChoosingVault, !isChoosingSource, !workspaceCommandPending,
              !showVaultCreation, !showTopicPage, !showURLSource, !showPasteSource,
              !showRecovery, !showIssues, cloudSummaryConfirmation == nil,
              pendingAISuggestion == nil, ambiguousMatches.isEmpty, unresolvedTarget == nil,
              semanticReadyIdentity == editorIdentity,
              let coordinator = semanticCoordinator else { return false }
        return coordinator.session.identity == editorIdentity && coordinator.session.semanticEdit != nil
    }

    var canFormatDocument: Bool {
        canEditPage
    }

    var canOpenSettings: Bool {
        if showSettings { return true }
        return !busy
            && !isLifecycleActionInProgress
            && !workspaceCommandPending
            && [.closed, .open, .locked].contains(sessionPhase)
            && !isChoosingVault
            && !isChoosingSource
            && !showVaultCreation
            && !showTopicPage
            && !showURLSource
            && !showPasteSource
            && !showRecovery
            && !showIssues
            && cloudSummaryConfirmation == nil
            && pendingAISuggestion == nil
            && ambiguousMatches.isEmpty
            && unresolvedTarget == nil
    }

    func openSettings(category: SettingsCategory? = nil) {
        guard canOpenSettings else { return }
        if let category {
            selectedSettingsCategory = category
        } else if !showSettings {
            selectedSettingsCategory = .defaultCategory
        }
        showSettings = true
    }

    func dismissSettings(force: Bool = false) {
        guard force || !isVaultAuthenticationPending else { return }
        showCustomTeXCommandsModal = false
        showAIActivityHistory = false
        showSettings = false
        if let url = pendingBlockURL, isVaultAvailable, !busy {
            pendingBlockURL = nil
            openBlockURL(url)
        }
    }

    var root: URL?
    var vaultName = "Noema"
    var notes: [NoteRecord] = [] {
        didSet { libraryCatalogRevision = UUID(); invalidateSearch() }
    }
    var sources: [SourceRecord] = [] {
        didSet { libraryCatalogRevision = UUID(); invalidateSearch() }
    }
    private var libraryCatalogRevision = UUID()
    private var libraryRowsRevision: UUID?
    private var libraryRowsScope: LibraryScope?
    private var libraryRowsEditorRevision: UUID?
    var downloadingSources: Set<UUID> = []
    private struct PendingSourceDownload {
        var source: SourceRecord
        var url: URL
        var shouldImport: Bool
        var download: @Sendable (URL) async throws -> Data
    }
    private var sourceDownloadQueue: [PendingSourceDownload] = []
    private var sourceDownloadTask: Task<Void, Never>?
    var sourceAvailability: [UUID: String] = [:]
    var checkingSourceAvailability: Set<UUID> = []
    private var sourceAvailabilityQueue: [SourceRecord] = []
    private var sourceAvailabilityTask: Task<Void, Never>?
    var generatingSourcePages: Set<UUID> = []
    var generatingSourceSummaries: Set<UUID> = []
    var generatingSourceTitles: Set<UUID> = []
    var sourceRenameCompleted = 0
    var sourceRenameTotal = 0
    private var sourceNamingOverrides: Set<UUID> = []
    private var sourceNamingQueue: [SourceRecord] = []
    private var sourceNamingTask: Task<Void, Never>?

    var trashedPages: [TrashedItem] = []
    private(set) var trashOperationInProgress = false
    var rows: [LibraryRow] = []
    var knowledgeFamily: KnowledgeLibraryFamily = .blocks
    var knowledgeCatalogue: KnowledgeCatalogueSnapshot?
    @ObservationIgnored var entityPropertySearchDidLoad: (@MainActor () async -> Void)?
    var knowledgeCatalogueLoading = false
    var knowledgeCatalogueError: String?
    @ObservationIgnored private var knowledgeCatalogueTicket = UUID()
    var semanticRows: [SemanticBlockHit] = []
    private var semanticRowsRevision: UUID?
    private var semanticRowsEditorRevision: UUID?
    var selectedSemanticID: String?
    private var sidebarRecentHistory = SidebarRecentHistory()
    private var sidebarRecentPresentation = SidebarRecentPresentation()
    var sidebarRecentDefaults: UserDefaults = .standard
    private var sidebarRecentVaultID: UUID?
    private var sidebarRecentCacheRevision: UUID?
    private var sidebarRecentCacheEditorRevision: UUID?
    private var sidebarRecentCache: [SidebarRecentItem] = []
    private(set) var selectedSidebarRecentItemID: RecentItemID?
    var recentItemIDs: [RecentItemID] { isLocked ? [] : sidebarRecentHistory.ids }
    private(set) var organisationContainers: [OrganisationContainer] = []
    private(set) var organisationMemberships: [OrganisationMembership] = []
    private(set) var organisationMutationInProgress = false
    private(set) var favouriteReferences: [OrganisationItemReference] = []
    private(set) var favouriteMutationInProgress = false
    var currentFavouriteReference: OrganisationItemReference? {
        if let note = currentNote { return .init(kind: .page, itemID: note.id) }
        if let source = currentSource { return .init(kind: .source, itemID: source.id) }
        return nil
    }
    var currentDocumentIsFavourite: Bool {
        currentFavouriteReference.map { favouriteReferences.contains($0) } ?? false
    }
    var favouriteRows: [LibraryRow] {
        guard isVaultAvailable else { return [] }
        return favouriteReferences.compactMap { reference in
            switch reference.kind {
            case .page: return notes.first { $0.id == reference.itemID }.map { LibraryRow(note: $0) }
            case .source: return sources.first { $0.id == reference.itemID }.map { LibraryRow(source: $0) }
            default: return nil
            }
        }
    }
    func reloadFavourites() async {
        guard isVaultAvailable, let repository else { return }
        let ticket = generation
        do {
            let snapshot = try await repository.sqliteBlockStore.organisationSnapshot(includingHidden: false)
            guard generation == ticket, isVaultAvailable else { return }
            organisationContainers = snapshot.containers
            organisationMemberships = snapshot.memberships
            favouriteReferences = snapshot.favourites.map(\.reference)
        } catch {
            if generation == ticket, isVaultAvailable { errorMessage = error.localizedDescription }
        }
    }
    func toggleCurrentFavourite() {
        guard let reference = currentFavouriteReference else { return }
        toggleFavourite(reference)
    }
    func toggleFavourite(_ reference: OrganisationItemReference) {
        guard canInteractWithWorkspace, isVaultAvailable, !favouriteMutationInProgress, !organisationMutationInProgress,
              let repository, isOrganisableDocument(reference) else { return }
        let ticket = generation
        let favourite = !favouriteReferences.contains(reference)
        favouriteMutationInProgress = true
        Task {
            defer { if generation == ticket { favouriteMutationInProgress = false } }
            do {
                let snapshot = try await repository.sqliteBlockStore.organisationSnapshot(includingHidden: false)
                guard generation == ticket, isVaultAvailable else { return }
                _ = try await repository.sqliteBlockStore.setFavourite(reference, favourite: favourite,
                    expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                guard generation == ticket, isVaultAvailable else { return }
                await reloadFavourites()
            } catch {
                if generation == ticket, isVaultAvailable { errorMessage = error.localizedDescription }
            }
        }
    }
    enum OrganisationEdit {
        case create(OrganisationContainerKind, String, UUID?)
        case renameContainer(OrganisationContainer, String)
        case move(OrganisationContainer, UUID?)
        case delete(OrganisationContainer)
        case membership(UUID, OrganisationItemReference, Bool)
        case place(OrganisationItemReference, UUID, UUID?)
        case dropBatch([OrganisationDropEdit], UUID?)
    }
    enum OrganisationDropEdit {
        case item(OrganisationItemReference, UUID?)
        case folder(OrganisationContainer)
    }
    func organisationDragBatch(_ payloads: [String]) -> String {
        organisationDragValue(payloads.joined(separator: "\n"))
    }
    func organisationDragValue(_ payload: String) -> String {
        guard isVaultAvailable, let sessionID = sessionState.sessionID else { return "" }
        return "noema-session:\(sessionID.uuidString):" + payload
    }
    func receiveOrganisationDrop(_ values: [String], into destination: UUID?) -> Bool {
        guard canInteractWithWorkspace, isVaultAvailable, !organisationMutationInProgress,
              !favouriteMutationInProgress, !values.isEmpty,
              let sessionID = sessionState.sessionID else { return false }
        let prefix = "noema-session:\(sessionID.uuidString):"
        guard destination == nil || organisationContainers.contains(where: { $0.id == destination }) else { return false }
        var payloads: [OrganisationDrag.Payload] = []
        for value in values {
            guard value.hasPrefix(prefix) else { return false }
            for raw in value.dropFirst(prefix.count).split(separator: "\n", omittingEmptySubsequences: false) {
                guard let payload = OrganisationDrag.parse(String(raw)) else { return false }
                if !payloads.contains(payload) { payloads.append(payload) }
            }
        }
        let draggedFolders = Set(payloads.compactMap { payload -> UUID? in
            if case .container(let id) = payload { return id }
            return nil
        })
        var edits: [OrganisationDropEdit] = []
        for payload in payloads {
            switch payload {
            case .item(let reference, let source):
                guard destination != nil else { return false }
                if let source {
                    guard organisationMemberships.contains(where: { $0.containerID == source && $0.reference == reference }) else { return false }
                }
                if source != destination { edits.append(.item(reference, source)) }
            case .container(let id):
                guard let container = organisationContainers.first(where: { $0.id == id }),
                      container.kind == .folder else { return false }
                var cursor = destination
                var visited: Set<UUID> = [id]
                while let parent = cursor {
                    guard visited.insert(parent).inserted,
                          let ancestor = organisationContainers.first(where: { $0.id == parent }) else { return false }
                    cursor = ancestor.parentID
                }
                // A selected descendant travels with its selected ancestor.
                cursor = container.parentID
                visited = [id]
                var ancestorSelected = false
                while let parent = cursor {
                    guard visited.insert(parent).inserted,
                          let ancestor = organisationContainers.first(where: { $0.id == parent }) else { return false }
                    if draggedFolders.contains(parent) { ancestorSelected = true }
                    cursor = ancestor.parentID
                }
                if !ancestorSelected, container.parentID != destination { edits.append(.folder(container)) }
            }
        }
        guard !edits.isEmpty else { return false }
        editOrganisation(.dropBatch(edits, destination))
        return true
    }
    func editOrganisation(_ edit: OrganisationEdit) {
        guard canInteractWithWorkspace, isVaultAvailable, !organisationMutationInProgress, !favouriteMutationInProgress,
              let repository else { return }
        let ticket = generation
        organisationMutationInProgress = true
        Task {
            var completedDrops = 0
            defer { if generation == ticket { organisationMutationInProgress = false } }
            do {
                let snapshot = try await repository.sqliteBlockStore.organisationSnapshot(includingHidden: false)
                guard generation == ticket, isVaultAvailable else { return }
                switch edit {
                case .create(let kind, let name, let parent):
                    _ = try await repository.sqliteBlockStore.createContainer(kind: kind, name: name, parentID: parent,
                        expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                case .renameContainer(let container, let name):
                    _ = try await repository.sqliteBlockStore.renameContainer(id: container.id, name: name,
                        expected: container.revision, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                case .move(let container, let parent):
                    let index = snapshot.containers.filter { $0.parentID == parent && $0.id != container.id }.count
                    _ = try await repository.sqliteBlockStore.moveContainer(id: container.id, parentID: parent, index: index,
                        expected: container.revision, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                case .delete(let container):
                    _ = try await repository.sqliteBlockStore.deleteContainer(id: container.id, expected: container.revision,
                        expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                case .dropBatch(let edits, let destination):
                    if let destination, !snapshot.containers.contains(where: { $0.id == destination }) {
                        throw VaultError.invalid("The destination is no longer available.")
                    }
                    // Recheck every move against the admitted snapshot before publishing any.
                    for pending in edits {
                        switch pending {
                        case .item(let reference, let source):
                            if let source, !snapshot.memberships.contains(where: { $0.containerID == source && $0.reference == reference }) {
                                throw VaultError.conflict("A dragged membership changed. Select the items again.")
                            }
                        case .folder(let container):
                            guard snapshot.containers.contains(where: { $0.id == container.id && $0.revision == container.revision }) else {
                                throw VaultError.conflict("A dragged folder changed. Select the folders again.")
                            }
                            var cursor = destination
                            var visited: Set<UUID> = [container.id]
                            while let id = cursor {
                                guard visited.insert(id).inserted,
                                      let parent = snapshot.containers.first(where: { $0.id == id }) else {
                                    throw VaultError.invalid("The folder destination would create a cycle.")
                                }
                                cursor = parent.parentID
                            }
                        }
                    }
                    var vaultRevision = snapshot.vaultRevision
                    for edit in edits {
                        guard generation == ticket, isVaultAvailable else { return }
                        switch edit {
                        case .item(let reference, let source):
                            guard let destination else { throw VaultError.invalid("Choose a collection or folder for these items.") }
                            let result = try await repository.sqliteBlockStore.placeMembership(reference: reference,
                                containerID: destination, removingFrom: source, expectedVaultRevision: vaultRevision, operationID: UUID())
                            vaultRevision = result.vaultRevision
                        case .folder(let container):
                            let result = try await repository.sqliteBlockStore.moveContainer(id: container.id, parentID: destination,
                                index: Int.max, expected: container.revision, expectedVaultRevision: vaultRevision, operationID: UUID())
                            vaultRevision = result.vaultRevision
                        }
                        completedDrops += 1
                    }
                case .place(let reference, let destination, let source):
                    _ = try await repository.sqliteBlockStore.placeMembership(reference: reference, containerID: destination,
                        removingFrom: source, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                case .membership(let id, let reference, let adding):
                    if adding {
                        _ = try await repository.sqliteBlockStore.addMembership(containerID: id, reference: reference,
                            expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                    } else {
                        _ = try await repository.sqliteBlockStore.removeMembership(containerID: id, reference: reference,
                            expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
                    }
                }
                guard generation == ticket, isVaultAvailable else { return }
                await reloadFavourites()
            } catch {
                if generation == ticket, isVaultAvailable {
                    let failure: String
                    if case .dropBatch(let edits, _) = edit {
                        failure = "Completed \(completedDrops) of \(edits.count) dropped items. " + error.localizedDescription
                    } else { failure = error.localizedDescription }
                    await reloadFavourites()
                    if generation == ticket, isVaultAvailable { errorMessage = failure }
                }
            }
        }
    }
    private(set) var editingLockOperations: Set<UUID> = []
    var tags: [String] = []
    var wordCount = 0
    var scope: LibraryScope = .wiki {
        didSet { if scope != oldValue { cancelCloudSummary(); invalidateSearch() } }
    }
    /// The Sources table and inspector share this synchronous selection route with cloud work.
    private(set) var librarySourceSelection: UUID?
    func setLibrarySourceSelection(_ id: UUID?) {
        guard id != librarySourceSelection else { return }
        cancelCloudSummary()
        librarySourceSelection = id
    }
    var searchText = "" {
        didSet { if searchText != oldValue { invalidateSearch() } }
    }
    var searchMode: VaultSearchMode = .vault {
        didSet { if searchMode != oldValue { invalidateSearch() } }
    }
    var searchScope: VaultSearchScope = .all {
        didSet { if searchScope != oldValue { invalidateSearch() } }
    }
    var searchStatus: VaultSearchStatus = .idle
    var sidebarSearchResults = SidebarSearchResults()
    var visibleSearchResults: SidebarSearchResults { sidebarSearchResults.filtered(to: searchScope) }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var unseenRenamedPages: Set<UUID> = []
    var appIsActive = true
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue {
                invalidateSearch()
                if isSearching || searchMode == .quickOpen { queryChanged() }
                cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
                if let id = nativePageSummaryID { cancelSummary(target: .page(id)) }
            }
        }
    }
    var currentNote: NoteRecord?
    var currentSource: SourceRecord?
    var title = "" {
        didSet {
            if title != oldValue {
                cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
                if isSearching || searchMode == .quickOpen || scope == .semantic { invalidateSearch() }
            }
        }
    }
    var editorDocument = BlockDocumentCodec.decode("") {
        didSet {
            if editorDocument != oldValue {
                bodyProjection = nil
                cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
                if isSearching || searchMode == .quickOpen || scope == .semantic { invalidateSearch() }
            }
        }
    }
    @ObservationIgnored private var bodyProjection: String? = ""
    /// Compatibility projection for interchange, AI and source presentation.
    var body: String {
        get { bodyProjection ?? BlockDocumentCodec.encode(editorDocument) }
        set { editorDocument = BlockDocumentCodec.decode(newValue); bodyProjection = newValue }
    }
    var editorIdentity: EditorSession.Identity {
        .init(pageID: currentNote?.id, vaultID: sessionState.vaultID, sessionID: sessionState.sessionID)
    }
    @ObservationIgnored private var editorGeneration: UUID?
    @ObservationIgnored private var editorRevision: UInt64 = 0
    func registerEditorSession(_ session: EditorSession) {
        guard session.identity == editorIdentity else { return }
        editorGeneration = session.generation; editorRevision = session.revision
    }
    func acceptEditorSnapshot(_ snapshot: EditorSession.DocumentSnapshot) {
        guard canOperateOnLoadedContent, !editingLocked, snapshot.identity == editorIdentity,
              snapshot.generation == editorGeneration, snapshot.revision > editorRevision else { return }
        editorRevision = snapshot.revision
        editorDocument = snapshot.document
        edited()
    }
    private var semanticReadyIdentity: EditorSession.Identity?
    @ObservationIgnored weak var semanticCoordinator: RichArticleView.Coordinator?
    var pendingSemanticOccurrence: PendingSemanticOccurrence?
    @ObservationIgnored private var semanticOccurrenceNavigationTicket = UUID()
    var semanticInspectionPageID: UUID?
    var semanticInspectionRecords: [SemanticInspectionRecord] = []
    var semanticInspectionSelectionIDs: [UUID] = []
    var semanticInspectionFocusID: UUID?
    var semanticInspectionOpenRequest = UUID()
    var semanticInspectionLoading = false
    var semanticInspectionError: String?
    @ObservationIgnored private var semanticInspectionTicket = UUID()
    var canAnnotateSelection = false
    var semanticSavedRevision: UInt64 = 0
    @ObservationIgnored var flushEditorPublication: (() -> Void)?
    @ObservationIgnored private weak var publicationCoordinator: RichArticleView.Coordinator?
    func registerHostedEditor(_ coordinator: RichArticleView.Coordinator) {
        guard coordinator.session.identity == editorIdentity else { return }
        registerEditorSession(coordinator.session)
        publicationCoordinator = coordinator
        flushEditorPublication = { [weak coordinator] in coordinator?.flushPublication() }
    }
    func unregisterHostedEditor(_ coordinator: RichArticleView.Coordinator) {
        if publicationCoordinator === coordinator {
            publicationCoordinator = nil; flushEditorPublication = nil
        }
        if semanticCoordinator === coordinator {
            semanticCoordinator = nil; semanticReadyIdentity = nil
            canAnnotateSelection = false
        }
    }
    var tagInput = "" { didSet { if tagInput != oldValue { cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate() } } }
    var preview: [PreviewBlock] = []
    var backlinks: [NoteRecord] = []
    var outgoingLinkTargets: [String] = []
    var editorNotice: String?
    var editingHint: String?
    var editorReadOnly = false
    var pendingBlockURL: URL?
    var generatingAISummary = false
    var aiSummaryNotice: String?
    var busy = false
    var saveStatus = "Saved locally"
    var errorMessage: String?
    var externalChange = false
    var issues: [String] = []
    private var dismissedVaultNotices: Set<String> = []
    func dismissVaultNotice(_ issue: String) {
        dismissedVaultNotices.insert(issue); issues.removeAll { $0 == issue }
    }
    func dismissAllVaultNotices() {
        dismissedVaultNotices.formUnion(issues); issues = []
    }
    var recoveredDrafts: [DraftRecord] = []
    var damagedRecoveryEntries: [DamagedRecoveryEntry] = []
    var hasRecoveryEntries: Bool { !recoveredDrafts.isEmpty || !damagedRecoveryEntries.isEmpty }
    var showRecovery = false
    var showTopicPage = false
    var generatingTopicPage = false
    var aiPageSourceID: UUID?
    var aiPageProviderOverride: AIProvider?
    var aiPageDraft: AIPageDraft?
    var aiPageSubmission: AIPageSubmission?
    private var aiPageOperationID: UUID?
    private var aiPageActivityID: UUID?
    private var aiPagePublicationActivityID: UUID?
    var aiPageTask: Task<Void, Never>?
    var aiPageFetch: @Sendable (URL) async throws -> WebSourceFetch = WebSourceFetcher.fetch

    var showURLSource = false
    var showPasteSource = false
    var showIssues = false
    var ambiguousMatches: [NoteRecord] = []
    var unresolvedTarget: String?
    var wikiQuery: String?
    var editorAction: EditorAction?
    var searchFocusToken = 0
    var workspaceNavigationToken = 0
    private let storageProvider: VaultStorageProvider
    let activityRecorder: AIActivityRecorder
    let externalAIService: ExternalAIService
    let vaultAIConfigurationStore: VaultAIConfigurationStore
    let aiProviderPreferences: AIProviderPreferences
    @ObservationIgnored private let aiPreferenceDefaults: UserDefaults
    let sessionManager: VaultSessionManager
    var quiescenceCoordinator: VaultSaveQuiescenceCoordinator { sessionManager.quiescenceCoordinator }
    private(set) var sessionState: VaultSessionState = .closed
    /// Typed manager failures retained at the UI boundary, including rollback failures.
    private(set) var sessionTransitionErrors: [VaultSessionError] = []
    private var lifecycleAction: String?
    private var lifecycleActionID: UUID?
    private(set) var vaultAccessAuthenticationRequired = false
    private(set) var isVaultAuthenticationPending = false
    @ObservationIgnored private nonisolated(unsafe) var authenticationObservationTask: Task<Void, Never>?
    var workspaceCommandPending = false
    private(set) var isChoosingVault = false
    private(set) var isChoosingSource = false
    private var vaultCommandPanel: NSOpenPanel?
    private var sourceCommandPanel: NSOpenPanel?
    var isLifecycleActionInProgress: Bool { lifecycleAction != nil }
    @ObservationIgnored private nonisolated(unsafe) var sessionObservationTask: Task<Void, Never>?
    @ObservationIgnored var semanticProcessingGeneration: EmbeddingIndexGeneration?
    @ObservationIgnored var semanticPublicationAuthority: EmbeddingPublicationAuthority?
    @ObservationIgnored var aiProcessingCoordinator: AIProcessingCoordinator?
    @ObservationIgnored var aiProcessingLedger: SQLiteAIWorkLedger?
    @ObservationIgnored var embeddingBackfillRuntime: EmbeddingBackfillRuntime?
    @ObservationIgnored var aiProcessingBindingID = UUID()
    @ObservationIgnored var aiProcessingEventTask: Task<Void, Never>?
    @ObservationIgnored var aiProcessingRetirementTask: Task<Void, Never>?
    var aiProcessingFailure: AIWorkFailure?
    private var activeSession: VaultSession?
    private var activeLease: VaultSessionLease?
    private(set) var lockedVaultURL: URL?
    private(set) var repository: FileVaultRepository?
    var index: (any SearchIndex)?
    @ObservationIgnored var semanticIndex: SQLiteEmbeddingIndex?
    var semanticIndexIssue: String?
    var semanticIndexCompatibility: SemanticIndexCompatibility = .unavailable
    private var recovery: RecoveryStore?
    private var scopeURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var searchRevision = UUID()
    private var refreshTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var aiSummaryTask: Task<Void, Never>?
    private var pageLCCTask: Task<Void, Never>?
    private var sourceLCCTasks: [UUID: Task<Void, Never>] = [:]
    private var sourcePageTasks: [UUID: Task<Void, Never>] = [:]
    private var sourceSummaryTasks: [UUID: Task<Void, Never>] = [:]
    private var untitledPages: [UUID: String] = [:]
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var saving = false
    private var refreshing = false
    private var pendingRefresh = false
    private var generation = UUID()
    private var progressTicket: UUID?
    var aiClient: AIProcessingClient = .live
    var previewRenderer: @Sendable (String) async -> ([PreviewBlock], Int) = { captured in
        await Task.detached {
            (
                MarkdownService.preview(captured),
                BlockDocumentCodec.markdownBody(captured).split(whereSeparator: \.isWhitespace).count
            )
        }.value
    }
    var searchIndexFactory: @Sendable (URL, VaultSessionLease?, VaultAccessGate?) throws -> any SearchIndex = { url, lease, gate in
        try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate)
    }
    var semanticIndexFactory: @Sendable (URL, VaultSessionLease, VaultAccessGate) throws -> SQLiteEmbeddingIndex = { root, lease, gate in
        try SQLiteEmbeddingIndex(applicationSupportRoot: root, lease: lease, accessGate: gate)
    }
    var embeddingProviderFactory: @Sendable () throws -> any EmbeddingProvider = { try AppleSentenceEmbeddingProvider() }
    var aiProcessingClock: AIProcessingClock = .continuous
    var aiProcessingConfiguration = AIProcessingConfiguration()
    var sourceAvailabilityChecker: (@Sendable (SourceRecord, URL, any VaultContentStore) async -> String)?
    var localStorageRoot: URL?
    var persistSecurityScopedBookmark: Bool = true
    var requiresSecurityScopedAccess: Bool = false
    var securityScopeAcquirer: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var securityScopeReleaser: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var bookmarkResolver: (@Sendable (Data) throws -> (url: URL, isStale: Bool))?
    private(set) var lockedVaultBookmark: Data?
    var needsPermissionReauthorization = false

    init(
        repository: FileVaultRepository? = nil,
        recovery: RecoveryStore? = nil,
        storageProvider: VaultStorageProvider = .plaintext,
        sessionManager: VaultSessionManager = VaultSessionManager(),
        aiDefaults: UserDefaults = .standard,
        activityRecorder: AIActivityRecorder = .shared,
        externalAIServiceFactory: ((VaultAccessGate, UserDefaults, AIActivityRecorder) -> ExternalAIService)? = nil
    ) {
        self.activityRecorder = activityRecorder
        self.storageProvider = storageProvider
        self.sidebarRecentDefaults = aiDefaults
        self.aiPreferenceDefaults = aiDefaults
        self.vaultAIConfigurationStore = VaultAIConfigurationStore(defaults: aiDefaults)
        self.aiProviderPreferences = AIProviderPreferences(defaults: aiDefaults)
        self.sessionManager = sessionManager
        self.externalAIService = externalAIServiceFactory?(sessionManager.accessGate, aiDefaults, activityRecorder)
            ?? ExternalAIService(accessGate: sessionManager.accessGate, defaults: aiDefaults, activityRecorder: activityRecorder)
        self.repository = repository
        self.recovery = recovery
        self.activeLease = repository?.sessionLease
        let initialState = sessionManager.accessGate.currentState
        self.sessionState = initialState
        self.vaultAccessAuthenticationRequired = initialState.vaultID.map { sessionManager.accessAuthenticationRequired(for: $0) } ?? false
        self.isVaultAuthenticationPending = sessionManager.isAuthenticationPending
        if case .locked(_, let lockedRoot, let name, _) = initialState {
            self.lockedVaultURL = lockedRoot
            self.vaultName = name
        } else if case .open(let session) = initialState {
            self.activeSession = session
            self.vaultName = session.vaultName
        }
        externalAIService.embeddingSelectionDidChange = { [weak self] in
            guard let self, let repository = self.repository,
                  let lease = self.sessionManager.accessGate.currentLease else { return }
            Task { await self.bindAIProcessing(repository: repository, lease: lease, preservingEmbeddingApproval: true) }
        }
        startObservingSessionState()
        authenticationObservationTask = Task { @MainActor [weak self, sessionManager] in
            let stream = await sessionManager.authenticationObservations()
            for await pending in stream {
                guard let self, !Task.isCancelled else { break }
                // Ignore superseded pending emissions, just as session observations do.
                guard pending == sessionManager.isAuthenticationPending else { continue }
                self.isVaultAuthenticationPending = pending
            }
        }
    }

    deinit {
        sessionObservationTask?.cancel()
        authenticationObservationTask?.cancel()
    }

    private func startObservingSessionState() {
        sessionObservationTask?.cancel()
        let manager = sessionManager
        let initialState = sessionState
        sessionObservationTask = Task { @MainActor [weak self] in
            let stream = await manager.observations()
            var isFirstEmission = true
            for await nextState in stream {
                guard let self, !Task.isCancelled else { break }
                if isFirstEmission {
                    isFirstEmission = false
                    if nextState == initialState {
                        continue
                    }
                }
                self.applyObservedSessionState(nextState)
            }
        }
    }

    /// Synchronizes `AppModel` availability and purges in-memory content whenever the central
    /// `VaultSessionManager` transitions out of `.open` (including external/direct session transitions).
    func applyObservedSessionState(_ nextState: VaultSessionState) {
        let latestState = sessionManager.accessGate.currentState
        if nextState != latestState {
            return
        }
        let previousPhase = sessionState.phase
        sessionState = nextState
        if nextState.phase != .open { suspendAIProcessing() }
        vaultAccessAuthenticationRequired = nextState.vaultID.map { sessionManager.accessAuthenticationRequired(for: $0) } ?? false
        switch nextState {
        case .closed:
            let hadActiveResources = root != nil || lockedVaultURL != nil || activeSession != nil || activeLease != nil || repository != nil || index != nil || recovery != nil || !notes.isEmpty || !sources.isEmpty || currentNote != nil || currentSource != nil
            lockedVaultURL = nil
            lockedVaultBookmark = nil
            vaultName = "Noema"
            if hadActiveResources {
                releaseActiveVaultResources()
                clearSessionUIState()
            } else {
                busy = false
            }
            dismissSettings(force: true)

        case .opening(let targetRoot, _):
            lockedVaultURL = nil
            vaultName = targetRoot.lastPathComponent
            busy = true

        case .open(let session):
            if let activeLease, activeLease != session.lease {
                releaseActiveVaultResources()
                clearSessionUIState()
            }
            activeSession = session
            lockedVaultURL = nil
            vaultName = session.vaultName

        case .locking(let session):
            vaultName = session.vaultName
            busy = true

        case .locked(_, let lockedRoot, let name, _):
            let needsTeardown = root != nil || repository != nil || index != nil || recovery != nil || !notes.isEmpty || !sources.isEmpty || currentNote != nil || currentSource != nil
            lockedVaultURL = lockedRoot
            vaultName = name
            if needsTeardown {
                releaseActiveVaultResources()
                clearSessionUIState()
            } else {
                busy = false
            }
            if previousPhase != .locked {
                dismissSettings(force: true)
            }

        case .unlocking(_, let lockedRoot, let name, _):
            lockedVaultURL = lockedRoot
            vaultName = name
            busy = true
        }
    }

    var sessionPhase: VaultSessionPhase { sessionState.phase }
    var isVaultAvailable: Bool {
        guard case .open(let session) = sessionState else { return false }
        return sessionManager.accessGate.currentState == sessionState && activeLease == session.lease && root != nil && repository != nil
    }
    private var canOperateOnLoadedContent: Bool {
        isVaultAvailable || (!isLocked && sessionState == .closed && activeSession == nil && (repository != nil || !notes.isEmpty || !sources.isEmpty || currentNote != nil || currentSource != nil))
    }
    var isLocked: Bool {
        switch sessionState {
        case .locked, .unlocking:
            return true
        default:
            return false
        }
    }

    var editedTags: [String] { normalizeTags(tagInput.components(separatedBy: ",")) }
    var dirty: Bool {
        guard let note = currentNote else { return false }
        let contentChanged = note.document.map { editorDocument != $0 } ?? (body != note.body)
        return title != note.title || contentChanged || editedTags != note.tags || (semanticCoordinator?.session.identity == editorIdentity && semanticCoordinator?.session.semanticEdit != nil && (semanticCoordinator?.session.revision ?? 0) != semanticSavedRevision)
    }
    var scopeTitle: String {
        switch scope { case .wiki: "Pages"; case .sources: "Sources"; case .semantic: "Knowledge"; case .trash: "Trash"; case .tag(let tag): "#" + tag }
    }
    var activeTagFilter: String? {
        if case .tag(let tag) = scope { return tag }
        return nil
    }
    var sidebarRecentItems: [SidebarRecentItem] {
        guard canOperateOnLoadedContent, !isLocked else { return [] }
        if sidebarRecentCacheRevision == libraryCatalogRevision,
           sidebarRecentCacheEditorRevision == cloudEditorRevision { return sidebarRecentCache }
        let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sidebarRecentPresentation.reconcile(recentItemIDs)
        sidebarRecentCache = sidebarRecentPresentation.ids.compactMap { id in
            switch id {
            case .page(let pageID):
                guard let note = noteMap[pageID] else { return nil }
                let label = currentNote?.id == pageID ? title : note.title
                return SidebarRecentItem(id: id, title: label, symbol: "doc.text", accessibilityLabel: "Page, \(label)", pageID: pageID)
            case .source(let sourceID):
                guard let source = sourceMap[sourceID], source.contentState != .unavailable, source.availabilityIssue == nil else { return nil }
                return SidebarRecentItem(id: id, title: source.title, symbol: source.metadata.isLinked ? "link" : "doc", accessibilityLabel: "Source, \(source.title)", pageID: nil)
            case .semanticBlock(let pageID, let blockID):
                guard let note = noteMap[pageID] else { return nil }
                let content = currentNote?.id == pageID ? body : note.body
                guard let block = BlockDocumentCodec.decode(content).block(blockID) else { return nil }
                let label = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let semantic = SemanticPresentation.find(block.metadata.semantic)
                let pageTitle = currentNote?.id == pageID ? title : note.title
                return SidebarRecentItem(id: id, title: label.isEmpty ? "Untitled block" : label,
                    symbol: semantic?.symbol ?? "square.stack", accessibilityLabel: "\(semantic?.title ?? "Semantic block"), \(label), in \(pageTitle)", pageID: pageID)
            }
        }
        sidebarRecentCacheRevision = libraryCatalogRevision
        sidebarRecentCacheEditorRevision = cloudEditorRevision
        return sidebarRecentCache
    }

    private func recentPreferenceKey(_ vaultID: UUID) -> String { "noema.sidebarRecentItems.v1.\(vaultID.uuidString)" }

    private func restoreSidebarRecentHistory(vaultID: UUID) {
        sidebarRecentVaultID = vaultID
        let decoded = sidebarRecentDefaults.data(forKey: recentPreferenceKey(vaultID))
            .flatMap { try? JSONDecoder().decode([RecentItemID].self, from: $0) } ?? []
        sidebarRecentHistory = SidebarRecentHistory(ids: decoded)
        sidebarRecentPresentation = SidebarRecentPresentation()
        sidebarRecentPresentation.reconcile(sidebarRecentHistory.ids)
        sidebarRecentCacheRevision = nil
    }

    private func persistSidebarRecentHistory() {
        guard let vaultID = sidebarRecentVaultID ?? repository?.manifest.id,
              let data = try? JSONEncoder().encode(sidebarRecentHistory.ids) else { return }
        sidebarRecentDefaults.set(data, forKey: recentPreferenceKey(vaultID))
    }

    private func recordSidebarAccess(_ id: RecentItemID) {
        guard canOperateOnLoadedContent, !isLocked else { return }
        sidebarRecentHistory.record(id)
        sidebarRecentPresentation.reconcile(sidebarRecentHistory.ids)
        sidebarRecentCacheRevision = nil
        persistSidebarRecentHistory()
    }

    private func pruneSidebarRecentHistory() {
        sidebarRecentCacheRevision = nil
        let valid = Set(sidebarRecentItems.map(\.id))
        sidebarRecentHistory.prune(keeping: valid)
        if let selectedSidebarRecentItemID, !valid.contains(selectedSidebarRecentItemID) { self.selectedSidebarRecentItemID = nil }
        persistSidebarRecentHistory()
    }

    func openSidebarRecentItem(_ id: RecentItemID) {
        guard canInteractWithWorkspace else { return }
        switch id {
        case .page(let pageID): select(pageID, scope: .wiki)
        case .source(let sourceID): select(sourceID, scope: .sources, previewSource: true)
        case .semanticBlock(let pageID, let blockID): select(pageID, scope: .wiki, block: blockID)
        }
        // History recording must not steal the collection highlight. Only this explicit choice does.
        switch id {
        case .page(let pageID):
            if currentNote?.id == pageID { selectedSidebarRecentItemID = id }
        case .source(let sourceID):
            if currentSource?.id == sourceID { selectedSidebarRecentItemID = id }
        case .semanticBlock(let pageID, let blockID):
            if currentNote?.id == pageID, selectedSemanticID == "\(pageID):\(blockID)" { selectedSidebarRecentItemID = id }
        }
    }
    var linkSuggestions: [NoteRecord] {
        guard let wikiQuery else { return [] }
        return Array(notes.filter { wikiQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(wikiQuery) }.sorted { $0.title < $1.title }.prefix(6))
    }

    struct AIProcessingClient: Sendable {
        var unavailabilityReason: @Sendable () -> String?
        var summarize: @Sendable (String) async throws -> String
        var inferLCC: @Sendable (String) async -> String?
        var lccCode: @Sendable (String) async throws -> String?
        var pageTitle: @Sendable (String) async throws -> String?
        var pageFromTopic: @Sendable (String, String) async throws -> String
        var pageFromSource: @Sendable (String) async throws -> String
        var researchTopic: @Sendable (String) async throws -> [WebTopicResult]
        // Optional only for legacy injected clients; production always generates one structured result.
        var enrich: (@Sendable (String, ExternalAIEnrichmentMode) async throws -> ExternalAIEnrichment)? = nil

        static let live = AIProcessingClient(
            unavailabilityReason: { OnDeviceSummary.unavailabilityReason },
            summarize: { try await OnDeviceSummary().summarize($0) },
            inferLCC: { await OnDeviceSummary().inferLCC($0) },
            lccCode: { try await OnDeviceSummary().lccCode($0) },
            pageTitle: { try await OnDeviceSummary().pageTitle($0) },
            pageFromTopic: { try await OnDeviceSummary().pageFromTopic($0, context: $1) },
            pageFromSource: { try await OnDeviceSummary().pageFromSource($0) },
            researchTopic: { try await WebTopicResearch.research($0) },
            enrich: { try await OnDeviceSummary().enrich($0, mode: $1) }
        )
    }

    var staleResultGuard: VaultStaleResultGuard { sessionManager.staleResultGuard }

    func issueCompletionTicket(
        kind: VaultCompletionKind,
        targetID: UUID? = nil,
        capturedText: String? = nil
    ) -> VaultCompletionTicket {
        sessionManager.issueCompletionTicket(
            kind: kind,
            lease: activeLease,
            token: generation,
            targetID: targetID,
            capturedText: capturedText
        )
    }

    @discardableResult
    func validateCompletion(
        _ ticket: VaultCompletionTicket?,
        expectedTargetID: UUID? = nil,
        checkTargetID: Bool = false,
        currentText: String? = nil,
        operation: String? = nil
    ) -> Result<VaultSession?, VaultStaleCompletionError> {
        sessionManager.staleResultGuard.validate(
            ticket,
            expectedToken: generation,
            expectedTargetID: expectedTargetID,
            checkTargetID: checkTargetID,
            currentText: currentText,
            operation: operation
        )
    }

    func isCompletionValid(
        _ ticket: VaultCompletionTicket?,
        expectedTargetID: UUID? = nil,
        checkTargetID: Bool = false,
        currentText: String? = nil,
        operation: String? = nil
    ) -> Bool {
        guard case .success = validateCompletion(
            ticket,
            expectedTargetID: expectedTargetID,
            checkTargetID: checkTargetID,
            currentText: currentText,
            operation: operation
        ) else {
            return false
        }
        return !isLocked && canOperateOnLoadedContent
    }

    private func cancelAllAsyncWork() {
        cancelCloudSummary()
        autosaveTask?.cancel(); autosaveTask = nil
        queryTask?.cancel(); queryTask = nil
        refreshTask?.cancel(); refreshTask = nil
        previewTask?.cancel(); previewTask = nil
        aiSummaryTask?.cancel(); aiSummaryTask = nil
        pageLCCTask?.cancel(); pageLCCTask = nil
        sourceDownloadTask?.cancel(); sourceDownloadTask = nil; sourceDownloadQueue = []; downloadingSources = []
        sourceNamingTask?.cancel(); sourceNamingTask = nil; sourceNamingQueue = []; sourceNamingOverrides = []
        sourceAvailabilityTask?.cancel(); sourceAvailabilityTask = nil; sourceAvailabilityQueue = []
        sourceAvailability = [:]; checkingSourceAvailability = []
        lccSaveTask?.cancel(); lccSaveTask = nil
        for (_, task) in sourceLCCSaveTasks { task.cancel() }
        sourceLCCSaveTasks.removeAll()
        for (_, task) in sourceLCCTasks { task.cancel() }
        sourceLCCTasks.removeAll()
        for (_, task) in sourcePageTasks { task.cancel() }
        sourcePageTasks.removeAll()
        for (_, task) in sourceSummaryTasks { task.cancel() }
        sourceSummaryTasks.removeAll()
        for (_, task) in titleTasks { task.cancel() }
        titleTasks.removeAll(); untitledPages.removeAll()
        showTopicPage = false; generatingTopicPage = false
        nativePageSummaryRequestID = nil; nativePageSummaryID = nil; nativeSourceSummaryIDs.removeAll()
        explicitTitleTask?.cancel(); explicitTitleTask = nil; generatingPageTitle = false
        aiProviderNotice = nil
        generatingAISummary = false; aiSummaryNotice = nil
        generatingPageLCC = false; generatingSourceLCCs = []
        generatingSourcePages = []; generatingSourceSummaries = []
        generatingSourceTitles = []; sourceRenameCompleted = 0; sourceRenameTotal = 0
        updatingSourceReferences = false; editingLockOperations.removeAll()
        trashOperationInProgress = false
        refreshing = false; pendingRefresh = false; progressTicket = nil; saving = false
    }

    private func releaseActiveVaultResources() {
        suspendAIProcessing()
        vaultCommandPanel?.cancel(nil)
        sourceCommandPanel?.cancel(nil)
        vaultCommandPanel = nil; sourceCommandPanel = nil
        isChoosingVault = false; isChoosingSource = false
        SourceReader.closeAll()
        if let scopeURL { securityScopeReleaser(scopeURL); self.scopeURL = nil }
        cancelAllAsyncWork()
        generation = UUID()
        activeSession = nil
        activeLease = nil
        repository = nil
        index = nil
        semanticIndex = nil
        semanticProcessingGeneration = nil
        semanticIndexIssue = nil
        semanticIndexCompatibility = .unavailable
        recovery = nil
        root = nil
    }

    private func clearSessionUIState() {
        pendingSemanticOccurrence = nil; semanticOccurrenceNavigationTicket = UUID()
        semanticInspectionTicket = UUID(); semanticInspectionRecords = []
        semanticInspectionPageID = nil; semanticInspectionSelectionIDs = []; semanticInspectionFocusID = nil
        semanticInspectionLoading = false; semanticInspectionError = nil; semanticCoordinator = nil; semanticReadyIdentity = nil
        navigationSaveTask = nil; navigationSaveQueue = []; pendingPageSaves = [:]; pageSaveFailures = [:]
        libraryRowsRevision = nil; libraryRowsScope = nil; libraryRowsEditorRevision = nil
        knowledgeCatalogueTicket = UUID(); knowledgeCatalogue = nil; knowledgeCatalogueLoading = false; knowledgeCatalogueError = nil
        semanticRowsRevision = nil; semanticRowsEditorRevision = nil
        notes = []; sources = []; rows = []; semanticRows = []; trashedPages = []; recoveredDrafts = []; damagedRecoveryEntries = []; issues = []
        dismissedVaultNotices = []
        tags = []; backlinks = []; outgoingLinkTargets = []; preview = []; unseenRenamedPages = []
        organisationContainers = []; organisationMemberships = []; organisationMutationInProgress = false
        favouriteReferences = []; favouriteMutationInProgress = false
        sidebarRecentHistory = SidebarRecentHistory(); sidebarRecentVaultID = nil
        sidebarRecentPresentation = SidebarRecentPresentation()
        selectedSidebarRecentItemID = nil; sidebarRecentCacheRevision = nil; sidebarRecentCache = []
        resetSearch(); scope = .wiki
        setLibrarySourceSelection(nil)
        selectedID = nil; selectedSemanticID = nil; currentNote = nil; currentSource = nil
        title = ""; body = ""; tagInput = ""; lccInput = ""; wordCount = 0
        editorNotice = nil; editingHint = nil; editorReadOnly = false; externalChange = false
        showRecovery = false; showTopicPage = false; generatingTopicPage = false
        showURLSource = false; showPasteSource = false; showIssues = false
        ambiguousMatches = []; unresolvedTarget = nil; wikiQuery = nil; editorAction = nil
        saveStatus = "Saved locally"; busy = false
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        if let storeError = error as? VaultContentStoreError {
            switch storeError {
            case .coordination(let domain, let code, let message),
                 .io(let domain, let code, let message):
                if domain == NSCocoaErrorDomain && code == NSFileReadNoPermissionError { return true }
                if domain == NSPOSIXErrorDomain && code == Int(EACCES) { return true }
                if message.localizedCaseInsensitiveContains("permission") { return true }
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EACCES) { return true }
        if nsError.localizedDescription.localizedCaseInsensitiveContains("permission")
            || nsError.localizedDescription.localizedCaseInsensitiveContains("reselect your vault folder") {
            return true
        }
        return false
    }

    var aiProviderNotice: String?
    private var providerPreflightTask: Task<Void, Never>?
    private var providerPreflightTarget: ExternalAISummaryTarget?
    private var providerPreflightID: UUID?
    private var nativePageSummaryID: UUID?
    private var nativePageSummaryRequestID: UUID?
    private var nativeSourceSummaryIDs: [UUID: UUID] = [:]
    private var explicitTitleTask: Task<Void, Never>?
    var generatingPageTitle = false

    var vaultAISettingsContext: VaultAISettingsContext? {
        guard isVaultAvailable, let lease = sessionManager.accessGate.currentLease else { return nil }
        return .init(lease: lease, vaultName: vaultName,
                     configuration: vaultAIConfigurationStore.configuration(for: lease.vaultID))
    }

    var activeVaultAIConfiguration: VaultAIConfiguration? { vaultAISettingsContext?.configuration }

    func vaultAIConfiguration(for lease: VaultSessionLease) -> VaultAIConfiguration? {
        guard let context = vaultAISettingsContext, context.lease == lease else { return nil }
        return context.configuration
    }

    func setVaultAIConfiguration(_ configuration: VaultAIConfiguration, for lease: VaultSessionLease) throws {
        guard vaultAIConfiguration(for: lease) != nil else { throw ExternalAIError.staleSession }
        // Commit local intent and revoke all runtime work before fallible Keychain I/O.
        semanticPublicationAuthority?.invalidate()
        externalAIService.invalidateEmbeddingRequests()
        try vaultAIConfigurationStore.set(configuration, lease: lease, gate: sessionManager.accessGate)
        suspendAIProcessing()
        if let repository {
            Task { await bindAIProcessing(repository: repository, lease: lease) }
        }
        sourceNamingTask?.cancel()
        sourceNamingQueue.removeAll()
        for task in titleTasks.values { task.cancel() }
        externalAIService.revokeAuthorization()
        if !configuration.enabled || configuration.provider != .openAI {
            do { try externalAIService.revokeVaultProcessing(for: lease) }
            catch { throw VaultAIConfigurationChangeError.cloudGrantCleanupFailed }
        }
    }

    private func providerAvailability(for action: AIAction, execution: AIProviderExecution = .userInvoked,
                                      openAIConfigured: Bool? = nil) -> AIProviderAvailability {
        var local: AIProviderStatus = aiClient.unavailabilityReason() == nil ? .available : .unavailable(.localModelUnavailable)
        if execution == .userInvoked, action == .summarizePage,
           !aiPreferenceDefaults.bool(forKey: EditorPreferences.aiSummariesKey) {
            local = .unavailable(.localDisabled)
        }
        let cloud: AIProviderStatus
        if let configured = openAIConfigured { cloud = configured ? .available : .unavailable(.missingCredentials) }
        else if cloudSummaryOverride != nil { cloud = .available }
        else { cloud = externalAIService.openAIProviderStatus }
        return .init(onDevice: local, openAI: cloud)
    }

    private func automaticLocalAIValidation(for action: AIAction) -> (@Sendable () throws -> Void)? {
        guard let context = vaultAISettingsContext,
              VaultAIPolicyResolver.resolve(configuration: context.configuration, action: action,
                  execution: .automatic, availability: providerAvailability(for: action, execution: .automatic)) == .permitted(.onDevice)
        else { return nil }
        return try? vaultAIConfigurationStore.localPublicationValidation(lease: context.lease, gate: sessionManager.accessGate)
    }

    func preferredAIProvider(for action: AIAction, temporaryOverride: AIProvider? = nil) -> AIProvider {
        activeVaultAIConfiguration?.provider ?? temporaryOverride ?? aiProviderPreferences.settings.preferredProvider(for: action)
    }

    private func resolveAIAction(_ action: AIAction, provider: AIProvider? = nil, openAIConfigured: Bool? = nil) -> AIProviderResolution {
        let policy = activeVaultAIConfiguration ?? VaultAIConfiguration(
            provider: temporaryProviderForUnadmittedContent(action, override: provider))
        let decision = VaultAIPolicyResolver.resolve(configuration: policy, action: action,
            execution: .userInvoked, availability: providerAvailability(for: action, openAIConfigured: openAIConfigured))
        let resolution = decision.providerResolution(for: policy.provider)
        if !resolution.isEligible { aiProviderNotice = resolution.errorMessage }
        else { aiProviderNotice = nil }
        return resolution
    }

    private func temporaryProviderForUnadmittedContent(_ action: AIAction, override: AIProvider?) -> AIProvider {
        override ?? aiProviderPreferences.settings.preferredProvider(for: action)
    }

    private func admitsNativeAction(_ action: AIAction, provider: AIProvider? = nil) -> Bool {
        let resolution = resolveAIAction(action, provider: provider)
        return resolution.isEligible && resolution.provider == .onDevice
    }

    func requestPageSummary(id: UUID, provider: AIProvider? = nil) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !hasPendingCloudSummary, pendingAISuggestion == nil, explicitTitleTask == nil, !isSummarizing(target: .page(id)) else { return }
        if preferredAIProvider(for: .summarizePage, temporaryOverride: provider) == .onDevice {
            guard currentNote?.id == id else {
                aiProviderNotice = "Open this page before generating an on-device summary."
                return
            }
            guard admitsNativeAction(.summarizePage, provider: provider) else { return }
            summarizePage()
        } else { preparePreferredCloudSummary(target: .page(id), action: .summarizePage) }
    }

    func requestSourceSummary(_ source: SourceRecord, provider: AIProvider? = nil) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !hasPendingCloudSummary, pendingAISuggestion == nil, explicitTitleTask == nil, !isSummarizing(target: .source(source.id)) else { return }
        if preferredAIProvider(for: .summarizeSource, temporaryOverride: provider) == .onDevice {
            guard admitsNativeAction(.summarizeSource, provider: provider) else { return }
            generateSourceSummary(source)
        } else { preparePreferredCloudSummary(target: .source(source.id), action: .summarizeSource) }
    }

    private func preparePreferredCloudSummary(target: ExternalAISummaryTarget, action: AIAction) {
        guard providerPreflightTarget == nil, cloudSummaryTarget == nil, cloudSummaryConfirmation == nil,
              let lease = sessionManager.accessGate.currentLease else {
            aiProviderNotice = "Open and unlock a vault before using OpenAI."
            return
        }
        let identity = UUID(), selection = selectedID, revision = cloudEditorRevision
        providerPreflightID = identity; providerPreflightTarget = target
        providerPreflightTask = Task {
            defer {
                if providerPreflightID == identity {
                    providerPreflightID = nil; providerPreflightTarget = nil; providerPreflightTask = nil
                }
            }
            let configured: Bool
            if let refresh = cloudCredentialAvailabilityOverride { configured = await refresh() }
            else if cloudSummaryOverride != nil { configured = true }
            else {
                await externalAIService.refreshStatus()
                configured = externalAIService.credentialStatus?.isAvailable == true
            }
            guard !Task.isCancelled, providerPreflightID == identity,
                  lease == sessionManager.accessGate.currentLease, selectedID == selection,
                  revision == cloudEditorRevision else { return }
            providerPreflightTarget = nil; providerPreflightTask = nil
            let resolution = resolveAIAction(action, provider: .openAI, openAIConfigured: configured)
            guard resolution.isEligible, resolution.provider == .openAI else { return }
            prepareCloudSummary(target: target, action: action == .suggestTitle ? .suggestTitle : action == .classifyLCC ? .lccClassification : nil)
        }
    }

    var hasPendingCloudSummary: Bool {
        providerPreflightTarget != nil || cloudSummaryTarget != nil || cloudSummaryConfirmation != nil
    }

    var nativePageSummaryTaskForTesting: Task<Void, Never>? { aiSummaryTask }
    func nativeSourceSummaryTaskForTesting(id: UUID) -> Task<Void, Never>? { sourceSummaryTasks[id] }
    var automaticSourceNamingTaskForTesting: Task<Void, Never>? { sourceNamingTask }

    func activeSummaryProvider(for target: ExternalAISummaryTarget) -> AIProvider? {
        if providerPreflightTarget == target || cloudSummaryTarget == target || cloudSummaryConfirmation?.request.target == target { return .openAI }
        return isSummarizing(target: target) ? .onDevice : nil
    }

    func isSummarizing(target: ExternalAISummaryTarget) -> Bool {
        if providerPreflightTarget == target || cloudSummaryTarget == target || cloudSummaryConfirmation?.request.target == target { return true }
        switch target {
        case .page(let id): return generatingAISummary && nativePageSummaryID == id
        case .source(let id): return generatingSourceSummaries.contains(id) || generatingSourceTitles.contains(id)
        }
    }

    func cancelSummary(target: ExternalAISummaryTarget) {
        let provider = activeSummaryProvider(for: target)
        if providerPreflightTarget == target || cloudSummaryTarget == target || cloudSummaryConfirmation?.request.target == target { cancelCloudSummary() }
        switch target {
        case .page(let id):
            if nativePageSummaryID == id {
                nativePageSummaryRequestID = nil
                aiSummaryTask?.cancel(); aiSummaryTask = nil
                generatingAISummary = false; nativePageSummaryID = nil
            }
        case .source(let id):
            nativeSourceSummaryIDs.removeValue(forKey: id)
            sourceSummaryTasks[id]?.cancel(); sourceSummaryTasks.removeValue(forKey: id)
            generatingSourceSummaries.remove(id)
        }
        aiProviderNotice = provider == .openAI
            ? "Summary cancelled. Text already sent to OpenAI cannot be recalled."
            : "On-device summary cancelled."
    }

    var pendingAISuggestion: AISuggestion?
    private struct AISuggestionContext: Sendable {
        let snapshot: CloudSummarySnapshot
        let selection: UUID?
        let editorRevision: UUID
        let provenance: SummaryProvenance
        let validate: @Sendable () throws -> Void
    }
    private var pendingAISuggestionContext: AISuggestionContext?
    private var suggestionRequestID: UUID?
    var aiSuggestionTaskForTesting: Task<Void, Never>? { explicitTitleTask }
    private var suggestionAcceptanceID: UUID?
    private var suggestionAcceptanceTask: Task<Void, Never>?
    var aiSuggestionAcceptanceTaskForTesting: Task<Void, Never>? { suggestionAcceptanceTask }

    private static func contentRevision(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sourceRevision(_ snapshot: CloudSummarySnapshot) -> String {
        switch snapshot {
        case .page(let page): return page.sourceRevision
        case .source(let source): return source.sourceRevision
        }
    }

    private static func enrichmentMode(_ snapshot: CloudSummarySnapshot) -> ExternalAIEnrichmentMode {
        switch snapshot {
        case .page(let page): return BlockDocumentCodec.decode(page.note.body).aiSummary == nil ? .initial : .regenerate
        case .source(let source): return source.source.metadata.aiSummary == nil ? .initial : .regenerate
        }
    }

    private static func classification(_ suggestion: ExternalAILCCSuggestion?, provenance: SummaryProvenance) -> LCCClassification? {
        guard let suggestion else { return nil }
        return LCCClassification(code: suggestion.code, level: suggestion.level, caption: suggestion.caption,
            provenance: provenance, classifiedAt: provenance.generatedAt)
    }

    private func nativeEnrichment(_ client: AIProcessingClient, text: String, mode: ExternalAIEnrichmentMode) async throws -> ExternalAIEnrichment {
        if let enrich = client.enrich { return try await enrich(text, mode) }
        // Compatibility seam for pre-enrichment injected clients; never used by the live provider.
        return try ExternalAIEnrichment(title: nil, summary: try await client.summarize(text), classification: nil, body: nil)
    }

    /// Failed debounced saves must not turn optimistic manual edits into AI overwrite targets.
    private func validateEditableMetadata(_ snapshot: CloudSummarySnapshot) throws {
        switch snapshot {
        case .page(let page):
            if currentNote?.id == page.note.id {
                let lcc = lccInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard title == page.note.title, editedTags == page.note.tags,
                      (lcc.isEmpty ? nil : lcc) == page.note.lcc else { throw ExternalAIError.staleContent }
            }
        case .source(let source):
            if let current = sources.first(where: { $0.id == source.source.id }) {
                guard current.title == source.source.title, current.metadata.lcc == source.source.metadata.lcc,
                      current.metadata.aiSummary == source.source.metadata.aiSummary else { throw ExternalAIError.staleContent }
            }
        }
    }

    func didDismissAISuggestionReview() {
        if pendingAISuggestionContext != nil { dismissAISuggestion() }
    }

    func dismissAISuggestion() {
        // An in-flight acceptance owns its final review outcome: cancellation
        // must not race a canonical write that has already committed.
        let rejectedID = pendingAISuggestion?.id
        if let rejectedID {
            let recorder = activityRecorder
            Task { await recorder.updateOutcome(rejectedID, outcome: .rejected) }
        }
        pendingAISuggestion = nil; pendingAISuggestionContext = nil
        suggestionRequestID = nil
        explicitTitleTask?.cancel(); explicitTitleTask = nil
        suggestionAcceptanceID = nil
        suggestionAcceptanceTask?.cancel(); suggestionAcceptanceTask = nil
        generatingPageTitle = false; generatingPageLCC = false; generatingSourceLCCs.removeAll()
        cloudPublicationGuard.invalidate()
    }

    /// Resolve intent before the first await. Captured provider/client remain stable for this request.
    private func requestAISuggestion(target: ExternalAISummaryTarget, action: AIAction, provider: AIProvider? = nil) {
        guard canOperateOnLoadedContent, !hasPendingCloudSummary, pendingAISuggestion == nil,
              explicitTitleTask == nil, suggestionAcceptanceTask == nil, let repository,
              let lease = sessionManager.accessGate.currentLease else { return }
        if case .source(let id) = target {
            guard !downloadingSources.contains(id), !generatingSourceTitles.contains(id),
                  !generatingSourceSummaries.contains(id), !generatingSourceLCCs.contains(id) else { return }
        }
        if preferredAIProvider(for: action, temporaryOverride: provider) == .openAI {
            preparePreferredCloudSummary(target: target, action: action)
            return
        }
        guard admitsNativeAction(action, provider: .onDevice) else { return }
        let identity = UUID(), selection = selectedID, client = aiClient
        suggestionRequestID = identity
        if case .page = target {
            if action == .suggestTitle { generatingPageTitle = true } else { generatingPageLCC = true }
        } else if action == .classifyLCC { generatingSourceLCCs.insert(target.id) }
        explicitTitleTask = Task {
            await withLocalAIActivity(id: identity, target: target, action: action == .suggestTitle ? .suggestTitle : .classifyLCC) { activity in
                defer {
                    if suggestionRequestID == identity {
                        generatingPageTitle = false; generatingPageLCC = false
                        generatingSourceLCCs.remove(target.id); explicitTitleTask = nil
                    }
                }
                do {
                    let snapshot: CloudSummarySnapshot
                    let input: String
                    var revision = cloudEditorRevision
                    switch target {
                    case .page(let id):
                        await lccSaveTask?.value
                        guard currentNote?.id == id, !editingLocked, !externalChange,
                              await saveCurrent(), let note = currentNote else { throw ExternalAIError.staleContent }
                        revision = cloudEditorRevision
                        let page = try await repository.pageSummarySnapshot(note)
                        snapshot = .page(page)
                        let text = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(
                            BlockDocumentCodec.decode(page.note.body).withoutAISummary))
                        input = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && action == .classifyLCC ? page.note.title : text
                    case .source(let id):
                        await sourceLCCSaveTasks[id]?.value
                        guard revision == cloudEditorRevision else { throw ExternalAIError.staleContent }
                        let source = try await repository.sourceSummarySnapshot(id: id)
                        snapshot = .source(source)
                        input = try await Task.detached { try CloudSummaryConfirmation.extractedText(source) }.value
                    }
                    try Task.checkCancellation()
                    guard suggestionRequestID == identity, selectedID == selection,
                          lease == sessionManager.accessGate.currentLease else { throw ExternalAIError.staleSession }
                    guard revision == cloudEditorRevision else { throw ExternalAIError.staleContent }
                    try validateEditableMetadata(snapshot)
                    guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExternalAIError.emptyContent }
                    cloudPublicationGuard.arm(requestID: identity)
                    try await activity.start(contentSizeBytes: input.utf8.count)
                    let value: String
                    if action == .suggestTitle {
                        guard let generated = try await client.pageTitle(String(input.prefix(6000))),
                              let clean = OnDeviceSummary.cleanTitle(generated),
                              clean.split(whereSeparator: \.isWhitespace).count <= 8 else { throw ExternalAIError.invalidResponse }
                        value = clean
                    } else {
                        guard let generated = try await client.lccCode(String(input.prefix(6000))),
                              let clean = OnDeviceSummary.cleanLCC(generated),
                              let validated = LCCClassificationVocabulary.suggestionCode(fromCallNumber: clean) else { throw ExternalAIError.invalidResponse }
                        value = validated
                    }
                    try Task.checkCancellation()
                    try cloudPublicationGuard.validate(requestID: identity)
                    guard suggestionRequestID == identity, selectedID == selection, revision == cloudEditorRevision,
                          lease == sessionManager.accessGate.currentLease else { throw ExternalAIError.staleContent }
                    activity.complete(outcome: .suggested)
                    await activity.finalize()
                    try Task.checkCancellation()
                    try cloudPublicationGuard.validate(requestID: identity)
                    guard suggestionRequestID == identity, selectedID == selection, revision == cloudEditorRevision,
                          lease == sessionManager.accessGate.currentLease else { throw ExternalAIError.staleContent }
                    pendingAISuggestion = AISuggestion(id: identity, action: action, value: value, rationale: nil,
                        provider: .onDevice, target: target)
                    pendingAISuggestionContext = AISuggestionContext(snapshot: snapshot, selection: selection,
                        editorRevision: revision, provenance: SummaryProvenance(provider: "On-device", model: "Apple Intelligence",
                            generatedAt: Date(), sourceRevision: Self.sourceRevision(snapshot)), validate: { try Task.checkCancellation() })
                } catch {
                    activity.fail(error)
                    guard suggestionRequestID == identity, !Task.isCancelled else { return }
                    aiProviderNotice = Self.cloudError(error)
                }
            }
        }
    }

    func acceptAISuggestion() {
        guard let suggestion = pendingAISuggestion, let context = pendingAISuggestionContext,
              canOperateOnLoadedContent, let repository, suggestionAcceptanceTask == nil else { return }
        pendingAISuggestion = nil; pendingAISuggestionContext = nil
        let ticket = generation, publicationGuard = cloudPublicationGuard
        suggestionAcceptanceID = suggestion.id
        suggestionAcceptanceTask = Task {
            defer {
                if generation == ticket, suggestionAcceptanceID == suggestion.id {
                    suggestionAcceptanceID = nil; suggestionAcceptanceTask = nil
                }
            }
            do {
                guard generation == ticket, selectedID == context.selection,
                      cloudEditorRevision == context.editorRevision else { throw ExternalAIError.staleContent }
                try publicationGuard.validate(requestID: suggestion.id)
                try validateEditableMetadata(context.snapshot)
                let validate: @Sendable () throws -> Void = {
                    try publicationGuard.validate(requestID: suggestion.id)
                    try context.validate()
                }
                switch context.snapshot {
                case .page(let page):
                    guard !editingLocked, !externalChange, currentNote?.id == page.note.id,
                          body == page.note.body else { throw ExternalAIError.staleContent }
                    let saved: NoteRecord
                    if suggestion.action == .suggestTitle {
                        saved = try await repository.publishPageTitle(page, title: suggestion.value, provenance: context.provenance, validate: validate)
                    } else {
                        saved = try await repository.publishPageLCC(page, lcc: suggestion.value, provenance: context.provenance, validate: validate)
                    }
                    await activityRecorder.updateOutcome(suggestion.id, outcome: .published)
                    guard generation == ticket, canOperateOnLoadedContent else { return }
                    recordPageRename(saved.id, from: page.note.title, to: saved.title)
                    if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                    if currentNote?.id == saved.id, cloudEditorRevision == context.editorRevision { apply(saved) }
                case .source(let source):
                    let saved: SourceRecord
                    if suggestion.action == .suggestTitle {
                        saved = try await repository.publishSourceTitle(source, title: suggestion.value, provenance: context.provenance, validate: validate)
                    } else {
                        saved = try await repository.publishSourceLCC(source, lcc: suggestion.value, provenance: context.provenance, validate: validate)
                    }
                    await activityRecorder.updateOutcome(suggestion.id, outcome: .published)
                    guard generation == ticket, canOperateOnLoadedContent else { return }
                    if let i = sources.firstIndex(where: { $0.id == saved.id }) { sources[i] = saved }
                    if currentSource?.id == saved.id { currentSource = saved }
                    SourceReader.updateTitle(id: saved.id, title: saved.title)
                }
                await refresh()
            } catch {
                await activityRecorder.updateOutcome(suggestion.id, outcome: .rejected)
                if generation == ticket, !Task.isCancelled { aiProviderNotice = Self.cloudError(error) }
            }
        }
    }

    var cloudSummaryConfirmation: CloudSummaryConfirmation?
    var cloudSummaryTarget: ExternalAISummaryTarget?
    var cloudSummaryError: String?
    private let cloudPublicationGuard = CloudSummaryPublicationGuard()
    private var cloudEditorRevision = UUID()
    private var cloudSummaryTask: Task<Void, Never>?
    /// Tests capture a pending worker before cancellation so assertions wait for its completion.
    var cloudSummaryTaskForTesting: Task<Void, Never>? { cloudSummaryTask }
    private var cloudActivityID: UUID?
    private var cloudRequestID: UUID?
    /// Test seam: restricted, consent-bound summaries only; production always uses the gateway.
    /// Test seam for preflight status only; it cannot grant gateway authorization or consent.
    var cloudCredentialAvailabilityOverride: (@Sendable () async -> Bool)?
    var cloudSummaryOverride: (@Sendable (ExternalAISummaryRequest, ExternalAIContentConsent) async throws -> ExternalAISummaryResult)?
    var cloudPublicationOverride: (@Sendable (ExternalAISummaryResult) async throws -> (@Sendable () throws -> Void))?

    func cancelCloudSummary() {
        if let activityID = cloudActivityID, cloudSummaryConfirmation != nil {
            let recorder = activityRecorder
            Task { await recorder.finish(activityID, status: .cancelled, failureCode: .cancelled) }
            cloudActivityID = nil
        }
        cancelAIPage()
        dismissAISuggestion()
        providerPreflightID = nil
        providerPreflightTask?.cancel(); providerPreflightTask = nil; providerPreflightTarget = nil
        cloudPublicationGuard.invalidate()
        cloudRequestID = nil
        cloudSummaryTask?.cancel(); cloudSummaryTask = nil
        cloudSummaryTarget = nil; cloudSummaryConfirmation = nil; cloudSummaryError = nil
    }

    func prepareCloudPageSummary(id: UUID) { prepareCloudSummary(target: .page(id)) }
    func prepareCloudSourceSummary(_ source: SourceRecord) { prepareCloudSummary(target: .source(source.id)) }

    private func prepareCloudSummary(target: ExternalAISummaryTarget, action: ExternalAIAction? = nil) {
        guard canOperateOnLoadedContent, let repository, let lease = sessionManager.accessGate.currentLease,
              cloudSummaryTarget == nil, cloudSummaryConfirmation == nil else { return }
        cancelCloudSummary()
        let identity = UUID()
        cloudRequestID = identity; cloudSummaryTarget = target
        let selection = selectedID
        cloudSummaryTask = Task {
            var createdActivityID: UUID?
            do {
                let snapshot: CloudSummarySnapshot
                let text: String
                let itemTitle: String
                var revision = cloudEditorRevision
                switch target {
                case .page(let id):
                    if currentNote?.id == id {
                        await lccSaveTask?.value
                        guard !editingLocked, !generatingAISummary, await saveCurrent() else { throw ExternalAIError.staleContent }
                    }
                    revision = cloudEditorRevision
                    guard let note = notes.first(where: { $0.id == id }) ?? (currentNote?.id == id ? currentNote : nil) else { throw ExternalAIError.staleContent }
                    let page = try await repository.pageSummarySnapshot(note)
                    snapshot = .page(page)
                    itemTitle = note.title
                    text = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(page.note.body).withoutAISummary))
                case .source(let id):
                    guard !downloadingSources.contains(id), !generatingSourceTitles.contains(id), !generatingSourceSummaries.contains(id) else { throw ExternalAIError.staleContent }
                    await sourceLCCSaveTasks[id]?.value
                    guard revision == cloudEditorRevision else { throw ExternalAIError.staleContent }
                    let source = try await repository.sourceSummarySnapshot(id: id)
                    snapshot = .source(source); itemTitle = source.source.title
                    text = try CloudSummaryConfirmation.extractedText(source)
                }
                try Task.checkCancellation()
                guard cloudRequestID == identity, selectedID == selection, revision == cloudEditorRevision,
                      ExternalAIVaultAuthority(lease: lease).matches(sessionManager.accessGate.currentLease) else { throw ExternalAIError.staleSession }
                try validateEditableMetadata(snapshot)
                let request = try ExternalAISummaryRequest(authority: ExternalAIVaultAuthority(lease: lease),
                    target: target, contentRevision: UUID(), content: text, action: action,
                    mode: Self.enrichmentMode(snapshot))
                let presentation = await externalAIService.consentPresentation(for: request.authority)
                try Task.checkCancellation()
                guard cloudRequestID == identity, selectedID == selection, revision == cloudEditorRevision,
                      request.authority.matches(sessionManager.accessGate.currentLease) else { throw ExternalAIError.staleSession }
                let configuration = externalAIService.configuration
                createdActivityID = request.id
                cloudActivityID = request.id
                await activityRecorder.begin(id: request.id, vaultID: lease.vaultID,
                    target: AIActivityTarget(type: target.isPageActivityTarget ? .page : .source, id: target.id),
                    action: request.action.activityAction, executionMode: .userInvoked, provider: .openAI,
                    modelID: configuration.model, contentSizeBytes: request.content.utf8.count)
                try Task.checkCancellation()
                guard cloudRequestID == identity, selectedID == selection, revision == cloudEditorRevision,
                      request.authority.matches(sessionManager.accessGate.currentLease) else {
                    throw ExternalAIError.staleSession
                }
                guard configuration == externalAIService.configuration else { throw ExternalAIError.staleContent }
                cloudSummaryConfirmation = CloudSummaryConfirmation(request: request, snapshot: snapshot,
                    title: itemTitle, model: configuration.model,
                    selection: selection, editorRevision: revision, presentation: presentation)
                cloudSummaryTarget = nil; cloudSummaryTask = nil
                if try !externalAIService.requiresSubmissionConfirmation(for: request.authority) {
                    confirmCloudSummary(userConfirmed: false)
                }
            } catch {
                if let activityID = createdActivityID {
                    let failure = AIActivityOperation.failure(error)
                    await activityRecorder.finish(activityID, status: failure.status, failureCode: failure.code)
                    if cloudActivityID == activityID { cloudActivityID = nil }
                }
                guard cloudRequestID == identity else { return }
                cloudSummaryTarget = nil; cloudSummaryTask = nil
                cloudSummaryError = Self.cloudError(error)
            }
        }
    }

    func confirmCloudSummary(userConfirmed: Bool = true) {
        guard let confirmation = cloudSummaryConfirmation, canOperateOnLoadedContent else { return }
        cloudSummaryConfirmation = nil
        let request = confirmation.request
        let identity = cloudRequestID
        let gateway = externalAIService.gateway
        let override = cloudSummaryOverride
        let publicationOverride = cloudPublicationOverride
        guard confirmation.model == externalAIService.configuration.model else {
            let recorder = activityRecorder
            Task { await recorder.finish(request.id, status: .cancelled, failureCode: .publication) }
            cloudActivityID = nil
            cloudSummaryError = ExternalAIError.staleContent.localizedDescription; return
        }
        cloudSummaryTarget = request.target
        cloudPublicationGuard.arm(requestID: request.id)
        let publicationGuard = cloudPublicationGuard
        cloudSummaryTask = Task {
            var suggestedInferenceCompleted = false
            defer {
                if cloudRequestID == identity { cloudSummaryTarget = nil; cloudSummaryTask = nil }
            }
            do {
                guard let repository, cloudRequestID == identity,
                      request.authority.matches(sessionManager.accessGate.currentLease),
                      selectedID == confirmation.selection else { throw ExternalAIError.staleSession }
                guard cloudEditorRevision == confirmation.editorRevision else { throw ExternalAIError.staleContent }
                if case .page(let page) = confirmation.snapshot, currentNote?.id == page.note.id {
                    guard body == page.note.body, cloudEditorRevision == confirmation.editorRevision,
                          !editingLocked, !externalChange else { throw ExternalAIError.staleContent }
                }
                let consent = try externalAIService.approveSubmission(request, userConfirmed: userConfirmed)
                let result: ExternalAISummaryResult
                if let override { result = try await override(request, consent) }
                else {
                    switch request.action {
                    case .summarizePage: result = try await gateway.summarizePage(request, consent: consent)
                    case .summarizeSource: result = try await gateway.summarizeSource(request, consent: consent)
                    case .suggestTitle: result = try await gateway.suggestTitle(request, consent: consent)
                    case .lccClassification: result = try await gateway.classifyLCC(request, consent: consent)
                    case .composePage: throw ExternalAIError.unsupportedAction
                    }
                }
                guard result.requestID == request.id, result.target == request.target,
                      result.contentRevision == request.contentRevision, result.authority == request.authority, result.action == request.action, result.mode == request.mode else { throw ExternalAIError.invalidResponse }
                let validate: @Sendable () throws -> Void
                if let publicationOverride { validate = try await publicationOverride(result) }
                else {
                    let permit = try await gateway.publicationPermit(for: result)
                    validate = { try permit.validateSynchronously() }
                }
                try Task.checkCancellation()
                guard cloudRequestID == identity, request.authority.matches(sessionManager.accessGate.currentLease),
                      selectedID == confirmation.selection else { throw ExternalAIError.staleSession }
                guard cloudEditorRevision == confirmation.editorRevision else { throw ExternalAIError.staleContent }
                let provenance = SummaryProvenance(provider: "OpenAI", model: result.provenance.model,
                    generatedAt: result.provenance.generatedAt, sourceRevision: Self.sourceRevision(confirmation.snapshot))
                if request.action == .suggestTitle || request.action == .lccClassification {
                    let value: String
                    let rationale: String?
                    if request.action == .suggestTitle {
                        guard let title = result.title else { throw ExternalAIError.invalidResponse }
                        value = title; rationale = nil
                    } else {
                        guard let suggestion = result.lccSuggestion else { throw ExternalAIError.invalidResponse }
                        value = suggestion.code; rationale = suggestion.rationale
                    }
                    try publicationGuard.validate(requestID: request.id)
                    await activityRecorder.finish(request.id, status: .completed, outcome: .suggested)
                    suggestedInferenceCompleted = true
                    try Task.checkCancellation()
                    try publicationGuard.validate(requestID: request.id)
                    guard cloudRequestID == identity, request.authority.matches(sessionManager.accessGate.currentLease),
                          selectedID == confirmation.selection, cloudEditorRevision == confirmation.editorRevision else {
                        throw ExternalAIError.staleContent
                    }
                    pendingAISuggestion = AISuggestion(id: request.id,
                        action: request.action == .suggestTitle ? .suggestTitle : .classifyLCC,
                        value: value, rationale: rationale, provider: .openAI, target: request.target)
                    pendingAISuggestionContext = AISuggestionContext(snapshot: confirmation.snapshot,
                        selection: confirmation.selection, editorRevision: confirmation.editorRevision,
                        provenance: provenance, validate: validate)
                    if cloudActivityID == request.id { cloudActivityID = nil }
                    return
                }
                switch confirmation.snapshot {
                case .page(let page):
                    if currentNote?.id == page.note.id {
                        guard body == page.note.body, cloudEditorRevision == confirmation.editorRevision,
                              !editingLocked, !externalChange, !generatingAISummary else { throw ExternalAIError.staleContent }
                    }
                    let saved = try await repository.publishPageEnrichment(page, summary: result.summary,
                        classification: Self.classification(result.enrichment?.classification, provenance: provenance),
                        title: request.mode == .initial ? result.enrichment?.title : nil, provenance: provenance, validate: {
                        try publicationGuard.validate(requestID: request.id)
                        try validate()
                    })
                    await activityRecorder.finish(request.id, status: .completed, outcome: .published)
                    if cloudActivityID == request.id { cloudActivityID = nil }
                    try Task.checkCancellation()
                    guard cloudRequestID == identity, request.authority.matches(sessionManager.accessGate.currentLease) else { return }
                    if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                    if currentNote?.id == saved.id, body == page.note.body, cloudEditorRevision == confirmation.editorRevision { apply(saved) }
                case .source(let source):
                    let saved = try await repository.publishSourceEnrichment(source, summary: result.summary,
                        classification: Self.classification(result.enrichment?.classification, provenance: provenance),
                        title: request.mode == .initial ? result.enrichment?.title : nil, provenance: provenance, validate: {
                        try publicationGuard.validate(requestID: request.id)
                        try validate()
                    })
                    await activityRecorder.finish(request.id, status: .completed, outcome: .published)
                    if cloudActivityID == request.id { cloudActivityID = nil }
                    try Task.checkCancellation()
                    guard cloudRequestID == identity, request.authority.matches(sessionManager.accessGate.currentLease) else { return }
                    if let i = sources.firstIndex(where: { $0.id == saved.id }) { sources[i] = saved }
                    if currentSource?.id == saved.id { currentSource = saved }
                }
                await refresh()
            } catch {
                if suggestedInferenceCompleted { await activityRecorder.updateOutcome(request.id, outcome: .rejected) }
                let failure = AIActivityOperation.failure(error)
                await activityRecorder.finish(request.id, status: failure.status, failureCode: failure.code)
                if cloudActivityID == request.id { cloudActivityID = nil }
                guard cloudRequestID == identity else { return }
                cloudSummaryError = Self.cloudError(error)
            }
        }
    }

    private static func cloudError(_ error: Error) -> String {
        if let typed = error as? ExternalAIError { return typed.localizedDescription }
        if error is CancellationError { return ExternalAIError.cancelled.localizedDescription }
        if error is VaultContentStoreError || error is VaultError { return ExternalAIError.staleContent.localizedDescription }
        return ExternalAIError.providerUnavailable.localizedDescription
    }

    func deleteAISummary() {
        flushEditorPublication?()
        guard let currentNote, !editingLocked, !isSummarizing(target: .page(currentNote.id)) else { return }
        var document = BlockDocumentCodec.decode(body)
        guard document.removeAISummary() else { return }
        editorDocument = document; aiSummaryNotice = nil; edited()
    }

    func summarizePage() {
        guard canOperateOnLoadedContent, aiPreferenceDefaults.bool(forKey: EditorPreferences.aiSummariesKey),
              currentNote != nil, !editingLocked, !generatingAISummary, cloudSummaryTarget == nil, cloudSummaryConfirmation == nil else { return }
        if let reason = aiClient.unavailabilityReason() { aiSummaryNotice = reason; return }
        let capturedBody = body, capturedID = currentNote?.id, capturedRevision = cloudEditorRevision
        let requestID = UUID()
        nativePageSummaryID = capturedID; nativePageSummaryRequestID = requestID
        let content = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(body).withoutAISummary))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiSummaryNotice = "Add page content before generating a summary."; return
        }
        let completionTicket = issueCompletionTicket(
            kind: .aiProcessing,
            targetID: capturedID,
            capturedText: capturedBody
        )
        let client = aiClient
        generatingAISummary = true; aiSummaryNotice = nil
        aiSummaryTask?.cancel()
        aiSummaryTask = Task {
            await withLocalAIActivity(id: requestID, target: capturedID.map { .page($0) }, action: .summarizePage) { activity in
                defer {
                    if generation == completionTicket.token, nativePageSummaryRequestID == requestID {
                        nativePageSummaryRequestID = nil; nativePageSummaryID = nil
                        generatingAISummary = false
                        aiSummaryTask = nil
                    }
                }
                do {
                    guard await saveCurrent(), let note = currentNote, let repository else { throw ExternalAIError.staleContent }
                    let snapshot = try await repository.pageSummarySnapshot(note)
                    try await activity.start(contentSizeBytes: content.utf8.count)
                    let enrichment = try await nativeEnrichment(client, text: content, mode: Self.enrichmentMode(.page(snapshot)))
                    let summary = enrichment.summary
                    guard isCompletionValid(
                        completionTicket,
                        expectedTargetID: currentNote?.id,
                        checkTargetID: true,
                        operation: "summarizePage"
                    ) else { return }
                    guard !Task.isCancelled, nativePageSummaryRequestID == requestID else { return }
                    guard body == capturedBody, capturedRevision == cloudEditorRevision, !editingLocked, !externalChange,
                          aiPreferenceDefaults.bool(forKey: EditorPreferences.aiSummariesKey) else {
                        aiSummaryNotice = "The page changed during generation. Generate the summary again."; return
                    }
                    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.utf8.count <= ExternalAILimits.maximumSummaryBytes else { activity.fail(ExternalAIError.invalidResponse); aiSummaryNotice = "No valid summary was returned. Try again."; return }
                    let provenance = SummaryProvenance(provider: "On-device", model: "Apple Intelligence", generatedAt: Date(), sourceRevision: snapshot.sourceRevision)
                    cloudPublicationGuard.arm(requestID: requestID)
                    let publicationGuard = cloudPublicationGuard
                    let saved = try await repository.publishPageEnrichment(snapshot, summary: summary,
                        classification: Self.classification(enrichment.classification, provenance: provenance),
                        title: Self.enrichmentMode(.page(snapshot)) == .initial ? enrichment.title : nil,
                        provenance: provenance, validate: { try publicationGuard.validate(requestID: requestID) })
                    activity.complete()
                    guard !Task.isCancelled, nativePageSummaryRequestID == requestID,
                          capturedRevision == cloudEditorRevision else { return }
                    if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                    apply(saved)

                } catch {
                    activity.fail(error)
                    guard !Task.isCancelled, nativePageSummaryRequestID == requestID else { return }
                    guard isCompletionValid(
                        completionTicket,
                        expectedTargetID: currentNote?.id,
                        checkTargetID: true,
                        operation: "summarizePage"
                    ) else { return }
                    aiSummaryNotice = "On-device summary generation failed. Try again."
                }
            }
        }
    }

    private func resolveBookmarkData(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if let bookmarkResolver {
            return try bookmarkResolver(data)
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    func restore() async {
        guard let data = UserDefaults.standard.data(forKey: "vaultBookmark") else { return }
        do {
            let (url, stale) = try resolveBookmarkData(data)
            await open(url, create: false)
            if stale, root != nil, persistSecurityScopedBookmark { try remember(url) }
        } catch {
            needsPermissionReauthorization = true
            errorMessage = "Reselect your vault folder to restore access. " + error.localizedDescription
        }
    }
    func chooseVault(create: Bool) {
        guard canPerformWorkspaceCommand(create ? .createVault : .openVault) else { return }
        if create { showVaultCreation = true; return }
        isChoosingVault = true
        let admittedState = sessionState
        let panel = NSOpenPanel()
        vaultCommandPanel = panel
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
        panel.prompt = "Open Vault"
        panel.message = "Choose the folder containing your vault.json file."
        presentPanel(panel) { [weak self] response in
            guard let self, self.vaultCommandPanel === panel else { return }
            self.isChoosingVault = false
            self.vaultCommandPanel = nil
            guard response == .OK, let url = panel.url,
                  self.sessionState == admittedState,
                  self.canPerformWorkspaceCommand(.openVault) else { return }
            self.workspaceCommandPending = true
            Task { @MainActor in
                defer { self.workspaceCommandPending = false }
                guard self.sessionState == admittedState,
                      self.sessionState == self.sessionManager.accessGate.currentState,
                      !self.isLifecycleActionInProgress, !self.busy else { return }
                await self.open(url, create: false)
            }
        }
    }
    func chooseVaultParent(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Parent Folder"
        panel.message = "Choose the existing parent folder, such as Noema in iCloud Drive. The vault will be created inside it after confirmation."
        presentPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
    func createVault(parent: URL, name: String, encryptionRequested: Bool, accessAuthenticationRequested: Bool = false) async throws {
        // A UI bypass must never silently create plaintext for an encrypted request.
        guard !encryptionRequested else { throw VaultError.invalid(VaultCreation.encryptionUnavailable) }
        guard await flushPendingEdits() else { throw VaultError.invalid("Save the current page before creating a vault.") }
        let hasScope = securityScopeAcquirer(parent)
        defer { if hasScope { securityScopeReleaser(parent) } }
        let storageProvider = self.storageProvider
        let url = try await sessionManager.createVault(
            parent: parent, name: name, encryptionRequested: encryptionRequested,
            accessAuthenticationRequested: accessAuthenticationRequested,
            storageProvider: storageProvider
        )
        await open(url, create: false)
        if root == url { showVaultCreation = false }
        else { throw VaultError.storage(errorMessage ?? "The vault was created but could not be opened. Use Open Vault to retry.") }
    }
    private func presentPanel(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    private func remember(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        lockedVaultBookmark = bookmark
        UserDefaults.standard.set(bookmark, forKey: "vaultBookmark")
    }

    @discardableResult
    func flushPendingEdits(waitForTitles: Bool = false) async -> Bool {
        flushEditorPublication?()
        await waitForSave()
        autosaveTask?.cancel(); autosaveTask = nil
        if lccSaveTask != nil {
            lccSaveTask?.cancel(); lccSaveTask = nil
            if let note = currentNote, !editingLocked {
                let trimmed = lccInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedValue = trimmed.isEmpty ? nil : trimmed
                if !dirty {
                    await persistPageLCC(pageID: note.id, lcc: normalizedValue, ticket: generation)
                    if errorMessage != nil { return false }
                }
            }
        }
        let pendingSourceLCC = Array(sourceLCCSaveTasks.values)
        for task in pendingSourceLCC { await task.value }
        guard await finishCurrentPage(waitForTitles: waitForTitles) else { return false }
        guard pendingPageSaves.isEmpty else { errorMessage = "Save failed. Recover pending page drafts before closing."; return false }
        return true
    }

    private func beginLifecycleAction(_ action: String) -> Bool {
        let current = sessionManager.accessGate.currentState
        guard lifecycleAction == nil, !current.isTransitioning else {
            presentLifecycleFailure(VaultSessionError.transitionInProgress(current: current.phase, requested: action))
            return false
        }
        lifecycleAction = action
        lifecycleActionID = UUID()
        sessionTransitionErrors = []
        return true
    }

    /// Cancels using central truth even if the pending observation has not reached the UI yet.
    func cancelVaultAuthentication() async {
        let actionID = lifecycleActionID
        let cancelled = await sessionManager.cancelAuthentication()
        if cancelled, let actionID {
            while lifecycleActionID == actionID { await Task.yield() }
        }
        isVaultAuthenticationPending = sessionManager.isAuthenticationPending
        if cancelled, actionID != nil, lifecycleActionID == nil { busy = false }
    }

    @discardableResult
    func setVaultAccessAuthenticationRequired(_ required: Bool) async -> Bool {
        guard let session = sessionManager.accessGate.currentState.activeSession,
              beginLifecycleAction("changeVaultAccessPolicy") else { return false }
        defer { lifecycleAction = nil; lifecycleActionID = nil }
        errorMessage = nil
        do {
            try await sessionManager.setAccessAuthenticationRequired(
                required, expectedSession: session, storageProvider: storageProvider
            )
            try requireLifecycleState(.open, action: "changeVaultAccessPolicy", session: session)
            vaultAccessAuthenticationRequired = sessionManager.accessAuthenticationRequired(for: session.vaultID)
            return true
        } catch {
            presentLifecycleFailure(error)
            return false
        }
    }

    private func requireLifecycleState(_ phase: VaultSessionPhase, action: String, session: VaultSession? = nil) throws {
        let current = sessionManager.accessGate.currentState
        guard current.phase == phase else {
            throw VaultSessionError.unexpectedFinalState(action: action, expected: phase, actual: current.phase)
        }
        if let session {
            let matches = phase == .locked
                ? current == .locked(vaultID: session.vaultID, root: session.root, vaultName: session.vaultName, generation: session.generation)
                : current == .open(session)
            guard matches else { throw VaultSessionError.cancelled(action: action) }
        }
    }

    private func presentLifecycleFailure(_ error: Error, cleanupError: Error? = nil) {
        sessionTransitionErrors = [error, cleanupError].compactMap { $0 as? VaultSessionError }
        applyObservedSessionState(sessionManager.accessGate.currentState)
        busy = false
        errorMessage = error.localizedDescription
        if let cleanupError {
            errorMessage = error.localizedDescription + " Cleanup failed: " + cleanupError.localizedDescription
        }
    }

    private func closeSessionChecked(expectedSession: VaultSession? = nil) async throws {
        let retiringRepository = repository
        try await sessionManager.close(expectedSession: expectedSession)
        try requireLifecycleState(.closed, action: "close")
        // Retire only after the central transition commits: a cancelled close
        // must leave the still-open session's connection usable.
        try await retiringRepository?.shutdownPageStorage()
    }

    func open(_ url: URL, create: Bool) async {
        let normalizedTarget = url.standardizedFileURL.resolvingSymlinksInPath()
        if !create,
           isVaultAvailable,
           let currentRoot = root?.standardizedFileURL.resolvingSymlinksInPath(),
           currentRoot == normalizedTarget {
            guard beginLifecycleAction("open") else { return }
            defer { lifecycleAction = nil; lifecycleActionID = nil }
            guard await flushPendingEdits() else { return }
            await refresh()
            if let url = pendingBlockURL { pendingBlockURL = nil; openBlockURL(url) }
            return
        }

        // If the vault is currently locked and the user re-selected the same vault folder (e.g. via
        // "Reselect Vault Folder…" after lost security-scoped permissions), route through unlockVault(using:)
        // so the locked session is unlocked cleanly with its fresh security-scoped URL.
        if !create, isLocked {
            let lockedTarget = (lockedVaultURL ?? sessionState.root)?.standardizedFileURL.resolvingSymlinksInPath()
            if lockedTarget == normalizedTarget {
                _ = await unlockVault(using: url)
                return
            }
        }

        guard beginLifecycleAction("open") else { return }
        defer { lifecycleAction = nil; lifecycleActionID = nil }
        if !(await flushPendingEdits()) { return }
        busy = true; errorMessage = nil
        if !isLocked { needsPermissionReauthorization = false }

        let storageProvider = self.storageProvider
        let hasScope = (scopeURL == url) ? false : securityScopeAcquirer(url)

        do {
            if requiresSecurityScopedAccess && !hasScope && scopeURL != url {
                throw VaultError.unavailable("Permission to access ‘\(url.lastPathComponent)’ was lost. Reselect your vault folder to restore access.")
            }
            try await Task.detached {
                _ = try FileVaultRepository.preflightOpen(root: url, create: create, storageProvider: storageProvider)
            }.value
        } catch {
            if hasScope, scopeURL != url { securityScopeReleaser(url) }
            sessionState = await sessionManager.state
            busy = false
            if !isVaultAvailable {
                needsPermissionReauthorization = Self.isPermissionDenied(error) || (requiresSecurityScopedAccess && !hasScope)
            }
            errorMessage = error.localizedDescription
            return
        }

        needsPermissionReauthorization = false

        // Keep the previous resources until the central close has actually committed.
        do {
            try await closeSessionChecked()
        } catch {
            if hasScope, scopeURL != url { securityScopeReleaser(url) }
            presentLifecycleFailure(error)
            return
        }
        releaseActiveVaultResources()
        clearSessionUIState()
        busy = true
        lockedVaultURL = nil
        lockedVaultBookmark = nil
        var openedSession: VaultSession?

        do {
            let (session, lease, repo) = try await sessionManager.openRepository(
                root: url,
                create: create,
                storageProvider: storageProvider
            )
            openedSession = session
            let vaultID = repo.manifest.id
            let baseDir = try localStorageRoot ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let localBase = baseDir.appendingPathComponent("KnowledgeVault/\(vaultID.uuidString)")
            let gate = sessionManager.accessGate
            let factory = searchIndexFactory
            let embeddingFactory = semanticIndexFactory
            let (searchIndex, journal, cached, drafts, semantic, semanticIssue) = try await Task.detached {
                let idx = try factory(localBase.appendingPathComponent("search.sqlite"), lease, gate)
                let recoveryStore = try RecoveryStore(
                    directory: localBase.appendingPathComponent("Drafts"),
                    sessionLease: lease,
                    accessGate: gate
                )
                let cachedEntries = try await idx.cachedEntries()
                let recovered = try await recoveryStore.listing()
                let semantic: SQLiteEmbeddingIndex?
                let semanticIssue: String?
                do { semantic = try embeddingFactory(baseDir, lease, gate); semanticIssue = nil }
                catch { semantic = nil; semanticIssue = "Semantic index unavailable. Lexical search remains available." }
                return (idx, recoveryStore, cachedEntries, recovered, semantic, semanticIssue)
            }.value
            try requireLifecycleState(.open, action: "open", session: session)
            self.scopeURL = (hasScope || self.scopeURL == url) ? url : nil
            dismissedVaultNotices = []
            generation = UUID()
            activeSession = session
            activeLease = lease
            sessionState = .open(session)
            lockedVaultURL = nil
            repository = repo; index = searchIndex; recovery = journal
            semanticIndex = semantic
            semanticIndexIssue = semanticIssue
            await bindAIProcessing(repository: repo, lease: lease)
            try requireLifecycleState(.open, action: "AI processing admission", session: session)
            unseenRenamedPages.removeAll()
            restoreSidebarRecentHistory(vaultID: vaultID)
            root = url; vaultName = url.lastPathComponent; scope = .wiki; resetSearch()
            selectedID = nil; currentNote = nil; currentSource = nil; externalChange = false
            title = ""; body = ""; tagInput = ""; lccInput = ""; preview = []; backlinks = []; outgoingLinkTargets = []; wordCount = 0
            notes = cached.notes; sources = cached.sources; trashedPages = []; trashOperationInProgress = false
            updateTags()
            applyRecoveryListing(drafts)
            if persistSecurityScopedBookmark {
                try remember(url)
            }
            busy = false
            await updateRows()
            await refresh()
            if let url = pendingBlockURL { pendingBlockURL = nil; openBlockURL(url) }
            try requireLifecycleState(.open, action: "open", session: session)
        } catch {
            if hasScope, scopeURL != url { securityScopeReleaser(url) }
            var cleanupError: Error?
            if let openedSession, sessionManager.accessGate.currentState.sessionID == openedSession.id {
                do { try await closeSessionChecked(expectedSession: openedSession) }
                catch { cleanupError = error }
            }
            releaseActiveVaultResources()
            clearSessionUIState()
            needsPermissionReauthorization = Self.isPermissionDenied(error) || (requiresSecurityScopedAccess && !hasScope)
            presentLifecycleFailure(error, cleanupError: cleanupError)
        }
    }

    /// Quiesces in-flight saves, autosaves, LCC metadata updates, and source imports/downloads,
    /// preserving unsaved edits in `RecoveryStore` if needed, before transitioning the vault to `.locked`.
    /// On unrecoverable quiescence failure, surfaces `errorMessage` and keeps the vault open without falsely publishing `.locked`.
    @discardableResult
    func lockVault(cancelPreCommitSaves: Bool = false) async -> Bool {
        flushEditorPublication?()
        guard beginLifecycleAction("lock") else { return false }
        defer { lifecycleAction = nil; lifecycleActionID = nil }
        if sessionManager.accessGate.currentState.phase == .locked {
            applyObservedSessionState(sessionManager.accessGate.currentState)
            return true
        }
        guard let repository, let currentRoot = root,
              let lockingSession = sessionManager.accessGate.currentState.activeSession else { return false }
        await waitForSave()
        if dirty, semanticCoordinator?.session.semanticEdit != nil {
            guard await saveCurrent() else { return false }
        }
        guard pendingPageSaves.isEmpty else { errorMessage = "Save failed. Recover pending page drafts before locking."; return false }
        busy = true; errorMessage = nil; needsPermissionReauthorization = false
        autosaveTask?.cancel(); autosaveTask = nil
        lccSaveTask?.cancel(); lccSaveTask = nil
        for (_, task) in sourceLCCSaveTasks { task.cancel() }
        sourceLCCSaveTasks.removeAll()

        let dirtySnapshot: VaultPendingEditorState.DirtyNoteState? = {
            guard dirty, let note = currentNote else { return nil }
            return VaultPendingEditorState.DirtyNoteState(
                note: note,
                title: title,
                body: body,
                tags: editedTags,
                lcc: lccInput,
                preferDirectSave: !cancelPreCommitSaves
            )
        }()
        let pendingLCCSnapshot: VaultPendingEditorState.PendingPageLCCUpdate? = {
            guard let note = currentNote else { return nil }
            let trimmed = lccInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLCC = trimmed.isEmpty ? nil : trimmed
            guard normalizedLCC != note.lcc else { return nil }
            return VaultPendingEditorState.PendingPageLCCUpdate(note: note, lcc: normalizedLCC)
        }()
        let pendingState = VaultPendingEditorState(
            dirtyNote: dirtySnapshot,
            pendingPageLCC: pendingLCCSnapshot,
            pendingSourceLCCs: [],
            activeDownloadSourceIDs: Array(downloadingSources)
        )

        do {
            _ = try await sessionManager.lockWithQuiescence(
                repository: repository,
                recovery: recovery,
                pendingState: pendingState,
                cancelPreCommitSaves: cancelPreCommitSaves
            )
            // Quiescence succeeded and session is now .locked. Tear down UI & vault resources.
            try requireLifecycleState(.locked, action: "lock", session: lockingSession)
            try await repository.shutdownPageStorage()
            let observed = sessionManager.accessGate.currentState
            lockedVaultURL = currentRoot
            if persistSecurityScopedBookmark, lockedVaultBookmark == nil {
                lockedVaultBookmark = UserDefaults.standard.data(forKey: "vaultBookmark")
            }
            vaultName = currentRoot.lastPathComponent
            releaseActiveVaultResources()
            clearSessionUIState()
            sessionState = observed
            dismissSettings(force: true)
            return true
        } catch {
            presentLifecycleFailure(error)
            saveStatus = "Lock failed · edits retained"
            if let recovery, sessionManager.accessGate.currentState.phase == .open {
                do { applyRecoveryListing(try await recovery.listing()) }
                catch {
                    errorMessage = (errorMessage ?? "Lock failed.") + " Recovery reload failed: " + error.localizedDescription
                }
            }
            return false
        }
    }

    @discardableResult
    func unlockVault(using overrideURL: URL? = nil) async -> Bool {
        guard beginLifecycleAction("unlock") else { return false }
        defer { lifecycleAction = nil; lifecycleActionID = nil }
        let initialLockedRoot: URL? = {
            if let overrideURL { return overrideURL }
            if let lockedVaultURL { return lockedVaultURL }
            if case .locked(_, let root, _, _) = sessionState { return root }
            return nil
        }()
        guard let fallbackRoot = initialLockedRoot else { return false }
        busy = true; errorMessage = nil; needsPermissionReauthorization = false

        var candidateURL = fallbackRoot
        var resolvedStaleBookmark = false
        if overrideURL == nil,
           let bookmarkData = lockedVaultBookmark ?? (persistSecurityScopedBookmark ? UserDefaults.standard.data(forKey: "vaultBookmark") : nil) {
            do {
                let resolved = try resolveBookmarkData(bookmarkData)
                candidateURL = resolved.url
                resolvedStaleBookmark = resolved.isStale
            } catch {
                sessionState = await sessionManager.state
                busy = false
                needsPermissionReauthorization = true
                errorMessage = "Reselect your vault folder to restore access. " + error.localizedDescription
                return false
            }
        }

        let hasScope = securityScopeAcquirer(candidateURL)
        var unlockedSession: VaultSession?
        do {
            if requiresSecurityScopedAccess && !hasScope {
                needsPermissionReauthorization = true
                throw VaultError.unavailable("Permission to access ‘\(candidateURL.lastPathComponent)’ was lost. Reselect your vault folder to restore access.")
            }
            cancelAllAsyncWork()
            let storageProvider = self.storageProvider
            let (session, lease, repo) = try await sessionManager.unlockRepository(
                root: candidateURL,
                storageProvider: storageProvider
            )
            unlockedSession = session
            let vaultID = repo.manifest.id
            let baseDir = try localStorageRoot ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let localBase = baseDir.appendingPathComponent("KnowledgeVault/\(vaultID.uuidString)")
            let gate = sessionManager.accessGate
            let factory = searchIndexFactory
            let embeddingFactory = semanticIndexFactory
            let (searchIndex, journal, cached, drafts, semantic, semanticIssue) = try await Task.detached {
                let idx = try factory(localBase.appendingPathComponent("search.sqlite"), lease, gate)
                let recoveryStore = try RecoveryStore(
                    directory: localBase.appendingPathComponent("Drafts"),
                    sessionLease: lease,
                    accessGate: gate
                )
                let cached = try await idx.cachedEntries()
                let drafts = try await recoveryStore.listing()
                let semantic: SQLiteEmbeddingIndex?
                let semanticIssue: String?
                do { semantic = try embeddingFactory(baseDir, lease, gate); semanticIssue = nil }
                catch { semantic = nil; semanticIssue = "Semantic index unavailable. Lexical search remains available." }
                return (idx, recoveryStore, cached, drafts, semantic, semanticIssue)
            }.value
            try requireLifecycleState(.open, action: "unlock", session: session)
            if persistSecurityScopedBookmark, (resolvedStaleBookmark || overrideURL != nil) {
                try remember(candidateURL)
            }
            SourceReader.closeAll()
            if let scopeURL { securityScopeReleaser(scopeURL) }
            self.scopeURL = hasScope ? candidateURL : nil
            cancelAllAsyncWork()
            dismissedVaultNotices = []
            generation = UUID()
            activeSession = session
            activeLease = lease
            sessionState = .open(session)
            lockedVaultURL = nil
            repository = repo; index = searchIndex; recovery = journal
            semanticIndex = semantic
            semanticIndexIssue = semanticIssue
            await bindAIProcessing(repository: repo, lease: lease)
            try requireLifecycleState(.open, action: "AI processing admission", session: session)
            unseenRenamedPages.removeAll()
            restoreSidebarRecentHistory(vaultID: vaultID)
            root = candidateURL; vaultName = candidateURL.lastPathComponent; scope = .wiki; resetSearch()
            selectedID = nil; currentNote = nil; currentSource = nil; externalChange = false
            title = ""; body = ""; tagInput = ""; lccInput = ""; preview = []; backlinks = []; outgoingLinkTargets = []; wordCount = 0
            notes = cached.notes; sources = cached.sources; trashedPages = []; trashOperationInProgress = false
            updateTags()
            applyRecoveryListing(drafts)
            busy = false
            await updateRows()
            await refresh()
            if let url = pendingBlockURL { pendingBlockURL = nil; openBlockURL(url) }
            try requireLifecycleState(.open, action: "unlock", session: session)
            return true
        } catch {
            if hasScope, scopeURL != candidateURL { securityScopeReleaser(candidateURL) }
            var cleanupError: Error?
            if let unlockedSession, sessionManager.accessGate.currentState.sessionID == unlockedSession.id {
                do {
                    try await sessionManager.lock(expectedSession: unlockedSession)
                    try requireLifecycleState(.locked, action: "unlock.rollback", session: unlockedSession)
                } catch { cleanupError = error }
            }
            // Failed initialization publishes no resources. Only central state determines the
            // fallback UI; a failed rollback must never manufacture a locked state.
            if sessionManager.accessGate.currentState.phase != .open {
                releaseActiveVaultResources()
                clearSessionUIState()
            }
            if Self.isPermissionDenied(error) || (requiresSecurityScopedAccess && !hasScope) {
                needsPermissionReauthorization = true
            }
            presentLifecycleFailure(error, cleanupError: cleanupError)
            return false
        }
    }

    @discardableResult
    func closeVault(force: Bool = false) async -> Bool {
        if sessionManager.isAuthenticationPending { await cancelVaultAuthentication() }
        guard beginLifecycleAction("close") else { return false }
        defer { lifecycleAction = nil; lifecycleActionID = nil }
        await waitForSave()
        if force, let recovery {
            if let latest = capturePageSave() { pendingPageSaves[latest.note.id] = latest }
            do { for snapshot in pendingPageSaves.values { try await recovery.store(snapshot.draft) } }
            catch { errorMessage = "Could not preserve pending drafts: " + error.localizedDescription; return false }
        }
        if !force, isVaultAvailable {
            guard await flushPendingEdits() else {
                if Task.isCancelled { presentLifecycleFailure(VaultSessionError.cancelled(action: "close")) }
                return false
            }
        }
        do {
            try await closeSessionChecked()
            releaseActiveVaultResources()
            lockedVaultURL = nil
            lockedVaultBookmark = nil
            needsPermissionReauthorization = false
            sessionState = sessionManager.accessGate.currentState
            if persistSecurityScopedBookmark {
                UserDefaults.standard.removeObject(forKey: "vaultBookmark")
            }
            clearSessionUIState()
            dismissSettings(force: true)
            errorMessage = nil
            return true
        } catch {
            presentLifecycleFailure(error)
            return false
        }
    }

    func scheduleRefresh() {
        guard isVaultAvailable else { return }
        refreshTask?.cancel()
        let completionTicket = issueCompletionTicket(kind: .refresh)
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard isCompletionValid(completionTicket, operation: "scheduleRefresh") else { return }
            await refresh()
        }
    }
    func refresh() async {
        guard isVaultAvailable, let repository, let index else { return }
        let favouritesGeneration = generation
        await reloadFavourites()
        guard generation == favouritesGeneration, isVaultAvailable else { return }
        if refreshing { pendingRefresh = true; return }
        refreshing = true
        let completionTicket = issueCompletionTicket(kind: .indexing)
        let ticket = completionTicket.token, initiallyEmpty = notes.isEmpty && sources.isEmpty
        let scanTicket = UUID(); progressTicket = scanTicket
        if initiallyEmpty { busy = true }
        defer {
            if generation == ticket {
                progressTicket = nil
                busy = false
                refreshing = false
                if pendingRefresh {
                    pendingRefresh = false
                    scheduleRefresh()
                }
            }
        }
        do {
            // Publish metadata before original verification/extraction on a cold session.
            // Existing populated sessions retain their complete records until the scan commits.
            if initiallyEmpty {
                let metadata = try await repository.scanSources()
                guard isCompletionValid(completionTicket, operation: "refresh.sourceMetadata") else { return }
                sources = metadata.sources
            }
            let result = try await repository.scan { [weak self] chunk in
                guard initiallyEmpty else { return }
                Task { @MainActor in
                    guard let self,
                          self.isCompletionValid(completionTicket, operation: "refresh.scanChunk"),
                          self.progressTicket == scanTicket else { return }
                    self.notes.append(contentsOf: chunk.notes)
                    self.rows = self.notes.map { LibraryRow(note: $0) }
                }
            }
            progressTicket = nil
            guard isCompletionValid(completionTicket, operation: "refresh.scan") else { return }
            try Task.checkCancellation()
            let previousTitles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            for note in result.notes {
                if let previous = previousTitles[note.id] { recordPageRename(note.id, from: previous, to: note.title) }
            }
            notes = result.notes; sources = result.sources
            SourceReader.reconcile(result)
            // Explicit checks are snapshots too: never let an old Available override a new failure.
            let availableIDs = Set(sources.filter { $0.contentState == .loaded && $0.availabilityIssue == nil }.map(\.id))
            sourceAvailability = sourceAvailability.filter { availableIDs.contains($0.key) }
            if let selected = currentSource, let fresh = sources.first(where: { $0.id == selected.id }) {
                currentSource = fresh; title = fresh.title; body = fresh.body
                if fresh.contentState == .unavailable { preview = []; wordCount = 0 }
                else if selected.contentState != fresh.contentState || selected.body != fresh.body { generatePreview() }
            } else if currentSource != nil {
                currentSource = nil; selectedID = nil; title = ""; body = ""; preview = []; wordCount = 0
            }
            issues = result.issues.filter { !dismissedVaultNotices.contains($0) }
            do {
                let expirationFailures = try await repository.expireTrash(now: Date())
                guard isCompletionValid(completionTicket, operation: "refresh.expireTrash") else { return }
                if !expirationFailures.isEmpty { errorMessage = expirationFailures.joined(separator: "\n") }
                let pages = try await repository.trashItems()
                guard isCompletionValid(completionTicket, operation: "refresh.trashItems") else { return }
                trashedPages = pages
            } catch {
                guard isCompletionValid(completionTicket, operation: "refresh.trashError") else { return }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                errorMessage = "Could not load Trash: " + error.localizedDescription
            }
            updateTags()
            if let note = currentNote, let fresh = notes.first(where: { $0.id == note.id }), fresh.contentHash != note.contentHash {
                if dirty || saving { externalChange = true }
                else { apply(fresh) }
            } else if let note = currentNote, !notes.contains(where: { $0.id == note.id }), !saving {
                externalChange = true
            }
            pruneSidebarRecentHistory()
            try await index.reconcile(result)
            guard isCompletionValid(completionTicket, operation: "refresh.reconcile") else { return }
            try Task.checkCancellation()
            await updateRows(); await updateBacklinks()
        } catch {
            guard isCompletionValid(completionTicket, operation: "refresh.error") else { return }
            // File notifications supersede scheduled refreshes, including scans already
            // in progress. Cancellation does not mean the preceding page save failed.
            guard !(error is CancellationError), !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    private func invalidateSearch() {
        searchRevision = UUID()
        queryTask?.cancel(); queryTask = nil
        sidebarSearchResults = SidebarSearchResults()
        searchStatus = isSearching || searchMode == .quickOpen ? .searching : .idle
    }

    private func resetSearch() {
        invalidateSearch()
        searchText = ""; searchMode = .vault; searchScope = .all
        sidebarSearchResults = SidebarSearchResults(); searchStatus = .idle
    }

    func setSearchMode(_ mode: VaultSearchMode) {
        if searchMode != mode {
            searchMode = mode
            searchScope = .all
        }
        queryChanged()
    }

    func setSearchScope(_ scope: VaultSearchScope) {
        searchScope = scope
        queryChanged()
    }

    func queryChanged() {
        queryTask?.cancel()
        // Revision changes even for repeated query text, including A → B → A.
        invalidateSearch()
        guard canOperateOnLoadedContent else { return }
        let revision = searchRevision
        let completionTicket = issueCompletionTicket(kind: .search, capturedText: searchText)
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "queryChanged"),
                  revision == searchRevision else { return }
            await updateRows()
        }
    }

    private func semanticCatalog(_ notes: [NoteRecord], revision: UUID, editorRevision: UUID) async -> [SemanticBlockHit] {
        if semanticRowsRevision == revision && semanticRowsEditorRevision == editorRevision { return semanticRows }
        return await Task.detached { SemanticBlockHit.search(notes, query: "") }.value
    }

    func changeScope(_ scope: LibraryScope) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        // Revoke immediately, including while an asynchronous save delays applying the scope.
        cancelCloudSummary()
        let completionTicket = issueCompletionTicket(kind: .lifecycle)
        let applyScope = { @MainActor in
            self.autosaveTask?.cancel(); self.wikiQuery = nil; self.editorAction = nil
            self.scope = scope
            if scope == .trash { self.searchText = "" }
            self.selectedID = nil; self.currentNote = nil; self.currentSource = nil; self.selectedSemanticID = nil; self.selectedSidebarRecentItemID = nil
            self.externalChange = false; self.errorMessage = nil
            if self.searchText.isEmpty {
                switch scope {
                case .wiki:
                    self.rows = self.notes.map { LibraryRow(note: $0) }
                case .sources:
                    self.rows = self.sources.map { LibraryRow(source: $0) }
                case .tag(let tag):
                    self.rows = self.notes.filter { $0.allTags.contains(tag) }.map { LibraryRow(note: $0) }
                case .semantic, .trash:
                    break
                }
            }
        }
        if !dirty && !saving && !needsTitle {
            applyScope()
            Task {
                guard isCompletionValid(completionTicket, operation: "changeScope") else { return }
                await updateRows()
                if scope == .trash, isCompletionValid(completionTicket, operation: "changeScope.trash") {
                    await refresh()
                }
            }
        } else {
            Task {
                await waitForSave()
                guard isCompletionValid(completionTicket, operation: "changeScope.wait") else { return }
                if await finishCurrentPage(), isCompletionValid(completionTicket, operation: "changeScope.finish") {
                    applyScope()
                    await updateRows()
                    if scope == .trash, isCompletionValid(completionTicket, operation: "changeScope.trash") {
                        await refresh()
                    }
                }
            }
        }
    }
    func updateRows() async {
        guard canOperateOnLoadedContent else { return }
        let query = searchText
        // Each execution supersedes earlier executions, even with identical inputs.
        searchRevision = UUID()
        let revision = searchRevision
        let completionTicket = issueCompletionTicket(kind: .search, capturedText: query)
        var snapshot = notes
        if let currentNote, let i = snapshot.firstIndex(where: { $0.id == currentNote.id }) {
            snapshot[i].body = body; snapshot[i].title = title
        }
        let capturedNotes = snapshot
        let capturedSources = sources
        let catalogRevision = libraryCatalogRevision
        let editorRevision = cloudEditorRevision
        // Query entry never narrows the underlying library. Its full collection
        // stays available until the view explicitly presents search results.
        if (isSearching || searchMode == .quickOpen), scope != .trash, scope != .semantic,
           libraryRowsRevision != catalogRevision || libraryRowsScope != scope || libraryRowsEditorRevision != editorRevision {
            let catalogScope = scope
            let baselineRows = await Task.detached {
                let baseRows: [LibraryRow]
                switch catalogScope {
                case .wiki: baseRows = capturedNotes.map { LibraryRow(note: $0) }
                case .sources: baseRows = capturedSources.map { LibraryRow(source: $0) }
                case .tag(let tag): baseRows = capturedNotes.filter { $0.allTags.contains(tag) }.map { LibraryRow(note: $0) }
                case .semantic, .trash: baseRows = []
                }
                return baseRows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }.value
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.libraryCatalog"),
                  revision == searchRevision, catalogRevision == libraryCatalogRevision,
                  editorRevision == cloudEditorRevision else { return }
            if rows != baselineRows { rows = baselineRows }
            libraryRowsRevision = catalogRevision; libraryRowsScope = catalogScope
            libraryRowsEditorRevision = editorRevision
        }
        if searchMode == .quickOpen {
            searchStatus = .searching
            if scope == .semantic {
                let blocks = await semanticCatalog(capturedNotes, revision: catalogRevision, editorRevision: editorRevision)
                guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.quickOpenLibrary"),
                      revision == searchRevision, catalogRevision == libraryCatalogRevision,
                      editorRevision == cloudEditorRevision else { return }
                semanticRows = blocks
                semanticRowsRevision = catalogRevision; semanticRowsEditorRevision = editorRevision
            }
            let results = await Task.detached {
                SidebarSearchResults.quickOpen(query, notes: capturedNotes, sources: capturedSources)
            }.value
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.quickOpen"),
                  revision == searchRevision else { return }
            sidebarSearchResults = results; searchStatus = .results
            return
        }
        if isSearching {
            searchStatus = .searching
            guard let index else {
                sidebarSearchResults = SidebarSearchResults()
                searchStatus = .failed("The vault search index is unavailable.")
                return
            }
            do {
                let allBlocks = await semanticCatalog(capturedNotes, revision: catalogRevision, editorRevision: editorRevision)
                guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.searchLibrary"),
                      revision == searchRevision, catalogRevision == libraryCatalogRevision,
                      editorRevision == cloudEditorRevision else { return }
                semanticRows = allBlocks
                semanticRowsRevision = catalogRevision; semanticRowsEditorRevision = editorRevision
                let results = try await SidebarSearchResults.search(query, notes: capturedNotes, sources: capturedSources, index: index, semanticBlocks: allBlocks)
                guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.sidebarSearch"),
                      revision == searchRevision else { return }
                sidebarSearchResults = results
                searchStatus = .results
            } catch {
                guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.sidebarSearchError"),
                      revision == searchRevision else { return }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                sidebarSearchResults = SidebarSearchResults()
                searchStatus = .failed(error.localizedDescription)
            }
            return
        }
        guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.clearSidebarSearch"),
              revision == searchRevision else { return }
        sidebarSearchResults = SidebarSearchResults()
        searchStatus = .idle
        if scope == .semantic || semanticRows.isEmpty {
            let hits = await semanticCatalog(capturedNotes, revision: catalogRevision, editorRevision: editorRevision)
            if isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.semanticBlocks"), revision == searchRevision,
               catalogRevision == libraryCatalogRevision, editorRevision == cloudEditorRevision {
                semanticRows = hits
                semanticRowsRevision = catalogRevision; semanticRowsEditorRevision = editorRevision
            }
            if scope == .semantic { return }
        }
        guard revision == searchRevision else { return }
        guard let index else { return }
        let capturedScope = scope, capturedQuery = searchText
        let kind: EntryKind = scope == .sources ? .source : .wiki
        let tag: String? = { if case .tag(let tag) = scope { return tag }; return nil }()
        do {
            let hits = try await index.search(capturedQuery, kind: kind, tag: tag)
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.indexSearch"),
                  capturedScope == scope, revision == searchRevision else { return }
            let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newRows: [LibraryRow] = hits.compactMap { hit in
                if hit.kind == .wiki, let note = noteMap[hit.id] { return LibraryRow(note: note) }
                if let source = sourceMap[hit.id] { return LibraryRow(source: source) }
                return nil
            }
            if newRows != rows { rows = newRows }
            libraryRowsRevision = catalogRevision; libraryRowsScope = capturedScope
            libraryRowsEditorRevision = nil
        } catch {
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.indexSearchError"),
                  capturedScope == scope, revision == searchRevision else { return }
            guard !(error is CancellationError), !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    func select(_ id: UUID?, scope targetScope: LibraryScope? = nil, block blockID: UUID? = nil, previewSource: Bool = false) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        if let id, id == currentNote?.id {
            selectedSidebarRecentItemID = nil
            if let targetScope { scope = targetScope; searchText = "" }
            if let blockID, editorDocument.block(blockID) != nil {
                selectedSemanticID = "\(id):\(blockID)"
                editorAction = EditorAction(operation: .block(blockID))
                recordSidebarAccess(.semanticBlock(pageID: id, blockID: blockID))
            } else if blockID == nil {
                selectedSemanticID = nil
                recordSidebarAccess(.page(id))
            }
            return
        }
        pendingSemanticOccurrence = nil; semanticOccurrenceNavigationTicket = UUID()
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: id)
        if let blockID {
            guard let note = notes.first(where: { $0.id == id }), BlockDocumentCodec.decode(note.body).block(blockID) != nil else { return }
        }
        queueCurrentPageSave()
        wikiQuery = nil; editorAction = nil
        if let targetScope { scope = targetScope; searchText = "" }
        selectedSidebarRecentItemID = nil
        selectedID = id; currentSource = nil; currentNote = nil; externalChange = false; errorMessage = nil
        // Identity checks suspend the outgoing editor's authority. Preserve its
        // registration if coalesced navigation returns before SwiftUI replaces it.
        if let note = notes.first(where: { $0.id == id }) {
            apply(note)
            recordSidebarAccess(blockID.map { .semanticBlock(pageID: note.id, blockID: $0) } ?? .page(note.id))
        } else if let source = sources.first(where: { $0.id == id }) {
            currentSource = source; title = source.title; body = source.body
        } else {
            title = ""; body = ""; tagInput = ""; lccInput = ""; preview = []; backlinks = []; outgoingLinkTargets = []; wordCount = 0
            editorNotice = nil; editingHint = nil; editorReadOnly = false
        }
        selectedSemanticID = nil
        if let blockID, let note = currentNote {
            selectedSemanticID = "\(note.id):\(blockID)"
            editorAction = EditorAction(operation: .block(blockID))
        }
        Task {
            guard isCompletionValid(completionTicket, expectedTargetID: selectedID, checkTargetID: true, operation: "select.begin") else { return }
            if let blockID {
                guard let note = notes.first(where: { $0.id == id }), BlockDocumentCodec.decode(note.body).block(blockID) != nil else {
                    if let id { sidebarRecentHistory.prune(keeping: Set(recentItemIDs.filter { $0 != .semanticBlock(pageID: id, blockID: blockID) })); sidebarRecentCacheRevision = nil; persistSidebarRecentHistory() }
                    return
                }
            }
            if let source = sources.first(where: { $0.id == id }) {
                var source = source
                if previewSource, source.contentState == .notLoaded, let repository {
                    do { source = try await repository.loadSource(id: source.id) }
                    catch { if isCompletionValid(completionTicket, expectedTargetID: selectedID, checkTargetID: true, operation: "select.loadSource.error") { errorMessage = error.localizedDescription }; return }
                    guard isCompletionValid(completionTicket, expectedTargetID: selectedID, checkTargetID: true, operation: "select.loadSource") else { return }
                    if let position = sources.firstIndex(where: { $0.id == source.id }) { sources[position] = source }
                }
                currentSource = source; title = source.title; body = source.body
                generatePreview(recordSourceAccess: !previewSource); backlinks = []; outgoingLinkTargets = []
                if previewSource, let root, let repository {
                    do {
                        try await SourceReader.open(source, root: root, contentStore: repository.contentStore,
                            isStillValid: { [weak self] in self?.isCompletionValid(completionTicket, expectedTargetID: self?.selectedID, checkTargetID: true, operation: "select.sourceReader") == true })
                        guard isCompletionValid(completionTicket, expectedTargetID: selectedID, checkTargetID: true, operation: "select.sourceReader.presented") else { return }
                        if SourceReader.openReaderIDs.contains(source.id) { recordSidebarAccess(.source(source.id)) }
                    } catch {
                        if isCompletionValid(completionTicket, expectedTargetID: selectedID, checkTargetID: true, operation: "select.sourceReader.error") { errorMessage = error.localizedDescription }
                    }
                }
            }
            if targetScope != nil { await updateRows() }
            guard isCompletionValid(completionTicket, expectedTargetID: selectedID, checkTargetID: true, operation: "select.backlinks") else { return }
            await updateBacklinks()
        }
    }
    func recordPageRename(_ id: UUID, from oldTitle: String, to newTitle: String) {
        guard oldTitle != newTitle else { return }
        if !appIsActive || currentNote?.id != id { unseenRenamedPages.insert(id) }
    }
    func markPageViewed(_ id: UUID) {
        if appIsActive { unseenRenamedPages.remove(id) }
    }
    var lccInput = "" { didSet { if lccInput != oldValue { cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate() } } }
    var generatingPageLCC = false
    var generatingSourceLCCs: Set<UUID> = []
    private var lccSaveTask: Task<Void, Never>?
    private var sourceLCCSaveTasks: [UUID: Task<Void, Never>] = [:]

    private func apply(_ note: NoteRecord) {
        let isDifferentPage = currentNote?.id != note.id
        lccSaveTask?.cancel()
        markPageViewed(note.id)
        editingHint = nil
        aiSummaryNotice = nil
        editorAction = nil
        if isDifferentPage {
            semanticInspectionPageID = nil; semanticInspectionRecords = []
            semanticInspectionSelectionIDs = []; semanticInspectionFocusID = nil
            semanticInspectionTicket = UUID()
            backlinks = []
            outgoingLinkTargets = []
        }
        currentNote = note; title = note.title; editorDocument = note.document ?? BlockDocumentCodec.decode(note.body); bodyProjection = note.body; tagInput = note.tags.joined(separator: ", ")
        lccInput = note.lcc ?? ""
        let document = editorDocument
        editorReadOnly = document.unsupportedVersion
        editorNotice = document.unsupportedVersion ? "This page uses a newer block format and is read-only. Its original content is preserved." : document.recoveredMetadata != nil ? "External Markdown changed. The earlier editor metadata was preserved for recovery; external text is shown." : nil
        externalChange = false; saveStatus = "Saved locally"
        if let pending = pendingPageSaves[note.id] {
            currentNote = pending.note
            title = pending.draft.title; editorDocument = pending.draft.document ?? BlockDocumentCodec.decode(pending.draft.contentBody)
            tagInput = pending.draft.tags.joined(separator: ", "); lccInput = pending.note.lcc ?? ""
            saveStatus = "Unsaved changes"
        }
        if let failure = pageSaveFailures[note.id] { errorMessage = failure; saveStatus = "Save failed · draft retained" }
        generatePreview()
    }
    func setPageLCC(_ value: String) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !editingLocked, let note = currentNote else { return }
        lccInput = value
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = trimmed.isEmpty ? nil : trimmed
        guard normalizedValue != note.lcc else { return }
        currentNote?.lcc = normalizedValue
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i].lcc = normalizedValue }
        saveStatus = "Unsaved changes"
        lccSaveTask?.cancel()
        let targetID = note.id, ticket = generation
        lccSaveTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            await persistPageLCC(pageID: targetID, lcc: normalizedValue, ticket: ticket)
        }
    }
    private func persistPageLCC(pageID: UUID, lcc: String?, ticket: UUID) async {
        await waitForSave()
        guard generation == ticket, canOperateOnLoadedContent, let repository,
              var note = (currentNote?.id == pageID ? currentNote : notes.first(where: { $0.id == pageID })),
              !note.isEditingLocked else { return }
        if currentNote?.id == pageID, dirty {
            _ = await saveCurrent()
            return
        }
        saving = true; saveStatus = "Saving…"
        defer { saving = false }
        do {
            note.lcc = lcc
            let editorSnapshot = semanticCoordinator?.session.identity.pageID == pageID ? semanticCoordinator?.session.snapshot() : nil
            let saved = try await repository.save(note: note, title: note.title, body: note.body, tags: note.tags)
            let semantic = try await repository.sqliteBlockStore.loadSemanticPage(pageID: pageID)
            guard generation == ticket, canOperateOnLoadedContent else { return }
            if let i = notes.firstIndex(where: { $0.id == pageID }) { notes[i] = saved }
            if currentNote?.id == pageID {
                currentNote = saved
                reconcileMetadataPublication(semantic, captured: editorSnapshot)
                lccInput = saved.lcc ?? ""
                saveStatus = dirty ? "Unsaved changes" : "Saved locally"
            }
            scheduleRefresh()
        } catch { if generation == ticket, canOperateOnLoadedContent { errorMessage = error.localizedDescription } }
    }
    func refreshPageLCC(provider: AIProvider? = nil) {
        guard canInteractWithWorkspace, let note = currentNote, !editingLocked, !externalChange else { return }
        requestAISuggestion(target: .page(note.id), action: .classifyLCC, provider: provider)
    }
    func updateSourceLCC(_ source: SourceRecord, lcc: String) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !downloadingSources.contains(source.id) else { return }
        cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
        let trimmed = lcc.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = trimmed.isEmpty ? nil : trimmed
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].metadata.lcc = normalizedValue
        }
        if currentSource?.id == source.id {
            currentSource?.metadata.lcc = normalizedValue
        }
        sourceLCCSaveTasks[source.id]?.cancel()
        let completionTicket = issueCompletionTicket(kind: .sourceLoading, targetID: source.id)
        sourceLCCSaveTasks[source.id] = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard isCompletionValid(completionTicket, operation: "updateSourceLCC.wait"), let repository else { return }
            do {
                let updated = try await repository.updateSourceLCC(source, lcc: normalizedValue)
                guard isCompletionValid(completionTicket, operation: "updateSourceLCC.save") else { return }
                if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i] = updated }
                if currentSource?.id == source.id { currentSource = updated }
                // Metadata-only input must be materialized for the selected inspector,
                // as well as indexed. Refresh publishes verified original content
                // through the session completion guards and clears unavailable text.
                await refresh()
            } catch {
                if isCompletionValid(completionTicket, operation: "updateSourceLCC.error") {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    func refreshSourceLCC(_ source: SourceRecord, provider: AIProvider? = nil) {
        guard canInteractWithWorkspace else { return }
        requestAISuggestion(target: .source(source.id), action: .classifyLCC, provider: provider)
    }
    func openBlockURL(_ url: URL) {
        pendingSemanticOccurrence = nil; semanticOccurrenceNavigationTicket = UUID()
        guard url.scheme == "noema", url.host == "page", let noteID = UUID(uuidString: url.lastPathComponent),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "block" })?.value, let blockID = UUID(uuidString: value) else { return }
        guard isVaultAvailable, !busy, canInteractWithWorkspace else { pendingBlockURL = url; return }
        guard let note = notes.first(where: { $0.id == noteID }),
              BlockDocumentCodec.decode(note.body).block(blockID) != nil else {
            errorMessage = "This block link is not available in the open vault."; return
        }
        select(noteID, block: blockID)
    }
    var editingLocked: Bool {
        currentNote?.isEditingLocked == true || editorReadOnly
            || currentNote.map { editingLockOperations.contains($0.id) } == true
    }
    var updatingSourceReferences = false
    func setSourceReference(pageID: UUID, sourceID: UUID, linked: Bool) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !updatingSourceReferences else { return }
        updatingSourceReferences = true
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: pageID)
        let ticket = completionTicket.token
        Task {
            defer { if generation == ticket { updatingSourceReferences = false } }
            if currentNote?.id == pageID, !(await saveCurrent()) { return }
            guard isCompletionValid(completionTicket, operation: "setSourceReference.pre"), let repository,
                  let note = notes.first(where: { $0.id == pageID }), !note.isEditingLocked,
                  !(currentNote?.id == pageID && editorReadOnly) else { return }
            saving = true
            defer { if generation == ticket { saving = false } }
            do {
                let saved = try await repository.setSourceReference(note: note, sourceID: sourceID, linked: linked)
                guard isCompletionValid(completionTicket, operation: "setSourceReference.save") else { return }
                if let i = notes.firstIndex(where: { $0.id == pageID }) { notes[i] = saved }
                if currentNote?.id == pageID { currentNote = saved }
                scheduleRefresh()
            } catch { if isCompletionValid(completionTicket, operation: "setSourceReference.error") { errorMessage = error.localizedDescription } }
        }
    }
    func toggleEditingLock(_ id: UUID? = nil) {
        guard canInteractWithWorkspace,
              canOperateOnLoadedContent,
              let targetID = id ?? currentNote?.id,
              notes.contains(where: { $0.id == targetID }),
              !editingLockOperations.contains(targetID) else { return }
        if currentNote?.id == targetID { flushEditorPublication?() }
        editingLockOperations.insert(targetID)
        if currentNote?.id == targetID {
            semanticCoordinator?.view?.locked = true
            semanticCoordinator?.view?.isEditable = false
        }
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: targetID)
        let ticket = completionTicket.token
        Task {
            defer {
                if generation == ticket {
                    editingLockOperations.remove(targetID)
                    if currentNote?.id == targetID {
                        semanticCoordinator?.view?.locked = editingLocked
                        semanticCoordinator?.view?.isEditable = canEditPage
                        semanticCoordinator?.updateAnnotationAvailability()
                    }
                }
            }
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "toggleEditingLock.wait") else { return }
            if currentNote?.id == targetID, !(await saveCurrent()) { return }
            guard isCompletionValid(completionTicket, operation: "toggleEditingLock.pre"),
                  let note = notes.first(where: { $0.id == targetID }), let repository else { return }
            let editorSnapshot = semanticCoordinator?.session.identity.pageID == targetID
                ? semanticCoordinator?.session.snapshot() : nil
            saving = true
            defer { if generation == ticket { saving = false } }
            do {
                let saved = try await repository.setEditingLock(note: note, locked: !note.isEditingLocked)
                // Metadata writes advance the canonical page revision and annotation evidence.
                // Publish that evidence without treating it as a new user edit or resetting undo.
                let semantic = try? await repository.sqliteBlockStore.loadSemanticPage(pageID: targetID)
                guard isCompletionValid(completionTicket, operation: "toggleEditingLock.save") else { return }
                if currentNote?.id == saved.id {
                    let unchangedDocument = editorDocument == (note.document ?? BlockDocumentCodec.decode(note.body))
                    currentNote = saved; editingHint = nil
                    if unchangedDocument { editorDocument = saved.document ?? BlockDocumentCodec.decode(saved.body) }
                    if let editorSnapshot, let semantic,
                       semantic.snapshot.revision.token.base64EncodedString() == saved.contentHash,
                       semanticCoordinator?.session.acceptSemanticPublication(semantic, for: editorSnapshot) == true {
                        semanticSavedRevision = editorSnapshot.revision
                        if unchangedDocument, semanticCoordinator?.session.revision == editorSnapshot.revision {
                            semanticCoordinator?.lastDocument = saved.document
                        }
                        semanticCoordinator?.refreshSemanticRanges()
                    }
                    semanticCoordinator?.view?.locked = editingLocked
                    semanticCoordinator?.view?.isEditable = canEditPage
                    semanticCoordinator?.updateAnnotationAvailability()
                }
                if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                scheduleRefresh()
            } catch {
                if isCompletionValid(completionTicket, operation: "toggleEditingLock.error") {
                    errorMessage = "Could not change editing lock: " + error.localizedDescription
                }
            }
        }
    }
    func edited() {
        guard canOperateOnLoadedContent, !editingLocked else { return }
        if let note = currentNote, let placeholder = untitledPages[note.id],
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title != placeholder {
            untitledPages.removeValue(forKey: note.id)
        }
        guard currentNote != nil, dirty else { return }
        saveStatus = "Unsaved changes"
        autosaveTask?.cancel()
        autosaveTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            _ = await saveCurrent()
        }
    }
    private struct PageSaveSnapshot {
        let id: UUID
        let note: NoteRecord
        let draft: DraftRecord
        let editor: EditorSession.DocumentSnapshot?
        let pageRevision: BlockStoreRevision?
        let generation: UUID
    }
    private var navigationSaveTask: Task<Void, Never>?
    private var navigationSaveQueue: [(pageID: UUID, snapshotID: UUID)] = []
    @ObservationIgnored var pageSavePreparation: (@MainActor () async throws -> Void)?
    private var pendingPageSaves: [UUID: PageSaveSnapshot] = [:]
    var pageSaveFailures: [UUID: String] = [:]

    private func capturePageSave() -> PageSaveSnapshot? {
        flushEditorPublication?()
        guard canOperateOnLoadedContent, dirty, var note = currentNote else { return nil }
        let trimmedLCC = lccInput.trimmingCharacters(in: .whitespacesAndNewlines)
        note.lcc = trimmedLCC.isEmpty ? nil : trimmedLCC
        let editor = semanticCoordinator?.session.identity.pageID == note.id ? semanticCoordinator?.session.snapshot() : nil
        var draft = DraftRecord(note: note, title: title, document: editorDocument, tags: editedTags)
        draft.semanticEdit = editor?.semanticEdit
        return PageSaveSnapshot(id: UUID(), note: note, draft: draft, editor: editor,
            pageRevision: editor?.pageRevision, generation: generation)
    }

    private func queueCurrentPageSave() {
        autosaveTask?.cancel()
        if needsTitle, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let id = currentNote?.id, let placeholder = untitledPages[id] { title = placeholder }
        guard let snapshot = capturePageSave() else { startTitleGeneration(); return }
        if let pending = pendingPageSaves[snapshot.note.id],
           pending.draft.title == snapshot.draft.title, pending.draft.document == snapshot.draft.document,
           pending.draft.tags == snapshot.draft.tags, pending.note.lcc == snapshot.note.lcc,
           pending.editor?.generation == snapshot.editor?.generation,
           pending.editor?.revision == snapshot.editor?.revision { return }
        pendingPageSaves[snapshot.note.id] = snapshot
        applyRecoveryListing(RecoveryListing(drafts: recoveredDrafts, damagedEntries: damagedRecoveryEntries))
        navigationSaveQueue.append((snapshot.note.id, snapshot.id))
        guard navigationSaveTask == nil else { return }
        navigationSaveTask = Task {
            defer { navigationSaveTask = nil }
            while !navigationSaveQueue.isEmpty {
                let job = navigationSaveQueue.removeFirst()
                await waitForSave(includeNavigation: false)
                guard let captured = pendingPageSaves[job.pageID], captured.id == job.snapshotID,
                      captured.generation == generation, canOperateOnLoadedContent else { continue }
                _ = await persistPageSave(captured)
            }
        }
    }

    @discardableResult func saveCurrent() async -> Bool {
        await waitForSave()
        guard !Task.isCancelled, !saving else { return false }
        guard let snapshot = capturePageSave() else { return true }
        // Queued work is drained; an explicit retry replaces this page's failed capture.
        pendingPageSaves[snapshot.note.id] = snapshot
        return await persistPageSave(snapshot)
    }

    private func persistPageSave(_ captured: PageSaveSnapshot) async -> Bool {
        guard let repository, let recovery, captured.generation == generation else { return false }
        let note = captured.note, draft = captured.draft, editorSnapshot = captured.editor
        let capturedDocument = draft.document ?? BlockDocumentCodec.decode(draft.contentBody)
        let ticket = captured.generation
        if pendingPageSaves[note.id] == nil { pendingPageSaves[note.id] = captured }
        saving = true
        if currentNote?.id == note.id { saveStatus = "Saving…" }
        do {
            try await pageSavePreparation?()
            guard generation == ticket, canOperateOnLoadedContent else { saving = false; return false }
            let capturedWordCount = capturedDocument.withoutAISummary.flattened.map(\.text).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
            if currentNote?.id == note.id, editorDocument == capturedDocument { wordCount = capturedWordCount }
            try await recovery.store(draft)
            let saved: NoteRecord
            var semanticPublication: SemanticPageSnapshot?
            if let snapshot = editorSnapshot, let edit = snapshot.semanticEdit,
               let pageRevision = captured.pageRevision {
                let store = repository.sqliteBlockStore
                var entities = snapshot.expectedEntityRevisions, objects = snapshot.expectedObjectRevisions
                for annotation in edit.annotations where annotation.referent.disposition != .unresolved {
                    let target = annotation.referent.identity
                    if ["question", "definition"].contains(target.kind) {
                        if objects[target.id] == nil, !edit.objects.contains(where: { $0.id == target.id }) { objects[target.id] = try await store.loadObject(id: target.id).revision }
                    } else if entities[target.id] == nil { entities[target.id] = try await store.loadEntity(id: target.id).revision }
                }
                let vault = try await store.canonicalVaultRevision()
                let result = try await repository.saveSemantic(note: note, title: draft.title, tags: draft.tags, edit: edit,
                    expectedPageRevision: pageRevision, expectedEntityRevisions: entities,
                    expectedObjectRevisions: objects, expectedVaultRevision: vault)
                saved = result.0; semanticPublication = result.1
                guard generation == ticket, canOperateOnLoadedContent else { saving = false; return false }
                if currentNote?.id == note.id,
                   semanticCoordinator?.session.generation == snapshot.generation,
                   semanticCoordinator?.session.acceptSemanticPublication(result.1, for: snapshot) == true {
                    semanticCoordinator?.refreshSemanticRanges()
                    semanticSavedRevision = snapshot.revision
                    if semanticCoordinator?.session.revision == snapshot.revision { semanticCoordinator?.lastDocument = saved.document }
                }
            } else {
                saved = try await repository.save(note: note, title: draft.title, document: capturedDocument, tags: draft.tags)
            }
            guard generation == ticket, canOperateOnLoadedContent else { saving = false; return false }
            recordPageRename(saved.id, from: note.title, to: saved.title)
            if currentNote?.id == saved.id {
                currentNote = saved
                if lccInput.trimmingCharacters(in: .whitespacesAndNewlines) == (note.lcc ?? "") { lccInput = saved.lcc ?? "" }
                if title == draft.title { title = saved.title }
                // Reconcile canonical revision evidence only for the captured document;
                // edits made while saving retain their newer draft.
                if editorDocument == draft.document { editorDocument = saved.document ?? BlockDocumentCodec.decode(saved.body) }
                if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                updateTags()
            }
            if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
            let latest = pendingPageSaves[saved.id]
            let superseded = latest != nil && latest?.id != captured.id
            if let latest, superseded, latest.note.contentHash == note.contentHash {
                // Advance only our own acknowledged predecessor, never a scan/external revision.
                var rebasedNote = latest.note; rebasedNote.contentHash = saved.contentHash
                var rebasedDraft = latest.draft; rebasedDraft.note = rebasedNote
                var editor = latest.editor
                if let snapshot = editor, let semanticPublication {
                    let session = EditorSession()
                    session.restorePendingSnapshot(snapshot, identity: snapshot.identity)
                    session.rebaseSemanticEvidence(semanticPublication)
                    editor = session.snapshot(); rebasedDraft.semanticEdit = editor?.semanticEdit
                }
                pendingPageSaves[saved.id] = PageSaveSnapshot(id: latest.id, note: rebasedNote,
                    draft: rebasedDraft, editor: editor, pageRevision: editor?.pageRevision, generation: latest.generation)
            } else if !superseded { pendingPageSaves.removeValue(forKey: saved.id) }
            if let semanticPublication, currentNote?.id == saved.id,
               let session = semanticCoordinator?.session, session.pageRevision == captured.pageRevision {
                let unchanged = session.revision == editorSnapshot?.revision && editorDocument == saved.document
                session.rebaseSemanticEvidence(semanticPublication)
                if unchanged { semanticSavedRevision = session.revision }
            }
            if !superseded && (currentNote?.id != saved.id || !dirty) { try await recovery.remove(saved.id) }
            pageSaveFailures.removeValue(forKey: saved.id)
            if currentNote?.id == saved.id {
                saveStatus = dirty ? "Unsaved changes" : "Saved locally"
                errorMessage = nil; externalChange = false
            }
            applyRecoveryListing(try await recovery.listing())
            saving = false
            scheduleRefresh()
            startTitleGeneration(for: saved)
            if currentNote?.id == saved.id {
                if dirty { edited() }
                return !dirty
            }
            return true
        } catch {
            guard generation == ticket, canOperateOnLoadedContent else { saving = false; return false }
            saving = false
            pageSaveFailures[note.id] = error.localizedDescription
            if currentNote?.id == note.id {
                saveStatus = "Save failed · draft retained"
                errorMessage = error.localizedDescription
                if case VaultError.conflict = error { externalChange = true }
            }
            do {
                let drafts = try await recovery.listing()
                guard generation == ticket, canOperateOnLoadedContent else { return false }
                applyRecoveryListing(drafts)
            } catch {
                if generation == ticket, canOperateOnLoadedContent {
                    errorMessage = (errorMessage ?? "Save failed.") + " Recovery reload failed: " + error.localizedDescription
                }
            }
            return false
        }
    }
    private func waitForSave(includeNavigation: Bool = true) async {
        if includeNavigation {
            while let task = navigationSaveTask { await task.value }
        }
        while saving {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
    var needsTitle: Bool {
        guard let note = currentNote, let placeholder = untitledPages[note.id] else { return false }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == placeholder
    }
    var hasPendingTitles: Bool { !titleTasks.isEmpty }
    func editorAllowsGeneratedTitle(for note: NoteRecord) -> Bool {
        guard notes.first(where: { $0.id == note.id })?.lcc == note.lcc else { return false }
        guard currentNote?.id == note.id else { return true }
        return !dirty && !editingLocked && !externalChange && currentNote?.contentHash == note.contentHash
    }
    @discardableResult func finishCurrentPage(waitForTitles: Bool = false) async -> Bool {
        autosaveTask?.cancel()
        if needsTitle, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let id = currentNote?.id, let placeholder = untitledPages[id] { title = placeholder }
        guard await saveCurrent() else { return false }
        startTitleGeneration()
        if waitForTitles {
            let pending = Array(titleTasks.values)
            for task in pending { await task.value }
            return await saveCurrent()
        }
        return true
    }
    private func reconcileMetadataPublication(_ saved: SemanticPageSnapshot, captured: EditorSession.DocumentSnapshot?) {
        guard let captured, currentNote?.id == saved.snapshot.pageID,
              currentNote?.contentHash == saved.snapshot.revision.token.base64EncodedString(),
              semanticCoordinator?.session.acceptSemanticPublication(saved, for: captured) == true else { return }
        semanticSavedRevision = captured.revision
        if semanticCoordinator?.session.revision == captured.revision {
            editorDocument = saved.snapshot.document
            semanticCoordinator?.lastDocument = saved.snapshot.document
        }
        semanticCoordinator?.refreshSemanticRanges()
    }
    private func startTitleGeneration(for candidate: NoteRecord? = nil) {
        guard canOperateOnLoadedContent, let validateAI = automaticLocalAIValidation(for: .suggestTitle),
              let note = candidate ?? currentNote, let repository,
              untitledPages[note.id] == note.title,
              titleTasks[note.id] == nil, !note.isEditingLocked,
              (currentNote?.id != note.id || (!editingLocked && !externalChange)),
              aiClient.unavailabilityReason() == nil else { return }
        let completionTicket = issueCompletionTicket(kind: .aiProcessing, targetID: note.id)
        let content = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(note.body).withoutAISummary))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let client = aiClient
        titleTasks[note.id] = Task { [self] in
            await withLocalAIActivity(target: .page(note.id), action: .suggestTitle, executionMode: .automatic) { activity in
                defer { if generation == completionTicket.token { titleTasks.removeValue(forKey: note.id) } }
                do {
                    try validateAI()
                    try await activity.start(contentSizeBytes: content.utf8.count)
                    async let generatedTitle = client.pageTitle(content)
                    async let generatedLCC = client.inferLCC(content)
                    let (generated, lcc) = try await (generatedTitle, generatedLCC)
                    guard let generated else { activity.fail(ExternalAIError.invalidResponse); return }
                    await waitForSave()
                    guard isCompletionValid(completionTicket, operation: "startTitleGeneration.generate"),
                          untitledPages[note.id] == note.title,
                          editorAllowsGeneratedTitle(for: note) else { return }
                    saving = true
                    defer { if generation == completionTicket.token { saving = false } }
                    var updatedNote = note
                    if note.lcc == nil, let lcc, !lcc.isEmpty { updatedNote.lcc = lcc }
                    let editorSnapshot = semanticCoordinator?.session.identity.pageID == note.id ? semanticCoordinator?.session.snapshot() : nil
                    let saved = try await repository.save(note: updatedNote, title: generated, body: note.body, tags: note.tags, validating: validateAI)
                    let semantic = try await repository.sqliteBlockStore.loadSemanticPage(pageID: note.id)
                    activity.complete()
                    guard isCompletionValid(completionTicket, operation: "startTitleGeneration.save") else { return }
                    recordPageRename(saved.id, from: note.title, to: saved.title)
                    untitledPages.removeValue(forKey: note.id)
                    if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                    if currentNote?.id == saved.id {
                        currentNote = saved
                        reconcileMetadataPublication(semantic, captured: editorSnapshot)
                        if title == note.title { title = saved.title }
                    }
                    scheduleRefresh()
                } catch { activity.fail(error) /* Content is already saved; retain the placeholder for another attempt. */ }
            }
        }
    }
    func suggestPageTitle(provider: AIProvider? = nil) {
        guard canInteractWithWorkspace, let note = currentNote, !editingLocked, !externalChange else { return }
        requestAISuggestion(target: .page(note.id), action: .suggestTitle, provider: provider)
    }

    func suggestSourceTitle(_ source: SourceRecord) {
        guard canInteractWithWorkspace else { return }
        requestAISuggestion(target: .source(source.id), action: .suggestTitle)
    }

    func prepareUntitledPageForNaming() {
        guard canOperateOnLoadedContent, let note = currentNote, !editingLocked else { return }
        let candidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty || candidate.range(of: #"^Untitled(?: [0-9]+)?$"#, options: .regularExpression) != nil else { return }
        untitledPages[note.id] = candidate.isEmpty ? note.title : title
    }
    func savePage() {
        prepareUntitledPageForNaming()
        saveNow()
    }
    func saveNow() {
        autosaveTask?.cancel()
        guard isVaultAvailable else { return }
        Task { _ = await finishCurrentPage() }
    }
    func generatePreview(recordSourceAccess: Bool = false) {
        previewTask?.cancel()
        guard canOperateOnLoadedContent else { return }
        let captured = body
        let targetID = currentNote?.id ?? currentSource?.id
        let completionTicket = issueCompletionTicket(kind: .preview, targetID: targetID, capturedText: captured)
        let renderer = previewRenderer
        previewTask = Task {
            let (blocks, count) = await renderer(captured)
            guard isCompletionValid(
                completionTicket,
                expectedTargetID: currentNote?.id ?? currentSource?.id,
                checkTargetID: true,
                currentText: body,
                operation: "generatePreview"
            ) else { return }
            preview = blocks; wordCount = count
            if recordSourceAccess, let source = currentSource, source.contentState == .loaded, source.availabilityIssue == nil { recordSidebarAccess(.source(source.id)) }
        }
    }
    private func updateTags() { tags = Array(Set(notes.flatMap(\.allTags))).sorted() }
    func createPageFromTopic(_ input: String) async -> Bool {
        await prepareAIPage(.topic(input))
    }

    func newPage(template: Bool = false, named name: String = "Untitled") {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .pageMutation)
        Task {
            if !(await finishCurrentPage()) { return }
            guard isCompletionValid(completionTicket, operation: "newPage.finish"), let repository else { return }
            do {
                let body = template ? "## Overview\n\n\n## Personal context\n\nWhy does this matter to me?\n\n## Connections\n\n" : ""
                let note = try await repository.create(title: name, body: body)
                guard isCompletionValid(completionTicket, operation: "newPage.create") else { return }
                if name == "Untitled" { untitledPages[note.id] = note.title }
                errorMessage = nil
                notes.insert(note, at: 0); scope = .wiki
                selectedID = note.id; currentSource = nil; apply(note)
                selectedSidebarRecentItemID = nil
                recordSidebarAccess(.page(note.id))
                await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "newPage.error") { errorMessage = error.localizedDescription } }
        }
    }
    func trashCurrent() { trashPage(currentNote?.id) }
    func trashPage(_ id: UUID?) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, let id else { return }
        let completionTicket = issueCompletionTicket(kind: .trashMutation, targetID: id)
        Task {
            if currentNote?.id == id, !(await saveCurrent()) { return }
            guard isCompletionValid(completionTicket, operation: "trashPage.pre"),
                  let note = notes.first(where: { $0.id == id }), let repository else { return }
            do {
                try await repository.trash(note: note)
                guard isCompletionValid(completionTicket, operation: "trashPage.trash") else { return }
                if currentNote?.id == id {
                    selectedID = nil; currentNote = nil; body = ""; backlinks = []; outgoingLinkTargets = []; externalChange = false
                }
                await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "trashPage.error") { errorMessage = error.localizedDescription } }
        }
    }
    func restoreTrashedPage(_ page: TrashedItem) {
        performTrashOperation([page], restoring: true)
    }
    func permanentlyDeleteTrashedPage(_ page: TrashedItem) {
        performTrashOperation([page], restoring: false)
    }
    func emptyTrash(_ pages: [TrashedItem]) {
        performTrashOperation(pages, restoring: false)
    }
    private func performTrashOperation(_ pages: [TrashedItem], restoring: Bool) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !trashOperationInProgress, !pages.isEmpty, let repository else { return }
        trashOperationInProgress = true; errorMessage = nil
        let completionTicket = issueCompletionTicket(kind: .trashMutation)
        let ticket = completionTicket.token
        Task {
            defer { if generation == ticket { trashOperationInProgress = false } }
            guard isCompletionValid(completionTicket, operation: "performTrashOperation.start") else { return }
            var failures: [String] = []
            if restoring {
                for page in pages {
                    guard isCompletionValid(completionTicket, operation: "performTrashOperation.restore") else { return }
                    do { try await repository.restore(page) }
                    catch { failures.append("\(page.title): \(error.localizedDescription)") }
                }
            } else {
                failures = await repository.emptyTrashItems(pages)
            }
            guard isCompletionValid(completionTicket, operation: "performTrashOperation.post") else { return }
            do {
                let remaining = try await repository.trashItems()
                guard isCompletionValid(completionTicket, operation: "performTrashOperation.trashItems") else { return }
                trashedPages = remaining
            } catch { failures.append("Could not reload Trash: " + error.localizedDescription) }
            await refresh()
            guard isCompletionValid(completionTicket, operation: "performTrashOperation.complete") else { return }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }
    func reloadDiskVersion() {
        guard canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: selectedID)
        Task {
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "reloadDiskVersion.wait") else { return }
            if dirty, let note = currentNote, let recovery {
                do {
                    try await recovery.store(DraftRecord(note: note, title: title, document: editorDocument, tags: editedTags, semanticEdit: semanticCoordinator?.session.semanticEdit))
                    let drafts = try await recovery.listing()
                    guard isCompletionValid(completionTicket, operation: "reloadDiskVersion.drafts") else { return }
                    applyRecoveryListing(drafts)
                } catch {
                    if isCompletionValid(completionTicket, operation: "reloadDiskVersion.recoveryError") {
                        errorMessage = "Could not preserve your draft: " + error.localizedDescription
                    }
                    return
                }
            }
            if let repository, let entries = try? await repository.scan(),
               isCompletionValid(completionTicket, operation: "reloadDiskVersion.scan"),
               let fresh = entries.notes.first(where: { $0.id == selectedID }) {
                pendingPageSaves.removeValue(forKey: fresh.id); pageSaveFailures.removeValue(forKey: fresh.id)
                semanticCoordinator = nil; semanticReadyIdentity = nil
                apply(fresh); errorMessage = nil
            } else if isCompletionValid(completionTicket, operation: "reloadDiskVersion.unavailable") {
                errorMessage = "The original page is unavailable. You can save your draft as a new page."
            }
        }
    }
    func saveDraftAsNewPage(_ recovered: DraftRecord? = nil) {
        guard canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .pageMutation)
        Task {
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "saveDraftAsNewPage.start"), let repository else { return }
            let originalID = recovered?.id ?? currentNote?.id
            do {
                let preservationDraft = recovered ?? currentNote.map { DraftRecord(note: $0, title: title, document: editorDocument, tags: editedTags, semanticEdit: semanticCoordinator?.session.semanticEdit) }
                let note: NoteRecord
                if let preservationDraft, preservationDraft.semanticEdit != nil {
                    note = try await repository.recoverSemanticDraft(preservationDraft)
                } else {
                    let created = try await repository.create(title: (recovered?.title ?? title) + " (recovered)", body: recovered?.contentBody ?? body)
                    note = try await repository.save(note: created, title: created.title, body: created.body, tags: recovered?.tags ?? editedTags)
                }
                if let originalID { try await recovery?.remove(originalID) }
                let drafts = try await recovery?.listing() ?? RecoveryListing()
                guard isCompletionValid(completionTicket, operation: "saveDraftAsNewPage") else { return }
                if let originalID { pendingPageSaves.removeValue(forKey: originalID); pageSaveFailures.removeValue(forKey: originalID) }
                applyRecoveryListing(drafts)
                notes.insert(note, at: 0); scope = .wiki; currentSource = nil; selectedID = note.id; apply(note)
                selectedSidebarRecentItemID = nil
                recordSidebarAccess(.page(note.id))
                errorMessage = nil; showRecovery = false; await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "saveDraftAsNewPage.error") { errorMessage = error.localizedDescription } }
        }
    }
    func discardRecovery(_ draft: DraftRecord) {
        guard canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: draft.id)
        Task {
            guard isCompletionValid(completionTicket, operation: "discardRecovery.start") else { return }
            do {
                await waitForSave()
                try await recovery?.remove(draft.id)
                pendingPageSaves.removeValue(forKey: draft.id); pageSaveFailures.removeValue(forKey: draft.id)
                let drafts = try await recovery?.listing() ?? RecoveryListing()
                guard isCompletionValid(completionTicket, operation: "discardRecovery") else { return }
                applyRecoveryListing(drafts)
            } catch { if isCompletionValid(completionTicket, operation: "discardRecovery.error") { errorMessage = error.localizedDescription } }
        }
    }
    private func applyRecoveryListing(_ listing: RecoveryListing) {
        recoveredDrafts = listing.drafts
        for pending in pendingPageSaves.values {
            recoveredDrafts.removeAll { $0.id == pending.note.id }
            recoveredDrafts.append(pending.draft)
        }
        damagedRecoveryEntries = listing.damagedEntries
    }
    func updateBacklinks() async {
        guard canOperateOnLoadedContent, let note = currentNote, let index else { backlinks = []; outgoingLinkTargets = []; return }
        let completionTicket = issueCompletionTicket(kind: .search, targetID: note.id)
        async let incomingTask = try? index.backlinks(to: note)
        async let outgoingTask = try? index.outgoingLinks(from: note.id)
        let (incomingIDs, outgoingTargets) = await (incomingTask, outgoingTask)
        guard isCompletionValid(completionTicket, expectedTargetID: currentNote?.id, checkTargetID: true, operation: "updateBacklinks") else { return }
        let ids = Set(incomingIDs ?? [])
        backlinks = notes.filter { ids.contains($0.id) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        outgoingLinkTargets = outgoingTargets ?? []
    }
    func followWikiLink(_ target: String) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        let key = normalized(target)
        let matches = notes.filter { normalized($0.title) == key || $0.aliases.contains(where: { normalized($0) == key }) }
        if matches.count == 1 { select(matches[0].id) }
        else if matches.isEmpty { unresolvedTarget = target }
        else { ambiguousMatches = matches }
    }
    func suggestLink(_ title: String) { guard canEditPage else { return }; editorAction = EditorAction(operation: .wikiLink(title)); wikiQuery = nil }
    func format(_ prefix: String, _ suffix: String) { guard canEditPage else { return }; editorAction = EditorAction(operation: .wrap(prefix, suffix)) }
    func importFiles() { addSource() }
    func linkSources() { addSource() }
    func addSource() {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !isChoosingSource else { return }
        isChoosingSource = true
        let completionTicket = issueCompletionTicket(kind: .sourceLoading)
        let panel = NSOpenPanel()
        sourceCommandPanel = panel
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.prompt = "Add Source"
        panel.message = "Choose up to 5 files. Link by default, or import files up to 2 MB each."
        let importOption = NSButton(checkboxWithTitle: "Import into vault (maximum 2 MB per file)", target: nil, action: nil)
        importOption.state = .off; importOption.setFrameSize(NSSize(width: 380, height: 28))
        panel.accessoryView = importOption; panel.isAccessoryViewDisclosed = true
        presentPanel(panel) { [weak self] response in
            guard let self, self.sourceCommandPanel === panel else { return }
            self.isChoosingSource = false
            self.sourceCommandPanel = nil
            guard response == .OK,
                  self.isCompletionValid(completionTicket, operation: "addSource.panel") else { return }
            let urls = panel.urls
            guard urls.count <= 5 else { self.errorMessage = "Add up to 5 files at a time."; return }
            let shouldImport = importOption.state == .on
            Task { @MainActor in
                guard self.isCompletionValid(completionTicket, operation: "addSource.panelCompletion") else { return }
                await self.addSourceFiles(urls, shouldImport: shouldImport)
            }
        }
    }
    func addSourceFiles(
        _ urls: [URL],
        shouldImport: Bool,
        isCloudNotDownloaded: @escaping @Sendable (URL) -> Bool = FileVaultRepository.isCloudFileNotDownloaded,
        downloadCloudFile: @escaping @Sendable (URL) async throws -> Data = FileVaultRepository.downloadCloudFile
    ) async {
        guard canOperateOnLoadedContent else { return }
        guard urls.count <= 5 else { errorMessage = "Add up to 5 files at a time."; return }
        guard let repository else { return }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading)
        guard await finishCurrentPage(),
              isCompletionValid(completionTicket, operation: "addSourceFiles.finish") else { return }
        scope = .sources
        var failures: [String] = []
        for url in urls {
            do {
                guard isCompletionValid(completionTicket, operation: "addSourceFiles.loop") else { return }
                if isCloudNotDownloaded(url) {
                    let pending = try await repository.beginSourceDownload(at: url, shouldImport: shouldImport)
                    guard isCompletionValid(completionTicket, operation: "addSourceFiles.beginDownload") else { return }
                    sources.append(pending)
                    rows = sources.map(LibraryRow.init(source:))
                    enqueueSourceDownload(pending, url: url, shouldImport: shouldImport, download: downloadCloudFile)
                    continue
                }
                let added: [SourceRecord]
                do {
                    if shouldImport {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let data = try await Task.detached {
                            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            guard values.isRegularFile == true else { throw VaultError.invalid("Choose a regular file. Folders are not supported.") }
                            guard (values.fileSize ?? 0) <= FileVaultRepository.maximumImportBytes else { throw VaultError.invalid("Files larger than 2 MB must be linked instead of imported.") }
                            return try FileVaultRepository.coordinatedRead(url)
                        }.value
                        guard isCompletionValid(completionTicket, operation: "addSourceFiles.readImport") else { return }
                        added = [try await repository.importSource(data: data, filename: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent, originURL: nil)]
                    } else {
                        added = try await repository.linkSources(at: url, maximumFiles: 5)
                    }
                } catch let error as VaultError {
                    if case .unavailable = error {
                        let pending = try await repository.beginSourceDownload(at: url, shouldImport: shouldImport)
                        guard isCompletionValid(completionTicket, operation: "addSourceFiles.fallbackDownload") else { return }
                        sources.append(pending)
                        rows = sources.map(LibraryRow.init(source:))
                        enqueueSourceDownload(pending, url: url, shouldImport: shouldImport, download: downloadCloudFile)
                        continue
                    }
                    throw error
                }
                guard isCompletionValid(completionTicket, operation: "addSourceFiles.added") else { return }
                sources.append(contentsOf: added)
                rows = sources.map(LibraryRow.init(source:))
                for source in added { enqueueSourceTitle(source) }
            } catch {
                guard isCompletionValid(completionTicket, operation: "addSourceFiles.error") else { return }
                failures.append(url.lastPathComponent + ": " + error.localizedDescription)
                errorMessage = failures.joined(separator: "\n")
            }
        }
        guard isCompletionValid(completionTicket, operation: "addSourceFiles.refresh") else { return }
        await refresh()
    }
    private func enqueueSourceDownload(
        _ source: SourceRecord,
        url: URL,
        shouldImport: Bool,
        download: @escaping @Sendable (URL) async throws -> Data
    ) {
        guard canOperateOnLoadedContent else { return }
        downloadingSources.insert(source.id)
        sourceDownloadQueue.append(PendingSourceDownload(source: source, url: url, shouldImport: shouldImport, download: download))
        guard sourceDownloadTask == nil, let repository else { return }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading, targetID: source.id)
        let ticket = completionTicket.token
        sourceDownloadTask = Task {
            defer {
                if generation == ticket {
                    sourceDownloadTask = nil
                    sourceDownloadQueue = []
                    downloadingSources = []
                }
            }
            while !sourceDownloadQueue.isEmpty {
                guard isCompletionValid(completionTicket, operation: "sourceDownload.loop") else { return }
                let item = sourceDownloadQueue.removeFirst()
                guard downloadingSources.contains(item.source.id) else { continue }
                do {
                    let access = item.url.startAccessingSecurityScopedResource()
                    defer { if access { item.url.stopAccessingSecurityScopedResource() } }
                    let data = try await item.download(item.url)
                    guard isCompletionValid(completionTicket, operation: "sourceDownload.downloaded"),
                          downloadingSources.contains(item.source.id) else { return }
                    let completed = try await repository.completeSourceDownload(
                        id: item.source.id,
                        at: item.url,
                        data: data,
                        shouldImport: item.shouldImport
                    )
                    guard isCompletionValid(completionTicket, operation: "sourceDownload.completed") else { return }
                    downloadingSources.remove(item.source.id)
                    sourceAvailability.removeValue(forKey: item.source.id)
                    if let indexPos = sources.firstIndex(where: { $0.id == item.source.id }) {
                        sources[indexPos] = completed
                    } else {
                        sources.append(completed)
                    }
                    if currentSource?.id == completed.id {
                        currentSource = completed
                        title = completed.title
                        body = completed.body
                        generatePreview()
                    }
                    await refresh()
                    enqueueSourceTitle(completed)
                } catch {
                    await repository.cancelSourceDownload(id: item.source.id)
                    guard isCompletionValid(completionTicket, operation: "sourceDownload.error") else { return }
                    downloadingSources.remove(item.source.id)
                    sources.removeAll { $0.id == item.source.id }
                    errorMessage = item.url.lastPathComponent + ": " + error.localizedDescription
                    await refresh()
                }
            }
        }
    }
    func addURLSources(_ text: String) async -> [String] {
        guard canOperateOnLoadedContent, let repository, await finishCurrentPage() else { return ["Open a vault and finish saving before adding sources."] }
        let lines: [String]
        do { lines = try WebSourceFetcher.lines(text) } catch { return [error.localizedDescription] }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading)
        scope = .sources
        var failures: [String] = []
        for address in lines {
            guard isCompletionValid(completionTicket, operation: "addURLSources.loop") else { return failures + ["Vault changed; remaining URLs were not added."] }
            do {
                let source = try await repository.importURLSource(address)
                guard isCompletionValid(completionTicket, operation: "addURLSources.imported") else { return failures }
                sources.append(source); rows = sources.map(LibraryRow.init(source:))
                enqueueSourceTitle(source)
            } catch {
                guard isCompletionValid(completionTicket, operation: "addURLSources.error") else { return failures }
                failures.append(address + ": " + error.localizedDescription)
            }
        }
        if isCompletionValid(completionTicket, operation: "addURLSources.refresh") { await refresh() }
        return failures
    }
    func availabilityLabel(_ id: UUID) -> String {
        if downloadingSources.contains(id) { return "Downloading from iCloud" }
        return sourceAvailability[id] ?? sources.first(where: { $0.id == id })?.availabilityIssue ?? "Available"
    }
    func checkSourceAvailability(_ requested: [SourceRecord]) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, let repository, let root else { return }
        for source in requested where !checkingSourceAvailability.contains(source.id) && !downloadingSources.contains(source.id) {
            checkingSourceAvailability.insert(source.id); sourceAvailabilityQueue.append(source)
        }
        guard sourceAvailabilityTask == nil, !sourceAvailabilityQueue.isEmpty else { return }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading)
        let ticket = completionTicket.token
        let customChecker = sourceAvailabilityChecker
        sourceAvailabilityTask = Task {
            defer { if generation == ticket { sourceAvailabilityTask = nil; checkingSourceAvailability = []; sourceAvailabilityQueue = [] } }
            while !sourceAvailabilityQueue.isEmpty {
                guard isCompletionValid(completionTicket, operation: "checkSourceAvailability.loop") else { return }
                let source = sourceAvailabilityQueue.removeFirst()
                let status: String
                if let customChecker {
                    status = await customChecker(source, root, repository.contentStore)
                } else if source.metadata.isURLSource == true {
                    do { status = try await repository.checkURLSourceAvailability(source) }
                    catch { status = "Availability check: " + error.localizedDescription }
                } else {
                    status = await Task.detached { FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) }.value
                }
                guard isCompletionValid(completionTicket, operation: "checkSourceAvailability.result") else { return }
                if sources.contains(where: { $0.id == source.id }) { sourceAvailability[source.id] = status }
                checkingSourceAvailability.remove(source.id)
            }
        }
    }
    func sourceSummaryContent(_ source: SourceRecord, root: URL) async throws -> String {
        guard canOperateOnLoadedContent, let contentStore = repository?.contentStore else {
            throw VaultError.unavailable("Open a vault before reading a source.")
        }
        if let gated = contentStore as? GatedVaultContentStore {
            let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            if normalizedRoot != gated.root {
                throw VaultAccessError.wrongVault(
                    expectedVaultID: gated.vaultID,
                    expectedRoot: gated.root,
                    actualVaultID: nil,
                    actualRoot: normalizedRoot,
                    operation: "sourceSummaryContent"
                )
            }
            try gated.validateAccess(operation: "sourceSummaryContent")
        }
        let loaded: SourceRecord
        if source.contentState == .loaded { loaded = source }
        else if let repository { loaded = try await repository.loadSource(id: source.id) }
        else { throw VaultError.unavailable("Source content is unavailable.") }
        return try await Task.detached {
            let source = loaded
            if let gated = contentStore as? GatedVaultContentStore {
                try gated.validateAccess(operation: "sourceSummaryContent")
            }
            if !source.metadata.originalFilename.lowercased().hasSuffix(".pdf") {
                let ext = URL(fileURLWithPath: source.metadata.originalFilename).pathExtension.lowercased()
                let content = ["html", "htm"].contains(ext) ? source.body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : source.body
                return BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(content).withoutAISummary))
            }
            let data = try FileVaultRepository.readSourceOriginal(source, root: root, contentStore: contentStore)
            if source.metadata.originalFilename.lowercased().hasSuffix(".pdf"), let pdf = PDFDocument(data: data) { return pdf.string ?? "" }
            return ""
        }.value
    }
    func createPageFromSource(_ source: SourceRecord, provider: AIProvider? = nil) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent, !downloadingSources.contains(source.id), !hasPendingCloudSummary,
              !generatingTopicPage, aiPageDraft == nil, aiPageSubmission == nil else { return }
        aiPageSourceID = source.id
        aiPageProviderOverride = provider
        showTopicPage = true
    }

    func generateSourceSummary(_ source: SourceRecord) {
        guard canOperateOnLoadedContent, !downloadingSources.contains(source.id), !generatingSourceTitles.contains(source.id),
              !generatingSourceSummaries.contains(source.id), cloudSummaryTarget == nil, cloudSummaryConfirmation == nil,
              let repository else { return }
        if let reason = aiClient.unavailabilityReason() { aiProviderNotice = reason; return }
        let completionTicket = issueCompletionTicket(kind: .aiProcessing, targetID: source.id)
        let requestID = UUID()
        nativeSourceSummaryIDs[source.id] = requestID
        let client = aiClient
        generatingSourceSummaries.insert(source.id)
        sourceSummaryTasks[source.id] = Task {
            await withLocalAIActivity(id: requestID, target: .source(source.id), action: .summarizeSource) { activity in
                defer {
                    if generation == completionTicket.token, nativeSourceSummaryIDs[source.id] == requestID {
                        nativeSourceSummaryIDs.removeValue(forKey: source.id)
                        generatingSourceSummaries.remove(source.id); sourceSummaryTasks.removeValue(forKey: source.id)
                    }
                }
                do {
                    let snapshot = try await repository.sourceSummarySnapshot(id: source.id)
                    let text = try await Task.detached { try CloudSummaryConfirmation.extractedText(snapshot) }.value
                    guard isCompletionValid(completionTicket, operation: "generateSourceSummary.read") else { return }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExternalAIError.emptyContent }
                    cloudPublicationGuard.arm(requestID: requestID)
                    let publicationGuard = cloudPublicationGuard
                    try await activity.start(contentSizeBytes: text.utf8.count)
                    let enrichment = try await nativeEnrichment(client, text: String(text.prefix(6000)), mode: Self.enrichmentMode(.source(snapshot)))
                    let summary = enrichment.summary
                    try Task.checkCancellation()
                    guard nativeSourceSummaryIDs[source.id] == requestID,
                          isCompletionValid(completionTicket, operation: "generateSourceSummary.generate") else { return }
                    guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          summary.utf8.count <= ExternalAILimits.maximumSummaryBytes else { throw ExternalAIError.invalidResponse }
                    let saved = try await repository.publishSourceEnrichment(snapshot, summary: summary,
                        classification: Self.classification(enrichment.classification, provenance: SummaryProvenance(provider: "On-device", model: "Apple Intelligence", generatedAt: Date())),
                        title: Self.enrichmentMode(.source(snapshot)) == .initial ? enrichment.title : nil,
                        provenance: SummaryProvenance(provider: "On-device", model: "Apple Intelligence", generatedAt: Date()),
                        validate: { try publicationGuard.validate(requestID: requestID) })
                    activity.complete()
                    guard isCompletionValid(completionTicket, operation: "generateSourceSummary.save") else { return }
                    if let i = sources.firstIndex(where: { $0.id == saved.id }) { sources[i] = saved }
                    if currentSource?.id == saved.id { currentSource = saved }
                    await refresh()
                } catch {
                    activity.fail(error)
                    guard !Task.isCancelled, nativeSourceSummaryIDs[source.id] == requestID,
                          isCompletionValid(completionTicket, operation: "generateSourceSummary.error") else { return }
                    aiProviderNotice = Self.cloudError(error)
                }
            }
        }
    }
    func enqueueSourceTitle(_ source: SourceRecord) {
        guard canOperateOnLoadedContent, let validateAI = automaticLocalAIValidation(for: .processSource) else { return }
        if sourceNamingTask == nil { sourceRenameCompleted = 0; sourceRenameTotal = 0 }
        sourceNamingQueue.append(source); generatingSourceTitles.insert(source.id); sourceRenameTotal += 1
        guard sourceNamingTask == nil, let repository, let root else { return }
        let completionTicket = issueCompletionTicket(kind: .aiProcessing, targetID: source.id)
        let ticket = completionTicket.token
        let client = aiClient
        sourceNamingTask = Task {
            defer {
                if generation == ticket { sourceNamingTask = nil; sourceNamingQueue = []; generatingSourceTitles = []; sourceRenameCompleted = 0; sourceRenameTotal = 0 }
            }
            while !sourceNamingQueue.isEmpty {
                guard (try? validateAI()) != nil,
                      isCompletionValid(completionTicket, operation: "enqueueSourceTitle.loop") else { return }
                let source = sourceNamingQueue.removeFirst()
                if sourceNamingOverrides.contains(source.id) {
                    generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1; continue
                }
                await withLocalAIActivity(target: .source(source.id), action: .processSource, executionMode: .automatic) { activity in
                    do {
                        if let reason = client.unavailabilityReason() { throw VaultError.unavailable(reason) }
                        let snapshot = try await repository.sourceSummarySnapshot(id: source.id)
                        let source = snapshot.source
                        let text = try await sourceSummaryContent(source, root: root)
                        guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.read") else { return }
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.unavailable("No readable text for automatic naming and summary. Original file name retained.") }
                        let excerpt = String(text.prefix(6000))
                        try validateAI()
                        try await activity.start(contentSizeBytes: text.utf8.count)
                        async let generatedTitle = client.pageTitle(text)
                        async let generatedSummary = client.summarize(excerpt)
                        async let generatedLCC = client.inferLCC(excerpt)
                        let (titleResult, summary, lcc) = try await (generatedTitle, generatedSummary, generatedLCC)
                        guard let title = titleResult else { throw VaultError.unavailable("No valid topic title was generated. Original file name retained.") }
                        guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.generate") else { return }
                        if sourceNamingOverrides.contains(source.id) {
                            return
                        }
                        guard sources.first(where: { $0.id == source.id })?.metadata.lcc == source.metadata.lcc else {
                            throw ExternalAIError.staleContent
                        }
                        let renamed = try await repository.publishSourceProcessing(snapshot, title: title, summary: summary,
                            lcc: lcc, provenance: SummaryProvenance(provider: "On-device", model: "Apple Intelligence", generatedAt: Date()),
                            validate: validateAI)
                        activity.complete()
                        guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.rename") else { return }
                        if let position = sources.firstIndex(where: { $0.id == source.id }) { sources[position] = renamed }
                        if let index { try await index.reconcile(repository.scan()) }
                        guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.reconcile") else { return }
                        await updateRows()
                    } catch { activity.fail(error); if isCompletionValid(completionTicket, operation: "enqueueSourceTitle.error") { errorMessage = "Source naming: " + error.localizedDescription } }
                }
                if generation == ticket {
                    generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1
                }
            }
        }
    }
    func renameSource(_ source: SourceRecord, title: String) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
        sourceNamingOverrides.insert(source.id); generatingSourceTitles.remove(source.id)
        let completionTicket = issueCompletionTicket(kind: .sourceLoading, targetID: source.id)
        Task {
            guard isCompletionValid(completionTicket, operation: "renameSource.start"), let repository else { return }
            do {
                let renamed = try await repository.renameSource(source, title: title)
                guard isCompletionValid(completionTicket, operation: "renameSource") else { return }
                SourceReader.updateTitle(id: source.id, title: renamed.title)
                await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "renameSource.error") { errorMessage = error.localizedDescription } }
        }
    }
    func deleteSource(_ source: SourceRecord) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        sourceNamingOverrides.insert(source.id); generatingSourceTitles.remove(source.id)
        downloadingSources.remove(source.id)
        sourceDownloadQueue.removeAll { $0.source.id == source.id }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading, targetID: source.id)
        Task {
            guard isCompletionValid(completionTicket, operation: "deleteSource.start"), let repository else { return }
            do {
                try await repository.deleteSource(source)
                guard isCompletionValid(completionTicket, operation: "deleteSource") else { return }
                SourceReader.close(id: source.id)
                await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "deleteSource.error") { errorMessage = error.localizedDescription } }
        }
    }
    func openSource(_ id: UUID?) {
        guard canInteractWithWorkspace, canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading, targetID: id)
        Task {
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "openSource.wait") else { return }
            guard await finishCurrentPage(),
                  isCompletionValid(completionTicket, operation: "openSource.finish") else { return }
            guard let id, !downloadingSources.contains(id), let source = sources.first(where: { $0.id == id }), let repository, let root else { return }
            do {
                try await SourceReader.open(
                    source,
                    root: root,
                    contentStore: repository.contentStore,
                    isStillValid: { [weak self] in
                        self?.isCompletionValid(completionTicket, operation: "openSource.reader") == true
                    }
                )
                if isCompletionValid(completionTicket, operation: "openSource.presented"), SourceReader.openReaderIDs.contains(source.id) {
                    recordSidebarAccess(.source(source.id))
                }
            } catch { if isCompletionValid(completionTicket, operation: "openSource.error") { errorMessage = error.localizedDescription } }
        }
    }
    func pasteSource(title: String, text: String, originURL: String) async -> Bool {
        guard canOperateOnLoadedContent, let repository else { return false }
        let completionTicket = issueCompletionTicket(kind: .sourceLoading)
        do {
            let source = try await repository.importSource(data: Data(text.utf8), filename: "pasted.txt", title: title, originURL: originURL)
            guard isCompletionValid(completionTicket, operation: "pasteSource") else { return false }
            scope = .sources; await refresh(); select(source.id); return true
        } catch { if isCompletionValid(completionTicket, operation: "pasteSource.error") { errorMessage = error.localizedDescription }; return false }
    }
    func revealVault() { guard isVaultAvailable, let root else { return }; NSWorkspace.shared.open(root) }
}


extension AppModel {
    /// Preparation and inference create only transient drafts. Publication is an explicit review action.
    func cancelAIPage() {
        if let activityID = aiPageActivityID, aiPagePublicationActivityID != activityID {
            let recorder = activityRecorder
            if aiPageDraft != nil {
                Task { await recorder.updateOutcome(activityID, outcome: .rejected) }
            } else if aiPageSubmission != nil {
                Task { await recorder.finish(activityID, status: .cancelled, failureCode: .cancelled) }
            }
        }
        aiPageActivityID = nil
        cloudPublicationGuard.invalidate()
        aiPageOperationID = nil
        aiPageTask?.cancel(); aiPageTask = nil
        aiPageDraft = nil; aiPageSubmission = nil
        generatingTopicPage = false
    }

    func prepareAIPage(_ input: AIPageInput) async -> Bool {
        guard canOperateOnLoadedContent, !generatingTopicPage, !hasPendingCloudSummary,
              let repository, let lease = sessionManager.accessGate.currentLease else { return false }
        if case .topic(let text) = input {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 120 else { return false }
        }
        if let previousActivityID = aiPageActivityID {
            let recorder = activityRecorder
            if aiPageDraft != nil {
                Task { await recorder.updateOutcome(previousActivityID, outcome: .rejected) }
            } else if aiPageSubmission != nil {
                Task { await recorder.finish(previousActivityID, status: .cancelled, failureCode: .cancelled) }
            }
        }
        aiPageActivityID = nil
        aiPageDraft = nil; aiPageSubmission = nil
        let identity = UUID()
        aiPageOperationID = identity
        generatingTopicPage = true; errorMessage = nil
        let provider = preferredAIProvider(for: .composePage, temporaryOverride: aiPageProviderOverride)
        let client = aiClient
        var startedActivityID: UUID?
        var suggestionCompleted = false
        defer { if aiPageOperationID == identity { generatingTopicPage = false } }
        do {
            guard await finishCurrentPage(), lease == sessionManager.accessGate.currentLease else { throw ExternalAIError.staleSession }
            let revision = cloudEditorRevision, selection = selectedID
            var source: SourceSummarySnapshot?
            var references = "", fetched: WebSourceFetch?, address: String?
            var retainSource = false
            let text: String
            switch input {
            case .source(let id):
                let snapshot = try await repository.sourceSummarySnapshot(id: id)
                text = String(try CloudSummaryConfirmation.extractedText(snapshot).prefix(6000))
                source = snapshot
            case .topic(let topic):
                let results = try await client.researchTopic(topic)
                guard !results.isEmpty else { throw VaultError.unavailable("No readable web results were found.") }
                let context = results.enumerated().map { "[\($0.offset + 1)] " + $0.element.title + "\n" + $0.element.text }.joined(separator: "\n\n")
                text = OnDeviceSummary.topicPrompt(topic: topic, context: context)
                references = "\n\n## Web references\n\n" + results.enumerated().map { offset, result in
                    let label = result.title.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                    return "- [\(offset + 1)] [\(label)](<\(result.url.absoluteString)>)"
                }.joined(separator: "\n")
            case .url(let value, let retain):
                let url = try WebSourceFetcher.validatedURL(value)
                let capture = try await aiPageFetch(url)
                fetched = capture; address = url.absoluteString; retainSource = retain
                if capture.filename.hasSuffix("pdf") {
                    guard let pdf = PDFDocument(data: capture.data) else { throw ExternalAIError.emptyContent }
                    text = String((pdf.string ?? "").prefix(6000))
                } else {
                    guard let decoded = String(data: capture.data, encoding: .utf8) else { throw ExternalAIError.emptyContent }
                    text = String((capture.filename.hasSuffix("html") ? WebTopicResearch.plainText(decoded) : decoded).prefix(6000))
                }
                references = "\n\n## Web references\n\n- [Captured document](<" + url.absoluteString + ">)"
            }
            try Task.checkCancellation()
            guard aiPageOperationID == identity, lease == sessionManager.accessGate.currentLease,
                  selection == selectedID, revision == cloudEditorRevision else { throw ExternalAIError.staleContent }
            let context = AIPageCompositionContext(id: UUID(), authority: ExternalAIVaultAuthority(lease: lease),
                selection: selection, editorRevision: revision, inputText: text, source: source,
                references: references, fetched: fetched, address: address, retainSource: retainSource)
            if provider == .openAI {
                if cloudSummaryOverride == nil { await externalAIService.refreshStatus() }
                try Task.checkCancellation()
                guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
                try validateAIPageContext(context)
                let resolution = resolveAIAction(.composePage, provider: .openAI)
                guard resolution.isEligible, resolution.provider == .openAI else { return false }
                let request = try ExternalAISummaryRequest(authority: context.authority, target: .page(context.id),
                    contentRevision: UUID(), content: text, action: .composePage, mode: .compose)
                let configuration = externalAIService.configuration
                startedActivityID = request.id; aiPageActivityID = request.id
                await activityRecorder.begin(id: request.id, vaultID: lease.vaultID,
                    target: .init(type: .page, id: context.id), action: .composePage,
                    executionMode: .userInvoked, provider: .openAI, modelID: configuration.model,
                    contentSizeBytes: text.utf8.count)
                guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
                try validateAIPageContext(context)
                guard configuration == externalAIService.configuration else { throw ExternalAIError.staleContent }
                aiPageSubmission = AIPageSubmission(request: request, context: context, model: configuration.model)
                if try !externalAIService.requiresSubmissionConfirmation(for: context.authority) {
                    await generateCloudAIPage(userConfirmed: false)
                }
            } else {
                guard admitsNativeAction(.composePage, provider: .onDevice) else { return false }
                guard let enrich = client.enrich else { throw ExternalAIError.unsupportedAction }
                startedActivityID = identity; aiPageActivityID = identity
                await activityRecorder.begin(id: identity, vaultID: lease.vaultID,
                    target: .init(type: .page, id: context.id), action: .composePage,
                    executionMode: .userInvoked, provider: .onDevice, modelID: "apple-foundation-models",
                    contentSizeBytes: text.utf8.count)
                guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
                try validateAIPageContext(context)
                let enrichment = try await enrich(text, .compose)
                guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
                try validateAIPageContext(context)
                await activityRecorder.finish(identity, status: .completed, outcome: .suggested)
                suggestionCompleted = true
                guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
                try validateAIPageContext(context)
                let provenance = SummaryProvenance(provider: "On-device", model: "Apple Intelligence", generatedAt: Date())
                aiPageDraft = AIPageDraft(context: context, enrichment: enrichment, provenance: provenance, validate: { try Task.checkCancellation() })
            }
            return aiPageDraft != nil || aiPageSubmission != nil
        } catch {
            if let activityID = startedActivityID {
                if suggestionCompleted { await activityRecorder.updateOutcome(activityID, outcome: .rejected) }
                let failure = AIActivityOperation.failure(error)
                await activityRecorder.finish(activityID, status: failure.status, failureCode: failure.code)
                if aiPageActivityID == activityID { aiPageActivityID = nil }
            }
            if aiPageOperationID == identity { errorMessage = Self.cloudError(error) }
            return false
        }
    }

    func generateCloudAIPage(userConfirmed: Bool = true) async {
        guard let submission = aiPageSubmission, let identity = aiPageOperationID else { return }
        aiPageSubmission = nil
        generatingTopicPage = true
        var suggestionCompleted = false
        defer { if aiPageOperationID == identity { generatingTopicPage = false } }
        do {
            try validateAIPageContext(submission.context)
            guard submission.model == externalAIService.configuration.model else { throw ExternalAIError.staleContent }
            let consent = try externalAIService.approveSubmission(submission.request, userConfirmed: userConfirmed)
            let gateway = externalAIService.gateway
            let result: ExternalAISummaryResult
            if let override = cloudSummaryOverride { result = try await override(submission.request, consent) }
            else { result = try await gateway.composePage(submission.request, consent: consent) }
            guard result.requestID == submission.request.id, result.action == .composePage,
                  result.authority == submission.context.authority, result.target == .page(submission.context.id),
                  result.contentRevision == submission.request.contentRevision, result.mode == .compose,
                  let enrichment = result.enrichment else { throw ExternalAIError.invalidResponse }
            let validate: @Sendable () throws -> Void
            if let override = cloudPublicationOverride { validate = try await override(result) }
            else {
                let permit = try await gateway.publicationPermit(for: result)
                validate = { try permit.validateSynchronously() }
            }
            guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
            try validateAIPageContext(submission.context)
            let provenance = SummaryProvenance(provider: "OpenAI", model: result.provenance.model,
                generatedAt: result.provenance.generatedAt)
            await activityRecorder.finish(submission.request.id, status: .completed, outcome: .suggested)
            suggestionCompleted = true
            guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
            try validateAIPageContext(submission.context)
            aiPageDraft = AIPageDraft(context: submission.context, enrichment: enrichment, provenance: provenance, validate: validate)
        } catch {
            if suggestionCompleted { await activityRecorder.updateOutcome(submission.request.id, outcome: .rejected) }
            let failure = AIActivityOperation.failure(error)
            await activityRecorder.finish(submission.request.id, status: failure.status, failureCode: failure.code)
            if aiPageActivityID == submission.request.id { aiPageActivityID = nil }
            if aiPageOperationID == identity { errorMessage = Self.cloudError(error) }
        }
    }

    private func validateAIPageContext(_ context: AIPageCompositionContext) throws {
        try Task.checkCancellation()
        guard canOperateOnLoadedContent, context.authority.matches(sessionManager.accessGate.currentLease),
              context.selection == selectedID, context.editorRevision == cloudEditorRevision else { throw ExternalAIError.staleContent }
    }

    func publishAIPageDraft(title reviewedTitle: String) async -> Bool {
        guard let draft = aiPageDraft, let identity = aiPageOperationID, let repository else { return false }
        let activityID = aiPageActivityID
        aiPagePublicationActivityID = activityID
        generatingTopicPage = true
        defer {
            if aiPagePublicationActivityID == activityID { aiPagePublicationActivityID = nil }
            if aiPageOperationID == identity { generatingTopicPage = false }
        }
        do {
            try validateAIPageContext(draft.context)
            try draft.validate()
            guard let generatedBody = draft.enrichment.body, draft.enrichment.title != nil else { throw ExternalAIError.invalidResponse }
            var source = draft.context.source
            if draft.context.retainSource, let capture = draft.context.fetched, let address = draft.context.address {
                let retained = try await repository.importURLSource(address, fetch: { _ in capture })
                source = try await repository.sourceSummarySnapshot(id: retained.id)
            }
            try validateAIPageContext(draft.context)
            guard aiPageOperationID == identity else { throw ExternalAIError.cancelled }
            cloudPublicationGuard.arm(requestID: identity)
            let publicationGuard = cloudPublicationGuard
            let saved = try await repository.createEnrichedPage(id: draft.id, title: reviewedTitle,
                body: generatedBody + draft.context.references, summary: draft.enrichment.summary,
                classification: Self.classification(draft.enrichment.classification, provenance: draft.provenance),
                provenance: draft.provenance, source: source, validate: {
                    try publicationGuard.validate(requestID: identity)
                    try draft.validate()
                })
            if let activityID { await activityRecorder.updateOutcome(activityID, outcome: .published) }
            guard aiPageOperationID == identity, draft.context.authority.matches(sessionManager.accessGate.currentLease) else { return false }
            aiPageDraft = nil; aiPageSubmission = nil; aiPageOperationID = nil; aiPageActivityID = nil
            errorMessage = nil; searchText = ""; scope = .wiki
            notes.insert(saved, at: 0); selectedID = saved.id; currentSource = nil; apply(saved)
            selectedSidebarRecentItemID = nil
            recordSidebarAccess(.page(saved.id))
            await refresh()
            return true
        } catch {
            if aiPageOperationID != identity, let activityID {
                await activityRecorder.updateOutcome(activityID, outcome: .rejected)
            }
            if aiPageOperationID == identity { errorMessage = Self.cloudError(error) }
            return false
        }
    }
}


extension AppModel {
    func configureSemanticEditor(_ coordinator: RichArticleView.Coordinator?) {
        guard coordinator == nil || coordinator?.session.identity == editorIdentity else { return }
        semanticCoordinator = coordinator; semanticReadyIdentity = nil; semanticSavedRevision = 0
        if let coordinator { registerEditorSession(coordinator.session) }
        guard let coordinator, let repository, let pageID = currentNote?.id else { return }
        let identity = coordinator.session.identity, localRevision = coordinator.session.revision
        let loadGeneration = coordinator.session.generation
        if let pending = pendingPageSaves[pageID]?.editor {
            coordinator.session.restorePendingSnapshot(pending, identity: identity)
            registerEditorSession(coordinator.session)
            semanticReadyIdentity = coordinator.session.semanticEdit == nil ? nil : identity
            coordinator.view?.locked = editingLocked
            coordinator.view?.isEditable = canEditPage
            coordinator.refreshSemanticRanges(); coordinator.updateAnnotationAvailability()
            return
        }
        Task { @MainActor [weak self, weak coordinator] in
            do {
                let snapshot = try await repository.sqliteBlockStore.loadSemanticPage(pageID: pageID)
                guard let self, let coordinator else { return }
                var loaded = snapshot.snapshot.document, visible = coordinator.document
                loaded.originalSource = nil; visible.originalSource = nil
                guard self.canOperateOnLoadedContent, self.semanticCoordinator === coordinator, self.editorIdentity == identity,
                    coordinator.session.identity == identity, coordinator.session.generation == loadGeneration,
                    coordinator.session.revision == localRevision,
                    BlockDocumentCodec.encode(visible) == BlockDocumentCodec.encode(loaded) else { return }
                guard self.currentNote?.contentHash == snapshot.snapshot.revision.token.base64EncodedString() else {
                    self.externalChange = true
                    self.errorMessage = "This page changed before editing was ready. Reload its disk version to continue."
                    return
                }
                coordinator.session.load(snapshot, identity: identity, selection: coordinator.session.selection)
                self.registerEditorSession(coordinator.session)
                self.semanticSavedRevision = 0
                self.semanticReadyIdentity = identity
                coordinator.view?.locked = self.editingLocked
                coordinator.view?.isEditable = self.canEditPage
                coordinator.refreshSemanticRanges()
                coordinator.updateAnnotationAvailability()
                self.revealPendingSemanticOccurrence(in: coordinator)
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func annotationChoices() async throws -> [EditorAnnotationChoice] {
        guard canOperateOnLoadedContent, let repository, let pageID = currentNote?.id else { throw VaultError.unavailable("The vault is unavailable.") }
        let store = repository.sqliteBlockStore
        let entities = try await store.searchEntities(query: "", limit: 1000)
        let objects = try await store.objects(pageID: pageID)
        return entities.filter { $0.entity.lifecycle == .live }.map(EditorAnnotationChoice.entity)
            + objects.filter { $0.object.lifecycle == .live }.map(EditorAnnotationChoice.object)
    }
    func annotateSelection(_ coordinator: RichArticleView.Coordinator, _ blockID: UUID, _ range: NSRange,
        _ choice: EditorAnnotationChoice, _ localRevision: UInt64) async throws {
        guard canEditPage, !saving,
              coordinator === semanticCoordinator, coordinator.session.revision == localRevision,
              let repository else { throw VaultError.invalid("The selection changed or the editor is unavailable.") }
        let store = repository.sqliteBlockStore
        let referent: SemanticReferent
        let referentRevision: BlockStoreRevision?
        var object: SemanticObject?
        switch choice {
        case .entity(let snapshot):
            referent = .init(identity: .init(kind: snapshot.entity.typeKey, id: snapshot.entity.id)); referentRevision = snapshot.revision
        case .object(let snapshot):
            referent = .init(identity: .init(kind: snapshot.object.typeKey, id: snapshot.object.id)); referentRevision = snapshot.revision
        case .newEntity(let typeKey, let label):
            let vault = try await store.canonicalVaultRevision()
            let created = try await store.createEntity(.init(typeKey: typeKey, label: label), expectedVaultRevision: vault, operationID: UUID())
            referent = .init(identity: .init(kind: typeKey, id: created.value.entity.id)); referentRevision = created.value.revision
        case .newObject(let typeKey, let text):
            let value = SemanticObject(typeKey: typeKey, properties: typeKey == "question" ? .init(properties: ["questionText": .string(text)]) : .init(), definitionText: typeKey == "definition" ? text : nil, term: typeKey == "definition" ? text : nil)
            object = value; referent = .init(identity: .init(kind: typeKey, id: value.id)); referentRevision = nil
        }
        guard coordinator.session.revision == localRevision, coordinator === semanticCoordinator,
              canEditPage, !saving else { throw VaultError.invalid("The selection changed. Select it again.") }
        try coordinator.commitAnnotation(blockID: blockID, range: range, referent: referent, referentRevision: referentRevision, object: object)
        edited()
    }
}


extension AppModel {
    var canEditSemanticTarget: Bool { canOperateOnLoadedContent && !editingLocked && !saving }
    var canEditSemanticAssociation: Bool {
        canEditSemanticTarget && canEditPage && semanticCoordinator?.view?.hasMarkedText() != true
    }
    func semanticSelectionChanged(_ ids: [UUID]) {
        guard semanticInspectionSelectionIDs != ids else { return }
        semanticInspectionSelectionIDs = ids
    }
    func inspectSemanticAssociation(_ id: UUID) {
        guard canOperateOnLoadedContent, let pageID = currentNote?.id else { return }
        semanticInspectionFocusID = id; semanticInspectionSelectionIDs = [id]
        semanticInspectionOpenRequest = UUID()
        Task { await refreshSemanticInspection(pageID: pageID) }
    }
    func refreshSemanticInspection(pageID: UUID) async {
        guard canOperateOnLoadedContent, currentNote?.id == pageID, let repository else { return }
        let ticket = UUID(), sessionID = sessionState.sessionID
        semanticInspectionTicket = ticket; semanticInspectionLoading = true
        do {
            let store = repository.sqliteBlockStore
            let annotations: [SemanticAnnotation]
            if let editor = semanticCoordinator, editor.session.identity.pageID == pageID, let edit = editor.session.semanticEdit {
                annotations = edit.annotations
            } else { annotations = try await store.loadSemanticPage(pageID: pageID).annotations.map(\.annotation) }
            var records: [SemanticInspectionRecord] = []
            for annotation in annotations where annotation.anchorDisposition != .deleted {
                let identity = annotation.referent.identity
                var target: SemanticInspectionTarget = .unavailable(identity), subject: KnowledgeEntitySnapshot?, occurrences: [SemanticAnnotationSnapshot] = []
                if annotation.referent.disposition != .unresolved {
                    if ["question", "definition"].contains(identity.kind) {
                        if let object = try? await store.loadObject(id: identity.id) {
                            target = .object(object)
                            if let id = object.object.subjectEntityID { subject = try? await store.loadEntity(id: id) }
                        }
                    } else if let entity = try? await store.loadEntity(id: identity.id) {
                        target = .entity(entity); occurrences = try await store.occurrences(entityID: identity.id)
                    }
                }
                let previews = try await semanticOccurrencePreviews(occurrences.map(\.annotation), store: store)
                records.append(.init(annotation: annotation, target: target, subject: subject, occurrences: occurrences, occurrencePreviews: previews))
            }
            guard semanticInspectionTicket == ticket, sessionState.sessionID == sessionID,
                currentNote?.id == pageID, canOperateOnLoadedContent else { return }
            semanticInspectionPageID = pageID; semanticInspectionRecords = records; semanticInspectionLoading = false
        } catch {
            guard semanticInspectionTicket == ticket, currentNote?.id == pageID else { return }
            semanticInspectionLoading = false; semanticInspectionError = error.localizedDescription
        }
    }
    func semanticOccurrencePreviews(_ annotations: [SemanticAnnotation], store: SQLiteBlockStore) async throws -> [SemanticOccurrencePreview] {
        let trashed = Set(try await store.allTrashedPages().map(\.id))
        var pages: [UUID: (record: NoteRecord, snapshot: BlockStoreSnapshot)] = [:]
        var unavailable = Set<UUID>()
        var previews: [SemanticOccurrencePreview] = []
        for annotation in annotations {
            if let id = annotation.location.pageID, pages[id] == nil, !unavailable.contains(id) {
                do { pages[id] = try await store.loadPage(pageID: id) }
                catch { unavailable.insert(id) }
            }
            let page = annotation.location.pageID.flatMap { pages[$0] }
            previews.append(.make(annotation: annotation, record: page?.record, snapshot: page?.snapshot,
                trashed: annotation.location.pageID.map { trashed.contains($0) } ?? false))
        }
        return previews
    }
    func navigateSemanticAssociation(_ annotation: SemanticAnnotation) {
        Task { _ = await navigateSemanticOccurrence(annotation) }
    }
    @discardableResult func navigateSemanticOccurrence(_ requested: SemanticAnnotation) async -> Bool {
        guard canOperateOnLoadedContent, let repository, let pageID = requested.location.pageID else {
            semanticInspectionError = "This occurrence has no available page location."; return false
        }
        let ticket = UUID(), sessionID = sessionState.sessionID
        semanticOccurrenceNavigationTicket = ticket; semanticInspectionError = nil
        guard await saveCurrent(), canOperateOnLoadedContent, sessionState.sessionID == sessionID else { return false }
        do {
            let store = repository.sqliteBlockStore
            let semantic = try await store.loadSemanticPage(pageID: pageID)
            guard semanticOccurrenceNavigationTicket == ticket, sessionState.sessionID == sessionID, canOperateOnLoadedContent else { return false }
            guard let current = semantic.annotations.first(where: { $0.annotation.id == requested.id })?.annotation,
                current.referent.identity == requested.referent.identity else {
                semanticInspectionError = "This association is no longer at the captured location."; return false
            }
            let page = try await store.loadPage(pageID: pageID)
            let trashed = try await store.allTrashedPages().contains { $0.id == pageID }
            guard semantic.snapshot.revision == page.snapshot.revision else {
                semanticInspectionError = "This page changed. Refresh its occurrences."; return false
            }
            let preview = SemanticOccurrencePreview.make(annotation: current, record: page.record, snapshot: page.snapshot, trashed: trashed)
            guard preview.canNavigate, let blockID = current.location.blockID else {
                semanticInspectionError = preview.state.rawValue + ". The preservation record is retained."; return false
            }
            guard semanticOccurrenceNavigationTicket == ticket, sessionState.sessionID == sessionID, canOperateOnLoadedContent else { return false }
            pendingSemanticOccurrence = .init(pageID: pageID, blockID: blockID, annotationID: current.id)
            if pageID == currentNote?.id, let coordinator = semanticCoordinator,
                coordinator.session.pageRevision == page.snapshot.revision {
                return revealPendingSemanticOccurrence(in: coordinator)
            }
            autosaveTask?.cancel(); scope = .wiki; searchText = ""
            if let index = notes.firstIndex(where: { $0.id == pageID }) { notes[index] = page.record } else { notes.append(page.record) }
            selectedID = pageID; currentSource = nil; apply(page.record)
            selectedSemanticID = "\(pageID):\(blockID)"
            editorAction = EditorAction(operation: .block(blockID))
            selectedSidebarRecentItemID = nil
            recordSidebarAccess(.semanticBlock(pageID: pageID, blockID: blockID))
            return true
        } catch {
            if semanticOccurrenceNavigationTicket == ticket, sessionState.sessionID == sessionID {
                semanticInspectionError = "Occurrence unavailable: " + error.localizedDescription
            }
            return false
        }
    }
    @discardableResult func revealPendingSemanticOccurrence(in coordinator: RichArticleView.Coordinator) -> Bool {
        guard let pending = pendingSemanticOccurrence, coordinator.session.identity.pageID == pending.pageID,
            currentNote?.id == pending.pageID, let view = coordinator.view else { return false }
        guard let entry = view.semanticRangeIndex.entriesByBlock[pending.blockID]?.first(where: { $0.annotation.id == pending.annotationID }) else {
            pendingSemanticOccurrence = nil
            semanticInspectionError = "This annotation cannot be displayed at its captured location."; return false
        }
        pendingSemanticOccurrence = nil
        view.setSelectedRange(entry.range); view.scrollRangeToVisible(entry.range)
        inspectSemanticAssociation(pending.annotationID)
        return true
    }
    func saveInspectedTarget(_ target: SemanticInspectionTarget, name: String, detail: String, answered: Bool, answer: String) async -> Bool {
        guard canEditSemanticTarget, let repository else { return false }
        let pageID = currentNote?.id
        semanticInspectionError = nil
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            semanticInspectionError = "Enter a name or question text."; return false
        }
        guard await saveCurrent(), currentNote?.id == pageID, canEditSemanticTarget else { return false }
        let sessionID = sessionState.sessionID, saveGeneration = generation
        saving = true
        defer { if generation == saveGeneration { saving = false; if dirty { edited() } } }
        do {
            let store = repository.sqliteBlockStore, vault = try await repository.sqliteBlockStore.canonicalVaultRevision()
            let identity: EntityIdentity, revision: BlockStoreRevision
            switch target {
            case .entity(let value):
                let result = try await store.updateEntity(id: value.entity.id,
                    patch: .init(label: name, description: detail.isEmpty ? nil : detail, clearDescription: detail.isEmpty),
                    expected: value.revision, expectedVaultRevision: vault, operationID: UUID())
                identity = .init(kind: result.value.entity.typeKey, id: result.value.entity.id); revision = result.value.revision
            case .object(let value):
                let patch = value.object.typeKey == "question" ? SemanticObjectPatch(questionStatus: answered ? .answered : .unanswered,
                    answerText: answer, properties: ["questionText": .string(name)]) : SemanticObjectPatch(definitionText: detail, term: name)
                let result = try await store.updateObject(id: value.object.id, patch: patch,
                    expected: value.revision, expectedVaultRevision: vault, operationID: UUID())
                identity = .init(kind: result.value.object.typeKey, id: result.value.object.id); revision = result.value.revision
            case .unavailable: return false
            }
            guard sessionState.sessionID == sessionID, canOperateOnLoadedContent else { return false }
            semanticCoordinator?.session.acceptReferentRevision(identity, revision: revision)
            if let current = currentNote?.id { await refreshSemanticInspection(pageID: current) }
            await refreshKnowledgeCatalogue()
            return true
        } catch { if sessionState.sessionID == sessionID { semanticInspectionError = error.localizedDescription }; return false }
    }
    func removeInspectedAssociation(_ id: UUID) async -> Bool {
        await mutateInspectedAssociation(.remove(annotationID: id), referentRevision: nil)
    }
    func replaceInspectedAssociation(_ id: UUID, choice: EditorAnnotationChoice) async -> Bool {
        switch choice {
        case .entity(let value):
            return await mutateInspectedAssociation(.replace(annotationID: id, referent: .init(identity: .init(kind: value.entity.typeKey, id: value.entity.id)), designation: value.entity.typeKey), referentRevision: value.revision)
        case .object(let value):
            return await mutateInspectedAssociation(.replace(annotationID: id, referent: .init(identity: .init(kind: value.object.typeKey, id: value.object.id)), designation: value.object.typeKey), referentRevision: value.revision)
        default: semanticInspectionError = "Choose an existing canonical target."; return false
        }
    }
    private func mutateInspectedAssociation(_ command: EditorAnnotationCommand, referentRevision: BlockStoreRevision?) async -> Bool {
        guard canEditSemanticAssociation, let coordinator = semanticCoordinator, let pageID = currentNote?.id else { return false }
        semanticInspectionError = nil
        do {
            try coordinator.commitAssociationCommand(command, referentRevision: referentRevision)
            edited()
            guard await saveCurrent() else { semanticInspectionError = errorMessage ?? "The association draft is preserved."; return false }
            semanticInspectionSelectionIDs = []
            await refreshSemanticInspection(pageID: pageID)
            return true
        } catch { semanticInspectionError = error.localizedDescription; return false }
    }
}


extension AppModel {
    func refreshKnowledgeCatalogue() async {
        guard canOperateOnLoadedContent, let repository else { return }
        let ticket = UUID(), sessionID = sessionState.sessionID
        knowledgeCatalogueTicket = ticket; knowledgeCatalogueLoading = true; knowledgeCatalogueError = nil
        do {
            let catalogue = try await repository.sqliteBlockStore.knowledgeCatalogue()
            guard knowledgeCatalogueTicket == ticket, sessionState.sessionID == sessionID, canOperateOnLoadedContent else { return }
            knowledgeCatalogue = catalogue; knowledgeCatalogueLoading = false
        } catch {
            guard knowledgeCatalogueTicket == ticket, sessionState.sessionID == sessionID else { return }
            knowledgeCatalogueLoading = false; knowledgeCatalogueError = error.localizedDescription
        }
    }
    func catalogueOccurrencePreviews(target: SemanticInspectionTarget) async throws -> [SemanticOccurrencePreview] {
        guard canOperateOnLoadedContent, let repository else { throw VaultError.unavailable("The vault is unavailable.") }
        let store = repository.sqliteBlockStore
        let annotations: [SemanticAnnotation]
        switch target {
        case .entity(let value): annotations = try await store.occurrences(entityID: value.entity.id).map(\.annotation)
        case .object(let value): annotations = (try await store.knowledgeCatalogue()).annotations.map(\.annotation).filter { $0.referent.identity.id == value.object.id && $0.referent.identity.kind == value.object.typeKey }
        case .unavailable: annotations = []
        }
        return try await semanticOccurrencePreviews(annotations, store: store)
    }
}

extension AppModel {
    func catalogueAnnotationPreview(_ annotation: SemanticAnnotation) async throws -> [SemanticOccurrencePreview] {
        guard canOperateOnLoadedContent, let repository else { throw VaultError.unavailable("The vault is unavailable.") }
        return try await semanticOccurrencePreviews([annotation], store: repository.sqliteBlockStore)
    }
}

extension AppModel {
    func loadEntityProperties(entityID: UUID) async throws -> EntityPropertiesSnapshot {
        guard canOperateOnLoadedContent, !isLocked, let repository else { throw VaultError.unavailable("The vault is unavailable.") }
        let sessionID = sessionState.sessionID, store = repository.sqliteBlockStore
        let vault = try await store.canonicalVaultRevision()
        let entity = try await store.loadEntity(id: entityID)
        let definitions = try await store.listPropertyDefinitions(includeRetired: true)
        let values = try await store.loadPropertyValues(entityID: entityID)
        let relationships: [EntityPropertyRelationshipSnapshot]
        var supportsRelationships = true
        do { relationships = try await store.queryPropertyRelationships(entityID: entityID) }
        catch KnowledgeStoreError.transitionRequired {
            // Schema 7 owns scalar properties already; relationship support is an
            // explicit later upgrade and must not hide those existing values.
            relationships = []; supportsRelationships = false
        }
        var entities = try await store.knowledgeCatalogue().entities
        let endpointIDs = Set(relationships.flatMap { [$0.relationship.sourceID, $0.relationship.targetID] }).union([entityID])
        for id in endpointIDs where !entities.contains(where: { $0.entity.id == id }) {
            entities.append(try await store.loadEntity(id: id))
        }
        let template: EntityPropertyTemplateSnapshot?
        do { template = try await store.loadPropertyTemplate(typeKey: entity.entity.typeKey) }
        catch KnowledgeStoreError.transitionRequired { template = nil }
        guard canOperateOnLoadedContent, !isLocked, sessionState.sessionID == sessionID,
              try await store.canonicalVaultRevision() == vault else { throw KnowledgeStoreError.staleRevision }
        return .init(entity: entity, definitions: definitions, values: values, relationships: relationships,
                     entities: entities, vaultRevision: vault, sessionID: sessionID,
                     supportsRelationships: supportsRelationships, template: template)
    }

    /// The UI supplies its selection lifetime check; the store still checks all canonical revisions.
    func editEntityProperties(_ edit: EntityPropertyEdit, snapshot: EntityPropertiesSnapshot,
                              isCurrent: @MainActor () -> Bool) async throws {
        guard canEditSemanticTarget, !isLocked, let repository, snapshot.entity.entity.lifecycle == .live,
              sessionState.sessionID == snapshot.sessionID, isCurrent(), !Task.isCancelled else {
            throw VaultError.unavailable("This entity selection is no longer editable.")
        }
        let store = repository.sqliteBlockStore
        switch edit {
        case .saveValues(let assignments):
            _ = try await store.savePropertyValues(entityID: snapshot.entity.entity.id, assignments: assignments,
                expectedEntity: snapshot.values.entityRevision, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
        case .createDefinition(let label, let kind, let cardinality, let presentation):
            let key = EntityPropertyDefinition.normalize(label)
            guard !snapshot.definitions.contains(where: { $0.definition.normalizedKey == key }) else {
                throw VaultError.invalid("A property with this name already exists. Reuse the existing definition.")
            }
            let definition = try EntityPropertyDefinition(vaultID: repository.manifest.id, label: label,
                kind: kind, cardinality: cardinality, displayOrder: snapshot.definitions.count, presentation: presentation)
            _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
        case .saveDefinition(var definition):
            guard let previous = snapshot.definitions.first(where: { $0.definition.id == definition.id }) else { throw KnowledgeStoreError.notFound(definition.id) }
            definition.updatedAt = Date()
            _ = try await store.savePropertyDefinition(definition, expected: previous.revision, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
        case .addRelationship(let definitionID, let otherID, let incoming):
            guard let other = snapshot.entities.first(where: { $0.entity.id == otherID }) else { throw KnowledgeStoreError.notFound(otherID) }
            _ = try await store.createPropertyRelationship(definitionID: definitionID, entityID: snapshot.entity.entity.id,
                otherEntityID: otherID, direction: incoming ? .incoming : .outgoing, expectedEntity: snapshot.entity.revision,
                expectedOther: other.revision, expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
        case .removeRelationship(let edge):
            guard let source = snapshot.entities.first(where: { $0.entity.id == edge.relationship.sourceID }),
                  let target = snapshot.entities.first(where: { $0.entity.id == edge.relationship.targetID }) else {
                throw VaultError.unavailable("A relationship endpoint is unavailable. Refresh before editing.")
            }
            _ = try await store.removePropertyRelationship(id: edge.relationship.id, expected: edge.revision,
                expectedSource: source.revision, expectedTarget: target.revision,
                expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
        }
    }
}


extension AppModel {
    func searchEntityPropertyTargets(query: String) async throws -> [KnowledgeEntitySnapshot] {
        guard canOperateOnLoadedContent, !isLocked, let repository else { throw VaultError.unavailable("The vault is unavailable.") }
        let sessionID = sessionState.sessionID
        let values = try await repository.sqliteBlockStore.searchEntities(query: query, limit: 100)
        if let entityPropertySearchDidLoad { await entityPropertySearchDidLoad() }
        guard canOperateOnLoadedContent, !isLocked, sessionState.sessionID == sessionID, !Task.isCancelled else {
            throw VaultError.unavailable("The entity search is no longer current.")
        }
        return values.filter { $0.entity.lifecycle == .live }
    }
}


extension AppModel {
    func loadPropertyTemplateConfiguration(typeKey: String) async throws -> EntityPropertyTemplateConfiguration {
        guard canOperateOnLoadedContent, !isLocked, let repository else { throw VaultError.unavailable("The vault is unavailable.") }
        let sessionID = sessionState.sessionID, store = repository.sqliteBlockStore
        let vault = try await store.canonicalVaultRevision()
        let template = try await store.loadPropertyTemplate(typeKey: typeKey)
        let definitions = try await store.listPropertyDefinitions(includeRetired: true)
        guard canOperateOnLoadedContent, !isLocked, sessionState.sessionID == sessionID, !Task.isCancelled,
              try await store.canonicalVaultRevision() == vault else { throw KnowledgeStoreError.staleRevision }
        return .init(template: template, definitions: definitions, vaultRevision: vault, sessionID: sessionID)
    }

    func savePropertyTemplateConfiguration(_ definitionIDs: [UUID], snapshot: EntityPropertyTemplateConfiguration,
                                           isCurrent: @MainActor () -> Bool) async throws {
        guard canEditSemanticTarget, !isLocked, let repository, sessionState.sessionID == snapshot.sessionID,
              isCurrent(), !Task.isCancelled else { throw VaultError.unavailable("This template selection is no longer editable.") }
        _ = try await repository.sqliteBlockStore.savePropertyTemplate(typeKey: snapshot.template.typeKey,
            definitionIDs: definitionIDs, expected: snapshot.template.revision,
            expectedVaultRevision: snapshot.vaultRevision, operationID: UUID())
    }
}
