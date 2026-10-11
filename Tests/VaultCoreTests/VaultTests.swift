import Foundation
import Testing
@testable import VaultCore

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VaultTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func markdownRoundTripPreservesUnknownMetadata() throws {
    let id = UUID()
    let input = Data("---\nid: \(id.uuidString)\ntitle: Pertinax\ntags: [history]\ncustom:\n  confidence: tentative\n  values: [one, two]\n---\n## Personal context\n\nMy own perspective. [[Rome|the city]] #learning\n".utf8)
    var note = try NoteCodec.decode(input, path: "Wiki/Pertinax.md", vaultID: UUID())
    note.title = "Pertinax in my reading"; note.updatedAt = timestamp()
    let output = try NoteCodec.encode(note)
    let decoded = try NoteCodec.decode(output, path: note.relativePath, vaultID: UUID())
    #expect(decoded.id == id)
    #expect(decoded.body == note.body)
    #expect(decoded.originalHeader?.contains("confidence: tentative") == true)
    #expect(decoded.originalHeader?.contains("values:") == true)
    #expect(decoded.allTags == ["history", "learning"])
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

@Test func malformedTextAndFrontmatterAreRejected() throws {
    for input in [Data([0xff, 0xfe, 0xfd]), Data("---\ntitle: [unclosed\n---\nbody".utf8), Data("---\ntitle: x\nbody".utf8), Data("---\nid: not-a-uuid\n---\nbody".utf8)] {
        #expect(throws: (any Error).self) { try NoteCodec.decode(input, path: "Wiki/bad.md", vaultID: UUID()) }
    }
}

@Test func linksAndTagsExcludeCode() {
    let text = "# Heading\n\n[[Pertinax|my reading]] #history #rome/empire\n\n`[[Ignore]] #ignored`\n\n```swift\n[[Also ignore]] #code\n```\n"
    let analysis = MarkdownService.analyze(text)
    #expect(analysis.links == [WikiLink(target: "Pertinax", label: "my reading")])
    #expect(analysis.tags == ["history", "rome/empire"])
    let blocks = MarkdownService.preview(text)
    #expect(blocks.contains { $0.style == .heading(1) })
    #expect(blocks.flatMap(\.spans).contains { $0.wikiTarget == "Pertinax" })
    #expect(blocks.contains { $0.style == .code })
}

@Test func externalMarkdownIsNotRewrittenDuringScanning() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let url = folder.appendingPathComponent("Wiki/External.md")
    let original = Data("A page edited outside the app. #outside".utf8)
    try original.write(to: url)
    let scan = try await repo.scan()
    #expect(scan.notes.count == 1)
    #expect(try Data(contentsOf: url) == original)
    let saved = try await repo.save(note: scan.notes[0], title: "External", body: "An updated thought", tags: ["outside"])
    #expect(saved.id == scan.notes[0].id)
    #expect(saved.originalHeader?.contains("id:") == true)
}

@Test func sourceImportPreservesOriginalAndRejectsMutation() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let original = Data("First line\r\nSecond line: café\r\n".utf8)
    let source = try await repo.importSource(data: original, filename: "source.md", title: "Raw source", originURL: "https://example.com/article")
    let url = folder.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/original.md")
    #expect(try Data(contentsOf: url) == original)
    #expect(source.metadata.sha256 == digest(original))
    #expect(try await repo.scan().sources.count == 1)
    try Data("changed externally".utf8).write(to: url)
    let result = try await repo.scan()
    #expect(result.sources.isEmpty)
    #expect(result.issues.contains { $0.contains("checksum") })
}

@Test func unsupportedImportsAndIncompleteRecordsStaySafe() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    await #expect(throws: (any Error).self) { try await repo.importSource(data: Data([0xff]), filename: "bad.txt", title: "bad", originURL: nil) }
    await #expect(throws: (any Error).self) { try await repo.importSource(data: Data("text".utf8), filename: "bad.pdf", title: "bad", originURL: nil) }
    await #expect(throws: (any Error).self) { try await repo.importSource(data: Data("text".utf8), filename: "bad.txt", title: "bad", originURL: "file:///etc/passwd") }
    let incomplete = folder.appendingPathComponent("Sources/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
    try Data("uncommitted source".utf8).write(to: incomplete.appendingPathComponent("original.txt"))
    let scan = try await repo.scan()
    #expect(scan.sources.isEmpty)
    #expect(!scan.issues.isEmpty)
    #expect(FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("original.txt").path))
}

