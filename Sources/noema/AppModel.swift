import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VaultCore

enum LibraryScope: Hashable { case wiki, sources, trash, tag(String) }
struct LibraryRow: Identifiable {
    var id: UUID
    var title: String
    var excerpt: String
    var tags: [String]
    var kind: EntryKind
    var updatedAt: Date?
    var hasAISummary = false

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
    var trashedPages: [TrashedPage] = []
    var rows: [LibraryRow] = []
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
        switch scope { case .wiki: "Pages"; case .sources: "Sources"; case .trash: "Trash"; case .tag(let tag): "#" + tag }
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
            notes = result.notes; sources = result.sources; issues = result.issues
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
    func select(_ id: UUID?) {
        Task {
            await waitForSave()
            if !(await finishCurrentPage()) { return }
            autosaveTask?.cancel(); wikiQuery = nil; editorAction = nil
            selectedID = id; currentSource = nil; currentNote = nil; externalChange = false; errorMessage = nil
            reading = true
            if let note = notes.first(where: { $0.id == id }) { apply(note) }
            else if let source = sources.first(where: { $0.id == id }) {
                currentSource = source; title = source.title; body = source.body; reading = true
                generatePreview(); backlinks = []
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
    func importFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = "Import Sources"
        presentPanel(panel) { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self, let repository = self.repository else { return }
                for url in panel.urls {
                    let access = url.startAccessingSecurityScopedResource()
                    do {
                        let data = try await Task.detached { try FileVaultRepository.coordinatedRead(url) }.value
                        _ = try await repository.importSource(data: data, filename: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent, originURL: nil)
                    } catch { self.errorMessage = error.localizedDescription }
                    if access { url.stopAccessingSecurityScopedResource() }
                }
                self.scope = .sources; await self.refresh()
            }
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
