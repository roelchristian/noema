import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
    @Suite(.serialized) @MainActor
    struct HostedNavigationEditingTests {
        @Test func identityKeyedNavigationKeepsNativeEditing() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaHostedNavigation-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let a = try await repository.create(title: "A", body: "Ada Lovelace")
            let b = try await repository.create(title: "B", body: "")
            let model = AppModel(); model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false); model.select(a.id)
            _ = NSApplication.shared
            let host = NSHostingView(rootView: ContentView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            func editor(_ view: NSView) -> ArticleTextView? {
                if let article = view as? ArticleTextView { return article }
                return view.subviews.compactMap { editor($0) }.first
            }
            func ready() async throws -> ArticleTextView {
                for _ in 0..<200 {
                    host.layoutSubtreeIfNeeded()
                    if model.canEditPage, let view = editor(host), view.isEditable { return view }
                    try await Task.sleep(for: .milliseconds(10))
                }
                print("READINESS page=\(String(describing: model.currentNote?.id)) coordinator=\(String(describing: model.semanticCoordinator?.session.identity)) authority=\(model.semanticCoordinator?.session.semanticEdit != nil) locked=\(model.editingLocked) error=\(String(describing: model.errorMessage))")
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            let initial = try await ready()
            initial.setSelectedRange(NSRange(location: 0, length: 3))
            let coordinator = try #require(model.semanticCoordinator)
            let selection = try #require(coordinator.annotationSelection())
            try await model.annotateSelection(coordinator, selection.0, selection.1,
                .newEntity(typeKey: "person", label: "Ada"), coordinator.session.revision)
            #expect(await model.saveCurrent())
            model.toggleEditingLock(a.id)
            for _ in 0..<200 {
                if model.editingLockOperations.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(model.editingLocked)
            model.select(b.id)
            let destination = try await ready()
            #expect(coordinator.session.identity.pageID == a.id)
            let destinationCoordinator = try #require(model.semanticCoordinator)
            model.unregisterHostedEditor(coordinator) // A late teardown cannot release B.
            #expect(model.semanticCoordinator === destinationCoordinator)
            #expect(model.flushEditorPublication != nil && model.canFormatDocument)
            window.makeFirstResponder(destination)
            destination.insertText("Destination", replacementRange: NSRange(location: 0, length: 0))
            model.flushEditorPublication?()
            #expect(model.editorDocument.blocks.first?.text == "Destination")
            destination.setSelectedRange(NSRange(location: 0, length: 11))
            model.editorAction = EditorAction(operation: .wrap("**", "**"))
            for _ in 0..<200 {
                host.layoutSubtreeIfNeeded()
                if model.editorDocument.blocks.first?.runs.first?.style.bold == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.editorDocument.blocks.first?.runs.first?.style.bold == true)
            #expect(await model.saveCurrent())
            let savedB = try await repository.sqliteBlockStore.loadSemanticPage(pageID: b.id)
            #expect(savedB.snapshot.document.blocks.first?.text == "Destination")
            #expect(savedB.snapshot.document.blocks.first?.runs.first?.style.bold == true)
            model.select(a.id)
            model.newPage(named: "C")
            for _ in 0..<200 {
                if model.currentNote?.title == "C" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let blank = try await ready()
            let c = try #require(model.currentNote?.id)
            window.makeFirstResponder(blank)
            blank.insertText("New destination", replacementRange: NSRange(location: 0, length: 0))
            model.flushEditorPublication?()
            #expect(model.editorDocument.blocks.first?.text == "New destination")
            #expect(await model.saveCurrent())
            model.toggleEditingLock(c)
            for _ in 0..<200 {
                if model.editingLockOperations.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.editingLocked && !blank.isEditable)
            model.toggleEditingLock(c)
            let unlocked = try await ready()
            window.makeFirstResponder(unlocked)
            unlocked.insertText(" pending", replacementRange: NSRange(location: 15, length: 0))
            let release = AsyncStream.makeStream(of: Void.self)
            var savingEntered = false
            model.pageSavePreparation = {
                savingEntered = true
                for await _ in release.stream { break }
            }
            defer { release.continuation.finish() }
            model.select(b.id)
            for _ in 0..<200 {
                if savingEntered { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(savingEntered)
            model.select(c)
            let resumed = try await ready()
            #expect(resumed.string.contains("New destination pending"))
            model.select(b.id); model.select(c); model.select(b.id); model.select(c)
            _ = try await ready()
            release.continuation.finish(); model.pageSavePreparation = nil
            #expect(await model.flushPendingEdits())
            #expect(try await repository.sqliteBlockStore.loadSemanticPage(pageID: c).snapshot.document.blocks.first?.text == "New destination pending")
            #expect(try await repository.sqliteBlockStore.loadSemanticPage(pageID: a.id).annotations.count == 1)
            #expect(model.errorMessage == nil && model.pageSaveFailures.isEmpty)
            #expect(await model.closeVault())
        }
    }
}
