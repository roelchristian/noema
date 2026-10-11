import Foundation
import PDFKit
import Testing
import VaultCore
@testable import noema

struct SourceSummaryStorageTests {
    @Test @MainActor func importedSummaryRejectsChangedOriginalAndUnsafeFilename() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/summary-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try FileVaultRepository.open(root: root, create: true)
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let original = try #require(pdf.dataRepresentation())
        let source = try await repository.importSource(data: original, filename: "fixture.pdf", title: "Fixture", originURL: nil)
        let model = AppModel(repository: repository)
        #expect(try await model.sourceSummaryContent(source, root: root).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let store = try PlaintextVaultContentStore(root: root)
        try store.write(Data([4, 5, 6, 7]), at: "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename,
                        condition: .replace(expected: original))
        await #expect(throws: VaultError.self) { _ = try await model.sourceSummaryContent(source, root: root) }
        var unsafe = source
        unsafe.metadata.storedFilename = "../../vault.json"
        await #expect(throws: VaultError.self) { _ = try await model.sourceSummaryContent(unsafe, root: root) }
    }
}
