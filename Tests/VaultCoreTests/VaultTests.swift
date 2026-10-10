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
