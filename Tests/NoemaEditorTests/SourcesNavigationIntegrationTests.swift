import Foundation
import PDFKit
import Synchronization
import Testing
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized)
struct SourcesNavigationIntegrationTests {
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test @MainActor func importedSummaryRejectsChangedOriginalAndUnsafeFilename() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/summary-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SummaryStoreProbe(root: root)
        let repository = try await openCanonicalAppFixture(root: root, create: true, contentStore: store)
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let original = try #require(pdf.dataRepresentation())
        let source = try await repository.importSource(data: original, filename: "fixture.pdf", title: "Fixture", originURL: nil)
        let model = AppModel(repository: repository)
        store.reads.withLock { $0.removeAll() }
        #expect(try await model.sourceSummaryContent(source, root: root).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(store.reads.withLock { $0.contains("Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename) })
        try store.write(Data([4, 5, 6, 7]), at: "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename,
                        condition: .replace(expected: original))
        await #expect(throws: VaultError.self) { _ = try await model.sourceSummaryContent(source, root: root) }
        var unsafe = source
        unsafe.metadata.storedFilename = "../../vault.json"
        await #expect(throws: VaultError.self) { _ = try await model.sourceSummaryContent(unsafe, root: root) }
    }

    @Test @MainActor func sourcesNavigationPreservesPreviewSearchRefreshAndSessionRestrictions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-sources-navigation-\(UUID())", isDirectory: true)
        let root = base.appendingPathComponent("Alpha", isDirectory: true)
        let otherRoot = base.appendingPathComponent("Beta", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let source = try await repository.importSource(data: Data("Unique searchable source content".utf8), filename: "fixture.txt", title: "Original Source", originURL: nil)
        _ = try await repository.create(title: "Fixture Page", body: "Page excerpt remains available")
        _ = try await openCanonicalAppFixture(root: otherRoot, create: true)
        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        model.sourceAvailabilityChecker = { _, _, _ in "Available (test)" }
        await model.open(root, create: false)
        #expect(model.isVaultAvailable)

        for _ in 0..<5 {
            model.changeScope(.sources)
            await model.updateRows()
            #expect(model.rows.map(\.id) == [source.id])
            #expect(model.rows.allSatisfy { $0.excerpt.isEmpty })
            model.changeScope(.wiki)
            await model.updateRows()
        }
        #expect(model.sources.first?.body == source.body)
        #expect(model.downloadingSources.isEmpty && model.generatingSourceTitles.isEmpty)
        #expect(model.generatingSourcePages.isEmpty && model.generatingSourceSummaries.isEmpty)
        #expect(model.rows.first?.excerpt.contains("Page excerpt") == true)

        model.changeScope(.sources)
        model.select(source.id)
        await waitUntil { model.currentSource?.id == source.id && !model.preview.isEmpty }
        #expect(model.currentSource?.id == source.id)
        #expect(model.body == source.body && !model.preview.isEmpty)
        model.openSource(source.id)
        await waitUntil { SourceReader.openReaderIDs.contains(source.id) }
        #expect(SourceReader.openReaderIDs.contains(source.id))
        model.checkSourceAvailability([source])
        await waitUntil { model.sourceAvailability[source.id] == "Available (test)" }
        #expect(model.sourceAvailability[source.id] == "Available (test)")

        model.renameSource(source, title: "Renamed Source")
        await waitUntil { model.sources.first?.title == "Renamed Source" }
        model.changeScope(.sources)
        await model.refresh()
        #expect(model.rows.first?.title == "Renamed Source")
        model.searchText = "searchable"
        model.queryChanged()
        // Scope changes and watcher refreshes can supersede a search while it awaits
        // the index. Observe the current query's published results, as the UI does.
        await waitUntil {
            model.searchStatus == .results && model.sidebarSearchResults.sources.map(\.id) == [source.id]
        }
        #expect(model.searchStatus == .results)
        #expect(model.sidebarSearchResults.sources.map(\.id) == [source.id])
        model.searchText = ""
        await model.updateRows()

        #expect(await model.lockVault())
        #expect(model.sources.isEmpty && model.rows.isEmpty && model.sourceAvailability.isEmpty)
        #expect(model.currentSource == nil && model.body.isEmpty && model.preview.isEmpty)
        #expect(SourceReader.openReaderIDs.isEmpty)
        model.changeScope(.sources)
        model.select(source.id)
        model.openSource(source.id)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.sources.isEmpty && model.currentSource == nil)
        #expect(SourceReader.openReaderIDs.isEmpty)
        #expect(await model.unlockVault())
        model.changeScope(.sources)
        await model.updateRows()
        #expect(model.rows.first?.title == "Renamed Source")
        #expect(model.rows.first?.id == source.id)

        await model.open(otherRoot, create: false)
        #expect(model.root == otherRoot && model.sources.isEmpty && model.currentSource == nil)
        model.changeScope(.sources)
        await model.updateRows()
        #expect(model.rows.isEmpty && SourceReader.openReaderIDs.isEmpty)
        #expect(await model.closeVault())
        #expect(!model.isVaultAvailable && model.rows.isEmpty)
    }
    @Test @MainActor func metadataSelectionMaterializesAndRefreshDiscardsUnavailableInspectorContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-source-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: root) }
        let store = try NavigationSourceStore(root: root)
        let repository = try await openCanonicalAppFixture(root: root, create: true, contentStore: store)
        let bytes = Data("Fresh selected source text".utf8)
        let source = try await repository.importSource(data: bytes, filename: "source.txt", title: "Source", originURL: nil)
        let model = AppModel(storageProvider: VaultStorageProvider { _ in store })
        model.localStorageRoot = root.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        let metadata = try await repository.scanSources()
        model.sources = metadata.sources
        model.changeScope(.sources)
        model.select(source.id)
        await waitUntil { model.currentSource?.contentState == .notLoaded }
        #expect(model.currentSource?.availabilityIssue == "Not verified")
        #expect(model.body.isEmpty)
        model.updateSourceLCC(metadata.sources[0], lcc: "QA")
        for _ in 0..<100 {
            if try await repository.scanSources().sources.first?.metadata.lcc == "QA" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Wait for the index actor after the metadata write, while the UI still has a notLoaded record.
        try await Task.sleep(for: .milliseconds(30))
        await waitUntil { model.currentSource?.contentState == .loaded && !model.preview.isEmpty }
        #expect(model.errorMessage == nil)
        #expect(model.currentSource?.contentState == .loaded && model.body == source.body && !model.preview.isEmpty)
        #expect(try await repository.scanSources().sources.first?.metadata.lcc == "QA")
        #expect(try await model.sourceSummaryContent(metadata.sources[0], root: root).contains("Fresh selected"))
        await model.refresh()
        await waitUntil { !model.preview.isEmpty }
        #expect(model.currentSource?.contentState == .loaded)
        #expect(model.body == source.body && model.wordCount > 0 && !model.preview.isEmpty)
        model.sourceAvailability[source.id] = "Available"
        store.unavailable.withLock { $0 = true }
        await model.refresh()
        // A watcher refresh can already be running. refresh() then schedules another pass;
        // await the published unavailable state before restoring the fixture's storage.
        await waitUntil {
            model.currentSource?.contentState == .unavailable &&
            model.body.isEmpty && model.preview.isEmpty && model.wordCount == 0 &&
            model.sourceAvailability[source.id] == nil
        }
        #expect(model.currentSource?.contentState == .unavailable)
        #expect(model.body.isEmpty && model.preview.isEmpty && model.wordCount == 0)
        #expect(model.sourceAvailability[source.id] == nil)
        #expect(model.currentSource?.availabilityIssue?.contains("iCloud") == true)
        store.unavailable.withLock { $0 = false }
        await model.refresh()
        await waitUntil { !model.preview.isEmpty }
        #expect(model.body == source.body && !model.preview.isEmpty)
        let original = "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename
        try store.base.write(Data("Corruption".utf8), at: original, condition: .replace(expected: bytes))
        await model.refresh()
        await waitUntil {
            model.currentSource?.contentState == .unavailable &&
            model.body.isEmpty && model.preview.isEmpty && model.sourceAvailability.isEmpty
        }
        // Canonical source identity survives corruption; its plaintext becomes unavailable.
        #expect(model.sources.map(\.id) == [source.id])
        #expect(model.currentSource?.id == source.id && model.selectedID == source.id)
        #expect(model.currentSource?.contentState == .unavailable)
        #expect(model.currentSource?.availabilityIssue?.contains("checksum") == true)
        #expect(model.body.isEmpty && model.preview.isEmpty && model.sourceAvailability.isEmpty)
        #expect(await model.closeVault())
    }

    @Test @MainActor func linkedContentRefreshUpdatesSelectedPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-linked-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: root) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let external = root.appendingPathComponent("Linked.txt")
        try Data("First linked content".utf8).write(to: external)
        let source = try #require(try await repository.linkSources(at: external, maximumFiles: 1).first)
        let model = AppModel()
        model.localStorageRoot = root.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        model.changeScope(.sources); model.select(source.id)
        await waitUntil { model.currentSource?.id == source.id && !model.preview.isEmpty }
        let oldPreview = model.preview
        try Data("Second linked content with more words".utf8).write(to: external)
        await model.refresh()
        await waitUntil { model.wordCount == 6 }
        #expect(model.body == "Second linked content with more words")
        #expect(model.preview != oldPreview && !model.preview.isEmpty)
        #expect(await model.closeVault())
    }

}
}