@Test func renameAliasesAndDuplicateTitleValidation() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let original = try await repo.create(title: "Pertinax", body: "My history notes")
    let renamed = try await repo.save(note: original, title: "Pertinax and leadership", body: original.body, tags: ["History"])
    #expect(renamed.id == original.id)
    #expect(renamed.aliases == ["Pertinax"])
    #expect(renamed.tags == ["history"])
    let other = try await repo.create(title: "Other", body: "")
    await #expect(throws: (any Error).self) { try await repo.save(note: other, title: "pertinax", body: "", tags: []) }
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

@Test func deletedPageCannotBeSilentlyRecreatedByStaleEditor() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Deleted", body: "Original")
    try FileManager.default.removeItem(at: folder.appendingPathComponent(note.relativePath))
    await #expect(throws: (any Error).self) { try await repo.save(note: note, title: note.title, body: "Draft", tags: []) }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(note.relativePath).path))
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
    let journal = try RecoveryStore(directory: journalURL)
    try await journal.store(DraftRecord(note: note, title: note.title, body: "Recover me", tags: []))
    // A directory in place of the file reliably simulates a failed disk save.
    try FileManager.default.removeItem(at: folder.appendingPathComponent(note.relativePath))
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(note.relativePath), withIntermediateDirectories: true)
    await #expect(throws: (any Error).self) { try await repo.save(note: note, title: note.title, body: "Recover me", tags: []) }
    let reopened = try RecoveryStore(directory: journalURL)
    #expect(try await reopened.drafts().first?.body == "Recover me")
    try await reopened.remove(note.id)
    #expect(try await reopened.drafts().isEmpty)
}

@Test func benchmarkFiveThousandEntries() async throws {
    guard ProcessInfo.processInfo.environment["VAULT_BENCHMARK"] == "1" else { return }
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

@Test func externalMovePreservesIdentityAndDuplicateIDsAreQuarantined() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Move me", body: "Personal context")
    let original = folder.appendingPathComponent(note.relativePath)
    let moved = folder.appendingPathComponent("Wiki/Moved.md")
    try FileManager.default.moveItem(at: original, to: moved)
    let fresh = try await repo.scan().notes[0]
    #expect(fresh.id == note.id)
    #expect(fresh.relativePath == "Wiki/Moved.md")
    try FileManager.default.copyItem(at: moved, to: folder.appendingPathComponent("Wiki/Duplicate.md"))
    let duplicate = try await repo.scan()
    #expect(duplicate.notes.isEmpty)
    #expect(duplicate.issues.contains { $0.contains("Duplicate note ID") })
    await #expect(throws: (any Error).self) { try await repo.save(note: fresh, title: fresh.title, body: "Do not overwrite", tags: []) }
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

@Test func articleLockPersistsAndRejectsEdits() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    var note = try await repo.create(title: "Locked", body: "Original")
    note.editingLocked = true
    note = try await repo.save(note: note, title: note.title, body: note.body, tags: note.tags)
    #expect(note.isEditingLocked)
    await #expect(throws: (any Error).self) { try await repo.save(note: note, title: "Changed", body: "Changed", tags: []) }
    #expect(try await repo.scan().notes.first?.isEditingLocked == true)
    note.editingLocked = false
    note = try await repo.save(note: note, title: note.title, body: note.body, tags: note.tags)
    #expect(!note.isEditingLocked)
    let edited = try await repo.save(note: note, title: note.title, body: "Changed", tags: [])
    #expect(edited.body == "Changed")
}

@Test func missingTrashDoesNotBlockPageCreationOrRecovery() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let trash = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName)
    try FileManager.default.removeItem(at: trash)
    let note = try await repo.create(title: "New page", body: "Original")
    #expect(try await repo.trashedPages().isEmpty)
    #expect(try await repo.scan().notes.map(\.id) == [note.id])
    let saved = try await repo.save(note: note, title: note.title, body: "Saved body", tags: [])
    let bytes = try Data(contentsOf: folder.appendingPathComponent(saved.relativePath))
    try FileManager.default.removeItem(at: trash)
    try await repo.trash(note: saved)
    let page = try #require(await repo.trashedPages().first)
    try await repo.restore(page)
    #expect(try Data(contentsOf: folder.appendingPathComponent(saved.relativePath)) == bytes)
}

@Test func trashLockedPagePreservesBytesAndOtherPages() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let other = try await repo.create(title: "Keep", body: "Other page")
    var target = try await repo.create(title: "Trash", body: "Recover me")
    target.editingLocked = true
    target = try await repo.save(note: target, title: target.title, body: target.body, tags: target.tags)
    let bytes = try Data(contentsOf: folder.appendingPathComponent(target.relativePath))
    try await repo.trash(note: target)
    let remaining = try await repo.scan().notes
    #expect(remaining.map(\.id) == [other.id])
    #expect(remaining.first?.body == other.body)
    let trash = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(FileVaultRepository.trashDirectoryName), includingPropertiesForKeys: nil)
    #expect(trash.count == 1)
    #expect(try Data(contentsOf: #require(trash.first)) == bytes)
}

