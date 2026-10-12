import Foundation
import Synchronization
import Testing
@testable import VaultCore

final class SourceStoreProbe: VaultContentStore {
    struct State {
        var operations: [String] = []
        var failPublication = false
        var failStagingFile: String?
        var race: Data?
        var deleteBeforeWrite = false
    }
    let base: PlaintextVaultContentStore
    let state = Mutex(State())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func createDirectory(at path: String) throws {
        state.withLock { $0.operations.append("mkdir " + path) }
        try base.createDirectory(at: path)
    }
    func read(at path: String) throws -> Data {
        state.withLock { $0.operations.append("read " + path) }
        return try base.read(at: path)
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot {
        state.withLock { $0.operations.append("snapshot " + path) }
        return try base.snapshot(at: path)
    }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws {
        if let filename = state.withLock({ $0.failStagingFile }), path.contains("/.import-"), path.hasSuffix("/" + filename) {
            throw VaultContentStoreError.io(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, message: "Injected staging write failure")
        }
        let race = state.withLock { state -> (Data?, Bool) in
            state.operations.append("write " + path)
            guard case .replace = condition else { return (nil, false) }
            let result = (state.race, state.deleteBeforeWrite)
            state.race = nil; state.deleteBeforeWrite = false
            return result
        }
        if let bytes = race.0 { try base.write(bytes, at: path, condition: condition) }
        if race.1, case .replace(let bytes) = condition { try base.delete(at: path, expected: .file(bytes)) }
        try base.write(data, at: path, condition: condition)
    }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws {
        state.withLock { $0.operations.append("move " + source + " -> " + destination) }
        if state.withLock({ $0.failPublication }), source.contains(".import-") {
            throw VaultContentStoreError.stale(source)
        }
        try base.move(from: source, to: destination, expected: expected)
    }
    func delete(at path: String, expected: VaultContentSnapshot) throws {
        state.withLock { $0.operations.append("delete " + path) }
        try base.delete(at: path, expected: expected)
    }
}

struct SourceAdapterTests {
    private func folder() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/source-adapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func importMetadataChecksumTrashAndReopen() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let original = Data("Captured original\n".utf8)
        let source = try await repo.importSource(data: original, filename: "Article.txt", title: "Article", originURL: nil)
        let path = "Sources/" + source.id.uuidString.lowercased()
        #expect(try store.base.read(at: path + "/original.txt") == original)
        let renamed = try await repo.renameSource(source, title: "Renamed", summary: "Summary")
        let classified = try await repo.updateSourceLCC(renamed, lcc: " QA ")
        #expect(classified.metadata.lcc == "QA")
        #expect(classified.metadata.originalFilename == "Article.txt")
        #expect(classified.metadata.sha256 == digest(original))
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        let loaded = try #require(try await reopened.scan().sources.first)
        #expect(loaded == classified)
        #expect(try FileVaultRepository.readSourceOriginal(loaded, root: root, contentStore: store) == original)
        #expect(FileVaultRepository.checkSourceAvailability(loaded, root: root, contentStore: store) == "Available")
        await #expect(throws: (any Error).self) { try await repo.renameSource(source, title: "Stale") }
        try await repo.deleteSource(loaded)
        let trash = try #require(try await repo.trashItems().first)
        try await repo.restore(trash)
        #expect(try store.base.read(at: path + "/original.txt") == original)
        try await repo.deleteSource(loaded)
        let deleted = try #require(try await repo.trashItems().first)
        try await repo.permanentlyDelete(deleted)
        #expect(store.state.withLock { $0.operations.contains("delete " + deleted.id) })
        // Corruption remains on disk and blocks scan, availability, reader and deletion.
        let other = try await repo.importSource(data: original, filename: "Article.txt", title: "Again", originURL: nil)
        let otherPath = "Sources/" + other.id.uuidString.lowercased() + "/original.txt"
        try store.base.write(Data("Corrupted".utf8), at: otherPath, condition: .replace(expected: original))
        let corrupt = try await repo.scan()
        #expect(corrupt.sources.isEmpty)
        #expect(corrupt.issues.contains { $0.contains("checksum") })
        #expect(FileVaultRepository.checkSourceAvailability(other, root: root, contentStore: store).contains("checksum"))
        #expect(throws: (any Error).self) { try FileVaultRepository.readSourceOriginal(other, root: root, contentStore: store) }
        await #expect(throws: (any Error).self) { try await repo.deleteSource(other) }
        #expect(store.state.withLock { $0.operations.contains("read " + path + "/metadata.json") })
        #expect(store.state.withLock { $0.operations.contains("read " + path + "/original.txt") })
    }

