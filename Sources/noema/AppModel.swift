import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VaultCore
import PDFKit

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
        excerpt = BlockDocumentCodec.decode(source.body).flattened.map(\.text).joined(separator: " ")
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

@MainActor @Observable final class AppModel {
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
    private var sidebarLockSortDates: [UUID: String] = [:]
    private(set) var sidebarMoveFeedback: [UUID: UUID] = [:]
    var tags: [String] = []
    var wordCount = 0
    var scope: LibraryScope = .wiki
    var searchText = ""
    var sidebarSearchResults = SidebarSearchResults()
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var unseenRenamedPages: Set<UUID> = []
    var appIsActive = true
    var selectedID: UUID?
    var currentNote: NoteRecord?
    var currentSource: SourceRecord?
    var title = ""
    var body = ""
    var tagInput = ""
    var preview: [PreviewBlock] = []
    var backlinks: [NoteRecord] = []
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
    private var repository: FileVaultRepository?
    private var index: SQLiteSearchIndex?
    private var recovery: RecoveryStore?
    private var watcher: VaultWatcher?
    private var scopeURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var untitledPages: [UUID: String] = [:]
    private var titleTasks: [UUID: Task<Void, Never>] = [:]
    private var saving = false
    private var refreshing = false
    private var pendingRefresh = false
    private var generation = UUID()
    private var progressTicket: UUID?

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
    // Keep saved metadata current while the sidebar finishes its lock-change feedback.
    func holdSidebarPosition(_ id: UUID) {
        guard sidebarLockSortDates[id] == nil, let note = notes.first(where: { $0.id == id }) else { return }
        sidebarLockSortDates[id] = note.updatedAt
    }
    func finishSidebarLockFeedback(_ id: UUID, showMoveFeedback: Bool = true) {
        guard sidebarLockSortDates.removeValue(forKey: id) != nil else { return }
        if showMoveFeedback { sidebarMoveFeedback[id] = UUID() }
    }
    private func sidebarUpdatedDate(_ note: NoteRecord) -> Date {
        LibraryRow.date(sidebarLockSortDates[note.id] ?? note.updatedAt) ?? .distantPast
    }
    var recentSources: [SourceRecord] {
        Array(sources.sorted { $0.metadata.capturedAt > $1.metadata.capturedAt }.prefix(10))
    }
    var linkSuggestions: [NoteRecord] {
        guard let wikiQuery else { return [] }
        return Array(notes.filter { wikiQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(wikiQuery) }.sorted { $0.title < $1.title }.prefix(6))
    }

    func deleteAISummary() {
        guard currentNote != nil, !editingLocked, !generatingAISummary else { return }
        var document = BlockDocumentCodec.decode(body)
        guard document.removeAISummary() else { return }
        body = BlockDocumentCodec.encode(document); aiSummaryNotice = nil; edited()
    }