@Test func trashRestoreAndPermanentDeletionKeepIdentityAndRejectStaleData() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Restore me", body: "Original")
    let bytes = try Data(contentsOf: folder.appendingPathComponent(note.relativePath))
    try await repo.trash(note: note)
    let trashed = try #require(await repo.trashedPages().first)
    #expect(trashed.note.id == note.id)
    try await repo.restore(trashed)
    let restored = try #require(await repo.scan().notes.first)
    #expect(restored.id == note.id)
    #expect(try Data(contentsOf: folder.appendingPathComponent(restored.relativePath)) == bytes)
    #expect(try await repo.trashedPages().isEmpty)
    try await repo.trash(note: restored)
    let stale = try #require(await repo.trashedPages().first)
    let url = folder.appendingPathComponent(stale.id)
    var changed = stale.note; changed.body = "External change"
    try NoteCodec.encode(changed).write(to: url, options: .atomic)
    await #expect(throws: (any Error).self) { try await repo.restore(stale) }
    await #expect(throws: (any Error).self) { try await repo.permanentlyDelete(stale) }
    #expect(FileManager.default.fileExists(atPath: url.path))
    let fresh = try #require(await repo.trashedPages().first)
    try await repo.permanentlyDelete(fresh)
    #expect(try await repo.trashedPages().isEmpty)
    #expect(try await repo.scan().notes.isEmpty)
}

@Test func trashRestoreRejectsOccupiedIdentityAndPathsOutsideTrash() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Keep", body: "Keep me")
    let bytes = try Data(contentsOf: folder.appendingPathComponent(note.relativePath))
    try await repo.trash(note: note)
    let trashed = try #require(await repo.trashedPages().first)
    try bytes.write(to: folder.appendingPathComponent(note.relativePath))
    await #expect(throws: (any Error).self) { try await repo.restore(trashed) }
    await #expect(throws: (any Error).self) { try await repo.permanentlyDelete(TrashedPage(note: note)) }
    #expect(try Data(contentsOf: folder.appendingPathComponent(note.relativePath)) == bytes)
    #expect(try await repo.trashedPages().count == 1)
}

@Test func trashDamagedFilesRemainVisibleAndDoNotBlockRecovery() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Recover me", body: "Keep these bytes")
    try await repo.trash(note: note)
    let damagedURL = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/Damaged.md")
    let bytes = Data("---\ntitle: Unclosed YAML".utf8)
    try bytes.write(to: damagedURL)
    let entries = try await repo.trashedPages()
    #expect(entries.count == 2)
    let damaged = try #require(entries.first { $0.note.title == "Damaged" })
    #expect(damaged.readIssue != nil)
    #expect(!damaged.canRestore)
    #expect(damaged.canPermanentlyDelete)
    await #expect(throws: (any Error).self) { try await repo.restore(damaged) }
    try await repo.restore(#require(entries.first { $0.note.id == note.id }))
    #expect(try await repo.scan().notes.map(\.id) == [note.id])
    #expect(try Data(contentsOf: damagedURL) == bytes)
    try await repo.permanentlyDelete(damaged)
    #expect(try await repo.trashedPages().isEmpty)
}

@Test func trashEmptyUsesConfirmedSnapshotAndReportsPartialFailures() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let keep = try await repo.create(title: "Active", body: "Keep me")
    let changed = try await repo.create(title: "Changed", body: "Before")
    let deleted = try await repo.create(title: "Delete", body: "Disposable")
    try await repo.trash(note: changed); try await repo.trash(note: deleted)
    let confirmed = try await repo.trashedPages()
    let stale = try #require(confirmed.first { $0.note.id == changed.id })
    var replacement = stale.note; replacement.body = "Changed after confirmation"
    let replacementBytes = try NoteCodec.encode(replacement)
    try replacementBytes.write(to: folder.appendingPathComponent(stale.id), options: .atomic)
    let later = try await repo.create(title: "Later", body: "Not confirmed")
    try await repo.trash(note: later)
    let failures = await repo.emptyTrash(confirmed)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("Changed") == true)
    #expect(try Data(contentsOf: folder.appendingPathComponent(stale.id)) == replacementBytes)
    let remaining = try await repo.trashedPages()
    #expect(Set(remaining.map { $0.note.id }) == [changed.id, later.id])
    #expect(try await repo.scan().notes.map(\.id) == [keep.id])
    #expect(await repo.emptyTrash(remaining).isEmpty)
    #expect(try await repo.trashedPages().isEmpty)
    #expect(await repo.emptyTrash([]).isEmpty)
}