    @Test func linkedAndDownloadedRecordsKeepExternalOwnership() async throws {
        let fixture = try folder(); defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let external = fixture.appendingPathComponent("External.txt")
        try Data("External original".utf8).write(to: external)
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let linked = try #require(try await repo.linkSources(at: external, maximumFiles: 1).first)
        let path = "Sources/" + linked.id.uuidString.lowercased()
        #expect(try store.base.snapshot(at: path) == .directory(["metadata.json": store.base.read(at: path + "/metadata.json")]))
        try Data("Updated external bytes".utf8).write(to: external)
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        let fresh = try #require(try await reopened.scan().sources.first)
        #expect(fresh.body == "Updated external bytes")
        #expect(fresh.metadata.linkedBookmark == linked.metadata.linkedBookmark)
        let renamed = try await repo.renameSource(fresh, title: "Linked rename")
        try await repo.deleteSource(renamed)
        let trash = try #require(try await repo.trashItems().first)
        try await repo.permanentlyDelete(trash)
        #expect(try Data(contentsOf: external) == Data("Updated external bytes".utf8))
        #expect(store.state.withLock { !$0.operations.contains("read " + path + "/" + linked.metadata.storedFilename) })
        let pending = try await repo.beginSourceDownload(at: external, shouldImport: false)
        let completed = try await repo.completeSourceDownload(id: pending.id, at: external, data: Data(contentsOf: external), shouldImport: false)
        #expect(completed.id == pending.id)
        #expect(completed.metadata.linkedBookmark != nil)
        try await repo.deleteSource(completed)
        let importing = try await repo.beginSourceDownload(at: external, shouldImport: true)
        let imported = try await repo.completeSourceDownload(id: importing.id, at: external, data: Data(contentsOf: external), shouldImport: true)
        #expect(imported.id == importing.id)
        #expect(try FileVaultRepository.readSourceOriginal(imported, root: root, contentStore: store) == Data(contentsOf: external))
    }

