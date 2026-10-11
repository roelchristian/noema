import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VaultCore
import PDFKit
import ExternalAI
import CryptoKit

enum LibraryScope: Hashable { case wiki, sources, semantic, trash, tag(String) }

struct SemanticBlockHit: Identifiable, Sendable {
    var pageID: UUID
    var blockID: UUID
    var pageTitle: String
    var semantic: String
    var preview: String
    var id: String { "\(pageID):\(blockID)" }
    static func search(_ notes: [NoteRecord], query: String) -> [Self] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return notes.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.flatMap { note in
            BlockDocumentCodec.decode(note.body).semanticGroups.flatMap(\.blocks).compactMap { block in
                let tag = block.metadata.semantic ?? ""
                let preview = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let searchable = "\(tag) \(preview) \(note.title)"
                guard terms.allSatisfy({ searchable.localizedCaseInsensitiveContains($0) }) else { return nil }
                return Self(pageID: note.id, blockID: block.id, pageTitle: note.title, semantic: tag, preview: preview)
            }
        }
    }
}
struct SidebarSearchResults: Sendable {
    var query = ""
    var pages: [NoteRecord] = []
    var sources: [SourceRecord] = []
    var blocks: [SemanticBlockHit] = []
    var isEmpty: Bool { pages.isEmpty && sources.isEmpty && blocks.isEmpty }