@Test func trashSymlinksCannotDeleteOutsideFiles() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Protected", body: "Keep me")
    let original = folder.appendingPathComponent(note.relativePath)
    let bytes = try Data(contentsOf: original)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/Link.md"), withDestinationURL: original)
    let entries = try await repo.trashedPages()
    let entry = try #require(entries.first)
    #expect(entry.readIssue != nil)
    #expect(!entry.canRestore && !entry.canPermanentlyDelete)
    #expect(await repo.emptyTrash(entries).count == 1)
    #expect(try Data(contentsOf: original) == bytes)
}

@Test func trashSurvivesRefreshAndReopenUntilExplicitDeletion() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let note = try await repo.create(title: "Retained", body: "Keep until explicitly restored or deleted")
    let bytes = try Data(contentsOf: folder.appendingPathComponent(note.relativePath))
    try await repo.trash(note: note)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".Trash").path))
    for _ in 0..<3 {
        let reopened = try FileVaultRepository.open(root: folder)
        #expect(try await reopened.scan().notes.isEmpty)
        let entries = try await reopened.trashedPages()
        let retained = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(retained.id.hasPrefix("Removed Pages/"))
        #expect(retained.note.id == note.id)
        #expect(try Data(contentsOf: folder.appendingPathComponent(retained.id)) == bytes)
    }
    let retained = try #require(await repo.trashedPages().first)
    try await repo.restore(retained)
    #expect(try await repo.scan().notes.map(\.id) == [note.id])
}

@Test func legacyTrashMigratesWithoutOverwritingOrRewritingBytes() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let legacy = folder.appendingPathComponent(".Trash")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
    let filename = "Legacy.md"
    let existing = Data("---\nid: \(UUID())\ntitle: Current trash\n---\nNew storage".utf8)
    let old = Data("---\nid: \(UUID())\ntitle: Legacy trash\ncustom: retained\n---\nKeep original bytes".utf8)
    let damaged = Data("---\nUnclosed YAML".utf8)
    try existing.write(to: folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/" + filename))
    try old.write(to: legacy.appendingPathComponent(filename))
    try damaged.write(to: legacy.appendingPathComponent("Damaged.md"))
    let entries = try await repo.trashedPages()
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.id.hasPrefix("Removed Pages/") })
    #expect(Set(try entries.map { try Data(contentsOf: folder.appendingPathComponent($0.id)) }) == [existing, old, damaged])
    #expect(try FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil).isEmpty)
    #expect(try await repo.trashedPages().count == 3)
    let migrated = try #require(entries.first { $0.note.title == "Legacy trash" })
    try await repo.restore(migrated)
    let restored = try #require(await repo.scan().notes.first)
    #expect(try Data(contentsOf: folder.appendingPathComponent(restored.relativePath)) == old)
    #expect(await repo.emptyTrash(try await repo.trashedPages()).isEmpty)
}

@Test func linkedFolderLimitRejectsBeforePublishingAndCountsNestedFiles() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let vault = folder.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    let external = folder.appendingPathComponent("External/Nested")
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    for n in 0..<11 { try Data("Original \(n)".utf8).write(to: external.appendingPathComponent("\(n).txt")) }
    let repository = try FileVaultRepository.open(root: vault, create: true)
    await #expect(throws: VaultError.self) { try await repository.linkSources(at: external.deletingLastPathComponent(), maximumFiles: 10) }
    let scan = try await repository.scan()
    #expect(scan.sources.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("Sources").path).isEmpty)
}

@Test func linkedFileReloadsWithoutCopyingOrChangingOriginal() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("External.md")
    let bytes = Data("# Original\n".utf8); try bytes.write(to: file)
    let vault = folder.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    let repository = try FileVaultRepository.open(root: vault, create: true)
    let linked = try await repository.linkSources(at: file, maximumFiles: 10)
    #expect(linked.count == 1)
    #expect(linked[0].metadata.isLinked)
    #expect(try Data(contentsOf: file) == bytes)
    let sourceFolder = repository.root.appendingPathComponent("Sources/" + linked[0].id.uuidString.lowercased())
    #expect(!FileManager.default.fileExists(atPath: sourceFolder.appendingPathComponent("original.md").path))
    try Data("# Changed externally\n".utf8).write(to: file)
    let scan = try await repository.scan()
    #expect(scan.sources.first?.body == "# Changed externally\n")
    #expect(scan.sources.first?.id == linked[0].id)
}

