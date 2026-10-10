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
struct LibraryRow: Identifiable {
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

    private static func date(_ value: String) -> Date? {
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
    var sourceAvailability: [UUID: String] = [:]
    var checkingSourceAvailability: Set<UUID> = []
    private var sourceAvailabilityQueue: [SourceRecord] = []
    private var sourceAvailabilityTask: Task<Void, Never>?
    var generatingSourceSummaries: Set<UUID> = []
    var generatingSourceTitles: Set<UUID> = []
    var sourceRenameCompleted = 0
    var sourceRenameTotal = 0
    private var sourceNamingOverrides: Set<UUID> = []
    private var sourceNamingQueue: [SourceRecord] = []
    private var sourceNamingTask: Task<Void, Never>?

    var trashedPages: [TrashedPage] = []
    var rows: [LibraryRow] = []
    var semanticRows: [SemanticBlockHit] = []
    var selectedSemanticID: String?
    var tags: [String] = []
    var wordCount = 0
    var scope: LibraryScope = .wiki
    var searchText = ""
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
                let summary = try await OnDeviceSummary().summarize(content)
                guard currentNote?.id == capturedID, generation == capturedGeneration else { return }
                guard body == capturedBody, !editingLocked, !externalChange,
                      UserDefaults.standard.bool(forKey: EditorPreferences.aiSummariesKey) else {
                    aiSummaryNotice = "The page changed during generation. Generate the summary again."; return
                }
                guard !summary.isEmpty else { aiSummaryNotice = "No summary was returned. Try again."; return }
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
            sourceNamingTask?.cancel(); sourceNamingTask = nil; sourceNamingQueue = []
            sourceAvailabilityTask?.cancel(); sourceAvailabilityTask = nil; sourceAvailabilityQueue = []
            sourceAvailability = [:]; checkingSourceAvailability = []
            generatingSourceSummaries = []
            generatingSourceTitles = []; sourceRenameCompleted = 0; sourceRenameTotal = 0
            dismissedVaultNotices = []
            generation = UUID(); repository = repo; index = searchIndex; recovery = journal
            unseenRenamedPages.removeAll()
            root = url; vaultName = url.lastPathComponent; scope = .wiki; searchText = ""
            selectedID = nil; currentNote = nil; currentSource = nil; externalChange = false
            let cached = try await searchIndex.cachedEntries()
            notes = cached.notes; sources = cached.sources; trashedPages = []
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
            trashedPages = try await repository.trashedPages()
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
        Task { if await finishCurrentPage() { self.scope = scope; queryChanged() } }
    }
    private func updateRows() async {
        if scope == .semantic {
            let query = searchText, ticket = generation
            var snapshot = notes
            if let currentNote, let i = snapshot.firstIndex(where: { $0.id == currentNote.id }) {
                snapshot[i].body = body; snapshot[i].title = title
            }
            let capturedNotes = snapshot
            let hits = await Task.detached { SemanticBlockHit.search(capturedNotes, query: query) }.value
            guard scope == .semantic, searchText == query, generation == ticket, !Task.isCancelled else { return }
            semanticRows = hits
            return
        }
        guard let index else { return }
        let capturedScope = scope, capturedQuery = searchText
        let kind: EntryKind = scope == .sources ? .source : .wiki
        let tag: String? = { if case .tag(let tag) = scope { return tag }; return nil }()
        do {
            let hits = try await index.search(capturedQuery, kind: kind, tag: tag)
            guard capturedScope == scope, capturedQuery == searchText else { return }
            let noteMap = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = hits.compactMap { hit in
                if hit.kind == .wiki, let note = noteMap[hit.id] { return LibraryRow(note: note) }
                if let source = sourceMap[hit.id] { return LibraryRow(source: source) }
                return nil
            }
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
    private func apply(_ note: NoteRecord) {
        markPageViewed(note.id)
        editingHint = nil
        aiSummaryNotice = nil
        editorAction = nil
        currentNote = note; title = note.title; body = note.body; tagInput = note.tags.joined(separator: ", ")
        let document = BlockDocumentCodec.decode(note.body)
        editorReadOnly = document.unsupportedVersion
        editorNotice = document.unsupportedVersion ? "This page uses a newer block format and is read-only. Its original content is preserved." : document.recoveredMetadata != nil ? "External Markdown changed. The earlier editor metadata was preserved for recovery; external text is shown." : nil
        externalChange = false; saveStatus = "Saved locally"; generatePreview()
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
    func toggleEditingLock(_ id: UUID? = nil) {
        guard let targetID = id ?? currentNote?.id else { return }
        Task {
            if currentNote?.id == targetID, !(await saveCurrent()) { return }
            guard var note = notes.first(where: { $0.id == targetID }), let repository else { return }
            note.editingLocked = !note.isEditingLocked
            do {
                let saved = try await repository.save(note: note, title: note.title, body: note.body, tags: note.tags)
                if currentNote?.id == saved.id { apply(saved); reading = true }
                if let i = notes.firstIndex(where: { $0.id == saved.id }) { notes[i] = saved }
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
        guard dirty, let note = currentNote, let repository, let recovery else { return !saving }
        guard !saving else { return false }
        saving = true; saveStatus = "Saving…"
        let draft = DraftRecord(note: note, title: title, body: body, tags: editedTags)
        do {
            wordCount = await Task.detached { BlockDocumentCodec.markdownBody(draft.body).split(whereSeparator: \.isWhitespace).count }.value
            try await recovery.store(draft)
            let saved = try await repository.save(note: note, title: draft.title, body: draft.body, tags: draft.tags)
            recordPageRename(saved.id, from: note.title, to: saved.title)
            if currentNote?.id == saved.id {
                currentNote = saved
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
                guard let generated = try await OnDeviceSummary().pageTitle(content) else { return }
                await waitForSave()
                guard generation == capturedGeneration, untitledPages[note.id] == note.title,
                      editorAllowsGeneratedTitle(for: note) else { return }
                saving = true
                defer { saving = false }
                // The repository rejects stale edits, deleted pages, and newly locked pages.
                let saved = try await repository.save(note: note, title: generated, body: note.body, tags: note.tags)
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
    func restoreTrashedPage(_ page: TrashedPage) {
        Task {
            guard let repository else { return }
            do { try await repository.restore(page); await refresh() }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func permanentlyDeleteTrashedPage(_ page: TrashedPage) {
        Task {
            guard let repository else { return }
            do { try await repository.permanentlyDelete(page); await refresh() }
            catch { errorMessage = error.localizedDescription }
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
                guard let self, let repository = self.repository else { return }
                guard await self.finishCurrentPage() else { return }
                self.scope = .sources
                let ticket = self.generation
                var failures: [String] = []
                for url in urls {
                do {
                    guard self.generation == ticket else { return }
                    let added: [SourceRecord]
                    if shouldImport {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
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
                    guard self.generation == ticket else { return }
                    self.sources.append(contentsOf: added)
                    self.rows = self.sources.map(LibraryRow.init(source:))
                    for source in added { self.enqueueSourceTitle(source) }
                } catch {
                    failures.append(url.lastPathComponent + ": " + error.localizedDescription)
                    self.errorMessage = failures.joined(separator: "\n")
                }
                }
                await self.refresh()
            }
        }
    }
    func availabilityLabel(_ id: UUID) -> String {
        sourceAvailability[id] ?? sources.first(where: { $0.id == id })?.availabilityIssue ?? "Available"
    }
    func checkSourceAvailability(_ requested: [SourceRecord]) {
        guard let root else { return }
        for source in requested where !checkingSourceAvailability.contains(source.id) {
            checkingSourceAvailability.insert(source.id); sourceAvailabilityQueue.append(source)
        }
        guard sourceAvailabilityTask == nil, !sourceAvailabilityQueue.isEmpty else { return }
        let ticket = generation
        sourceAvailabilityTask = Task {
            defer { if generation == ticket { sourceAvailabilityTask = nil; checkingSourceAvailability = []; sourceAvailabilityQueue = [] } }
            while !sourceAvailabilityQueue.isEmpty {
                guard generation == ticket, !Task.isCancelled else { return }
                let source = sourceAvailabilityQueue.removeFirst()
                let status = await Task.detached { FileVaultRepository.checkSourceAvailability(source, root: root) }.value
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
    func generateSourceSummary(_ source: SourceRecord) {
        guard !generatingSourceTitles.contains(source.id), !generatingSourceSummaries.contains(source.id),
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
                let summary = try await OnDeviceSummary().summarize(String(text.prefix(6000)))
                guard generation == ticket else { return }
                _ = try await repository.renameSource(source, title: source.title, summary: summary)
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
                    async let generatedTitle = OnDeviceSummary().pageTitle(text)
                    async let generatedSummary = OnDeviceSummary().summarize(String(text.prefix(6000)))
                    let (titleResult, summary) = try await (generatedTitle, generatedSummary)
                    guard let title = titleResult else { throw VaultError.unavailable("No valid topic title was generated. Original file name retained.") }
                    guard generation == ticket else { return }
                    if sourceNamingOverrides.contains(source.id) {
                        generatingSourceTitles.remove(source.id); sourceRenameCompleted += 1; continue
                    }
                    let renamed = try await repository.renameSource(source, title: title, summary: summary)
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
            guard let id, let source = sources.first(where: { $0.id == id }), let root else { return }
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
