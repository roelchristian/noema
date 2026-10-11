import Foundation
import SwiftUI
import VaultCore

/// Window controls and menu commands share this admission policy and the existing AppModel actions.
enum WorkspaceCommand: CaseIterable, Equatable {
    case search, quickOpen, returnToLibrary, showTrash
    case newPage, newPersonalPage, newTopicPage, save
    case addSource, addURLSource, pasteSource, recovery, notices, revealVault, refresh
    case lock, unlock, close, openVault, createVault
}

/// The Vault menu and shortcut regression tests use the same definitions.
/// Command-F is intentionally absent: it remains reserved for document Find.
enum WorkspaceSearchMenuCommand: CaseIterable, Hashable {
    case vault, quickOpen

    var command: WorkspaceCommand {
        switch self {
        case .vault: .search
        case .quickOpen: .quickOpen
        }
    }

    var title: String {
        switch self {
        case .vault: "Find in Vault"
        case .quickOpen: "Quick Open"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .vault: KeyboardShortcut("f", modifiers: [.command, .shift])
        case .quickOpen: KeyboardShortcut("p", modifiers: [.command])
        }
    }
}

struct WorkspaceCommandAvailability {
    var phase: VaultSessionPhase
    var stateMatchesManager: Bool
    var vaultAvailable: Bool
    var busy: Bool = false
    var actionPending: Bool = false
    var presentationPending: Bool = false
    var documentSelected: Bool = false
    var pageSelected: Bool = false
    var hasRecovery: Bool = false
    var hasNotices: Bool = false

    func allows(_ command: WorkspaceCommand) -> Bool {
        guard stateMatchesManager, !busy, !actionPending, !presentationPending else { return false }
        switch command {
        case .openVault, .createVault:
            return phase == .closed || phase == .open || phase == .locked
        case .unlock:
            return phase == .locked
        case .close:
            return phase == .open || phase == .locked
        default:
            guard phase == .open, vaultAvailable else { return false }
            switch command {
            case .returnToLibrary: return documentSelected
            case .save: return pageSelected
            case .recovery: return hasRecovery
            case .notices: return hasNotices
            default: return true
            }
        }
    }
}

extension AppModel {
    private func commandAvailability(ignoringPendingCommand: Bool = false) -> WorkspaceCommandAvailability {
        WorkspaceCommandAvailability(
            phase: sessionPhase,
            stateMatchesManager: sessionState == sessionManager.accessGate.currentState,
            vaultAvailable: isVaultAvailable,
            busy: busy,
            actionPending: isLifecycleActionInProgress || (!ignoringPendingCommand && workspaceCommandPending),
            presentationPending: isChoosingVault || isChoosingSource || showVaultCreation || showTopicPage || showURLSource || showPasteSource || showRecovery || showIssues,
            documentSelected: currentNote != nil || currentSource != nil,
            pageSelected: currentNote != nil,
            hasRecovery: hasRecoveryEntries,
            hasNotices: !issues.isEmpty
        )
    }

    func canPerformWorkspaceCommand(_ command: WorkspaceCommand) -> Bool {
        commandAvailability().allows(command)
    }

    /// Returns the task for asynchronous commands so callers can await completion if needed.
    /// Admission is reserved before creating the task, preventing rapid clicks from queuing two transitions.
    @discardableResult
    func performWorkspaceCommand(_ command: WorkspaceCommand) -> Task<Void, Never>? {
        guard canPerformWorkspaceCommand(command) else { return nil }
        switch command {
        case .search:
            setSearchMode(.vault)
            searchFocusToken += 1
        case .quickOpen:
            setSearchMode(.quickOpen)
            searchFocusToken += 1
        case .returnToLibrary:
            workspaceNavigationToken += 1
            changeScope(scope)
        case .showTrash:
            workspaceNavigationToken += 1
            changeScope(.trash)
        case .newPage:
            workspaceNavigationToken += 1
            newPage()
        case .newPersonalPage:
            workspaceNavigationToken += 1
            newPage(template: true)
        case .newTopicPage: showTopicPage = true
        case .save: savePage()
        case .addSource: addSource()
        case .addURLSource: showURLSource = true
        case .pasteSource: showPasteSource = true
        case .recovery: showRecovery = true
        case .notices: showIssues = true
        case .revealVault: revealVault()
        case .openVault: chooseVault(create: false)
        case .createVault: chooseVault(create: true)
        case .refresh, .lock, .unlock, .close:
            let admittedState = sessionState
            workspaceCommandPending = true
            return Task { @MainActor in
                defer { workspaceCommandPending = false }
                // A direct manager transition may occur before this task receives its first turn.
                guard !Task.isCancelled, sessionState == admittedState,
                      commandAvailability(ignoringPendingCommand: true).allows(command) else { return }
                switch command {
                case .refresh: await refresh()
                case .lock: _ = await lockVault()
                case .unlock: _ = await unlockVault()
                case .close: _ = await closeVault()
                default: break
                }
            }
        }
        return nil
    }
}