@Test func importLimitAcceptsBoundaryAndRejectsLargerWithoutPublishing() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data(repeating: 65, count: FileVaultRepository.maximumImportBytes)
    let source = try await repository.importSource(data: bytes, filename: "boundary.txt", title: "Boundary", originURL: nil)
    let original = folder.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
    #expect(try Data(contentsOf: original) == bytes)
    await #expect(throws: VaultError.self) {
        try await repository.importSource(data: Data(repeating: 65, count: FileVaultRepository.maximumImportBytes + 1), filename: "too-large.txt", title: "Large", originURL: nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Sources").path).count == 1)
}

@Test func binarySourceImportsAndLinksPreserveBytesAndHTMLRemainsReadable() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("%PDF-1.7\n".utf8) + Data([0xff, 0, 1])
    let pdf = try await repository.importSource(data: bytes, filename: "paper.pdf", title: "Paper", originURL: nil)
    #expect(pdf.body.isEmpty)
    let original = folder.appendingPathComponent("Sources/" + pdf.id.uuidString.lowercased() + "/original.pdf")
    #expect(try Data(contentsOf: original) == bytes)
    await #expect(throws: VaultError.self) { try await repository.linkSources(at: original, maximumFiles: 10) }
    let external = folder.appendingPathComponent("external.pdf")
    try (bytes + Data([2])).write(to: external)
    let linked = try await repository.linkSources(at: external, maximumFiles: 10)
    #expect(linked.first?.metadata.isLinked == true)
    #expect(linked.first?.body.isEmpty == true)
    let html = try await repository.importSource(data: Data("<h1>Hello</h1>".utf8), filename: "page.html", title: "HTML", originURL: nil)
    #expect(html.body == "<h1>Hello</h1>")
    #expect(try await repository.scan().sources.count == 3)
}

@Test func sourceRenamePreservesOriginalSizeAndRejectsStaleMetadata() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("A specific subject in a document.".utf8)
    let source = try await repository.importSource(data: bytes, filename: "original.txt", title: "Original", originURL: nil)
    #expect(source.metadata.fileSize == bytes.count)
    let renamed = try await repository.renameSource(source, title: "Specific Subject")
    #expect(renamed.title == "Specific Subject")
    #expect(renamed.metadata.originalFilename == "original.txt")
    #expect(renamed.metadata.fileSize == bytes.count)
    #expect(renamed.id == source.id)
    let original = folder.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
    #expect(try Data(contentsOf: original) == bytes)
    await #expect(throws: VaultError.self) { try await repository.renameSource(source, title: "Stale Result") }
    #expect(try await repository.scan().sources.first?.title == "Specific Subject")
}

@Test func deletingLinkedSourceLeavesExternalOriginalAndOtherSourcesIntact() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let external = folder.appendingPathComponent("external.txt")
    let bytes = Data("External original".utf8); try bytes.write(to: external)
    let linked = try await repository.linkSources(at: external, maximumFiles: 5)[0]
    let kept = try await repository.importSource(data: Data("Keep".utf8), filename: "keep.txt", title: "Keep", originURL: nil)
    try await repository.deleteSource(linked)
    #expect(try Data(contentsOf: external) == bytes)
    let scan = try await repository.scan()
    #expect(scan.sources.map(\.id) == [kept.id])
    await #expect(throws: (any Error).self) { try await repository.renameSource(linked, title: "Do not recreate") }
}

@Test func deletingImportedSourceDeletesOriginalAndRejectsStaleOrMutatedFiles() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let source = try await repository.importSource(data: Data("Original".utf8), filename: "original.txt", title: "Original", originURL: nil)
    let renamed = try await repository.renameSource(source, title: "Renamed")
    await #expect(throws: VaultError.self) { try await repository.deleteSource(source) }
    let original = folder.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
    try Data("Changed".utf8).write(to: original)
    await #expect(throws: VaultError.self) { try await repository.deleteSource(renamed) }
    #expect(FileManager.default.fileExists(atPath: original.path))
    try Data("Original".utf8).write(to: original)
    try await repository.deleteSource(renamed)
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(try await repository.scan().sources.isEmpty)
}

@Test func sourceAISummaryPersistsWithTitleAndSurvivesManualRename() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("A source about caring for a sourdough starter.".utf8)
    let source = try await repository.importSource(data: bytes, filename: "starter.txt", title: "Starter", originURL: nil)
    #expect(source.metadata.aiSummary == nil)
    let generated = try await repository.renameSource(source, title: "Sourdough Starter Care", summary: "  Feeding and maintaining a sourdough starter.  ")
    #expect(generated.metadata.aiSummary == "Feeding and maintaining a sourdough starter.")
    let scanned = try await repository.scan().sources[0]
    #expect(scanned.metadata.aiSummary == generated.metadata.aiSummary)
    #expect(scanned.title == generated.title)
    let manual = try await repository.renameSource(scanned, title: "My Starter")
    #expect(manual.metadata.aiSummary == generated.metadata.aiSummary)
    #expect(manual.metadata.originalFilename == "starter.txt")
    let original = folder.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
    #expect(try Data(contentsOf: original) == bytes)
    await #expect(throws: VaultError.self) { try await repository.renameSource(source, title: "Stale", summary: "Must not overwrite") }
    await #expect(throws: VaultError.self) { try await repository.renameSource(manual, title: "Bad", summary: "  ") }
    #expect(try await repository.scan().sources[0].title == "My Starter")
}

