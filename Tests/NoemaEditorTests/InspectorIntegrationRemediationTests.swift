import Foundation
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite("Inspector Integration Remediation (UI.R.REM01)", .serialized)
struct InspectorIntegrationRemediationTests {
    @MainActor
    private func selectPage(_ page: NoteRecord, in model: AppModel, targets: [String]) async throws {
        model.select(page.id)
        for _ in 0..<100 {
            if model.currentNote?.id == page.id && model.outgoingLinkTargets == targets { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.currentNote?.id == page.id)
        try #require(model.outgoingLinkTargets == targets)
    }

    // UI.R.REM01: Both merged initialization paths must discard the previous vault's links.
    @Test @MainActor
    func populatedInspectorLinksArePurgedAcrossLockUnlockVaultSwitchAndClose() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-inspector-rem01-\(UUID())", isDirectory: true)
        let rootA = base.appendingPathComponent("Vault A", isDirectory: true)
        let rootB = base.appendingPathComponent("Vault B", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer {
            SourceReader.closeAll()
            try? FileManager.default.removeItem(at: base)
        }
        let repoA = try FileVaultRepository.open(root: rootA, create: true)
        let pageA = try await repoA.create(title: "Page A", body: "See [[Target A]].")
        let targetA = try await repoA.create(title: "Target A", body: "See [[Page A]].")
        let repoB = try FileVaultRepository.open(root: rootB, create: true)
        let pageB = try await repoB.create(title: "Page B", body: "See [[Only In B]].")

        let model = AppModel()
        model.localStorageRoot = base
        model.persistSecurityScopedBookmark = false
        await model.open(rootA, create: false)
        try #require(model.isVaultAvailable)
        try await selectPage(pageA, in: model, targets: ["target a"])
        #expect(model.backlinks.map(\.id) == [targetA.id])

        try #require(await model.lockVault())
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: nil) == .none)

        try #require(await model.unlockVault())
        #expect(model.currentNote == nil)
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        try await selectPage(pageA, in: model, targets: ["target a"])
        #expect(model.backlinks.map(\.id) == [targetA.id])

        await model.open(rootB, create: false)
        try #require(model.isVaultAvailable && model.root == rootB)
        #expect(model.currentNote == nil)
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        try await selectPage(pageB, in: model, targets: ["only in b"])
        #expect(model.backlinks.isEmpty)

        try #require(await model.closeVault())
        #expect(model.outgoingLinkTargets.isEmpty && model.backlinks.isEmpty)
        #expect(InspectorContext.resolve(model: model, librarySourceSelection: nil) == .none)
    }
}
}
