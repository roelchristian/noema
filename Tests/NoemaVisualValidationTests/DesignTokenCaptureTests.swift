import AppKit
import SwiftUI
import Testing
import NoemaBrand
@testable import VaultCore
@testable import noema

/// Explicit visual-validation harness; excluded from the default package test graph.
@Suite("Visual validation: design token native captures", .serialized)
struct DesignTokenCaptureTests {
    private struct AppearanceCase {
        let preference: ThemePreference
        let dark: Bool
        let increased: Bool
        var name: String {
            "\(preference.rawValue)-\(dark ? "dark" : "light")-\(increased ? "increased" : "standard")"
        }
        var theme: NoemaTheme {
            var value = NoemaTheme(dark: dark, increasedContrast: increased)
            value.preference = preference
            value.fullPalette = true
            return value
        }
        var appearance: NSAppearance.Name {
            if increased { return dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua }
            return dark ? .darkAqua : .aqua
        }
    }

    private var appearances: [AppearanceCase] {
        [.system, .midnightIris].flatMap { preference in
            [false, true].flatMap { dark in
                [false, true].map { AppearanceCase(preference: preference, dark: dark, increased: $0) }
            }
        }
    }

    @Test @MainActor func captureNativeAppearanceMatrixWhenRequested() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["NOEMA_TOKEN_SCREENSHOT_DIR"], "Invoke validation/ui-design-tokens/capture.sh with a managed run ID")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaTokenValidation-" + UUID().uuidString)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try FileVaultRepository.open(root: root, create: true)
        let model = AppModel()
        model.localStorageRoot = base.appendingPathComponent("Local", isDirectory: true)
        model.persistSecurityScopedBookmark = false
        await model.open(root, create: false)
        try #require(model.isVaultAvailable)
        var note = pageFixture()
        let source = sourceFixture()
        note.sourceIDs = [source.id]
        model.vaultName = "Design Token Fixture"
        model.notes = [note]
        model.sources = [source]
        model.currentNote = note
        model.selectedID = note.id
        model.title = note.title
        model.body = note.body
        model.tagInput = "architecture, macos"
        model.wordCount = 26
        model.lccInput = "QA76.76.D47"
        model.outgoingLinkTargets = ["Missing reference"]
        let state = InspectorState()
        for appearance in appearances {
            model.scope = .wiki
            model.currentNote = note
            try await renderWorkspace(model: model, name: "workspace-page", size: NSSize(width: 1200, height: 760), appearance: appearance, directory: directory)
            // Preserve the historical comparison fixture; native minimums have separate names.
            try await renderWorkspace(model: model, name: "workspace-minimum", size: NSSize(width: 960, height: 620), appearance: appearance, directory: directory)
            try await renderWorkspace(model: model, name: "workspace-native-minimum", size: NSSize(width: 720, height: 540), appearance: appearance, directory: directory)
            for context in [InspectorContext.page(note), .source(source, isDetail: false)] {
                let kind = context.targetKind == .page ? "page" : "source"
                for width in [InspectorState.minWidth, InspectorState.idealWidth, InspectorState.maxWidth] {
                    for tab in context.applicableTabs {
                        state.selectTab(tab, for: context)
                        try await render(InspectorContainer(model: model, state: state, context: context),
                            name: "inspector-\(kind)-\(tab.rawValue)-\(Int(width))", size: NSSize(width: width, height: 620),
                            appearance: appearance, directory: directory)
                    }
                }
            }
            state.selectTab(.properties, for: .page(note))
            for active in [false, true] {
                try await render(InspectorTabBar(tabs: InspectorTab.pageTabs, selectedTab: .properties, onSelect: { _ in })
                    .environment(\.appearsActive, active), name: "inspector-tabs-\(active ? "active" : "inactive")",
                    size: NSSize(width: 280, height: 44), appearance: appearance, directory: directory)
            }
            model.currentNote = nil
            model.selectedID = nil
            model.scope = .sources
            let presentation = SourcesTablePresentation()
            presentation.synchronize(inputs: [SourceTableInput(source: source)])
            try await render(SourcesLibraryView(model: model, presentation: presentation, selection: .constant(source.id), rename: { _ in }, delete: { _ in }), name: "sources-native-table", size: NSSize(width: 760, height: 620), appearance: appearance, directory: directory)
            try await renderWorkspace(model: model, name: "workspace-sources", size: NSSize(width: 960, height: 620), appearance: appearance, directory: directory)
            model.scope = .wiki
            model.notes = []
            try await renderWorkspace(model: model, name: "workspace-empty", size: NSSize(width: 960, height: 620), appearance: appearance, directory: directory)
            model.notes = [note]
            try await render(VaultCreationSheet(model: AppModel()), name: "vault-creation-sheet-content", size: NSSize(width: 540, height: 560), appearance: appearance, directory: directory)
            try await renderWorkspace(model: AppModel(), name: "workspace-no-vault", size: NSSize(width: 960, height: 620), appearance: appearance, directory: directory)
            try await renderWorkspace(model: AppModel(), name: "workspace-welcome-compact", size: NSSize(width: 680, height: 480), appearance: appearance, directory: directory)
        }
        try #require(await model.lockVault())
        for appearance in appearances {
            try await renderWorkspace(model: model, name: "workspace-locked", size: NSSize(width: 960, height: 620), appearance: appearance, directory: directory)
        }
        _ = await model.closeVault()
        let capturedCount = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }.count
        print("UI.TK07 captured \(capturedCount) native fixture PNGs in \(directory.path); Animations disabled for static capture; actual Reduce Motion is read-only OS state.")
    }

    @MainActor private func renderWorkspace(model: AppModel, name: String, size: NSSize,
                                            appearance: AppearanceCase, directory: URL) async throws {
        let suiteName = "NoemaTokenValidation.Panes." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let panes = WorkspacePaneState(defaults: defaults)
        try await render(ContentView(model: model, paneState: panes), name: name, size: size,
                         appearance: appearance, directory: directory)
    }

    @MainActor private func render<V: View>(_ view: V, name: String, size: NSSize,
                                           appearance: AppearanceCase, directory: URL) async throws {
        let theme = appearance.theme
        let root = view
            .environment(\.noemaTheme, theme)
            .environment(\.colorScheme, appearance.dark ? .dark : .light)
            .transaction { $0.disablesAnimations = true }
            .tint(theme.accent)
            .accentColor(theme.accent)
            .scrollContentBackground(theme.usesFullPalette ? .hidden : .automatic)
            .background(theme.color(.background))
            .frame(width: size.width, height: size.height)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance.appearance)
        hosting.appearance = window.appearance
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        // Permit initial onAppear/native representable work to finish without UI input.
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        #expect(hosting.fittingSize.width <= size.width + 1, "\(name) overflow at \(size.width)pt in \(appearance.name)")
        let verticalSafeArea = hosting.safeAreaInsets.top + hosting.safeAreaInsets.bottom
        #expect(hosting.fittingSize.height <= size.height + verticalSafeArea + 1, "\(name) host bounds exceed the requested frame and native safe area in \(appearance.name)")
        print("UI.TK07 bounds \(name) \(appearance.name): \(hosting.bounds.size), safe area \(verticalSafeArea)")
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        // A flat/transparent raster should fail instead of masquerading as evidence.
        var colors: Set<String> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 11) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 11) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.sRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)),\(Int(color.alphaComponent * 255))")
                }
            }
        }
        #expect(colors.count > 8, "\(name) produced a blank or nearly flat raster in \(appearance.name)")
        let png = try #require(bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name)-\(appearance.name).png"))
    }

    private func pageFixture() -> NoteRecord {
        let body = "# Native visual foundations\n\nA calm workspace keeps shared navigation and contextual details legible.\n\n[[Missing reference]]\n\n- Semantic colors\n- Consistent spacing\n- Native controls"
        return NoteRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, title: "Visual Foundations", aliases: ["UI.TK"], tags: ["architecture", "macos"], inlineTags: [], createdAt: "2026-10-12T00:00:00Z", updatedAt: "2026-10-12T00:00:00Z", body: body, relativePath: "Wiki/Visual Foundations.md", contentHash: digest(Data(body.utf8)), lcc: "QA76.76.D47", editingLocked: true, originalHeader: nil)
    }

    private func sourceFixture() -> SourceRecord {
        SourceRecord(metadata: SourceMetadata(id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!, title: "Native Interface Reference", capturedAt: "2026-10-12T00:00:00Z", originalFilename: "reference.pdf", originURL: "https://example.com/reference", sha256: "fixture", lcc: "QA76.9.U83", aiSummary: "Native macOS interface reference.", fileSize: 4096, storedFilename: "reference.pdf"), body: "Read-only reference content.")
    }
}