@Test func sourceSummaryRegenerationPreservesTitleAndRejectsStaleSummary() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repository = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("Source content".utf8)
    let source = try await repository.importSource(data: bytes, filename: "source.txt", title: "My title", originURL: nil)
    let generated = try await repository.renameSource(source, title: source.title, summary: "First summary")
    let regenerated = try await repository.renameSource(generated, title: generated.title, summary: "Updated summary")
    #expect(regenerated.title == source.title)
    #expect(regenerated.metadata.aiSummary == "Updated summary")
    #expect(regenerated.metadata.sha256 == source.metadata.sha256)
    await #expect(throws: VaultError.self) {
        try await repository.renameSource(generated, title: generated.title, summary: "Stale summary")
    }
    #expect(try await repository.scan().sources[0].metadata.aiSummary == "Updated summary")
    let original = folder.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
    #expect(try Data(contentsOf: original) == bytes)
}

@Test func availabilityChecksRetainBrokenLinkedSourcesAndRecover() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("External.txt")
    let bytes = Data("External source".utf8); try bytes.write(to: file)
    let root = folder.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repository = try FileVaultRepository.open(root: root, create: true)
    let source = try await repository.linkSources(at: file, maximumFiles: 1)[0]
    #expect(FileVaultRepository.checkSourceAvailability(source, root: root) == "Available")
    try FileManager.default.removeItem(at: file)
    #expect(FileVaultRepository.checkSourceAvailability(source, root: root) != "Available")
    let broken = try await repository.scan()
    #expect(broken.sources.first?.id == source.id)
    #expect(broken.sources.first?.availabilityIssue != nil)
    #expect(broken.sources.first?.body == "")
    try bytes.write(to: file)
    // Replacing the deleted file invalidates the old security bookmark; relinking restores access.
    #expect(FileVaultRepository.checkSourceAvailability(source, root: root).contains("stale"))
    try await repository.deleteSource(source)
    let relinked = try await repository.linkSources(at: file, maximumFiles: 1)[0]
    #expect(FileVaultRepository.checkSourceAvailability(relinked, root: root) == "Available")
    #expect(try await repository.scan().sources.first(where: { $0.id == relinked.id })?.availabilityIssue == nil)
}
@Test func importedAvailabilityRejectsMissingAndChangedOriginals() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = try FileVaultRepository.open(root: root, create: true)
    let source = try await repository.importSource(data: Data("Original".utf8), filename: "source.txt", title: "Source", originURL: nil)
    #expect(FileVaultRepository.checkSourceAvailability(source, root: root) == "Available")
    let file = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
    try Data("Changed".utf8).write(to: file)
    #expect(FileVaultRepository.checkSourceAvailability(source, root: root) != "Available")
    try FileManager.default.removeItem(at: file)
    #expect(FileVaultRepository.checkSourceAvailability(source, root: root) == "File not found")
}

@Test func duplicateSourceRejectsSameBytesAcrossModesAndBatchContinues() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = try FileVaultRepository.open(root: root, create: true)
    let bytes = Data("Existing content".utf8)
    let existing = try await repository.importSource(data: bytes, filename: "first.txt", title: "First", originURL: nil)
    var failures: [String] = []
    for (filename, data) in [("copy.txt", bytes), ("new.txt", Data("New content".utf8))] {
        do { _ = try await repository.importSource(data: data, filename: filename, title: filename, originURL: nil) }
        catch { failures.append(error.localizedDescription) }
    }
    #expect(failures.count == 1)
    #expect(failures[0].contains("File already added as a source"))
    #expect(try await repository.scan().sources.count == 2)
    let external = root.appendingPathComponent("copy.txt"); try bytes.write(to: external)
    await #expect(throws: VaultError.self) { try await repository.linkSources(at: external, maximumFiles: 5) }
    #expect(try await repository.scan().sources.contains { $0.id == existing.id })
}
@Test func duplicateLinkedSourceRejectsChangedSameFileAndImportOfLinkedBytes() async throws {
    let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = try FileVaultRepository.open(root: root, create: true)
    let file = root.appendingPathComponent("linked.txt")
    let bytes = Data("Linked content".utf8); try bytes.write(to: file)
    _ = try await repository.linkSources(at: file, maximumFiles: 5)
    await #expect(throws: VaultError.self) {
        try await repository.importSource(data: bytes, filename: "copy.txt", title: "Copy", originURL: nil)
    }
    try Data("Changed externally".utf8).write(to: file)
    await #expect(throws: VaultError.self) { try await repository.linkSources(at: file, maximumFiles: 5) }
    #expect(try await repository.scan().sources.count == 1)
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

