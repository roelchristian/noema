import Foundation
import Testing
@testable import VaultCore

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VaultTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func lccMetadataRoundTripOnNotesAndSources() async throws {
    let id = UUID()
    let input = Data("---\nid: \(id.uuidString)\ntitle: Pertinax\nlcc: DG299\ntags: [history]\n---\nBody\n".utf8)
    var note = try NoteCodec.decode(input, path: "Wiki/Pertinax.md", vaultID: UUID())
    #expect(note.lcc == "DG299")
    note.lcc = "DG270"
    let encoded = try NoteCodec.encode(note)
    let decoded = try NoteCodec.decode(encoded, path: "Wiki/Pertinax.md", vaultID: UUID())
    #expect(decoded.lcc == "DG270")

    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    var source = try await repo.importSource(data: Data(" Ruth text ".utf8), filename: "ruth.txt", title: "Ruth", originURL: nil)
    let metaURL = folder.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/metadata.json")
    var meta = try JSONDecoder().decode(SourceMetadata.self, from: Data(contentsOf: metaURL))
    meta.lcc = "BS1315"
    try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    let scanned = try await repo.scan()
    source = try #require(scanned.sources.first)
    #expect(source.metadata.lcc == "BS1315")
    let createdPage = try await repo.create(title: "Ruth Notes", body: "Notes", source: source)
    #expect(createdPage.lcc == "BS1315")

    let demoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Examples/Demo Vault")
    let demoWikiFiles = try FileManager.default.contentsOfDirectory(at: demoRoot.appendingPathComponent("Wiki"), includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "md" }
    #expect(!demoWikiFiles.isEmpty)
    for fileURL in demoWikiFiles {
        let note = try NoteCodec.decode(Data(contentsOf: fileURL), path: "Wiki/" + fileURL.lastPathComponent, vaultID: UUID())
        #expect(note.lcc?.isEmpty == false, "Expected non-empty lcc for \(fileURL.lastPathComponent)")
    }
    let demoSourceDirs = try FileManager.default.contentsOfDirectory(at: demoRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: [.isDirectoryKey])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    #expect(!demoSourceDirs.isEmpty)
    for dirURL in demoSourceDirs {
        let metadataURL = dirURL.appendingPathComponent("metadata.json")
        let metadata = try JSONDecoder().decode(SourceMetadata.self, from: Data(contentsOf: metadataURL))
        #expect(metadata.lcc?.isEmpty == false, "Expected non-empty lcc for source \(metadata.title)")
    }
}

@Test func conflictsPreserveBothVersionsAndTrashRejectsStaleData() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Conflict", body: "Original")
    let url = folder.appendingPathComponent(note.relativePath)
    var external = note; external.body = "External edit"
    let diskData = try NoteCodec.encode(external); try diskData.write(to: url, options: .atomic)
    await #expect(throws: (any Error).self) { try await repo.save(note: note, title: note.title, body: "My unsaved edit", tags: []) }
    #expect(try Data(contentsOf: url) == diskData)
    let copies = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Conflicts"), includingPropertiesForKeys: nil)
    #expect(copies.count == 1)
    #expect(try String(contentsOf: copies[0], encoding: .utf8).contains("My unsaved edit"))
    await #expect(throws: (any Error).self) { try await repo.trash(note: note) }
    let fresh = try await repo.scan().notes[0]
    try await repo.trash(note: fresh)
    #expect(try await repo.scan().notes.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func searchBacklinksAndRebuild() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let target = try await repo.create(title: "Pertinax", body: "Historical facts, and what leadership means to me.")
    let renamed = try await repo.save(note: target, title: "My Pertinax page", body: target.body, tags: ["history"])
    let related = try await repo.create(title: "Leadership", body: "I connect [[Pertinax]] with trust. #history")
    _ = try await repo.importSource(data: Data("A raw account of Pertinax".utf8), filename: "history.txt", title: "Raw history", originURL: nil)
    let entries = try await repo.scan()
    let index = try SQLiteSearchIndex(url: folder.appendingPathComponent("Local/index.sqlite"))
    try await index.reconcile(entries)
    #expect(try await index.search("Pertinax", kind: .wiki, tag: "history").count == 2)
    #expect(try await index.search("Pertinax", kind: .source, tag: nil).count == 1)
    #expect(try await index.backlinks(to: renamed) == [related.id])
    #expect(try await index.cachedEntries().notes.count == 2)
    let reopened = try SQLiteSearchIndex(url: folder.appendingPathComponent("Local/index.sqlite"))
    #expect(try await reopened.cachedEntries().notes.count == 2)
    #expect(try await reopened.search("Pertinax", kind: .wiki, tag: "history").count == 2)
    // Treat punctuation as literal user text, never arbitrary FTS query syntax.
    _ = try await index.search("\" OR )", kind: .wiki, tag: nil)
    let rebuilt = try SQLiteSearchIndex(url: folder.appendingPathComponent("Rebuilt/index.sqlite"))
    try await rebuilt.reconcile(entries)
    #expect(try await rebuilt.search("trust", kind: .wiki, tag: nil).first?.id == related.id)
    try await repo.trash(note: related)
    try await index.reconcile(repo.scan())
    #expect(try await index.backlinks(to: renamed).isEmpty)
}

