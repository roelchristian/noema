import Foundation
import SwiftUI
import Testing
import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
    @Suite(.serialized)
    struct SearchCommandTests {
        @Test
        func menuShortcutsDescribeDistinctSearchCommandsAndReserveDocumentFind() {
            let vault = WorkspaceSearchMenuCommand.vault
            #expect(vault.title == "Find in Vault")
            #expect(vault.command == .search)
            #expect(vault.shortcut.key == KeyEquivalent("f"))
            #expect(vault.shortcut.modifiers == [.command, .shift])

            let quickOpen = WorkspaceSearchMenuCommand.quickOpen
            #expect(quickOpen.title == "Quick Open")
            #expect(quickOpen.command == .quickOpen)
            #expect(quickOpen.shortcut.key == KeyEquivalent("p"))
            #expect(quickOpen.shortcut.modifiers == [.command])
            #expect(!WorkspaceSearchMenuCommand.allCases.contains {
                $0.shortcut.key == KeyEquivalent("f") && $0.shortcut.modifiers == [.command]
            })
        }

        @Test @MainActor
        func commandsSwitchModeAndRequestFocusWithoutChangingNavigationOrQuery() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSearchCommands-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try FileVaultRepository.open(root: root, create: true)
            let note = try await repository.create(title: "Command Page", body: "Protected command body")
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)
            model.currentNote = note; model.selectedID = note.id
            model.title = note.title; model.body = note.body
            model.scope = .sources
            model.searchText = "Command"

            let defaultsName = "NoemaSearchCommands.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: defaultsName))
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            defaults.set(false, forKey: WorkspacePaneState.sidebarVisibilityKey)
            let panes = WorkspacePaneState(defaults: defaults)
            let originalSidebarWidth = panes.sidebarWidth
            let originalInspectorVisible = panes.isInspectorVisible

            for (index, item) in [WorkspaceSearchMenuCommand.quickOpen, .vault, .quickOpen].enumerated() {
                #expect(model.canPerformWorkspaceCommand(item.command))
                model.performWorkspaceCommand(item.command)
                #expect(model.searchMode == (item == .vault ? .vault : .quickOpen))
                #expect(model.searchFocusToken == index + 1)
                #expect(model.scope == .sources && model.searchText == "Command")
                #expect(model.currentNote?.id == note.id && model.selectedID == note.id)
                #expect(model.title == note.title && model.body == note.body)
                #expect(!panes.isSidebarVisible && panes.sidebarWidth == originalSidebarWidth)
                #expect(panes.isInspectorVisible == originalInspectorVisible)
                #expect(defaults.bool(forKey: WorkspacePaneState.sidebarVisibilityKey) == false)
            }
            _ = await model.closeVault()
        }

        @Test @MainActor
        func rejectedSearchCommandsCannotChangeModeOrFocus() {
            let model = AppModel()
            model.searchMode = .quickOpen
            model.searchText = "Preserved"
            for item in WorkspaceSearchMenuCommand.allCases {
                #expect(!model.canPerformWorkspaceCommand(item.command))
                #expect(model.performWorkspaceCommand(item.command) == nil)
                #expect(model.searchMode == .quickOpen && model.searchFocusToken == 0)
                #expect(model.searchText == "Preserved")
            }
        }
    }
}
