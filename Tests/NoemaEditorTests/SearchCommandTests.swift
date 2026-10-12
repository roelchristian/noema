import Foundation
import SwiftUI
import Testing
import VaultCore
import ExternalAI
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
            let repository = try await openCanonicalAppFixture(root: root, create: true)
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
            let originalNavigationToken = model.workspaceNavigationToken

            for (index, item) in [WorkspaceSearchMenuCommand.quickOpen, .vault, .quickOpen].enumerated() {
                #expect(model.canPerformWorkspaceCommand(item.command))
                model.performWorkspaceCommand(item.command)
                #expect(model.searchMode == (item == .vault ? .vault : .quickOpen))
                #expect(model.searchFocusToken == index + 1)
                #expect(model.workspaceNavigationToken == originalNavigationToken)
                #expect(model.scope == .sources && model.searchText == "Command")
                #expect(model.currentNote?.id == note.id && model.selectedID == note.id)
                #expect(model.title == note.title && model.body == note.body)
                #expect(!panes.isSidebarVisible && panes.sidebarWidth == originalSidebarWidth)
                #expect(panes.isInspectorVisible == originalInspectorVisible)
                #expect(defaults.bool(forKey: WorkspacePaneState.sidebarVisibilityKey) == false)
            }
            model.performWorkspaceCommand(.returnToLibrary)
            #expect(model.workspaceNavigationToken == originalNavigationToken + 1)
            #expect(model.scope == .sources && model.currentNote == nil)
            _ = await model.closeVault()
        }

        @Test @MainActor
        func sameScopeTrashCommandEmitsNavigationEvenWithoutSelectedDocument() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSameScopeCommand-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: true)
            #expect(model.isVaultAvailable)
            model.scope = .trash
            let initialToken = model.workspaceNavigationToken
            for offset in 1...2 {
                #expect(model.canPerformWorkspaceCommand(.showTrash))
                model.performWorkspaceCommand(.showTrash)
                #expect(model.workspaceNavigationToken == initialToken + offset)
                #expect(model.scope == .trash)
                #expect(model.selectedID == nil && model.currentNote == nil && model.currentSource == nil)
            }
            let admittedToken = model.workspaceNavigationToken
            // Return to Library requires a selected document, even in an available vault.
            #expect(!model.canPerformWorkspaceCommand(.returnToLibrary))
            model.performWorkspaceCommand(.returnToLibrary)
            #expect(model.workspaceNavigationToken == admittedToken)
            model.busy = true
            for command in [WorkspaceCommand.showTrash, .newPage, .newPersonalPage] {
                #expect(!model.canPerformWorkspaceCommand(command))
                model.performWorkspaceCommand(command)
                #expect(model.workspaceNavigationToken == admittedToken)
            }
            model.busy = false
            _ = await model.closeVault()
        }

        @Test @MainActor
        func searchCannotTakeFocusBehindConsentOrSuggestionSheets() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSearchSheets-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try await openCanonicalAppFixture(root: root, create: true)
            let note = try await repository.create(title: "Review Page", body: "Review text")
            let model = AppModel()
            model.localStorageRoot = base.appendingPathComponent("Local")
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            let lease = try #require(model.sessionManager.accessGate.currentLease)
            let snapshot = try await repository.pageSummarySnapshot(note)
            let request = try ExternalAISummaryRequest(authority: ExternalAIVaultAuthority(lease: lease),
                target: .page(note.id), contentRevision: UUID(), content: note.body)
            let confirmation = CloudSummaryConfirmation(request: request, snapshot: .page(snapshot),
                title: note.title, model: "test-model", selection: nil, editorRevision: UUID())

            for consent in [true, false] {
                model.cloudSummaryConfirmation = consent ? confirmation : nil
                model.pendingAISuggestion = consent ? nil : AISuggestion(id: UUID(), action: .suggestTitle,
                    value: "Reviewed title", rationale: nil, provider: .onDevice, target: .page(note.id))
                for command in [WorkspaceCommand.search, .quickOpen] {
                    #expect(!model.canPerformWorkspaceCommand(command))
                    model.performWorkspaceCommand(command)
                    #expect(model.searchFocusToken == 0 && model.workspaceNavigationToken == 0)
                }
                #expect(model.canPerformWorkspaceCommand(.lock))
            }
            model.cloudSummaryConfirmation = nil; model.pendingAISuggestion = nil
            #expect(model.canPerformWorkspaceCommand(.search))
            #expect(model.canPerformWorkspaceCommand(.quickOpen))
            #expect(await model.closeVault())
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
                #expect(model.workspaceNavigationToken == 0)
                #expect(model.searchText == "Preserved")
            }
        }
    }
}