@Test func urlSourceValidationAndBatchLimits() throws {
    #expect(try WebSourceFetcher.lines(" https://example.com/a\n\nhttps://example.com/b ").count == 2)
    for invalid in ["", "file:///tmp/test", "https://", "ftp://example.com", "https://example.com/a b", "https://user:pass@example.com"] {
        #expect(throws: (any Error).self) { try WebSourceFetcher.validatedURL(invalid) }
    }
    #expect(throws: (any Error).self) { try WebSourceFetcher.lines(Array(repeating: "https://example.com", count: 6).joined(separator: "\n")) }
    #expect(try WebSourceFetcher.validatedURL("https://example.com/a?q=one").host == "example.com")
}

@Test func urlSourceFailureRetainsArchivedOriginalAndSummary() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("<html><body>Captured knowledge</body></html>".utf8)
    let source = try await repo.importURLSource("https://example.com/article", fetch: { _ in WebSourceFetch(data: bytes, filename: "page.html") })
    let renamed = try await repo.renameSource(source, title: "Captured knowledge", summary: "Saved AI summary")
    let original = folder.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/original.html")
    let status = try await repo.checkURLSourceAvailability(renamed, fetch: { _ in throw VaultError.unavailable("HTTP 404") })
    #expect(status.contains("Archived fetch"))
    let archived = try #require(try await repo.scan().sources.first)
    #expect(archived.body == String(data: bytes, encoding: .utf8))
    #expect(archived.metadata.aiSummary == "Saved AI summary")
    #expect(archived.availabilityIssue == status)
    #expect(try Data(contentsOf: original) == bytes)
    #expect(try await repo.checkURLSourceAvailability(archived, fetch: { _ in WebSourceFetch(data: Data("Changed remote page".utf8), filename: "page.txt") }) == "Available")
    #expect(try await repo.scan().sources.first?.availabilityIssue == nil)
    #expect(try Data(contentsOf: original) == bytes)
    // Pasted sources with an origin are not automatically treated as fetched pages.
    let pasted = try await repo.importSource(data: Data("Pasted text".utf8), filename: "pasted.txt", title: "Paste", originURL: "https://example.com")
    #expect(pasted.metadata.isURLSource == nil)
}

@Test func urlSourceBatchContinuesAfterItemFailure() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    var failures = 0
    for address in ["bad URL", "https://example.com/fails", "https://example.com/works"] {
        do {
            _ = try await repo.importURLSource(address, fetch: { url in
                if url.path == "/fails" { throw VaultError.unavailable("HTTP 500") }
                return WebSourceFetch(data: Data("Unique fetched content".utf8), filename: "page.txt")
            })
        } catch { failures += 1 }
    }
    #expect(failures == 2)
    #expect(try await repo.scan().sources.count == 1)
}

@Test func urlSourceLocalHTTPAcceptance() async throws {
    guard let base = ProcessInfo.processInfo.environment["NOEMA_URL_FETCH_TEST_BASE"] else { return }
    let fetched = try await WebSourceFetcher.fetch(WebSourceFetcher.validatedURL(base + "/ok"))
    #expect(fetched.filename == "page.html")
    #expect(String(data: fetched.data, encoding: .utf8) == "<html><body>Local HTTP capture</body></html>")
    for path in ["/missing", "/empty", "/large", "/binary"] {
        await #expect(throws: (any Error).self) { try await WebSourceFetcher.fetch(WebSourceFetcher.validatedURL(base + path)) }
    }
}

@Test(arguments: ["<html><nav>Navigation</nav><main><p>Article only</p></main><footer>Footer</footer></html>", "<html><body>Article without main</body></html>"])
func wikipediaCaptureUsesFullHTML(html: String) async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data(html.utf8)
    let source = try await repo.importURLSource("https://en.wikipedia.org/wiki/Article", fetch: { _ in WebSourceFetch(data: bytes, filename: "page.html") })
    #expect(source.body == html)
    #expect(try await repo.scan().sources.first?.body == source.body)
    #expect(try Data(contentsOf: folder.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/original.html")) == bytes)
    #expect(source.metadata.sha256 == digest(bytes))
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