private final class NavigationSourceStore: VaultContentStore {
    let base: PlaintextVaultContentStore
    let unavailable = Mutex(false)
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    private func validate(_ path: String) throws {
        if path.contains("/original."), unavailable.withLock({ $0 }) { throw VaultContentStoreError.unavailable(path) }
    }
    func synchronize(at path: String) throws { try base.synchronize(at: path) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalLinked(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data { try validate(path); return try base.read(at: path) }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try validate(path); return try base.changeToken(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}

private final class SummaryStoreProbe: VaultContentStore {
    let base: PlaintextVaultContentStore
    let reads = Mutex([String]())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
    func synchronize(at path: String) throws { try base.synchronize(at: path) }
    func publishCanonicalOriginal(_ data: Data, metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.publishCanonicalOriginal(data, metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalOriginal(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalOriginal(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func verifyCanonicalLinked(metadata: SourceMetadata, vaultID: UUID, operationID: UUID) throws -> CanonicalSourceByteReceipt {
        try base.verifyCanonicalLinked(metadata: metadata, vaultID: vaultID, operationID: operationID)
    }
    func createDirectory(at path: String) throws { try base.createDirectory(at: path) }
    func read(at path: String) throws -> Data {
        reads.withLock { $0.append(path) }
        return try base.read(at: path)
    }
    func snapshot(at path: String) throws -> VaultContentSnapshot { try base.snapshot(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { try base.delete(at: path, expected: expected) }
}
