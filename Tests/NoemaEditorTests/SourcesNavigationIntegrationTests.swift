import Foundation
import Testing
import VaultCore
@testable import noema

@Suite(.serialized)
struct SourcesNavigationIntegrationTests {
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test @MainActor func sourcesNavigationPreservesPreviewSearchRefreshAndSessionRestrictions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-sources-navigation-\(UUID())", isDirectory: true)
        let root = base.appendingPathComponent("Alpha", isDirectory: true)
        let otherRoot = base.appendingPathComponent("Beta", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { SourceReader.closeAll(); try? FileManager.default.removeItem(at: base) }
        let repository = try FileVaultRepository.open(root: root, create: true)
        let source = try await repository.importSource(data: Data("Unique searchable source content".utf8), filename: "fixture.txt", title: "Original Source", originURL: nil)
        _ = try await repository.create(title: "Fixture Page", body: "Page excerpt remains available")
        _ = try FileVaultRepository.open(root: otherRoot, create: true)
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
        await model.updateRows()
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
}