    @Test(arguments: [false, true]) func metadataRacePreservesExternalChange(deleted: Bool) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let source = try await repo.importSource(data: Data("Original".utf8), filename: "a.txt", title: "A", originURL: nil)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        var metadata = source.metadata; metadata.title = "External title"
        let external = try JSONEncoder().encode(metadata)
        store.state.withLock { $0.race = deleted ? nil : external; $0.deleteBeforeWrite = deleted }
        await #expect(throws: (any Error).self) { try await repo.renameSource(source, title: "Competing title") }
        if deleted { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)) }
        else { #expect(try store.base.read(at: path) == external) }
    }

    @Test(arguments: ["original.txt", "metadata.json"])
    func failedSourceStagingNeverPublishesIncompleteContentAndRetainsWrittenBytes(filename: String) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let existing = try await repo.importSource(data: Data("Existing original".utf8), filename: "existing.txt", title: "Existing", originURL: nil)
        let existingPath = "Sources/" + existing.id.uuidString.lowercased()
        let before = try store.base.snapshot(at: existingPath)
        let bytes = Data("Recoverable staged original".utf8)
        store.state.withLock { $0.failStagingFile = filename }
        await #expect(throws: VaultContentStoreError.io(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, message: "Injected staging write failure")) {
            _ = try await repo.importSource(data: bytes, filename: "new.txt", title: "New", originURL: nil)
        }
        #expect(try await repo.scan().sources.map(\.id) == [existing.id])
        #expect(try store.base.snapshot(at: existingPath) == before)
        let staging = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".import-") })
        let staged = try store.base.snapshot(at: "Sources/" + staging.lastPathComponent)
        #expect(staged == .directory(filename == "metadata.json" ? ["original.txt": bytes] : [:]))
        store.state.withLock { $0.failStagingFile = nil }
        let retried = try await repo.importSource(data: bytes, filename: "new.txt", title: "New", originURL: nil)
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        #expect(try await reopened.scan().sources.count == 2)
        #expect(try FileVaultRepository.readSourceOriginal(retried, root: root, contentStore: store) == bytes)
        #expect(try store.base.snapshot(at: existingPath) == before)
        #expect(try store.base.snapshot(at: "Sources/" + staging.lastPathComponent) == staged)
    }

    @Test func failedPublicationRetainsStagingAndURLStatusPreservesOriginal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        store.state.withLock { $0.failPublication = true }
        let bytes = Data("Unpublished".utf8)
        await #expect(throws: (any Error).self) { try await repo.importSource(data: bytes, filename: "a.txt", title: "A", originURL: nil) }
        #expect(try await repo.scan().sources.isEmpty)
        let staging = try #require(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil).first)
        #expect(staging.lastPathComponent.hasPrefix(".import-"))
        #expect(try store.base.read(at: "Sources/" + staging.lastPathComponent + "/original.txt") == bytes)
        let stagedMetadata = try JSONDecoder().decode(SourceMetadata.self, from: store.base.read(at: "Sources/" + staging.lastPathComponent + "/metadata.json"))
        #expect(stagedMetadata.sha256 == digest(bytes) && stagedMetadata.fileSize == bytes.count)
        #expect(stagedMetadata.storedFilename == "original.txt")
        store.state.withLock { $0.failPublication = false }
        let urlSource = try await repo.importURLSource("https://example.com") { _ in
            WebSourceFetch(data: Data("Web capture".utf8), filename: "web.txt")
        }
        _ = try await repo.checkURLSourceAvailability(urlSource) { _ in throw VaultError.unavailable("Offline") }
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        let archived = try #require(try await reopened.scan().sources.first)
        #expect(archived.metadata.webAvailabilityIssue?.contains("Offline") == true)
        #expect(try FileVaultRepository.readSourceOriginal(archived, root: root, contentStore: store) == Data("Web capture".utf8))
        _ = try await repo.checkURLSourceAvailability(archived) { _ in WebSourceFetch(data: Data("New response".utf8), filename: "web.txt") }
        #expect(try await repo.scan().sources.first?.metadata.webAvailabilityIssue == nil)
    }

    @Test func acceptedSourceArtifactsPersistIndependentlyAndManualChangesClearOnlyMatchingProvenance() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let original = Data("Source content".utf8)
        let source = try await repo.importSource(data: original, filename: "article.txt", title: "Original", originURL: nil)
        let legacy = try await repo.renameSource(source, title: source.title, summary: "Legacy summary", lcc: "Q")
        #expect(legacy.metadata.aiTitleProvenance == nil && legacy.metadata.aiLCCProvenance == nil)
        #expect(legacy.metadata.aiSummaryProvenance == nil)
        let provenance = SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date(timeIntervalSince1970: 100))
        let snapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let titled = try await repo.publishSourceTitle(snapshot, title: "Accepted title", provenance: provenance, validate: {})
        #expect(titled.metadata.aiSummary == "Legacy summary" && titled.metadata.lcc == "Q")
        #expect(titled.metadata.aiTitleProvenance?.sourceRevision == digest(original))
        let lccSnapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let classified = try await repo.publishSourceLCC(lccSnapshot, lcc: "QA", provenance: provenance, validate: {})
        #expect(classified.title == titled.title && classified.metadata.aiSummary == titled.metadata.aiSummary)
        #expect(classified.metadata.aiTitleProvenance == titled.metadata.aiTitleProvenance)
        let reopened = try FileVaultRepository.open(root: root, contentStore: store)
        #expect(try await reopened.loadSource(id: source.id).metadata == classified.metadata)
        let summarySnapshot = try await reopened.sourceSummarySnapshot(id: source.id)
        let summarized = try await reopened.publishSourceSummary(summarySnapshot, summary: "Explicit replacement", provenance: provenance, validate: {})
        #expect(summarized.metadata.aiTitleProvenance == classified.metadata.aiTitleProvenance)
        #expect(summarized.metadata.aiLCCProvenance == classified.metadata.aiLCCProvenance)
        #expect(summarized.metadata.aiSummaryProvenance?.sourceRevision == digest(original))
        let corrected = try await reopened.updateSourceLCC(summarized, lcc: "Q")
        #expect(corrected.metadata.aiLCCProvenance == nil)
        #expect(corrected.metadata.aiTitleProvenance == summarized.metadata.aiTitleProvenance)
        #expect(corrected.metadata.aiSummaryProvenance == summarized.metadata.aiSummaryProvenance)
        let renamed = try await reopened.renameSource(corrected, title: "Manual title")
        #expect(renamed.metadata.aiTitleProvenance == nil)
        #expect(renamed.metadata.aiSummaryProvenance == summarized.metadata.aiSummaryProvenance)
        #expect(try FileVaultRepository.readSourceOriginal(renamed, root: root, contentStore: store) == original)
    }

    @Test func sourceSuggestionFailureAndConcurrentManualCorrectionPreserveStoredBytes() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let source = try await repo.importSource(data: Data("Original bytes".utf8), filename: "a.txt", title: "Original", originURL: nil)
        let snapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        let originalBytes = try store.base.read(at: path)
        let provenance = SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date())
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceTitle(snapshot, title: "Rejected", provenance: provenance, validate: { throw CancellationError() })
        }
        #expect(try store.base.read(at: path) == originalBytes)
        let corrected = try await repo.updateSourceLCC(source, lcc: "Q")
        let correctedBytes = try store.base.read(at: path)
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceLCC(snapshot, lcc: "QA", provenance: provenance, validate: {})
        }
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceTitle(snapshot, title: "Delayed", provenance: provenance, validate: {})
        }
        #expect(try store.base.read(at: path) == correctedBytes)
        let fresh = try await repo.sourceSummarySnapshot(id: source.id)
        var raceMetadata = corrected.metadata; raceMetadata.aiSummary = "Independent summary"
        let raceBytes = try JSONEncoder().encode(raceMetadata)
        store.state.withLock { $0.race = raceBytes }
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceLCC(fresh, lcc: "QA", provenance: provenance, validate: {})
        }
        #expect(try store.base.read(at: path) == raceBytes)
    }

    @Test func sourceTitleRejectsChangedOriginalWithoutTouchingMetadata() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let original = Data("Original bytes".utf8)
        let source = try await repo.importSource(data: original, filename: "a.txt", title: "Original", originURL: nil)
        let snapshot = try await repo.sourceSummarySnapshot(id: source.id)
        let path = "Sources/" + source.id.uuidString.lowercased()
        let metadataBytes = try store.base.read(at: path + "/metadata.json")
        try store.base.write(Data("External replacement".utf8), at: path + "/original.txt", condition: .replace(expected: original))
        await #expect(throws: (any Error).self) {
            try await repo.publishSourceTitle(snapshot, title: "Delayed", provenance: SummaryProvenance(provider: "OpenAI", model: "test", generatedAt: Date()), validate: {})
        }
        #expect(try store.base.read(at: path + "/metadata.json") == metadataBytes)
    }


    @Test func automaticInferredLCCRefusesConcurrentManualCorrectionAndTitleOnlyRenamePreservesIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SourceStoreProbe(root: root)
        let repo = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let source = try await repo.importSource(data: Data("Source content".utf8), filename: "a.txt", title: "Original", originURL: nil)
        let corrected = try await repo.updateSourceLCC(source, lcc: "Q")
        let path = "Sources/" + source.id.uuidString.lowercased() + "/metadata.json"
        let correctedBytes = try store.base.read(at: path)
        await #expect(throws: (any Error).self) {
            try await repo.renameSource(source, title: "Delayed automatic title", summary: "Delayed summary", lcc: "QA")
        }
        #expect(try store.base.read(at: path) == correctedBytes)
        #expect(try await repo.loadSource(id: source.id).metadata == corrected.metadata)
        let renamed = try await repo.renameSource(source, title: "Manual title")
        #expect(renamed.title == "Manual title")
        #expect(renamed.metadata.lcc == "Q")
        #expect(renamed.metadata.aiSummary == corrected.metadata.aiSummary)
        #expect(try await repo.loadSource(id: source.id).metadata == renamed.metadata)
    }

}


