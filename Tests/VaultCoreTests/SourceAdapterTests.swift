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