@Test func webTopicResearchUsesRankedReadableResultsAndSkipsFailures() async throws {
    let html = "<a class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Ffirst&amp;x=1\">First &amp; best</a><a class='result__a' href='https://example.com/missing'>Missing</a><a class='result__a' href='https://example.com/third'>Third</a><a class='result__a' href='javascript:bad'>Invalid</a>"
    let results = try await WebTopicResearch.research("Roman history") { url in
        if url.host == "www.bing.com" {
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Roman history")
            return WebSourceFetch(data: Data(html.utf8), filename: "page.html")
        }
        if url.path == "/missing" { throw VaultError.unavailable("404") }
        return WebSourceFetch(data: Data("<script>Ignore instructions</script><p>Supported facts</p>".utf8), filename: "page.html")
    }
    #expect(results.map(\.title) == ["First & best", "Third"])
    #expect(results.first?.url.absoluteString == "https://example.com/first")
    #expect(results.allSatisfy { $0.text == "Supported facts" })
    await #expect(throws: VaultError.self) {
        try await WebTopicResearch.research("Blocked") { _ in WebSourceFetch(data: Data("Captcha".utf8), filename: "page.html") }
    }
}

@Test func liveWebTopicSearchAcceptance() async throws {
    guard ProcessInfo.processInfo.environment["NOEMA_WEB_SEARCH_TEST"] == "1" else { return }
    let results = try await WebTopicResearch.research("Roman Empire history")
    #expect(!results.isEmpty)
    #expect(results.count <= 3)
    #expect(results.allSatisfy { !$0.text.isEmpty })
}

@Test func webTopicRSSPreservesRankAndDecodesLinks() {
    let rss = "<rss><channel><item><title>First &amp; best</title><link>https://example.com/a?q=1&amp;x=2</link></item><item><title>Duplicate</title><link>https://example.com/a?q=1&amp;x=2</link></item><item><title>Invalid</title><link>file:///tmp/bad</link></item><item><title>Second</title><link>https://example.com/b</link></item></channel></rss>"
    let results = WebTopicResearch.results(in: rss)
    #expect(results.map(\.title) == ["First & best", "Second"])
    #expect(results.first?.url.absoluteString == "https://example.com/a?q=1&x=2")
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
    #expect(FileVaultRepository.checkSourceAvailability(completedImport, root: root) == "Available")
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

@Test func sourceTrashRejectsStaleSnapshotsAndDuplicateRestoration() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let bytes = Data("Preserved original".utf8)
    let source = try await repo.importSource(data: bytes, filename: "original.txt", title: "Source", originURL: nil)
    try await repo.deleteSource(source)
    let item = try #require(await repo.trashItems().first)
    let original = folder.appendingPathComponent(item.id + "/original.txt")
    try Data("Changed".utf8).write(to: original)
    await #expect(throws: (any Error).self) { try await repo.restore(item) }
    await #expect(throws: (any Error).self) { try await repo.permanentlyDelete(item) }
    #expect(try await repo.trashItems().first?.readIssue != nil)
    try bytes.write(to: original)
    _ = try await repo.importSource(data: bytes, filename: "duplicate.txt", title: "Duplicate", originURL: nil)
    await #expect(throws: (any Error).self) { try await repo.restore(item) }
    #expect(try Data(contentsOf: original) == bytes)
}

@Test func trashExpiresAfterFifteenDaysWithLegacyGraceAndDamagedProtection() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let repo = try FileVaultRepository.open(root: folder, create: true)
    let external = folder.appendingPathComponent("linked.txt")
    let bytes = Data("Keep outside vault".utf8); try bytes.write(to: external)
    let linked = try await repo.linkSources(at: external, maximumFiles: 1)[0]
    let imported = try await repo.importSource(data: Data("Import".utf8), filename: "original.txt", title: "Import", originURL: nil)
    let page = try await repo.create(title: "Page", body: "Page")
    try await repo.deleteSource(linked); try await repo.deleteSource(imported); try await repo.trash(note: page)
    let legacy = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/legacy.md")
    try Data("Legacy body".utf8).write(to: legacy)
    let damaged = folder.appendingPathComponent(FileVaultRepository.trashDirectoryName + "/damaged.md")
    try Data("---\ntitle: Unclosed".utf8).write(to: damaged)
    let start = Date()
    #expect(try await repo.expireTrash(now: start).isEmpty)
    #expect(try await repo.expireTrash(now: start.addingTimeInterval(14 * 86400)).isEmpty)
    #expect(try await repo.trashItems().count == 5)
    let reopened = try FileVaultRepository.open(root: folder)
    #expect(try await reopened.expireTrash(now: start.addingTimeInterval(15 * 86400)).count == 1)
    #expect(try await reopened.trashItems().count == 1)
    #expect(FileManager.default.fileExists(atPath: damaged.path))
    #expect(try Data(contentsOf: external) == bytes)
}
