import Foundation
import PDFKit
import Synchronization
import Testing
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
struct SourceSummaryStorageTests {
    @Test @MainActor func importedSummaryRejectsChangedOriginalAndUnsafeFilename() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/summary-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SummaryStoreProbe(root: root)
        let repository = try FileVaultRepository.open(root: root, create: true, contentStore: store)
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
}
}

private final class SummaryStoreProbe: VaultContentStore {
    let base: PlaintextVaultContentStore
    let reads = Mutex([String]())
    init(root: URL) throws { base = try PlaintextVaultContentStore(root: root) }
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