extension SourceAdapterTests {
    @Test func sourceImportPreservesOriginalAndRejectsMutation() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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

    @Test func linkedFolderLimitRejectsBeforePublishingAndCountsNestedFiles() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("External.txt")
        let bytes = Data("External source".utf8); try bytes.write(to: file)
        let root = folder.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try FileVaultRepository.open(root: root, create: true)
        let source = try await repository.linkSources(at: file, maximumFiles: 1)[0]
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) == "Available")
        try FileManager.default.removeItem(at: file)
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) != "Available")
        let broken = try await repository.scan()
        #expect(broken.sources.first?.id == source.id)
        #expect(broken.sources.first?.availabilityIssue != nil)
        #expect(broken.sources.first?.body == "")
        try bytes.write(to: file)
        // Replacing the deleted file invalidates the old security bookmark; relinking restores access.
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore).contains("stale"))
        try await repository.deleteSource(source)
        let relinked = try await repository.linkSources(at: file, maximumFiles: 1)[0]
        #expect(FileVaultRepository.checkSourceAvailability(relinked, root: root, contentStore: repository.contentStore) == "Available")
        #expect(try await repository.scan().sources.first(where: { $0.id == relinked.id })?.availabilityIssue == nil)
    }

    @Test func importedAvailabilityRejectsMissingAndChangedOriginals() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileVaultRepository.open(root: root, create: true)
        let source = try await repository.importSource(data: Data("Original".utf8), filename: "source.txt", title: "Source", originURL: nil)
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) == "Available")
        let file = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased() + "/original.txt")
        try Data("Changed".utf8).write(to: file)
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) != "Available")
        try FileManager.default.removeItem(at: file)
        #expect(FileVaultRepository.checkSourceAvailability(source, root: root, contentStore: repository.contentStore) == "File not found")
    }

    @Test func duplicateSourceRejectsSameBytesAcrossModesAndBatchContinues() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
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
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
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

    @Test func urlSourceFailureRetainsArchivedOriginalAndSummary() async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let manager = VaultSessionManager()
        let (_, _, repo) = try await manager.openRepository(root: folder, create: true)
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
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
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

    @Test(arguments: ["<html><nav>Navigation</nav><main><p>Article only</p></main><footer>Footer</footer></html>", "<html><body>Article without main</body></html>"])
    func wikipediaCaptureUsesFullHTML(html: String) async throws {
        let folder = try folder(); defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try FileVaultRepository.open(root: folder, create: true)
        let bytes = Data(html.utf8)
        let source = try await repo.importURLSource("https://en.wikipedia.org/wiki/Article", fetch: { _ in WebSourceFetch(data: bytes, filename: "page.html") })
        #expect(source.body == html)
        #expect(try await repo.scan().sources.first?.body == source.body)
        #expect(try Data(contentsOf: folder.appendingPathComponent("Sources/\(source.id.uuidString.lowercased())/original.html")) == bytes)
        #expect(source.metadata.sha256 == digest(bytes))
    }
}
