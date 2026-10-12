import Foundation
import Testing
import VaultCore
@testable import noema

@Test func nativeWindowTitlesHideDocumentIdentityOutsideAvailableOpenSession() {
    let phases: [(VaultSessionPhase, String)] = [
        (.closed, "Noema"), (.opening, "Opening Vault…"),
        (.locking, "Locking Vault…"), (.locked, "Vault Locked"),
        (.unlocking, "Unlocking Vault…")
    ]
    for (phase, expected) in phases {
        for available in [false, true] {
            let value = WorkspaceWindowTitle(
                phase: phase, vaultName: "Atlas", scope: .wiki,
                document: .page("Private page"), vaultAvailable: available
            )
            #expect(value.title == expected)
            #expect(value.subtitle == (phase == .closed ? "" : "Atlas"))
        }
    }
    let reconstructing = WorkspaceWindowTitle(
        phase: .open, vaultName: "Atlas", scope: .wiki,
        document: .source("Private source"), vaultAvailable: false
    )
    #expect(reconstructing.title == "Opening Vault…")
    #expect(reconstructing.subtitle == "Atlas")
}

@Test func nativeWindowTitlesRepresentEveryLibraryScopeWithoutRedundantVaultSubtitle() {
    let scopes: [(LibraryScope, String)] = [
        (.wiki, "Pages"), (.sources, "Sources"), (.semantic, "Semantic Blocks"),
        (.trash, "Trash"), (.tag("Research"), "#Research")
    ]
    for (scope, expected) in scopes {
        let value = WorkspaceWindowTitle(phase: .open, vaultName: "Atlas", scope: scope, vaultAvailable: true)
        #expect(value.title == expected)
        #expect(value.subtitle.isEmpty)
    }
}

@Test func nativeWindowTitlesKeepFullDocumentIdentityAndOmitRedundantVaultSubtitle() {
    let longTitle = String(repeating: "Long document title 文献 📚 ", count: 40).trimmingCharacters(in: .whitespaces)
    for document in [WorkspaceWindowTitle.Document.page(longTitle), .source(longTitle)] {
        let value = WorkspaceWindowTitle(
            phase: .open, vaultName: "Atlas", scope: .sources,
            document: document, vaultAvailable: true
        )
        #expect(value.title == longTitle)
        #expect(!value.title.contains("…"))
        #expect(value.subtitle.isEmpty)
    }
    let duplicate = WorkspaceWindowTitle(
        phase: .open, vaultName: "Atlas", scope: .wiki,
        document: .page("atlas"), vaultAvailable: true
    )
    #expect(duplicate.title == "atlas")
    #expect(duplicate.subtitle.isEmpty)
    let emptyPage = WorkspaceWindowTitle(
        phase: .open, vaultName: "Atlas", scope: .wiki,
        document: .page(" \n "), vaultAvailable: true
    )
    let emptySource = WorkspaceWindowTitle(
        phase: .open, vaultName: "Atlas", scope: .sources,
        document: .source(""), vaultAvailable: true
    )
    #expect(emptyPage.title == "Untitled Page")
    #expect(emptySource.title == "Untitled Source")
    #expect(emptyPage.subtitle.isEmpty)
    #expect(emptySource.subtitle.isEmpty)
}

@Test @MainActor func nativeWindowTitleUsesGateMetadataBeforeModelObservation() {
    let model = AppModel()
    model.vaultName = "Previous vault"
    model.title = "Private previous page"
    let root = URL(fileURLWithPath: "/tmp/New Vault", isDirectory: true)
    model.sessionManager.accessGate.updateState(.opening(root: root, generation: 1))
    #expect(model.sessionPhase == .closed)
    #expect(model.windowTitle.title == "Opening Vault…")
    #expect(model.windowTitle.subtitle == "New Vault")
    model.sessionManager.accessGate.updateState(.locked(vaultID: UUID(), root: root, vaultName: "New Vault", generation: 1))
    #expect(model.windowTitle.title == "Vault Locked")
    #expect(model.windowTitle.subtitle == "New Vault")
    model.sessionManager.accessGate.updateState(.closed)
    #expect(model.windowTitle.title == "Noema")
    #expect(model.windowTitle.subtitle.isEmpty)
}

extension VaultUIIntegrationTests {
    @Test @MainActor func nativeWindowTitleTracksEditorAndPrimarySourceSelection() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-title-\(UUID())", isDirectory: true)
        let root = base.appendingPathComponent("Atlas", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try await openCanonicalAppFixture(root: root, create: true)
        let note = try await repo.create(title: "Initial page", body: "Content")
        let source = try await repo.importSource(data: Data("Source body".utf8), filename: "reference.txt", title: "Reference source", originURL: nil)
        let model = AppModel()
        model.localStorageRoot = base.appendingPathComponent("Local", isDirectory: true)
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        #expect(model.isVaultAvailable)

        model.currentNote = note
        model.selectedID = note.id
        model.title = note.title
        #expect(model.windowTitle.title == "Initial page")
        model.title = "Edited page"
        #expect(model.windowTitle.title == "Edited page")
        #expect(model.windowTitle.subtitle.isEmpty)

        model.currentNote = nil
        model.scope = .sources
        model.selectedID = source.id
        #expect(model.windowTitle.title == "Sources")
        #expect(model.windowTitle.subtitle.isEmpty)
        model.currentSource = source
        model.title = source.title
        #expect(model.windowTitle.title == "Reference source")
        #expect(model.windowTitle.subtitle.isEmpty)

        let session = try #require(model.sessionState.activeSession)
        // A direct revocation changes admission before the queued model observation runs.
        model.sessionManager.accessGate.updateState(.locking(session))
        #expect(model.currentSource != nil)
        #expect(model.windowTitle.title == "Locking Vault…")
        #expect(model.windowTitle.subtitle == "Atlas")
        model.sessionManager.accessGate.updateState(.open(session))
        #expect(await model.closeVault(force: true))
    }
}
