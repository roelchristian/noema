import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
    @Suite(.serialized)
    struct WorkspaceCommandTests {
        @Test(arguments: VaultSessionPhase.allCases)
        func availabilityFollowsEverySessionPhase(phase: VaultSessionPhase) {
            let policy = WorkspaceCommandAvailability(
                phase: phase, stateMatchesManager: true, vaultAvailable: phase == .open,
                documentSelected: true, pageSelected: true, hasRecovery: true, hasNotices: true
            )
            for command in WorkspaceCommand.allCases {
                let expected: Bool
                switch command {
                case .openVault, .createVault: expected = [.closed, .open, .locked].contains(phase)
                case .close: expected = [.open, .locked].contains(phase)
                case .unlock: expected = phase == .locked
                default: expected = phase == .open
                }
                #expect(policy.allows(command) == expected)
            }
        }

        @Test
        func transitionalWorkAndPresentationsDisableEveryCommand() {
            let stable = WorkspaceCommandAvailability(
                phase: .open, stateMatchesManager: true, vaultAvailable: true,
                documentSelected: true, pageSelected: true, hasRecovery: true, hasNotices: true
            )
            var busy = stable; busy.busy = true
            var pending = stable; pending.actionPending = true
            var modal = stable; modal.presentationPending = true
            var settings = stable; settings.settingsPresented = true
            var stale = stable; stale.stateMatchesManager = false
            for policy in [busy, pending, modal, settings, stale] {
                for command in WorkspaceCommand.allCases { #expect(!policy.allows(command)) }
            }
        }

        @Test
        func contextAvailabilityRequiresMatchingContent() {
            let policy = WorkspaceCommandAvailability(phase: .open, stateMatchesManager: true, vaultAvailable: true)
            #expect(!policy.allows(.returnToLibrary))
            #expect(!policy.allows(.save))
            #expect(!policy.allows(.recovery))
            #expect(!policy.allows(.notices))
            #expect(policy.allows(.search))
            #expect(policy.allows(.quickOpen))
            #expect(policy.allows(.newTopicPage))
        }

        @Test @MainActor
        func closedAndManagerMismatchCommandsCannotMutateUIState() {
            let gate = VaultAccessGate()
            let model = AppModel(sessionManager: VaultSessionManager(accessGate: gate))
            for command in [WorkspaceCommand.search, .quickOpen, .newTopicPage, .addURLSource, .pasteSource, .recovery, .notices, .lock, .unlock, .close] {
                #expect(model.performWorkspaceCommand(command) == nil)
            }
            #expect(model.searchFocusToken == 0)
            #expect(!model.showTopicPage && !model.showURLSource && !model.showPasteSource)
            model.busy = true
            model.chooseVault(create: true)
            #expect(!model.showVaultCreation)
            model.busy = false
            gate.updateState(.opening(root: URL(fileURLWithPath: "/tmp/UnopenedVault"), generation: 1))
            for command in WorkspaceCommand.allCases { #expect(!model.canPerformWorkspaceCommand(command)) }
            model.chooseVault(create: true)
            #expect(!model.showVaultCreation)
            gate.updateState(.closed)
        }

        @Test @MainActor
        func queuedLifecycleCommandRechecksManagerBeforeAccessingVault() async throws {
            let root = URL(fileURLWithPath: "/tmp/UnavailableCommandVault")
            let vaultID = UUID()
            let state = VaultSessionState.locked(vaultID: vaultID, root: root, vaultName: "Unavailable", generation: 1)
            let gate = VaultAccessGate(initialState: state)
            let model = AppModel(sessionManager: VaultSessionManager(accessGate: gate))
            let task = try #require(model.performWorkspaceCommand(.unlock))
            #expect(model.workspaceCommandPending)
            #expect(model.performWorkspaceCommand(.unlock) == nil)
            gate.updateState(.unlocking(vaultID: vaultID, root: root, vaultName: "Unavailable", generation: 1))
            await task.value
            #expect(!model.workspaceCommandPending)
            #expect(model.errorMessage == nil && model.sessionTransitionErrors.isEmpty)
            #expect(gate.currentState.phase == .unlocking)
            gate.updateState(.closed)
        }

        @Test @MainActor
        func staleRepositoryLeaseDisablesLoadedContentCommands() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaCommandLease-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let manager = VaultSessionManager()
            let (_, _, oldRepository) = try await manager.openRepository(root: root, create: true)
            let note = try await oldRepository.create(title: "Retained", body: "Protected body")
            try await manager.lock()
            _ = try await manager.unlock()
            let model = AppModel(repository: oldRepository, sessionManager: manager)
            model.root = root; model.notes = [note]; model.currentNote = note
            #expect(model.sessionPhase == .open && !model.isVaultAvailable)
            for command in [WorkspaceCommand.search, .quickOpen, .returnToLibrary, .newPage, .newTopicPage, .save, .addURLSource, .lock] {
                #expect(!model.canPerformWorkspaceCommand(command))
                #expect(model.performWorkspaceCommand(command) == nil)
            }
            #expect(model.searchFocusToken == 0 && !model.showTopicPage && !model.showURLSource)
            try await manager.close()
        }

        @Test @MainActor
        func damagedOnlyRecoveryRemainsAvailableThroughSharedCommandAndUnlock() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaDamagedCommand-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try FileVaultRepository.open(root: root, create: true)
            let local = base.appendingPathComponent("Local")
            let drafts = local.appendingPathComponent("KnowledgeVault/\(repository.manifest.id.uuidString)/Drafts")
            _ = try RecoveryStore(unguardedTestingDirectory: drafts)
            let damagedFile = drafts.appendingPathComponent(UUID().uuidString + ".json")
            let damagedBytes = Data("{\"body\":\"Incomplete unsaved draft".utf8)
            try damagedBytes.write(to: damagedFile)
            let model = AppModel()
            model.localStorageRoot = local
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable && model.recoveredDrafts.isEmpty)
            #expect(model.damagedRecoveryEntries.count == 1)
            #expect(model.canPerformWorkspaceCommand(.recovery))
            model.performWorkspaceCommand(.recovery)
            #expect(model.showRecovery)
            model.showRecovery = false
            let lock = try #require(model.performWorkspaceCommand(.lock))
            await lock.value
            #expect(!model.canPerformWorkspaceCommand(.recovery))
            #expect(model.damagedRecoveryEntries.isEmpty)
            let unlock = try #require(model.performWorkspaceCommand(.unlock))
            await unlock.value
            #expect(model.recoveredDrafts.isEmpty && model.damagedRecoveryEntries.count == 1)
            #expect(model.canPerformWorkspaceCommand(.recovery))
            model.performWorkspaceCommand(.recovery)
            #expect(model.showRecovery)
            #expect(try Data(contentsOf: damagedFile) == damagedBytes)
            model.showRecovery = false
            let close = try #require(model.performWorkspaceCommand(.close))
            await close.value
            #expect(!model.canPerformWorkspaceCommand(.recovery))
        }

        @Test @MainActor
        func sharedCommandsPreserveNavigationAndReserveLifecycleOnce() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSharedCommands-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                SourceReader.closeAll()
                try? FileManager.default.removeItem(at: base)
            }
            let repository = try FileVaultRepository.open(root: root, create: true)
            let note = try await repository.create(title: "Command Page", body: "Saved command body")
            let model = AppModel()
            model.localStorageRoot = base
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)
            model.currentNote = note; model.selectedID = note.id
            model.title = note.title; model.body = note.body
            model.scope = .sources; model.searchText = "Command"
            model.performWorkspaceCommand(.search)
            #expect(model.searchFocusToken == 1 && model.scope == .sources && model.searchText == "Command")
            model.performWorkspaceCommand(.returnToLibrary)
            #expect(model.currentNote == nil && model.scope == .sources && model.searchText == "Command")
            model.performWorkspaceCommand(.newTopicPage)
            #expect(model.showTopicPage)
            model.performWorkspaceCommand(.addURLSource)
            #expect(!model.showURLSource)
            model.showTopicPage = false
            let lock = try #require(model.performWorkspaceCommand(.lock))
            #expect(model.workspaceCommandPending)
            #expect(model.performWorkspaceCommand(.lock) == nil)
            #expect(model.performWorkspaceCommand(.close) == nil)
            await lock.value
            #expect(model.isLocked && !model.workspaceCommandPending)
            #expect(model.sessionTransitionErrors.isEmpty)
            let unlock = try #require(model.performWorkspaceCommand(.unlock))
            #expect(model.performWorkspaceCommand(.unlock) == nil)
            await unlock.value
            #expect(model.isVaultAvailable && !model.workspaceCommandPending)
            let close = try #require(model.performWorkspaceCommand(.close))
            #expect(model.performWorkspaceCommand(.close) == nil)
            await close.value
            #expect(model.sessionPhase == .closed && !model.workspaceCommandPending)
            #expect(model.sessionTransitionErrors.isEmpty)
        }

        @Test @MainActor
        func toolbarSplitDropdownsUseSegmentedCaretAndExposeMenus() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaToolbarSplit-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let repository = try FileVaultRepository.open(root: root, create: true)
            let note = try await repository.create(title: "Toolbar Page", body: "Toolbar test body")
            let model = AppModel()
            model.localStorageRoot = base
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)
            _ = NSApplication.shared
            let controller = NSHostingController(rootView: ContentView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 960, height: 620))
            window.makeKeyAndOrderFront(nil)
            defer { window.contentViewController = nil; window.close() }
            try await Task.sleep(for: .milliseconds(100))
            window.displayIfNeeded()

            let addControl = try #require(ToolbarSplitMenuPresenter.findSegmentedControl(forSymbol: "plus", in: window))
            #expect(addControl.segmentCount == 2)
            #expect(!addControl.showsMenuIndicator(forSegment: 0))
            #expect(addControl.showsMenuIndicator(forSegment: 1))
            let addMenu = try #require(addControl.menu(forSegment: 1))
            addMenu.delegate?.menuNeedsUpdate?(addMenu)
            #expect(addMenu.items.map(\.title).contains("Blank Page"))

            #expect(ToolbarSplitMenuPresenter.findSegmentedControl(forSymbol: "ellipsis", in: window)?.segmentCount != 2)

            model.currentNote = note
            model.selectedID = note.id
            try await Task.sleep(for: .milliseconds(100))
            window.displayIfNeeded()
            #expect(model.currentNote?.id == note.id)

            let itemIDs = window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
            #expect(itemIDs.contains("document.trash"))
            let trashItem = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "document.trash" })
            #expect(trashItem.label == "Move to Trash")
            #expect(ContentView.canTrashPage(note, model: model))

            var lockedNote = note
            lockedNote.editingLocked = true
            model.notes = [lockedNote]
            model.currentNote = lockedNote
            try await Task.sleep(for: .milliseconds(100))
            window.displayIfNeeded()
            #expect(model.currentNote?.isEditingLocked == true)
            #expect(model.editingLocked)
            #expect(!ContentView.canTrashPage(lockedNote, model: model))

            let close = try #require(model.performWorkspaceCommand(.close))
            await close.value
        }

        @Test @MainActor
        func modalSettingsGatesWorkspaceCommandsAndInteractionsWhileAllowingBackgroundSaves() async throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaSettingsCommandGate-\(UUID())")
            let root = base.appendingPathComponent("Vault")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }

            let repository = try FileVaultRepository.open(root: root, create: true)
            let first = try await repository.create(title: "First Page", body: "Original first body")
            let second = try await repository.create(title: "Second Page", body: "Second body")
            let model = AppModel()
            model.localStorageRoot = base
            model.persistSecurityScopedBookmark = false
            await model.open(root, create: false)
            #expect(model.isVaultAvailable)

            model.currentNote = first
            model.selectedID = first.id
            model.title = first.title
            model.body = first.body
            model.reading = true

            model.openSettings(category: .appearance)
            #expect(model.showSettings)
            #expect(!model.canInteractWithWorkspace)
            #expect(!model.canFormatDocument)

            // Every workspace command is unavailable while Settings is presented.
            for command in WorkspaceCommand.allCases {
                #expect(!model.canPerformWorkspaceCommand(command))
                #expect(model.performWorkspaceCommand(command) == nil)
            }

            // Navigation, scope changes, editing, formatting, creation, and deletion cannot occur behind Settings.
            model.changeScope(.sources)
            #expect(model.scope == .wiki)

            model.select(second.id)
            #expect(model.currentNote?.id == first.id)

            model.beginEditing()
            #expect(model.reading)

            model.reading = false
            #expect(!model.canFormatDocument)
            model.format("**", "**")
            #expect(model.body == "Original first body")

            model.newPage()
            try await Task.sleep(for: .milliseconds(50))
            #expect(model.notes.count == 2)

            model.trashPage(first.id)
            try await Task.sleep(for: .milliseconds(50))
            #expect(model.notes.count == 2)

            // Background saves continue to persist pending edits while Settings is open.
            model.body = "Updated while Settings open"
            await model.saveCurrent()
            let batch = try await repository.scan()
            let saved = try #require(batch.notes.first { $0.id == first.id })
            #expect(saved.body.contains("Updated while Settings open"))

            model.dismissSettings()
            #expect(!model.showSettings)
            #expect(model.canInteractWithWorkspace)
            #expect(model.canFormatDocument)

            model.changeScope(.sources)
            #expect(model.scope == .sources)

            let close = try #require(model.performWorkspaceCommand(.close))
            await close.value
        }
    }
}