    func summarizePage() {
        guard UserDefaults.standard.bool(forKey: EditorPreferences.aiSummariesKey),
              currentNote != nil, !editingLocked, !generatingAISummary else { return }
        if let reason = OnDeviceSummary.unavailabilityReason { aiSummaryNotice = reason; return }
        let capturedBody = body, capturedID = currentNote?.id, capturedGeneration = generation
        let content = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(body).withoutAISummary))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiSummaryNotice = "Add page content before generating a summary."; return
        }
        generatingAISummary = true; aiSummaryNotice = nil
        Task {
            defer { generatingAISummary = false }
            do {
                let generator = OnDeviceSummary()
                async let generatedSummary = generator.summarize(content)
                async let generatedLCC = generator.inferLCC(content)
                let (summary, lcc) = try await (generatedSummary, generatedLCC)
                guard currentNote?.id == capturedID, generation == capturedGeneration else { return }
                guard body == capturedBody, !editingLocked, !externalChange,
                      UserDefaults.standard.bool(forKey: EditorPreferences.aiSummariesKey) else {
                    aiSummaryNotice = "The page changed during generation. Generate the summary again."; return
                }
                guard !summary.isEmpty else { aiSummaryNotice = "No summary was returned. Try again."; return }
                if let lcc, !lcc.isEmpty {
                    lccInput = lcc
                    currentNote?.lcc = lcc
                    if let id = currentNote?.id, let i = notes.firstIndex(where: { $0.id == id }) {
                        notes[i].lcc = lcc
                    }
                }
                var document = BlockDocumentCodec.decode(body)
                document.setAISummary(summary)
                body = BlockDocumentCodec.encode(document); edited()
            } catch {
                guard currentNote?.id == capturedID, generation == capturedGeneration else { return }
                aiSummaryNotice = "Could not generate an AI summary: " + error.localizedDescription
            }
        }
    }

    func restore() async {
        guard let data = UserDefaults.standard.data(forKey: "vaultBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            await open(url, create: false)
            if stale, root != nil { try remember(url) }
        } catch { errorMessage = "Reselect your vault folder to restore access. " + error.localizedDescription }
    }
    func chooseVault(create: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = create
        panel.prompt = create ? "Create Vault Here" : "Open Vault"
        panel.message = create ? "Choose or create a folder. You can select a folder in iCloud Drive." : "Choose the folder containing your vault.json file."
        presentPanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.open(url, create: create) }
        }
    }
    private func presentPanel(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else { panel.begin(completionHandler: completion) }
    }
    private func remember(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "vaultBookmark")
    }
    func open(_ url: URL, create: Bool) async {
        if !(await finishCurrentPage()) { return }
        busy = true; errorMessage = nil
        let hasScope = url.startAccessingSecurityScopedResource()
        do {
            let repo = try await Task.detached { try FileVaultRepository.open(root: url, create: create) }.value
            let vaultID = repo.manifest.id
            let localBase = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("KnowledgeVault/\(vaultID.uuidString)")
            let (searchIndex, journal) = try await Task.detached {
                (try SQLiteSearchIndex(url: localBase.appendingPathComponent("search.sqlite")), try RecoveryStore(directory: localBase.appendingPathComponent("Drafts")))
            }.value
            watcher?.stop()
            if let scopeURL { scopeURL.stopAccessingSecurityScopedResource() }
            self.scopeURL = hasScope ? url : nil
            sourceDownloadTask?.cancel(); sourceDownloadTask = nil; sourceDownloadQueue = []; downloadingSources = []
            sourceNamingTask?.cancel(); sourceNamingTask = nil; sourceNamingQueue = []
            sourceAvailabilityTask?.cancel(); sourceAvailabilityTask = nil; sourceAvailabilityQueue = []
            sourceAvailability = [:]; checkingSourceAvailability = []
            showTopicPage = false; generatingTopicPage = false
            generatingSourcePages = []
            generatingSourceSummaries = []
            generatingSourceTitles = []; sourceRenameCompleted = 0; sourceRenameTotal = 0
            dismissedVaultNotices = []
            generation = UUID(); repository = repo; index = searchIndex; recovery = journal
            unseenRenamedPages.removeAll()
            recentPageIDs.removeAll()
            sidebarLockSortDates.removeAll()
            sidebarMoveFeedback.removeAll()
            root = url; vaultName = url.lastPathComponent; scope = .wiki; searchText = ""
            selectedID = nil; currentNote = nil; currentSource = nil; externalChange = false
            let cached = try await searchIndex.cachedEntries()
            notes = cached.notes; sources = cached.sources; trashedPages = []; trashOperationInProgress = false
            updateTags()
            recoveredDrafts = try await journal.drafts()
            try remember(url)
            watcher = VaultWatcher(url: url) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
            busy = false
            await updateRows()
            await refresh()
            if let url = pendingBlockURL { pendingBlockURL = nil; openBlockURL(url) }
        } catch {
            if hasScope, scopeURL != url { url.stopAccessingSecurityScopedResource() }
            busy = false; errorMessage = error.localizedDescription
        }
    }
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await refresh()
        }
    }
    func refresh() async {
        guard let repository, let index else { return }
        if refreshing { pendingRefresh = true; return }
        refreshing = true
        let ticket = generation, initiallyEmpty = notes.isEmpty && sources.isEmpty
        let scanTicket = UUID(); progressTicket = scanTicket
        if initiallyEmpty { busy = true }
        do {
            let result = try await repository.scan { [weak self] chunk in
                guard initiallyEmpty else { return }
                Task { @MainActor in
                    guard let self, self.generation == ticket, self.progressTicket == scanTicket else { return }
                    self.notes.append(contentsOf: chunk.notes); self.sources.append(contentsOf: chunk.sources)
                    self.rows = self.notes.map { LibraryRow(note: $0) }
                }
            }
            progressTicket = nil
            guard ticket == generation else { refreshing = false; return }
            let previousTitles = Dictionary(notes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            for note in result.notes {
                if let previous = previousTitles[note.id] { recordPageRename(note.id, from: previous, to: note.title) }
            }
            notes = result.notes; sources = result.sources; issues = result.issues.filter { !dismissedVaultNotices.contains($0) }
            do {
                let expirationFailures = try await repository.expireTrash(now: Date())
                if !expirationFailures.isEmpty { errorMessage = expirationFailures.joined(separator: "\n") }
                let pages = try await repository.trashItems()
                guard ticket == generation else { refreshing = false; return }
                trashedPages = pages
            } catch {
                guard ticket == generation else { refreshing = false; return }
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
            await updateRows(); await updateBacklinks()
        } catch { errorMessage = error.localizedDescription }
        progressTicket = nil; busy = false; refreshing = false
        if pendingRefresh { pendingRefresh = false; scheduleRefresh() }
    }
    func queryChanged() {
        queryTask?.cancel()
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            await updateRows()
        }
    }
    func changeScope(_ scope: LibraryScope) {
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
            Task { await updateRows(); if scope == .trash { await refresh() } }
        } else {
            Task {
                await waitForSave()
                if await finishCurrentPage() {
                    applyScope()
                    await updateRows()
                    if scope == .trash { await refresh() }
                }
            }
        }
    }
    private func updateRows() async {
        let query = searchText, ticket = generation
        var snapshot = notes
        if let currentNote, let i = snapshot.firstIndex(where: { $0.id == currentNote.id }) {
            snapshot[i].body = body; snapshot[i].title = title
        }
        let capturedNotes = snapshot
        if isSearching, let index {
            do {
                let results = try await SidebarSearchResults.search(query, notes: capturedNotes, sources: sources, index: index)
                guard searchText == query, generation == ticket, !Task.isCancelled else { return }
                sidebarSearchResults = results
                semanticRows = results.blocks
            } catch {
                guard searchText == query, generation == ticket, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            return
        }
        sidebarSearchResults = SidebarSearchResults()
        if scope == .semantic || semanticRows.isEmpty {
            let hits = await Task.detached { SemanticBlockHit.search(capturedNotes, query: query) }.value
            if searchText == query, generation == ticket, !Task.isCancelled {
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
            guard capturedScope == scope, capturedQuery == searchText, generation == ticket, !Task.isCancelled else { return }
            let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newRows: [LibraryRow] = hits.compactMap { hit in
                if hit.kind == .wiki, let note = noteMap[hit.id] { return LibraryRow(note: note) }
                if let source = sourceMap[hit.id] { return LibraryRow(source: source) }
                return nil
            }
            if newRows != rows { rows = newRows }
        } catch { errorMessage = error.localizedDescription }
    }
    func select(_ id: UUID?, scope targetScope: LibraryScope? = nil, block blockID: UUID? = nil) {
        Task {
            await waitForSave()
            if !(await finishCurrentPage()) { return }
            autosaveTask?.cancel(); wikiQuery = nil; editorAction = nil
            if let targetScope {
                scope = targetScope; searchText = ""
                await updateRows()
            }
            selectedID = id; currentSource = nil; currentNote = nil; externalChange = false; errorMessage = nil
            reading = true
            if let note = notes.first(where: { $0.id == id }) { apply(note) }
            else if let source = sources.first(where: { $0.id == id }) {
                currentSource = source; title = source.title; body = source.body; reading = true
                generatePreview(); backlinks = []
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
    var lccInput = ""
    var generatingPageLCC = false
    var generatingSourceLCCs: Set<UUID> = []
    private var lccSaveTask: Task<Void, Never>?
    private var sourceLCCSaveTasks: [UUID: Task<Void, Never>] = [:]

    private func apply(_ note: NoteRecord) {
        lccSaveTask?.cancel()
        markPageViewed(note.id)
        recentPageIDs.removeAll { $0 == note.id }
        recentPageIDs.insert(note.id, at: 0)
        editingHint = nil
        aiSummaryNotice = nil
        editorAction = nil
        currentNote = note; title = note.title; body = note.body; tagInput = note.tags.joined(separator: ", ")
        lccInput = note.lcc ?? ""
        let document = BlockDocumentCodec.decode(note.body)
        editorReadOnly = document.unsupportedVersion
        editorNotice = document.unsupportedVersion ? "This page uses a newer block format and is read-only. Its original content is preserved." : document.recoveredMetadata != nil ? "External Markdown changed. The earlier editor metadata was preserved for recovery; external text is shown." : nil
        externalChange = false; saveStatus = "Saved locally"; generatePreview()
    }
    func setPageLCC(_ value: String) {
        guard !editingLocked, let note = currentNote else { return }
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
        guard generation == ticket, let repository,
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
            guard generation == ticket else { return }
            if let i = notes.firstIndex(where: { $0.id == pageID }) { notes[i] = saved }
            if currentNote?.id == pageID {
                currentNote = saved
                lccInput = saved.lcc ?? ""
                saveStatus = dirty ? "Unsaved changes" : "Saved locally"
            }
            scheduleRefresh()
        } catch { if generation == ticket { errorMessage = error.localizedDescription } }
    }
    func refreshPageLCC() {
        guard let note = currentNote, !editingLocked, !generatingPageLCC else { return }
        if let reason = OnDeviceSummary.unavailabilityReason { errorMessage = reason; return }
        let content = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(body).withoutAISummary))
        let fallback = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : content
        guard !input.isEmpty else {
            errorMessage = "Add page content or a title before refreshing LCC metadata."
            return
        }
        let targetID = note.id, ticket = generation
        generatingPageLCC = true
        Task {
            defer { if generation == ticket { generatingPageLCC = false } }
            do {
                guard let lcc = try await OnDeviceSummary().lccCode(input), !lcc.isEmpty else {
                    throw VaultError.unavailable("Could not determine an LCC class code for this page.")
                }
                guard generation == ticket, currentNote?.id == targetID, !editingLocked else { return }
                lccInput = lcc
                currentNote?.lcc = lcc
                if let i = notes.firstIndex(where: { $0.id == targetID }) { notes[i].lcc = lcc }
                await persistPageLCC(pageID: targetID, lcc: lcc, ticket: ticket)
            } catch { if generation == ticket { errorMessage = "LCC refresh: " + error.localizedDescription } }
        }
    }
    func updateSourceLCC(_ source: SourceRecord, lcc: String) {
        guard !downloadingSources.contains(source.id) else { return }
        let trimmed = lcc.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = trimmed.isEmpty ? nil : trimmed
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].metadata.lcc = normalizedValue
        }
        if currentSource?.id == source.id {
            currentSource?.metadata.lcc = normalizedValue
        }
        sourceLCCSaveTasks[source.id]?.cancel()
        let ticket = generation
        sourceLCCSaveTasks[source.id] = Task {
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard generation == ticket, let repository else { return }
            do {
                let updated = try await repository.updateSourceLCC(source, lcc: normalizedValue)
                guard generation == ticket else { return }
                if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i] = updated }
                if currentSource?.id == source.id { currentSource = updated }
                if let index { var entries = ScanBatch(); entries.notes = notes; entries.sources = sources; try await index.reconcile(entries) }
            } catch { if generation == ticket { errorMessage = error.localizedDescription } }
        }
    }
    func refreshSourceLCC(_ source: SourceRecord) {
        guard !downloadingSources.contains(source.id), !generatingSourceLCCs.contains(source.id),
              let repository, let root else { return }
        if let reason = OnDeviceSummary.unavailabilityReason { errorMessage = reason; return }
        let ticket = generation
        generatingSourceLCCs.insert(source.id)
        Task {
            defer { if generation == ticket { generatingSourceLCCs.remove(source.id) } }
            do {
                let text = try await sourceSummaryContent(source, root: root)
                guard generation == ticket else { return }
                let input = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source.title : String(text.prefix(6000))
                guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VaultError.unavailable("No readable text for LCC classification.")
                }
                guard let lcc = try await OnDeviceSummary().lccCode(input), !lcc.isEmpty else {
                    throw VaultError.unavailable("Could not determine an LCC class code for this source.")
                }
                guard generation == ticket else { return }
                let current = sources.first(where: { $0.id == source.id }) ?? source
                let updated = try await repository.updateSourceLCC(current, lcc: lcc)
                guard generation == ticket else { return }
                if let i = sources.firstIndex(where: { $0.id == source.id }) { sources[i] = updated }
                if currentSource?.id == source.id { currentSource = updated }
                await refresh()
            } catch { if generation == ticket { errorMessage = "Source LCC: " + error.localizedDescription } }
        }
    }
    func openBlockURL(_ url: URL) {
        guard url.scheme == "noema", url.host == "page", let noteID = UUID(uuidString: url.lastPathComponent),
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "block" })?.value, let blockID = UUID(uuidString: value) else { return }
        guard root != nil, !busy else { pendingBlockURL = url; return }
        Task {
            await waitForSave()
            if !(await finishCurrentPage()) { return }
            guard let note = notes.first(where: { $0.id == noteID }), BlockDocumentCodec.decode(note.body).block(blockID) != nil else { errorMessage = "This block link is not available in the open vault."; return }
            autosaveTask?.cancel(); selectedID = noteID; currentSource = nil; apply(note); reading = true
            editorAction = EditorAction(operation: .block(blockID)); await updateBacklinks()
        }
    }
    var editingLocked: Bool { currentNote?.isEditingLocked == true || editorReadOnly }
    func beginEditing() {
        guard currentNote != nil else { return }
        guard !editingLocked else {
            editingHint = editorReadOnly ? "This article is read-only." : "Article locked. Unlock it to edit."
            return
        }
        editingHint = nil; reading = false
    }
    func finishEditing() { wikiQuery = nil; editorAction = nil; savePage(); reading = true }
    var updatingSourceReferences = false
    func setSourceReference(pageID: UUID, sourceID: UUID, linked: Bool) {
        guard !updatingSourceReferences else { return }
        updatingSourceReferences = true
        let ticket = generation
        Task {
            defer { updatingSourceReferences = false }
            if currentNote?.id == pageID, !(await saveCurrent()) { return }
            guard generation == ticket, let repository,
                  let note = notes.first(where: { $0.id == pageID }), !note.isEditingLocked,
                  !(currentNote?.id == pageID && editorReadOnly) else { return }
            saving = true
            defer { saving = false }
            do {
                let saved = try await repository.setSourceReference(note: note, sourceID: sourceID, linked: linked)
                guard generation == ticket else { return }
                if let i = notes.firstIndex(where: { $0.id == pageID }) { notes[i] = saved }
                if currentNote?.id == pageID { currentNote = saved }
                scheduleRefresh()
            } catch { if generation == ticket { errorMessage = error.localizedDescription } }
        }
    }
    func toggleEditingLock(_ id: UUID? = nil, preservingSidebarPosition: Bool = false) {
        guard let targetID = id ?? currentNote?.id else { return }
        if preservingSidebarPosition {
            guard notes.contains(where: { $0.id == targetID }),
                  sidebarLockSortDates[targetID] == nil else { return }
            holdSidebarPosition(targetID)
        }
        Task {
            var succeeded = false
            defer { if preservingSidebarPosition && !succeeded { finishSidebarLockFeedback(targetID, showMoveFeedback: false) } }

            if currentNote?.id == targetID, !(await saveCurrent()) { return }
            guard var note = notes.first(where: { $0.id == targetID }), let repository else { return }
            note.editingLocked = !note.isEditingLocked
            do {
                let saved = try await repository.save(note: note, title: note.title, body: note.body, tags: note.tags)
                if currentNote?.id == saved.id { apply(saved); reading = true }
                if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
                succeeded = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func edited() {
        guard !editingLocked else { return }
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
        guard dirty, var note = currentNote, let repository, let recovery else { return !saving }
        guard !saving else { return false }
        saving = true; saveStatus = "Saving…"
        let trimmedLCC = lccInput.trimmingCharacters(in: .whitespacesAndNewlines)
        note.lcc = trimmedLCC.isEmpty ? nil : trimmedLCC
        let draft = DraftRecord(note: note, title: title, body: body, tags: editedTags)
        do {
            wordCount = await Task.detached { BlockDocumentCodec.markdownBody(draft.body).split(whereSeparator: \.isWhitespace).count }.value
            try await recovery.store(draft)
            let saved = try await repository.save(note: note, title: draft.title, body: draft.body, tags: draft.tags)
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
            recoveredDrafts = try await recovery.drafts(); errorMessage = nil; externalChange = false
            saving = false
            scheduleRefresh()
            if dirty { edited() }
            return !dirty
        } catch {
            saving = false; saveStatus = "Draft preserved · save failed"
            errorMessage = error.localizedDescription
            if case VaultError.conflict = error { externalChange = true }
            recoveredDrafts = (try? await recovery.drafts()) ?? []
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
        guard needsTitle, let note = currentNote, let repository,
              titleTasks[note.id] == nil, !editingLocked, !externalChange,
              OnDeviceSummary.unavailabilityReason == nil else { return }
        let capturedGeneration = generation
        let content = BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(note.body).withoutAISummary))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        titleTasks[note.id] = Task { [self] in
            defer { titleTasks.removeValue(forKey: note.id) }
            do {
                let generator = OnDeviceSummary()
                async let generatedTitle = generator.pageTitle(content)
                async let generatedLCC = generator.inferLCC(content)
                let (generated, lcc) = try await (generatedTitle, generatedLCC)
                guard let generated else { return }
                await waitForSave()
                guard generation == capturedGeneration, untitledPages[note.id] == note.title,
                      editorAllowsGeneratedTitle(for: note) else { return }
                saving = true
                defer { saving = false }
                var updatedNote = note
                if let lcc, !lcc.isEmpty { updatedNote.lcc = lcc }
                // The repository rejects stale edits, deleted pages, and newly locked pages.
                let saved = try await repository.save(note: updatedNote, title: generated, body: note.body, tags: note.tags)
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
    func prepareUntitledPageForNaming() {
        guard let note = currentNote, !editingLocked else { return }
        let candidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty || candidate.range(of: #"^Untitled(?: [0-9]+)?$"#, options: .regularExpression) != nil else { return }
        untitledPages[note.id] = candidate.isEmpty ? note.title : title
    }
    func savePage() {
        prepareUntitledPageForNaming()
        saveNow()
    }
    func saveNow() { autosaveTask?.cancel(); Task { _ = await finishCurrentPage() } }
    func generatePreview() {
        previewTask?.cancel(); let captured = body
        previewTask = Task {
            let (blocks, count) = await Task.detached { (MarkdownService.preview(captured), BlockDocumentCodec.markdownBody(captured).split(whereSeparator: \.isWhitespace).count) }.value
            guard !Task.isCancelled, body == captured else { return }
            preview = blocks; wordCount = count
        }
    }
    private func updateTags() { tags = Array(Set(notes.flatMap(\.allTags))).sorted() }
    func createPageFromTopic(_ input: String) async -> Bool {
        let topic = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, topic.count <= 120, !generatingTopicPage, let repository else { return false }
        if let reason = OnDeviceSummary.unavailabilityReason { errorMessage = reason; return false }
        let ticket = generation
        generatingTopicPage = true; errorMessage = nil
        defer { if generation == ticket { generatingTopicPage = false } }
        do {
            guard await finishCurrentPage(), generation == ticket else { return false }
            let results = try await WebTopicResearch.research(topic)
            guard generation == ticket else { return false }
            let context = results.enumerated().map { offset, result in
                "[\(offset + 1)] " + result.title + "\n" + result.url.absoluteString + "\n" + result.text
            }.joined(separator: "\n\n")
            let generator = OnDeviceSummary()
            async let generatedArticle = generator.pageFromTopic(topic, context: context)
            async let generatedLCC = generator.inferLCC(OnDeviceSummary.topicPrompt(topic: topic, context: context))
            var article = try await generatedArticle
            let lcc = await generatedLCC
            article += "\n\n*AI-generated draft based on web results retrieved " + timestamp() + ".*"
            let references: [String] = results.enumerated().map { offset, result in
                let title = result.title.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                return "- [\(offset + 1)] [\(title)](<\(result.url.absoluteString)>)"
            }
            article += "\n\n## Web references\n\n" + references.joined(separator: "\n")
            guard generation == ticket, await finishCurrentPage(), generation == ticket else { return false }
            let note = try await repository.create(title: topic, body: article, lcc: lcc)
            guard generation == ticket else { return false }
            errorMessage = nil; searchText = ""; scope = .wiki; reading = false
            notes.insert(note, at: 0); selectedID = note.id; currentSource = nil; apply(note)
            await refresh()
            return generation == ticket
        } catch { if generation == ticket { errorMessage = "Create topic page: " + error.localizedDescription }; return false }
    }

    func newPage(template: Bool = false, named name: String = "Untitled") {
        Task {
            if !(await finishCurrentPage()) { return }
            guard let repository else { return }
            do {
                let body = template ? "## Overview\n\n\n## Personal context\n\nWhy does this matter to me?\n\n## Connections\n\n" : ""
                let note = try await repository.create(title: name, body: body)
                if name == "Untitled" { untitledPages[note.id] = note.title }
                errorMessage = nil
                notes.insert(note, at: 0); scope = .wiki; reading = false
                selectedID = note.id; currentSource = nil; apply(note)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func trashCurrent() { trashPage(currentNote?.id) }
    func trashPage(_ id: UUID?) {
        guard let id else { return }
        Task {
            if currentNote?.id == id, !(await saveCurrent()) { return }
            guard let note = notes.first(where: { $0.id == id }), let repository else { return }
            do {
                try await repository.trash(note: note)
                if currentNote?.id == id {
                    selectedID = nil; currentNote = nil; body = ""; externalChange = false
                }
                await refresh()
            } catch { errorMessage = error.localizedDescription }
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
        guard !trashOperationInProgress, !pages.isEmpty, let repository else { return }
        trashOperationInProgress = true; errorMessage = nil
        let ticket = generation
        Task {
            defer { if generation == ticket { trashOperationInProgress = false } }
            guard generation == ticket else { return }
            var failures: [String] = []
            if restoring {
                for page in pages {
                    guard generation == ticket else { return }
                    do { try await repository.restore(page) }
                    catch { failures.append("\(page.title): \(error.localizedDescription)") }
                }
            } else {
                failures = await repository.emptyTrashItems(pages)
            }
            guard generation == ticket else { return }
            do {
                let remaining = try await repository.trashItems()
                guard generation == ticket else { return }
                trashedPages = remaining
            } catch { failures.append("Could not reload Trash: " + error.localizedDescription) }
            await refresh()
            guard generation == ticket else { return }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        }
    }
    func reloadDiskVersion() {
        Task {
            if dirty, let note = currentNote, let recovery {
                try? await recovery.store(DraftRecord(note: note, title: title, body: body, tags: editedTags))
                recoveredDrafts = (try? await recovery.drafts()) ?? []
            }
            if let repository, let entries = try? await repository.scan(), let fresh = entries.notes.first(where: { $0.id == selectedID }) {
                apply(fresh); errorMessage = nil
            } else { errorMessage = "The original page is unavailable. You can save your draft as a new page." }
        }
    }
    func saveDraftAsNewPage(_ recovered: DraftRecord? = nil) {
        Task {
            guard let repository else { return }
            let originalID = recovered?.id ?? currentNote?.id
            do {
                var note = try await repository.create(title: (recovered?.title ?? title) + " (recovered)", body: recovered?.body ?? body)
                note = try await repository.save(note: note, title: note.title, body: note.body, tags: recovered?.tags ?? editedTags)
                if let originalID { try await recovery?.remove(originalID) }
                recoveredDrafts = (try? await recovery?.drafts()) ?? []
                notes.insert(note, at: 0); scope = .wiki; currentSource = nil; selectedID = note.id; apply(note)
                errorMessage = nil; showRecovery = false; await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func discardRecovery(_ draft: DraftRecord) {
        Task { do { try await recovery?.remove(draft.id); recoveredDrafts = (try? await recovery?.drafts()) ?? [] } catch { errorMessage = error.localizedDescription } }
    }
    private func updateBacklinks() async {
        guard let note = currentNote, let index else { backlinks = []; return }
        let ids = Set((try? await index.backlinks(to: note)) ?? [])
        backlinks = notes.filter { ids.contains($0.id) }.sorted { $0.title < $1.title }
    }
    func followWikiLink(_ target: String) {
        let key = normalized(target)
        let matches = notes.filter { normalized($0.title) == key || $0.aliases.contains(where: { normalized($0) == key }) }
        if matches.count == 1 { select(matches[0].id) }
        else if matches.isEmpty { unresolvedTarget = target }
        else { ambiguousMatches = matches }
    }
    func suggestLink(_ title: String) { guard !reading, !editingLocked else { return }; editorAction = EditorAction(operation: .wikiLink(title)); wikiQuery = nil }
    func format(_ prefix: String, _ suffix: String) { guard !reading, !editingLocked else { return }; editorAction = EditorAction(operation: .wrap(prefix, suffix)) }
    func importFiles() { addSource() }
    func linkSources() { addSource() }
    func addSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.prompt = "Add Source"
        panel.message = "Choose up to 5 files. Link by default, or import files up to 2 MB each."
        let importOption = NSButton(checkboxWithTitle: "Import into vault (maximum 2 MB per file)", target: nil, action: nil)
        importOption.state = .off; importOption.setFrameSize(NSSize(width: 380, height: 28))
        panel.accessoryView = importOption; panel.isAccessoryViewDisclosed = true
        presentPanel(panel) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard urls.count <= 5 else { self?.errorMessage = "Add up to 5 files at a time."; return }
            let shouldImport = importOption.state == .on
            Task { @MainActor in
                await self?.addSourceFiles(urls, shouldImport: shouldImport)
            }
        }
    }
    func addSourceFiles(
        _ urls: [URL],
        shouldImport: Bool,
        isCloudNotDownloaded: @escaping @Sendable (URL) -> Bool = FileVaultRepository.isCloudFileNotDownloaded,
        downloadCloudFile: @escaping @Sendable (URL) async throws -> Data = FileVaultRepository.downloadCloudFile
    ) async {
        guard urls.count <= 5 else { errorMessage = "Add up to 5 files at a time."; return }
        guard let repository else { return }
        guard await finishCurrentPage() else { return }
        scope = .sources
        let ticket = generation
        var failures: [String] = []
        for url in urls {
            do {
                guard generation == ticket else { return }
                if isCloudNotDownloaded(url) {
                    let pending = try await repository.beginSourceDownload(at: url, shouldImport: shouldImport)
                    guard generation == ticket else { return }
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
                        added = [try await repository.importSource(data: data, filename: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent, originURL: nil)]
                    } else {
                        added = try await repository.linkSources(at: url, maximumFiles: 5)
                    }
                } catch let error as VaultError {
                    if case .unavailable = error {
                        let pending = try await repository.beginSourceDownload(at: url, shouldImport: shouldImport)
                        guard generation == ticket else { return }
                        sources.append(pending)
                        rows = sources.map(LibraryRow.init(source:))
                        enqueueSourceDownload(pending, url: url, shouldImport: shouldImport, download: downloadCloudFile)
                        continue
                    }
                    throw error
                }
                guard generation == ticket else { return }
                sources.append(contentsOf: added)
                rows = sources.map(LibraryRow.init(source:))
                for source in added { enqueueSourceTitle(source) }
            } catch {
                failures.append(url.lastPathComponent + ": " + error.localizedDescription)
                errorMessage = failures.joined(separator: "\n")
            }
        }
        await refresh()
    }
    private func enqueueSourceDownload(
        _ source: SourceRecord,
        url: URL,
        shouldImport: Bool,
        download: @escaping @Sendable (URL) async throws -> Data
    ) {
        downloadingSources.insert(source.id)
        sourceDownloadQueue.append(PendingSourceDownload(source: source, url: url, shouldImport: shouldImport, download: download))
        guard sourceDownloadTask == nil, let repository else { return }
        let ticket = generation
        sourceDownloadTask = Task {
            defer {
                if generation == ticket {
                    sourceDownloadTask = nil
                    sourceDownloadQueue = []
                    downloadingSources = []
                }
            }
            while !sourceDownloadQueue.isEmpty {
                guard generation == ticket, !Task.isCancelled else { return }
                let item = sourceDownloadQueue.removeFirst()
                guard downloadingSources.contains(item.source.id) else { continue }
                do {
                    let access = item.url.startAccessingSecurityScopedResource()
                    defer { if access { item.url.stopAccessingSecurityScopedResource() } }
                    let data = try await item.download(item.url)
                    guard generation == ticket, downloadingSources.contains(item.source.id) else { continue }
                    let completed = try await repository.completeSourceDownload(
                        id: item.source.id,
                        at: item.url,
                        data: data,
                        shouldImport: item.shouldImport
                    )
                    guard generation == ticket else { return }
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
                    guard generation == ticket else { return }
                    downloadingSources.remove(item.source.id)
                    sources.removeAll { $0.id == item.source.id }
                    errorMessage = item.url.lastPathComponent + ": " + error.localizedDescription
                    await refresh()
                }
            }
        }
    }
    func addURLSources(_ text: String) async -> [String] {
        guard let repository, await finishCurrentPage() else { return ["Open a vault and finish saving before adding sources."] }
        let lines: [String]
        do { lines = try WebSourceFetcher.lines(text) } catch { return [error.localizedDescription] }
        let ticket = generation
        scope = .sources
        var failures: [String] = []
        for address in lines {
            guard generation == ticket else { return failures + ["Vault changed; remaining URLs were not added."] }
            do {
                let source = try await repository.importURLSource(address)
                guard generation == ticket else { return failures }
                sources.append(source); rows = sources.map(LibraryRow.init(source:))
                enqueueSourceTitle(source)
            } catch { failures.append(address + ": " + error.localizedDescription) }
        }
        if generation == ticket { await refresh() }
        return failures
    }
    func availabilityLabel(_ id: UUID) -> String {
        if downloadingSources.contains(id) { return "Downloading from iCloud" }
        return sourceAvailability[id] ?? sources.first(where: { $0.id == id })?.availabilityIssue ?? "Available"
    }
    func checkSourceAvailability(_ requested: [SourceRecord]) {
        guard let root else { return }
        for source in requested where !checkingSourceAvailability.contains(source.id) && !downloadingSources.contains(source.id) {
            checkingSourceAvailability.insert(source.id); sourceAvailabilityQueue.append(source)
        }
        guard sourceAvailabilityTask == nil, !sourceAvailabilityQueue.isEmpty else { return }
        let ticket = generation
        sourceAvailabilityTask = Task {
            defer { if generation == ticket { sourceAvailabilityTask = nil; checkingSourceAvailability = []; sourceAvailabilityQueue = [] } }
            while !sourceAvailabilityQueue.isEmpty {
                guard generation == ticket, !Task.isCancelled else { return }
                let source = sourceAvailabilityQueue.removeFirst()
                let status: String
                if source.metadata.isURLSource == true, let repository {
                    do { status = try await repository.checkURLSourceAvailability(source) }
                    catch { status = "Availability check: " + error.localizedDescription }
                } else {
                    status = await Task.detached { FileVaultRepository.checkSourceAvailability(source, root: root) }.value
                }
                guard generation == ticket else { return }
                if sources.contains(where: { $0.id == source.id }) { sourceAvailability[source.id] = status }
                checkingSourceAvailability.remove(source.id)
            }
        }
    }
    private func sourceSummaryContent(_ source: SourceRecord, root: URL) async throws -> String {
        return try await Task.detached {
            if !source.body.isEmpty {
                let ext = URL(fileURLWithPath: source.metadata.originalFilename).pathExtension.lowercased()
                let content = ["html", "htm"].contains(ext) ? source.body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression) : source.body
                return BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(content).withoutAISummary))
            }
            let url = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased()).appendingPathComponent(source.metadata.storedFilename)
            let data = try source.metadata.linkedBookmark.map(FileVaultRepository.readLinkedSource) ?? FileVaultRepository.coordinatedRead(url)
            if source.metadata.originalFilename.lowercased().hasSuffix(".pdf"), let pdf = PDFDocument(data: data) { return pdf.string ?? "" }
            return ""
        }.value
    }
    func createPageFromSource(_ source: SourceRecord) {
        guard !downloadingSources.contains(source.id), !generatingSourcePages.contains(source.id), let repository, let root else { return }
        if let reason = OnDeviceSummary.unavailabilityReason { errorMessage = reason; return }
        let ticket = generation
        generatingSourcePages.insert(source.id)
        Task {
            defer { if generation == ticket { generatingSourcePages.remove(source.id) } }
            do {
                let text = try await sourceSummaryContent(source, root: root)
                guard generation == ticket else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VaultError.unavailable("No readable text for a wiki page.")
                }
                let generator = OnDeviceSummary()
                let article = try await generator.pageFromSource(text)
                async let generatedTitle = generator.pageTitle(article)
                async let generatedLCC = generator.inferLCC(article)
                let pageTitle = (try await generatedTitle) ?? source.title
                let lcc = (await generatedLCC) ?? source.metadata.lcc
                guard generation == ticket, await finishCurrentPage(), generation == ticket else { return }
                let note = try await repository.create(title: pageTitle, body: article, source: source, lcc: lcc)
                guard generation == ticket else { return }
                errorMessage = nil; searchText = ""; scope = .wiki; reading = false
                notes.insert(note, at: 0); selectedID = note.id; currentSource = nil; apply(note)
                await refresh()
            } catch { if generation == ticket { errorMessage = "Create page: " + error.localizedDescription } }
        }
    }

    func generateSourceSummary(_ source: SourceRecord) {
        guard !downloadingSources.contains(source.id), !generatingSourceTitles.contains(source.id), !generatingSourceSummaries.contains(source.id),
              let repository, let root else { return }
        if let reason = OnDeviceSummary.unavailabilityReason { errorMessage = reason; return }
        let ticket = generation
        generatingSourceSummaries.insert(source.id)
        Task {
            defer { if generation == ticket { generatingSourceSummaries.remove(source.id) } }
            do {
                let text = try await sourceSummaryContent(source, root: root)
                guard generation == ticket else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VaultError.unavailable("No readable text for an AI summary.")
                }
                let excerpt = String(text.prefix(6000))
                let generator = OnDeviceSummary()
                async let generatedSummary = generator.summarize(excerpt)
                async let generatedLCC = generator.inferLCC(excerpt)
                let (summary, lcc) = try await (generatedSummary, generatedLCC)
                guard generation == ticket else { return }
                _ = try await repository.renameSource(source, title: source.title, summary: summary, lcc: lcc)
                guard generation == ticket else { return }
                await refresh()
            } catch { if generation == ticket { errorMessage = "Source summary: " + error.localizedDescription } }
        }
    }
    private func enqueueSourceTitle(_ source: SourceRecord) {
        if sourceNamingTask == nil { sourceRenameCompleted = 0; sourceRenameTotal = 0 }
        sourceNamingQueue.append(source); generatingSourceTitles.insert(source.id); sourceRenameTotal += 1
        guard sourceNamingTask == nil, let repository, let root else { return }
        let ticket = generation
        sourceNamingTask = Task {
            defer {
                if generation == ticket { sourceNamingTask = nil; sourceNamingQueue = []; generatingSourceTitles = []; sourceRenameCompleted = 0; sourceRenameTotal = 0 }
            }
            while !sourceNamingQueue.isEmpty {
                guard generation == ticket else { return }
                let source = sourceNamingQueue.removeFirst()
                if sourceNamingOverrides.contains(source.id) {
                    generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1; continue
                }
                do {
                    if let reason = OnDeviceSummary.unavailabilityReason { throw VaultError.unavailable(reason) }
                    let text = try await sourceSummaryContent(source, root: root)
                    guard generation == ticket else { return }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.unavailable("No readable text for automatic naming and summary. Original file name retained.") }
                    let excerpt = String(text.prefix(6000))
                    let generator = OnDeviceSummary()
                    async let generatedTitle = generator.pageTitle(text)
                    async let generatedSummary = generator.summarize(excerpt)
                    async let generatedLCC = generator.inferLCC(excerpt)
                    let (titleResult, summary, lcc) = try await (generatedTitle, generatedSummary, generatedLCC)
                    guard let title = titleResult else { throw VaultError.unavailable("No valid topic title was generated. Original file name retained.") }
                    guard generation == ticket else { return }
                    if sourceNamingOverrides.contains(source.id) {
                        generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1; continue
                    }
                    let renamed = try await repository.renameSource(source, title: title, summary: summary, lcc: lcc)
                    guard generation == ticket else { return }
                    if let position = sources.firstIndex(where: { $0.id == source.id }) { sources[position] = renamed }
                    if let index { var entries = ScanBatch(); entries.notes = notes; entries.sources = sources; try await index.reconcile(entries) }
                    await updateRows()
                } catch { if generation == ticket { errorMessage = "Source naming: " + error.localizedDescription } }
                generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1
            }
        }
    }
    func renameSource(_ source: SourceRecord, title: String) {
        sourceNamingOverrides.insert(source.id); generatingSourceTitles.remove(source.id)
        Task {
            guard let repository else { return }
            let ticket = generation
            do {
                let renamed = try await repository.renameSource(source, title: title)
                guard generation == ticket else { return }
                SourceReader.updateTitle(id: source.id, title: renamed.title)
                await refresh()
            } catch { if generation == ticket { errorMessage = error.localizedDescription } }
        }
    }
    func deleteSource(_ source: SourceRecord) {
        sourceNamingOverrides.insert(source.id); generatingSourceTitles.remove(source.id)
        downloadingSources.remove(source.id)
        sourceDownloadQueue.removeAll { $0.source.id == source.id }
        Task {
            guard let repository else { return }
            let ticket = generation
            do {
                try await repository.deleteSource(source)
                guard generation == ticket else { return }
                SourceReader.close(id: source.id)
                await refresh()
            } catch { if generation == ticket { errorMessage = error.localizedDescription } }
        }
    }
    func openSource(_ id: UUID?) {
        Task {
            await waitForSave()
            guard await finishCurrentPage() else { return }
            guard let id, !downloadingSources.contains(id), let source = sources.first(where: { $0.id == id }), let root else { return }
            do { try await SourceReader.open(source, root: root) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func pasteSource(title: String, text: String, originURL: String) async -> Bool {
        guard let repository else { return false }
        do {
            let source = try await repository.importSource(data: Data(text.utf8), filename: "pasted.txt", title: title, originURL: originURL)
            scope = .sources; await refresh(); select(source.id); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func revealVault() { if let root { NSWorkspace.shared.open(root) } }
}
