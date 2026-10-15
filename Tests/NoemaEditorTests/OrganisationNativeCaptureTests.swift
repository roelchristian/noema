import AppKit
import SwiftUI
import Testing
@testable import VaultCore
@testable import noema

/// Opt-in native review evidence, using an isolated vault and preference suite.
@Suite(.serialized) @MainActor
struct OrganisationNativeCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_ORGANISATION_CAPTURE_DIR"] != nil))
    func captureExpandedAndCollapsedSidebar() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["NOEMA_ORGANISATION_CAPTURE_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSidebarCapture-" + UUID().uuidString)
        let root = base.appendingPathComponent("Demo Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await openCanonicalAppFixture(root: root, create: true)
        let page = try await repository.create(title: "Research notes", body: "A personal atlas of thought.\n\nCollections gather related material. Folders organize it within a collection.")
        let source = try await repository.importSource(data: Data("Reading material for the collection.".utf8), filename: "reading.txt", title: "Reading material", originURL: nil)
        let store = repository.sqliteBlockStore
        let collection = try await store.createContainer(kind: .collection, name: "Research", parentID: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let folder = try await store.createContainer(kind: .folder, name: "Reading", parentID: collection.id, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        _ = try await store.createContainer(kind: .folder, name: "References", parentID: folder.id, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        let projects = try await store.createContainer(kind: .collection, name: "Projects", parentID: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        _ = try await store.addMembership(containerID: folder.id, reference: .init(kind: .page, itemID: page.id), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        _ = try await store.addMembership(containerID: folder.id, reference: .init(kind: .source, itemID: source.id), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        let model = AppModel()
        model.localStorageRoot = base.appendingPathComponent("Local")
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        try #require(model.isVaultAvailable)
        model.select(page.id)
        for _ in 0..<100 {
            if model.currentNote?.id == page.id { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.currentNote?.id == page.id)
        let suite = "NoemaSidebarCapture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let panes = WorkspacePaneState(defaults: defaults)
        panes.isCollectionVisible = false
        try await capture(ContentView(model: model, paneState: panes), to: directory.appendingPathComponent("sidebar-expanded.png"))
        try await capture(ContentView(model: model, paneState: panes, collapsedContainers: [collection.id]), to: directory.appendingPathComponent("sidebar-collapsed.png"))
        panes.isCollectionVisible = true
        panes.revealCollection()
        panes.isInspectorVisible = true
        try await capture(ContentView(model: model, paneState: panes, organisationSelection: folder.id), to: directory.appendingPathComponent("folder-contents-inspector.png"), size: NSSize(width: 1460, height: 740))
        try await capture(ContentView(model: model, paneState: panes, organisationSelection: folder.id), to: directory.appendingPathComponent("folder-compact-inspector.png"), size: NSSize(width: 1000, height: 740))
        panes.isInspectorVisible = false
        try await capture(ContentView(model: model, paneState: panes, organisationSelection: projects.id), to: directory.appendingPathComponent("collection-empty.png"), size: NSSize(width: 1100, height: 740))
        try #require(await model.closeVault())
    }

    private func capture<V: View>(_ view: V, to url: URL, size: NSSize = NSSize(width: 1100, height: 740)) async throws {
        _ = NSApplication.shared
        let root = view.environment(\.colorScheme, .dark)
            .environment(\.noemaTheme, NoemaTheme(dark: true, increasedContrast: false))
            .environment(\.appearsActive, true)
            .transaction { $0.disablesAnimations = true }
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