@Test func draftsSurviveStoreRecreationAndSaveFailures() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Draft", body: "Original")
    let journalURL = folder.appendingPathComponent("LocalDrafts")
    let journal = try RecoveryStore(unguardedTestingDirectory: journalURL)
    try await journal.store(DraftRecord(note: note, title: note.title, body: "Recover me", tags: []))
    // A directory in place of the file reliably simulates a failed disk save.
    try FileManager.default.removeItem(at: folder.appendingPathComponent(note.relativePath))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(note.relativePath), withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await repo.save(note: note, title: note.title, body: "Recover me", tags: []) }
    let reopened = try RecoveryStore(unguardedTestingDirectory: journalURL)
    #expect(try await reopened.drafts().first?.body == "Recover me")
    try await reopened.remove(note.id)
    #expect(try await reopened.drafts().isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"))
func benchmarkFiveThousandEntries() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    for i in 0..<5000 {
        let path = "Wiki/Page \(i).md"
        var note = try NoteCodec.decode(Data("## Personal context\n\nKnowledge about leadership and history, entry \(i). [[Page 1]] #history\n".utf8), path: path, vaultID: repo.manifest.id)
        note.createdAt = timestamp(); note.updatedAt = timestamp()
        try NoteCodec.encode(note).write(to: folder.appendingPathComponent(path))
    }
    let clock = ContinuousClock()
    var start = clock.now
    let entries = try await repo.scan()
    print("BENCH initial scan: \(start.duration(to: clock.now))")
    let indexURL = folder.appendingPathComponent("Local/search.sqlite")
    let index = try SQLiteSearchIndex(url: indexURL)
    start = clock.now; try await index.reconcile(entries)
    print("BENCH initial index: \(start.duration(to: clock.now))")
    let cachedIndex = try SQLiteSearchIndex(url: indexURL)
    start = clock.now; let cached = try await cachedIndex.cachedEntries()
    let cacheTime = start.duration(to: clock.now)
    print("BENCH cached load of \(cached.notes.count) pages: \(cacheTime)")
    #expect(cacheTime < .seconds(2))
    var times: [Duration] = []
    for _ in 0..<20 {
        start = clock.now
        let hits = try await cachedIndex.search("leadership", kind: .wiki, tag: "history")
        times.append(start.duration(to: clock.now)); #expect(hits.count == 5000)
    }
    let p95 = times.sorted()[18]
    print("BENCH search p95, 5000 results: \(p95)")
    #expect(p95 < .milliseconds(150))
}

@Test func vaultInsideHiddenParentRemainsReadable() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let root = folder.appendingPathComponent(".hidden-parent/Vault")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = try FileVaultRepository.open(root: root, create: true)
    _ = try await repo.create(title: "Visible note", body: "Personal context")
    _ = try await repo.importSource(data: Data("Original text".utf8), filename: "raw.txt", title: "Visible source", originURL: nil)
    let scan = try await repo.scan()
    #expect(scan.notes.count == 1)
    #expect(scan.sources.count == 1)
}