    static func search(_ query: String, notes: [NoteRecord], sources: [SourceRecord], index: any SearchIndex) async throws -> Self {
        let pageHits = try await index.search(query, kind: .wiki, tag: nil)
        let sourceHits = try await index.search(query, kind: .source, tag: nil)
        let blocks = await Task.detached { SemanticBlockHit.search(notes, query: query) }.value
        let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Self(query: query, pages: pageHits.compactMap { noteMap[$0.id] },
                    sources: sourceHits.compactMap { sourceMap[$0.id] }, blocks: blocks)
    }
}
struct LibraryRow: Identifiable, Equatable {
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
    var showVaultCreation = false
    var root: URL?
    var vaultName = "Noema"
    var notes: [NoteRecord] = []
    var sources: [SourceRecord] = []
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
    var semanticRows: [SemanticBlockHit] = []
    var selectedSemanticID: String?
    var recentPageIDs: [UUID] = []
    private(set) var editingLockOperations: Set<UUID> = []
    var tags: [String] = []
    var wordCount = 0
    var scope: LibraryScope = .wiki {
        didSet { if scope != oldValue { cancelCloudSummary() } }
    }
    /// The Sources table and inspector share this synchronous selection route with cloud work.
    private(set) var librarySourceSelection: UUID?
    func setLibrarySourceSelection(_ id: UUID?) {
        guard id != librarySourceSelection else { return }
        cancelCloudSummary()
        librarySourceSelection = id
    }
    var searchText = ""
    var sidebarSearchResults = SidebarSearchResults()
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var unseenRenamedPages: Set<UUID> = []
    var appIsActive = true
    var selectedID: UUID? {
        didSet {
            if selectedID != oldValue {
                cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
                if let id = nativePageSummaryID { cancelSummary(target: .page(id)) }
            }
        }
    }
    var currentNote: NoteRecord?
    var currentSource: SourceRecord?
    var title = "" { didSet { if title != oldValue { cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate() } } }
    var body = "" { didSet { if body != oldValue { cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate() } } }
    var tagInput = "" { didSet { if tagInput != oldValue { cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate() } } }
    var preview: [PreviewBlock] = []
    var backlinks: [NoteRecord] = []
    var outgoingLinkTargets: [String] = []
    var reading = true
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
    var showURLSource = false
    var showPasteSource = false
    var showIssues = false
    var ambiguousMatches: [NoteRecord] = []
    var unresolvedTarget: String?
    var wikiQuery: String?
    var editorAction: EditorAction?
    var searchFocusToken = 0
    private let storageProvider: VaultStorageProvider
    let externalAIService: ExternalAIService
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
    private var activeSession: VaultSession?
    private var activeLease: VaultSessionLease?
    private(set) var lockedVaultURL: URL?
    private var repository: FileVaultRepository?
    var index: (any SearchIndex)?
    private var recovery: RecoveryStore?
    private var watcher: VaultWatcher?
    private var scopeURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
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
        aiDefaults: UserDefaults = .standard
    ) {
        self.storageProvider = storageProvider
        self.aiPreferenceDefaults = aiDefaults
        self.aiProviderPreferences = AIProviderPreferences(defaults: aiDefaults)
        self.sessionManager = sessionManager
        self.externalAIService = ExternalAIService(accessGate: sessionManager.accessGate)
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
        sessionState = nextState
        vaultAccessAuthenticationRequired = nextState.vaultID.map { sessionManager.accessAuthenticationRequired(for: $0) } ?? false
        switch nextState {
        case .closed:
            let hadActiveResources = root != nil || lockedVaultURL != nil || activeSession != nil || activeLease != nil || repository != nil || index != nil || recovery != nil || watcher != nil || !notes.isEmpty || !sources.isEmpty || currentNote != nil || currentSource != nil
            lockedVaultURL = nil
            lockedVaultBookmark = nil
            vaultName = "Noema"
            if hadActiveResources {
                releaseActiveVaultResources()
                clearSessionUIState()
            } else {
                busy = false
            }

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
            let needsTeardown = root != nil || repository != nil || index != nil || recovery != nil || watcher != nil || !notes.isEmpty || !sources.isEmpty || currentNote != nil || currentSource != nil
            lockedVaultURL = lockedRoot
            vaultName = name
            if needsTeardown {
                releaseActiveVaultResources()
                clearSessionUIState()
            } else {
                busy = false
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
        return title != note.title || body != note.body || editedTags != note.tags
    }
    var scopeTitle: String {
        switch scope { case .wiki: "Pages"; case .sources: "Sources"; case .semantic: "Semantic Blocks"; case .trash: "Trash"; case .tag(let tag): "#" + tag }
    }
    var activeTagFilter: String? {
        if case .tag(let tag) = scope { return tag }
        return nil
    }
    var recentPages: [NoteRecord] {
        let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let accessed = recentPageIDs.compactMap { noteMap[$0] }
        let accessedSet = Set(accessed.map(\.id))
        let remaining = notes.filter { !accessedSet.contains($0.id) }.sorted {
            sidebarUpdatedDate($0) > sidebarUpdatedDate($1)
        }
        return Array((accessed + remaining).prefix(5))
    }
    var allPagesByUpdated: [NoteRecord] {
        notes.sorted {
            let lhs = sidebarUpdatedDate($0)
            let rhs = sidebarUpdatedDate($1)
            if lhs != rhs { return lhs > rhs }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    private func sidebarUpdatedDate(_ note: NoteRecord) -> Date {
        LibraryRow.date(note.updatedAt) ?? .distantPast
    }
    var recentSources: [SourceRecord] {
        Array(sources.sorted { $0.metadata.capturedAt > $1.metadata.capturedAt }.prefix(10))
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

        static let live = AIProcessingClient(
            unavailabilityReason: { OnDeviceSummary.unavailabilityReason },
            summarize: { try await OnDeviceSummary().summarize($0) },
            inferLCC: { await OnDeviceSummary().inferLCC($0) },
            lccCode: { try await OnDeviceSummary().lccCode($0) },
            pageTitle: { try await OnDeviceSummary().pageTitle($0) },
            pageFromTopic: { try await OnDeviceSummary().pageFromTopic($0, context: $1) },
            pageFromSource: { try await OnDeviceSummary().pageFromSource($0) },
            researchTopic: { try await WebTopicResearch.research($0) }
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
        vaultCommandPanel?.cancel(nil)
        sourceCommandPanel?.cancel(nil)
        vaultCommandPanel = nil; sourceCommandPanel = nil
        isChoosingVault = false; isChoosingSource = false
        SourceReader.closeAll()
        watcher?.stop(); watcher = nil
        if let scopeURL { securityScopeReleaser(scopeURL); self.scopeURL = nil }
        cancelAllAsyncWork()
        generation = UUID()
        activeSession = nil
        activeLease = nil
        repository = nil
        index = nil
        recovery = nil
        root = nil
    }

    private func clearSessionUIState() {
        notes = []; sources = []; rows = []; semanticRows = []; trashedPages = []; recoveredDrafts = []; damagedRecoveryEntries = []; issues = []
        dismissedVaultNotices = []
        tags = []; backlinks = []; outgoingLinkTargets = []; preview = []; recentPageIDs = []; unseenRenamedPages = []
        searchText = ""; sidebarSearchResults = SidebarSearchResults(); scope = .wiki
        setLibrarySourceSelection(nil)
        selectedID = nil; selectedSemanticID = nil; currentNote = nil; currentSource = nil
        title = ""; body = ""; tagInput = ""; lccInput = ""; wordCount = 0; reading = true
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

    func preferredAIProvider(for action: AIAction, temporaryOverride: AIProvider? = nil) -> AIProvider {
        temporaryOverride ?? aiProviderPreferences.settings.preferredProvider(for: action)
    }

    private func resolveAIAction(_ action: AIAction, provider: AIProvider? = nil, openAIConfigured: Bool? = nil) -> AIProviderResolution {
        var local: AIProviderStatus = aiClient.unavailabilityReason() == nil ? .available : .unavailable(.localModelUnavailable)
        if action == .summarizePage && !aiPreferenceDefaults.bool(forKey: EditorPreferences.aiSummariesKey) {
            local = .unavailable(.localDisabled)
        }
        let configured = openAIConfigured ?? (externalAIService.credentialStatus?.isAvailable == true || cloudSummaryOverride != nil)
        let cloud: AIProviderStatus = configured ? .available : .unavailable(.missingCredentials)
        let availability = AIProviderAvailability(onDevice: local, openAI: cloud)
        let resolution = AIProviderResolver.resolve(action: action, settings: aiProviderPreferences.settings,
            temporaryOverride: provider, execution: .userInvoked, availability: availability)
        if !resolution.isEligible { aiProviderNotice = resolution.errorMessage }
        else { aiProviderNotice = nil }
        return resolution
    }

    private func admitsNativeAction(_ action: AIAction, provider: AIProvider? = nil) -> Bool {
        let resolution = resolveAIAction(action, provider: provider)
        return resolution.isEligible && resolution.provider == .onDevice
    }

    func requestPageSummary(id: UUID, provider: AIProvider? = nil) {
        guard canOperateOnLoadedContent, !hasPendingCloudSummary, pendingAISuggestion == nil, explicitTitleTask == nil, !isSummarizing(target: .page(id)) else { return }
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
        guard canOperateOnLoadedContent, !hasPendingCloudSummary, pendingAISuggestion == nil, explicitTitleTask == nil, !isSummarizing(target: .source(source.id)) else { return }
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
            guard resolveAIAction(action, provider: .openAI, openAIConfigured: configured).isEligible else { return }
            prepareCloudSummary(target: target, action: action == .suggestTitle ? .suggestTitle : action == .classifyLCC ? .lccClassification : nil)
        }
    }

    var hasPendingCloudSummary: Bool {
        providerPreflightTarget != nil || cloudSummaryTarget != nil || cloudSummaryConfirmation != nil
    }

    var nativePageSummaryTaskForTesting: Task<Void, Never>? { aiSummaryTask }
    func nativeSourceSummaryTaskForTesting(id: UUID) -> Task<Void, Never>? { sourceSummaryTasks[id] }

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
                pendingAISuggestion = AISuggestion(id: identity, action: action, value: value, rationale: nil,
                    provider: .onDevice, target: target)
                pendingAISuggestionContext = AISuggestionContext(snapshot: snapshot, selection: selection,
                    editorRevision: revision, provenance: SummaryProvenance(provider: "On-device", model: "Apple Intelligence",
                        generatedAt: Date(), sourceRevision: Self.sourceRevision(snapshot)), validate: { try Task.checkCancellation() })
            } catch {
                guard suggestionRequestID == identity, !Task.isCancelled else { return }
                aiProviderNotice = Self.cloudError(error)
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
                    guard generation == ticket, canOperateOnLoadedContent else { return }
                    if let i = sources.firstIndex(where: { $0.id == saved.id }) { sources[i] = saved }
                    if currentSource?.id == saved.id { currentSource = saved }
                    SourceReader.updateTitle(id: saved.id, title: saved.title)
                }
                await refresh()
            } catch {
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
    private var cloudRequestID: UUID?
    /// Test seam: restricted, consent-bound summaries only; production always uses the gateway.
    /// Test seam for preflight status only; it cannot grant gateway authorization or consent.
    var cloudCredentialAvailabilityOverride: (@Sendable () async -> Bool)?
    var cloudSummaryOverride: (@Sendable (ExternalAISummaryRequest, ExternalAIContentConsent) async throws -> ExternalAISummaryResult)?
    var cloudPublicationOverride: (@Sendable (ExternalAISummaryResult) async throws -> (@Sendable () throws -> Void))?

    func cancelCloudSummary() {
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
                    target: target, contentRevision: UUID(), content: text, action: action)
                let presentation = await externalAIService.consentPresentation(for: request.authority)
                try Task.checkCancellation()
                guard cloudRequestID == identity, selectedID == selection, revision == cloudEditorRevision,
                      request.authority.matches(sessionManager.accessGate.currentLease) else { throw ExternalAIError.staleSession }
                cloudSummaryConfirmation = CloudSummaryConfirmation(request: request, snapshot: snapshot,
                    title: itemTitle, model: externalAIService.configuration.model,
                    selection: selection, editorRevision: revision, presentation: presentation)
                cloudSummaryTarget = nil; cloudSummaryTask = nil
            } catch {
                guard cloudRequestID == identity else { return }
                cloudSummaryTarget = nil; cloudSummaryTask = nil
                cloudSummaryError = Self.cloudError(error)
            }
        }
    }

    func confirmCloudSummary() {
        guard let confirmation = cloudSummaryConfirmation, canOperateOnLoadedContent else { return }
        cloudSummaryConfirmation = nil
        let request = confirmation.request
        let identity = cloudRequestID
        let gateway = externalAIService.gateway
        let override = cloudSummaryOverride
        let publicationOverride = cloudPublicationOverride
        guard confirmation.model == externalAIService.configuration.model else {
            cloudSummaryError = ExternalAIError.staleContent.localizedDescription; return
        }
        cloudSummaryTarget = request.target
        cloudPublicationGuard.arm(requestID: request.id)
        let publicationGuard = cloudPublicationGuard
        cloudSummaryTask = Task {
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
                let consent = ExternalAIContentConsent(approving: request)
                let result: ExternalAISummaryResult
                if let override { result = try await override(request, consent) }
                else {
                    switch request.action {
                    case .summarizePage: result = try await gateway.summarizePage(request, consent: consent)
                    case .summarizeSource: result = try await gateway.summarizeSource(request, consent: consent)
                    case .suggestTitle: result = try await gateway.suggestTitle(request, consent: consent)
                    case .lccClassification: result = try await gateway.classifyLCC(request, consent: consent)
                    }
                }
                guard result.requestID == request.id, result.target == request.target,
                      result.contentRevision == request.contentRevision, result.authority == request.authority, result.action == request.action else { throw ExternalAIError.invalidResponse }
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
                    pendingAISuggestion = AISuggestion(id: request.id,
                        action: request.action == .suggestTitle ? .suggestTitle : .classifyLCC,
                        value: value, rationale: rationale, provider: .openAI, target: request.target)
                    pendingAISuggestionContext = AISuggestionContext(snapshot: confirmation.snapshot,
                        selection: confirmation.selection, editorRevision: confirmation.editorRevision,
                        provenance: provenance, validate: validate)
                    return
                }
                switch confirmation.snapshot {
                case .page(let page):
                    if currentNote?.id == page.note.id {
                        guard body == page.note.body, cloudEditorRevision == confirmation.editorRevision,
                              !editingLocked, !externalChange, !generatingAISummary else { throw ExternalAIError.staleContent }
                    }
                    let saved = try await repository.publishPageSummary(page, summary: result.summary, provenance: provenance, validate: {
                        try publicationGuard.validate(requestID: request.id)
                        try validate()
                    })
                    try Task.checkCancellation()
                    guard cloudRequestID == identity, request.authority.matches(sessionManager.accessGate.currentLease) else { return }
                    if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                    if currentNote?.id == saved.id, body == page.note.body, cloudEditorRevision == confirmation.editorRevision { apply(saved) }
                case .source(let source):
                    let saved = try await repository.publishSourceSummary(source, summary: result.summary, provenance: provenance, validate: {
                        try publicationGuard.validate(requestID: request.id)
                        try validate()
                    })
                    try Task.checkCancellation()
                    guard cloudRequestID == identity, request.authority.matches(sessionManager.accessGate.currentLease) else { return }
                    if let i = sources.firstIndex(where: { $0.id == saved.id }) { sources[i] = saved }
                    if currentSource?.id == saved.id { currentSource = saved }
                }
                await refresh()
            } catch {
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
        guard let currentNote, !editingLocked, !isSummarizing(target: .page(currentNote.id)) else { return }
        var document = BlockDocumentCodec.decode(body)
        guard document.removeAISummary() else { return }
        body = BlockDocumentCodec.encode(document); aiSummaryNotice = nil; edited()
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
            defer {
                if generation == completionTicket.token, nativePageSummaryRequestID == requestID {
                    nativePageSummaryRequestID = nil; nativePageSummaryID = nil
                    generatingAISummary = false
                    aiSummaryTask = nil
                }
            }
            do {
                let summary = try await client.summarize(content)
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
                guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.utf8.count <= ExternalAILimits.maximumSummaryBytes else { aiSummaryNotice = "No valid summary was returned. Try again."; return }
                var document = BlockDocumentCodec.decode(body)
                document.setAISummary(summary)
                document.blocks[0].metadata.extra["aiProvider"] = "On-device"
                document.blocks[0].metadata.extra["aiModel"] = "Apple Intelligence"
                document.blocks[0].metadata.extra["aiGeneratedAt"] = ISO8601DateFormatter().string(from: Date())
                document.blocks[0].metadata.extra["aiSourceRevision"] = Self.contentRevision(content)
                body = BlockDocumentCodec.encode(document); edited()
            } catch {
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
        return await finishCurrentPage(waitForTitles: waitForTitles)
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
        try await sessionManager.close(expectedSession: expectedSession)
        try requireLifecycleState(.closed, action: "close")
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
            let (searchIndex, journal, cached, drafts) = try await Task.detached {
                let idx = try factory(localBase.appendingPathComponent("search.sqlite"), lease, gate)
                let recoveryStore = try RecoveryStore(
                    directory: localBase.appendingPathComponent("Drafts"),
                    sessionLease: lease,
                    accessGate: gate
                )
                let cachedEntries = try await idx.cachedEntries()
                let recovered = try await recoveryStore.listing()
                return (idx, recoveryStore, cachedEntries, recovered)
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
            unseenRenamedPages.removeAll()
            recentPageIDs.removeAll()
            root = url; vaultName = url.lastPathComponent; scope = .wiki; searchText = ""
            sidebarSearchResults = SidebarSearchResults()
            selectedID = nil; currentNote = nil; currentSource = nil; externalChange = false
            title = ""; body = ""; tagInput = ""; lccInput = ""; preview = []; backlinks = []; outgoingLinkTargets = []; wordCount = 0; reading = true
            notes = cached.notes; sources = cached.sources; trashedPages = []; trashOperationInProgress = false
            updateTags()
            applyRecoveryListing(drafts)
            if persistSecurityScopedBookmark {
                try remember(url)
            }
            watcher = VaultWatcher(url: url) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
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
        guard beginLifecycleAction("lock") else { return false }
        defer { lifecycleAction = nil; lifecycleActionID = nil }
        if sessionManager.accessGate.currentState.phase == .locked {
            applyObservedSessionState(sessionManager.accessGate.currentState)
            return true
        }
        guard let repository, let currentRoot = root,
              let lockingSession = sessionManager.accessGate.currentState.activeSession else { return false }
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
            let observed = sessionManager.accessGate.currentState
            lockedVaultURL = currentRoot
            if persistSecurityScopedBookmark, lockedVaultBookmark == nil {
                lockedVaultBookmark = UserDefaults.standard.data(forKey: "vaultBookmark")
            }
            vaultName = currentRoot.lastPathComponent
            releaseActiveVaultResources()
            clearSessionUIState()
            sessionState = observed
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
            let (searchIndex, journal, cached, drafts) = try await Task.detached {
                let idx = try factory(localBase.appendingPathComponent("search.sqlite"), lease, gate)
                let recoveryStore = try RecoveryStore(
                    directory: localBase.appendingPathComponent("Drafts"),
                    sessionLease: lease,
                    accessGate: gate
                )
                let cached = try await idx.cachedEntries()
                let drafts = try await recoveryStore.listing()
                return (idx, recoveryStore, cached, drafts)
            }.value
            try requireLifecycleState(.open, action: "unlock", session: session)
            if persistSecurityScopedBookmark, (resolvedStaleBookmark || overrideURL != nil) {
                try remember(candidateURL)
            }
            SourceReader.closeAll()
            watcher?.stop()
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
            unseenRenamedPages.removeAll()
            recentPageIDs.removeAll()
            root = candidateURL; vaultName = candidateURL.lastPathComponent; scope = .wiki; searchText = ""
            sidebarSearchResults = SidebarSearchResults()
            selectedID = nil; currentNote = nil; currentSource = nil; externalChange = false
            title = ""; body = ""; tagInput = ""; lccInput = ""; preview = []; backlinks = []; outgoingLinkTargets = []; wordCount = 0; reading = true
            notes = cached.notes; sources = cached.sources; trashedPages = []; trashOperationInProgress = false
            updateTags()
            applyRecoveryListing(drafts)
            watcher = VaultWatcher(url: candidateURL) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
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
        if !force, isVaultAvailable {
            guard await flushPendingEdits() else { return false }
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
    func queryChanged() {
        queryTask?.cancel()
        guard canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .search, capturedText: searchText)
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "queryChanged") else { return }
            await updateRows()
        }
    }
    func changeScope(_ scope: LibraryScope) {
        guard canOperateOnLoadedContent else { return }
        // Revoke immediately, including while an asynchronous save delays applying the scope.
        cancelCloudSummary()
        let completionTicket = issueCompletionTicket(kind: .lifecycle)
        let applyScope = { @MainActor in
            self.autosaveTask?.cancel(); self.wikiQuery = nil; self.editorAction = nil
            self.scope = scope
            if scope == .trash { self.searchText = "" }
            self.selectedID = nil; self.currentNote = nil; self.currentSource = nil; self.selectedSemanticID = nil
            self.externalChange = false; self.errorMessage = nil; self.reading = true
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
        let completionTicket = issueCompletionTicket(kind: .search, capturedText: query)
        var snapshot = notes
        if let currentNote, let i = snapshot.firstIndex(where: { $0.id == currentNote.id }) {
            snapshot[i].body = body; snapshot[i].title = title
        }
        let capturedNotes = snapshot
        let capturedSources = sources
        if isSearching, let index {
            do {
                let results = try await SidebarSearchResults.search(query, notes: capturedNotes, sources: capturedSources, index: index)
                guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.sidebarSearch") else { return }
                sidebarSearchResults = results
                semanticRows = results.blocks
            } catch {
                guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.sidebarSearchError") else { return }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            return
        }
        guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.clearSidebarSearch") else { return }
        sidebarSearchResults = SidebarSearchResults()
        if scope == .semantic || semanticRows.isEmpty {
            let hits = await Task.detached { SemanticBlockHit.search(capturedNotes, query: query) }.value
            if isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.semanticBlocks") {
                semanticRows = hits
            }
            if scope == .semantic { return }
        }
        guard let index else { return }
        let capturedScope = scope, capturedQuery = searchText
        let kind: EntryKind = scope == .sources ? .source : .wiki
        let tag: String? = { if case .tag(let tag) = scope { return tag }; return nil }()
        do {
            let hits = try await index.search(capturedQuery, kind: kind, tag: tag)
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.indexSearch"),
                  capturedScope == scope else { return }
            let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newRows: [LibraryRow] = hits.compactMap { hit in
                if hit.kind == .wiki, let note = noteMap[hit.id] { return LibraryRow(note: note) }
                if let source = sourceMap[hit.id] { return LibraryRow(source: source) }
                return nil
            }
            if newRows != rows { rows = newRows }
        } catch {
            guard isCompletionValid(completionTicket, currentText: searchText, operation: "updateRows.indexSearchError"),
                  capturedScope == scope else { return }
            guard !(error is CancellationError), !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
    func select(_ id: UUID?, scope targetScope: LibraryScope? = nil, block blockID: UUID? = nil) {
        guard canOperateOnLoadedContent else { return }
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: id)
        Task {
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "select.waitForSave") else { return }
            if !(await finishCurrentPage()) { return }
            guard isCompletionValid(completionTicket, operation: "select.finishCurrentPage") else { return }
            autosaveTask?.cancel(); wikiQuery = nil; editorAction = nil
            if let targetScope {
                scope = targetScope; searchText = ""
                await updateRows()
                guard isCompletionValid(completionTicket, operation: "select.updateRows") else { return }
            }
            selectedID = id; currentSource = nil; currentNote = nil; externalChange = false; errorMessage = nil
            reading = true
            if let note = notes.first(where: { $0.id == id }) { apply(note) }
            else if let source = sources.first(where: { $0.id == id }) {
                currentSource = source; title = source.title; body = source.body; reading = true
                generatePreview(); backlinks = []; outgoingLinkTargets = []
            } else {
                title = ""; body = ""; tagInput = ""; lccInput = ""; preview = []; backlinks = []; outgoingLinkTargets = []; wordCount = 0
                editorNotice = nil; editingHint = nil; editorReadOnly = false
            }
            selectedSemanticID = nil
            if let blockID, let note = currentNote, BlockDocumentCodec.decode(body).block(blockID) != nil {
                selectedSemanticID = "\(note.id):\(blockID)"
                editorAction = EditorAction(operation: .block(blockID))
            }
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
        recentPageIDs.removeAll { $0 == note.id }
        recentPageIDs.insert(note.id, at: 0)
        editingHint = nil
        aiSummaryNotice = nil
        editorAction = nil
        if isDifferentPage {
            backlinks = []
            outgoingLinkTargets = []
        }
        currentNote = note; title = note.title; body = note.body; tagInput = note.tags.joined(separator: ", ")
        lccInput = note.lcc ?? ""
        let document = BlockDocumentCodec.decode(note.body)
        editorReadOnly = document.unsupportedVersion
        editorNotice = document.unsupportedVersion ? "This page uses a newer block format and is read-only. Its original content is preserved." : document.recoveredMetadata != nil ? "External Markdown changed. The earlier editor metadata was preserved for recovery; external text is shown." : nil
        externalChange = false; saveStatus = "Saved locally"; generatePreview()
    }
    func setPageLCC(_ value: String) {
        guard canOperateOnLoadedContent, !editingLocked, let note = currentNote else { return }
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
            let saved = try await repository.save(note: note, title: note.title, body: note.body, tags: note.tags)
            guard generation == ticket, canOperateOnLoadedContent else { return }
            if let i = notes.firstIndex(where: { $0.id == pageID }) { notes[i] = saved }
            if currentNote?.id == pageID {
                currentNote = saved
                lccInput = saved.lcc ?? ""
                saveStatus = dirty ? "Unsaved changes" : "Saved locally"
            }
            scheduleRefresh()
        } catch { if generation == ticket, canOperateOnLoadedContent { errorMessage = error.localizedDescription } }
    }
    func refreshPageLCC(provider: AIProvider? = nil) {
        guard let note = currentNote, !editingLocked, !externalChange else { return }
        requestAISuggestion(target: .page(note.id), action: .classifyLCC, provider: provider)
    }
    func updateSourceLCC(_ source: SourceRecord, lcc: String) {
        guard canOperateOnLoadedContent, !downloadingSources.contains(source.id) else { return }
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
                if let index { try await index.reconcile(repository.scan()) }
            } catch {
                if isCompletionValid(completionTicket, operation: "updateSourceLCC.error") {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    func refreshSourceLCC(_ source: SourceRecord, provider: AIProvider? = nil) {
        requestAISuggestion(target: .source(source.id), action: .classifyLCC, provider: provider)
    }
    func openBlockURL(_ url: URL) {
        guard url.scheme == "noema", url.host == "page", let noteID = UUID(uuidString: url.lastPathComponent),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "block" })?.value, let blockID = UUID(uuidString: value) else { return }
        guard isVaultAvailable, !busy else { pendingBlockURL = url; return }
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: noteID)
        Task {
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "openBlockURL.wait") else { return }
            if !(await finishCurrentPage()) { return }
            guard isCompletionValid(completionTicket, operation: "openBlockURL.finish") else { return }
            guard let note = notes.first(where: { $0.id == noteID }), BlockDocumentCodec.decode(note.body).block(blockID) != nil else { errorMessage = "This block link is not available in the open vault."; return }
            autosaveTask?.cancel(); selectedID = noteID; currentSource = nil; apply(note); reading = true
            editorAction = EditorAction(operation: .block(blockID)); await updateBacklinks()
        }
    }
    var editingLocked: Bool { currentNote?.isEditingLocked == true || editorReadOnly }
    func beginEditing() {
        guard canOperateOnLoadedContent, currentNote != nil else { return }
        guard !editingLocked else {
            editingHint = editorReadOnly ? "This article is read-only." : "Article locked. Unlock it to edit."
            return
        }
        editingHint = nil; reading = false
    }
    func finishEditing() { guard canOperateOnLoadedContent else { return }; wikiQuery = nil; editorAction = nil; savePage(); reading = true }
    var updatingSourceReferences = false
    func setSourceReference(pageID: UUID, sourceID: UUID, linked: Bool) {
        guard canOperateOnLoadedContent, !updatingSourceReferences else { return }
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
        guard canOperateOnLoadedContent,
              let targetID = id ?? currentNote?.id,
              notes.contains(where: { $0.id == targetID }),
              !editingLockOperations.contains(targetID) else { return }
        editingLockOperations.insert(targetID)
        let completionTicket = issueCompletionTicket(kind: .pageMutation, targetID: targetID)
        let ticket = completionTicket.token
        Task {
            defer { if generation == ticket { editingLockOperations.remove(targetID) } }
            await waitForSave()
            guard isCompletionValid(completionTicket, operation: "toggleEditingLock.wait") else { return }
            if currentNote?.id == targetID, !(await saveCurrent()) { return }
            guard isCompletionValid(completionTicket, operation: "toggleEditingLock.pre"),
                  let note = notes.first(where: { $0.id == targetID }), let repository else { return }
            saving = true
            defer { if generation == ticket { saving = false } }
            do {
                let saved = try await repository.setEditingLock(note: note, locked: !note.isEditingLocked)
                guard isCompletionValid(completionTicket, operation: "toggleEditingLock.save") else { return }
                if currentNote?.id == saved.id {
                    currentNote = saved; reading = true; editingHint = nil
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
    @discardableResult func saveCurrent() async -> Bool {
        await waitForSave()
        guard canOperateOnLoadedContent, dirty, var note = currentNote, let repository, let recovery else { return !saving }
        guard !saving else { return false }
        let ticket = generation
        saving = true; saveStatus = "Saving…"
        let trimmedLCC = lccInput.trimmingCharacters(in: .whitespacesAndNewlines)
        note.lcc = trimmedLCC.isEmpty ? nil : trimmedLCC
        let draft = DraftRecord(note: note, title: title, body: body, tags: editedTags)
        do {
            wordCount = await Task.detached { BlockDocumentCodec.markdownBody(draft.body).split(whereSeparator: \.isWhitespace).count }.value
            try await recovery.store(draft)
            let saved = try await repository.save(note: note, title: draft.title, body: draft.body, tags: draft.tags)
            guard generation == ticket, canOperateOnLoadedContent else { saving = false; return false }
            recordPageRename(saved.id, from: note.title, to: saved.title)
            if currentNote?.id == saved.id {
                currentNote = saved
                lccInput = saved.lcc ?? ""
                if title == draft.title { title = saved.title }
                if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                updateTags()
            }
            if !dirty { try await recovery.remove(saved.id) }
            saveStatus = dirty ? "Unsaved changes" : "Saved locally"
            applyRecoveryListing(try await recovery.listing()); errorMessage = nil; externalChange = false
            saving = false
            scheduleRefresh()
            if dirty { edited() }
            return !dirty
        } catch {
            guard generation == ticket, canOperateOnLoadedContent else { saving = false; return false }
            saving = false; saveStatus = "Draft preserved · save failed"
            errorMessage = error.localizedDescription
            if case VaultError.conflict = error { externalChange = true }
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
    private func waitForSave() async {
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
    private func startTitleGeneration() {
        guard canOperateOnLoadedContent, needsTitle, let note = currentNote, let repository,
              titleTasks[note.id] == nil, !editingLocked, !externalChange,
              aiClient.unavailabilityReason() == nil else { return }
        let completionTicket = issueCompletionTicket(kind: .aiProcessing, targetID: note.id)
        let content = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(note.body).withoutAISummary))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let client = aiClient
        titleTasks[note.id] = Task { [self] in
            defer { if generation == completionTicket.token { titleTasks.removeValue(forKey: note.id) } }
            do {
                async let generatedTitle = client.pageTitle(content)
                async let generatedLCC = client.inferLCC(content)
                let (generated, lcc) = try await (generatedTitle, generatedLCC)
                guard let generated else { return }
                await waitForSave()
                guard isCompletionValid(completionTicket, operation: "startTitleGeneration.generate"),
                      untitledPages[note.id] == note.title,
                      editorAllowsGeneratedTitle(for: note) else { return }
                saving = true
                defer { if generation == completionTicket.token { saving = false } }
                var updatedNote = note
                if note.lcc == nil, let lcc, !lcc.isEmpty { updatedNote.lcc = lcc }
                let saved = try await repository.save(note: updatedNote, title: generated, body: note.body, tags: note.tags)
                guard isCompletionValid(completionTicket, operation: "startTitleGeneration.save") else { return }
                recordPageRename(saved.id, from: note.title, to: saved.title)
                untitledPages.removeValue(forKey: note.id)
                if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                if currentNote?.id == saved.id {
                    currentNote = saved
                    if title == note.title { title = saved.title }
                }
                scheduleRefresh()
            } catch { /* Content is already saved; retain the placeholder for another attempt. */ }
        }
    }
    func suggestPageTitle(provider: AIProvider? = nil) {
        guard let note = currentNote, !editingLocked, !externalChange else { return }
        requestAISuggestion(target: .page(note.id), action: .suggestTitle, provider: provider)
    }

    func suggestSourceTitle(_ source: SourceRecord) {
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
    func generatePreview() {
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
        }
    }
    private func updateTags() { tags = Array(Set(notes.flatMap(\.allTags))).sorted() }
    func createPageFromTopic(_ input: String) async -> Bool {
        let topic = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canOperateOnLoadedContent, !topic.isEmpty, topic.count <= 120, !generatingTopicPage, let repository else { return false }
        if let reason = aiClient.unavailabilityReason() { errorMessage = reason; return false }
        let completionTicket = issueCompletionTicket(kind: .aiProcessing)
        let client = aiClient
        generatingTopicPage = true; errorMessage = nil
        defer { if generation == completionTicket.token { generatingTopicPage = false } }
        do {
            guard await finishCurrentPage(),
                  isCompletionValid(completionTicket, operation: "createPageFromTopic.finishInitial") else { return false }
            let results = try await client.researchTopic(topic)
            guard isCompletionValid(completionTicket, operation: "createPageFromTopic.research") else { return false }
            let context = results.enumerated().map { offset, result in
                "[\(offset + 1)] " + result.title + "\n" + result.url.absoluteString + "\n" + result.text
            }.joined(separator: "\n\n")
            async let generatedArticle = client.pageFromTopic(topic, context)
            async let generatedLCC = client.inferLCC(OnDeviceSummary.topicPrompt(topic: topic, context: context))
            var article = try await generatedArticle
            let lcc = await generatedLCC
            guard isCompletionValid(completionTicket, operation: "createPageFromTopic.generate") else { return false }
            article += "\n\n*AI-generated draft based on web results retrieved " + timestamp() + ".*"
            let references: [String] = results.enumerated().map { offset, result in
                let title = result.title.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                return "- [\(offset + 1)] [\(title)](<\(result.url.absoluteString)>)"
            }
            article += "\n\n## Web references\n\n" + references.joined(separator: "\n")
            guard await finishCurrentPage(),
                  isCompletionValid(completionTicket, operation: "createPageFromTopic.preCreate") else { return false }
            let note = try await repository.create(title: topic, body: article, lcc: lcc)
            guard isCompletionValid(completionTicket, operation: "createPageFromTopic.create") else { return false }
            errorMessage = nil; searchText = ""; scope = .wiki; reading = false
            notes.insert(note, at: 0); selectedID = note.id; currentSource = nil; apply(note)
            await refresh()
            return isCompletionValid(completionTicket, operation: "createPageFromTopic.complete")
        } catch {
            if isCompletionValid(completionTicket, operation: "createPageFromTopic.error") {
                errorMessage = "Create topic page: " + error.localizedDescription
            }
            return false
        }
    }

    func newPage(template: Bool = false, named name: String = "Untitled") {
        guard canOperateOnLoadedContent else { return }
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
                notes.insert(note, at: 0); scope = .wiki; reading = false
                selectedID = note.id; currentSource = nil; apply(note)
                await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "newPage.error") { errorMessage = error.localizedDescription } }
        }
    }
    func trashCurrent() { trashPage(currentNote?.id) }
    func trashPage(_ id: UUID?) {
        guard canOperateOnLoadedContent, let id else { return }
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
        guard canOperateOnLoadedContent, !trashOperationInProgress, !pages.isEmpty, let repository else { return }
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
            if dirty, let note = currentNote, let recovery {
                do {
                    try await recovery.store(DraftRecord(note: note, title: title, body: body, tags: editedTags))
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
            guard isCompletionValid(completionTicket, operation: "saveDraftAsNewPage.start"), let repository else { return }
            let originalID = recovered?.id ?? currentNote?.id
            do {
                var note = try await repository.create(title: (recovered?.title ?? title) + " (recovered)", body: recovered?.body ?? body)
                note = try await repository.save(note: note, title: note.title, body: note.body, tags: recovered?.tags ?? editedTags)
                if let originalID { try await recovery?.remove(originalID) }
                let drafts = try await recovery?.listing() ?? RecoveryListing()
                guard isCompletionValid(completionTicket, operation: "saveDraftAsNewPage") else { return }
                applyRecoveryListing(drafts)
                notes.insert(note, at: 0); scope = .wiki; currentSource = nil; selectedID = note.id; apply(note)
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
                try await recovery?.remove(draft.id)
                let drafts = try await recovery?.listing() ?? RecoveryListing()
                guard isCompletionValid(completionTicket, operation: "discardRecovery") else { return }
                applyRecoveryListing(drafts)
            } catch { if isCompletionValid(completionTicket, operation: "discardRecovery.error") { errorMessage = error.localizedDescription } }
        }
    }
    private func applyRecoveryListing(_ listing: RecoveryListing) {
        recoveredDrafts = listing.drafts
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
        guard canOperateOnLoadedContent else { return }
        let key = normalized(target)
        let matches = notes.filter { normalized($0.title) == key || $0.aliases.contains(where: { normalized($0) == key }) }
        if matches.count == 1 { select(matches[0].id) }
        else if matches.isEmpty { unresolvedTarget = target }
        else { ambiguousMatches = matches }
    }
    func suggestLink(_ title: String) { guard canOperateOnLoadedContent, !reading, !editingLocked else { return }; editorAction = EditorAction(operation: .wikiLink(title)); wikiQuery = nil }
    func format(_ prefix: String, _ suffix: String) { guard canOperateOnLoadedContent, !reading, !editingLocked else { return }; editorAction = EditorAction(operation: .wrap(prefix, suffix)) }
    func importFiles() { addSource() }
    func linkSources() { addSource() }
    func addSource() {
        guard canOperateOnLoadedContent, !isChoosingSource else { return }
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
        guard canOperateOnLoadedContent, let repository, let root else { return }
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
        guard canOperateOnLoadedContent, !downloadingSources.contains(source.id), !generatingSourcePages.contains(source.id), let repository, let root else { return }
        guard admitsNativeAction(.processSource, provider: provider) else { return }
        let completionTicket = issueCompletionTicket(kind: .aiProcessing, targetID: source.id)
        let ticket = completionTicket.token
        let client = aiClient
        generatingSourcePages.insert(source.id)
        sourcePageTasks[source.id]?.cancel()
        sourcePageTasks[source.id] = Task {
            defer { if generation == ticket { generatingSourcePages.remove(source.id); sourcePageTasks.removeValue(forKey: source.id) } }
            do {
                let materialized = try await repository.loadSource(id: source.id)
                let text = try await sourceSummaryContent(materialized, root: root)
                guard isCompletionValid(completionTicket, operation: "createPageFromSource.read") else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VaultError.unavailable("No readable text for a wiki page.")
                }
                let article = try await client.pageFromSource(text)
                async let generatedTitle = client.pageTitle(article)
                async let generatedLCC = client.inferLCC(article)
                let pageTitle = (try await generatedTitle) ?? source.title
                let lcc = (await generatedLCC) ?? source.metadata.lcc
                guard isCompletionValid(completionTicket, operation: "createPageFromSource.generate"),
                      await finishCurrentPage(),
                      isCompletionValid(completionTicket, operation: "createPageFromSource.preCreate") else { return }
                let note = try await repository.create(title: pageTitle, body: article, source: materialized, lcc: lcc)
                guard isCompletionValid(completionTicket, operation: "createPageFromSource.create") else { return }
                errorMessage = nil; searchText = ""; scope = .wiki; reading = false
                notes.insert(note, at: 0); selectedID = note.id; currentSource = nil; apply(note)
                await refresh()
            } catch { if isCompletionValid(completionTicket, operation: "createPageFromSource.error") { errorMessage = "Create page: " + error.localizedDescription } }
        }
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
                let summary = try await client.summarize(String(text.prefix(6000)))
                try Task.checkCancellation()
                guard nativeSourceSummaryIDs[source.id] == requestID,
                      isCompletionValid(completionTicket, operation: "generateSourceSummary.generate") else { return }
                guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      summary.utf8.count <= ExternalAILimits.maximumSummaryBytes else { throw ExternalAIError.invalidResponse }
                let saved = try await repository.publishSourceSummary(snapshot, summary: summary,
                    provenance: SummaryProvenance(provider: "On-device", model: "Apple Intelligence", generatedAt: Date()),
                    validate: { try Task.checkCancellation() })
                guard isCompletionValid(completionTicket, operation: "generateSourceSummary.save") else { return }
                if let i = sources.firstIndex(where: { $0.id == saved.id }) { sources[i] = saved }
                if currentSource?.id == saved.id { currentSource = saved }
                await refresh()
            } catch {
                guard !Task.isCancelled, nativeSourceSummaryIDs[source.id] == requestID,
                      isCompletionValid(completionTicket, operation: "generateSourceSummary.error") else { return }
                aiProviderNotice = Self.cloudError(error)
            }
        }
    }
    func enqueueSourceTitle(_ source: SourceRecord) {
        guard canOperateOnLoadedContent else { return }
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
                guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.loop") else { return }
                let source = sourceNamingQueue.removeFirst()
                if sourceNamingOverrides.contains(source.id) {
                    generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1; continue
                }
                do {
                    if let reason = client.unavailabilityReason() { throw VaultError.unavailable(reason) }
                    let source = try await repository.loadSource(id: source.id)
                    let text = try await sourceSummaryContent(source, root: root)
                    guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.read") else { return }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.unavailable("No readable text for automatic naming and summary. Original file name retained.") }
                    let excerpt = String(text.prefix(6000))
                    async let generatedTitle = client.pageTitle(text)
                    async let generatedSummary = client.summarize(excerpt)
                    async let generatedLCC = client.inferLCC(excerpt)
                    let (titleResult, summary, lcc) = try await (generatedTitle, generatedSummary, generatedLCC)
                    guard let title = titleResult else { throw VaultError.unavailable("No valid topic title was generated. Original file name retained.") }
                    guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.generate") else { return }
                    if sourceNamingOverrides.contains(source.id) {
                        generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1; continue
                    }
                    guard sources.first(where: { $0.id == source.id })?.metadata.lcc == source.metadata.lcc else {
                        throw ExternalAIError.staleContent
                    }
                    let renamed = try await repository.renameSource(source, title: title, summary: summary,
                        lcc: source.metadata.lcc == nil ? lcc : nil)
                    guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.rename") else { return }
                    if let position = sources.firstIndex(where: { $0.id == source.id }) { sources[position] = renamed }
                    if let index { try await index.reconcile(repository.scan()) }
                    guard isCompletionValid(completionTicket, operation: "enqueueSourceTitle.reconcile") else { return }
                    await updateRows()
                } catch { if isCompletionValid(completionTicket, operation: "enqueueSourceTitle.error") { errorMessage = "Source naming: " + error.localizedDescription } }
                if generation == ticket {
                    generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1
                }
            }
        }
    }
    func renameSource(_ source: SourceRecord, title: String) {
        cloudEditorRevision = UUID(); cloudPublicationGuard.invalidate()
        guard canOperateOnLoadedContent else { return }
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
        guard canOperateOnLoadedContent else { return }
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
        guard canOperateOnLoadedContent else { return }
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