@Test func pageSourceReferencesAreManyToManyAndStaleSafe() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let first = try await repo.importSource(data: Data("original one".utf8), filename: "one.txt", title: "One", originURL: nil)
    let second = try await repo.importSource(data: Data("original two".utf8), filename: "two.txt", title: "Two", originURL: nil)
    let a = try await repo.create(title: "A", body: "Unchanged body")
    let b = try await repo.create(title: "B", body: "Another body")
    let linked = try await repo.setSourceReference(note: a, sourceID: first.id, linked: true)
    let both = try await repo.setSourceReference(note: linked, sourceID: second.id, linked: true)
    let shared = try await repo.setSourceReference(note: b, sourceID: first.id, linked: true)
    #expect(Set(both.linkedSourceIDs) == Set([first.id, second.id]))
    #expect(shared.linkedSourceIDs == [first.id])
    #expect(both.body == a.body)
    await #expect(throws: (any Error).self) { try await repo.setSourceReference(note: a, sourceID: second.id, linked: true) }
    let removed = try await repo.setSourceReference(note: both, sourceID: first.id, linked: false)
    #expect(removed.linkedSourceIDs == [second.id])
    let reopened = try await repo.scan()
    #expect(reopened.notes.first(where: { $0.id == a.id })?.linkedSourceIDs == [second.id])
    #expect(reopened.sources.first(where: { $0.id == first.id })?.metadata.sha256 == first.metadata.sha256)
    var locked = removed; locked.editingLocked = true
    locked = try await repo.save(note: locked, title: locked.title, body: locked.body, tags: locked.tags)
    await #expect(throws: (any Error).self) { try await repo.setSourceReference(note: locked, sourceID: first.id, linked: true) }
}

@Test func creatingPageFromSourcePersistsReferenceAndRejectsRemovedSource() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("Source facts".utf8)
    let source = try await repo.importSource(data: bytes, filename: "facts.txt", title: "Facts", originURL: nil)
    let existing = try await repo.create(title: "Facts", body: "Existing page")
    let page = try await repo.create(title: "Facts", body: "Generated article", source: source)
    #expect(page.title == "Facts 2")
    #expect(page.linkedSourceIDs == [source.id])
    #expect(page.body == "Generated article")
    let reopened = try await repo.scan()
    #expect(reopened.notes.first(where: { $0.id == page.id })?.linkedSourceIDs == [source.id])
    #expect(reopened.notes.first(where: { $0.id == existing.id })?.body == "Existing page")
    #expect(try Data(contentsOf: folder.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/\(source.metadata.storedFilename)")) == bytes)
    try await repo.deleteSource(source)
    await #expect(throws: VaultError.self) { try await repo.create(title: "Rejected", body: "Draft", source: source) }
    #expect(try await repo.scan().notes.count == 2)
}

@Test func cloudSourceDownloadQueuesAllowsPageLinkingAndCompletes() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let root = folder.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = try FileVaultRepository.open(root: root, create: true)
    let note = try await repo.create(title: "Research Note", body: "Initial body")

    // 1. Linked cloud/OneDrive file not yet downloaded locally
    let linkedFile = folder.appendingPathComponent("OneDriveReport.txt")
    try Data().write(to: linkedFile)
    let pendingLinked = try await repo.beginSourceDownload(at: linkedFile, shouldImport: false)
    #expect(pendingLinked.availabilityIssue == "Downloading from iCloud")
    #expect(pendingLinked.metadata.isLinked)
    #expect(try await repo.scan().sources.contains(where: { $0.id == pendingLinked.id }))

    // User can link the queued source to a wiki page while it is still downloading
    let linkedNote = try await repo.setSourceReference(note: note, sourceID: pendingLinked.id, linked: true)
    #expect(linkedNote.linkedSourceIDs == [pendingLinked.id])

    // Download completes and materializes the file locally
    let linkedBytes = Data("Downloaded OneDrive linked content".utf8)
    try linkedBytes.write(to: linkedFile)
    let completedLinked = try await repo.completeSourceDownload(id: pendingLinked.id, at: linkedFile, data: linkedBytes, shouldImport: false)
    #expect(completedLinked.id == pendingLinked.id)
    #expect(completedLinked.body == "Downloaded OneDrive linked content")
    #expect(completedLinked.metadata.sha256 == digest(linkedBytes))
    let scannedAfterLink = try await repo.scan()
    #expect(scannedAfterLink.notes.first(where: { $0.id == note.id })?.linkedSourceIDs == [completedLinked.id])
    #expect(scannedAfterLink.sources.first(where: { $0.id == completedLinked.id })?.availabilityIssue == nil)

    // 2. Imported cloud/OneDrive file not yet downloaded locally
    let importedFile = folder.appendingPathComponent("OneDriveNotes.md")
    try Data().write(to: importedFile)
    let pendingImport = try await repo.beginSourceDownload(at: importedFile, shouldImport: true)
    #expect(pendingImport.availabilityIssue == "Downloading from iCloud")
    #expect(!pendingImport.metadata.isLinked)
    // Incomplete import is not written to disk before download finishes
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/\(pendingImport.id.uuidString.lowercased())").path))

    let bothLinkedNote = try await repo.setSourceReference(note: linkedNote, sourceID: pendingImport.id, linked: true)
    #expect(Set(bothLinkedNote.linkedSourceIDs) == Set([completedLinked.id, pendingImport.id]))

    let importedBytes = Data("# Downloaded Markdown".utf8)
    try importedBytes.write(to: importedFile)
    let completedImport = try await repo.completeSourceDownload(id: pendingImport.id, at: importedFile, data: importedBytes, shouldImport: true)
    #expect(completedImport.id == pendingImport.id)
    #expect(completedImport.body == "# Downloaded Markdown")
    #expect(FileVaultRepository.checkSourceAvailability(completedImport, root: root, contentStore: repo.contentStore) == "Available")
}


@Test func mixedTrashRestoresSourcesAndKeepsLinkedOriginals() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let external = folder.appendingPathComponent("linked.txt")
    let linkedBytes = Data("Linked original".utf8); try linkedBytes.write(to: external)
    let linked = try await repo.linkSources(at: external, maximumFiles: 1)[0]
    let importedBytes = Data("Imported original".utf8)
    let imported = try await repo.importSource(data: importedBytes, filename: "original.txt", title: "Imported", originURL: nil)
    let page = try await repo.create(title: "Page", body: "A page")
    try await repo.trash(note: page)
    try await repo.deleteSource(linked); try await repo.deleteSource(imported)
    let items = try await repo.trashItems()
    #expect(items.count == 3)
    #expect(try await repo.scan().sources.isEmpty)
    #expect(try Data(contentsOf: external) == linkedBytes)
    for item in items { try await repo.restore(item) }
    #expect(try await repo.scan().sources.count == 2)
    #expect(try await repo.trashItems().isEmpty)
    #expect(try Data(contentsOf: folder.appendingPathComponent("Sources/" + imported.id.uuidString.lowercased() + "/original.txt")) == importedBytes)
    try await repo.deleteSource(linked)
    #expect(await repo.emptyTrashItems(try await repo.trashItems()).isEmpty)
    #expect(try Data(contentsOf: external) == linkedBytes)
}

@Test func searchIndexOutgoingLinksPreservesOrderDeduplicatesAndEnforcesSessionLease() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let alpha = try await repo.create(
        title: "Alpha",
        body: "See [[Beta]], then [[Gamma|custom label]], repeated [[beta]], and `[[IgnoredInCode]]` plus [[Unresolved Page]]."
    )
    var beta = try await repo.create(title: "Beta", body: "Back to [[Alpha]].")
    beta.aliases = ["Old Beta"]
    beta = try await repo.save(note: beta, title: "Beta", body: beta.body, tags: [])
    let gamma = try await repo.create(title: "Gamma", body: "Links to [[Old Beta]].")

    let sessionManager = VaultSessionManager()
    let (_, lease, _) = try await sessionManager.openRepository(root: folder)
    let indexURL = folder.appendingPathComponent("index.sqlite")
    let index = try SQLiteSearchIndex(
        url: indexURL,
        sessionLease: lease,
        accessGate: sessionManager.accessGate
    )
    let batch = try await repo.scan()
    try await index.reconcile(batch)

    let alphaOutlinks = try await index.outgoingLinks(from: alpha.id)
    #expect(alphaOutlinks == ["beta", "gamma", "unresolved page"])

    let gammaOutlinks = try await index.outgoingLinks(from: gamma.id)
    #expect(gammaOutlinks == ["old beta"])

    let betaBacklinks = try await index.backlinks(to: beta)
    #expect(Set(betaBacklinks) == Set([alpha.id, gamma.id]))

    // Updating Alpha's links updates the outgoingLinks query after reconcile.
    let updatedAlpha = try await repo.save(
        note: alpha,
        title: alpha.title,
        body: "Now only links to [[Gamma]].",
        tags: []
    )
    try await index.reconcile(try await repo.scan())
    #expect(try await index.outgoingLinks(from: updatedAlpha.id) == ["gamma"])

    // Locking the session invalidates the lease and rejects outgoingLinks queries.
    try await sessionManager.lock()
    await #expect(throws: VaultAccessError.self) {
        _ = try await index.outgoingLinks(from: updatedAlpha.id)
    }
}
