import Foundation
import VaultCore

/// The native titlebar owns truncation; keep the complete title available to accessibility.
/// This value uses session metadata and the editor's existing in-memory identity only.
struct WorkspaceWindowTitle: Equatable, Sendable {
    enum Document: Equatable, Sendable {
        case page(String)
        case source(String)
    }

    let title: String
    let subtitle: String
    let isCollectionScope: Bool

    var hasSubtitle: Bool { !subtitle.isEmpty }

    init(
        phase: VaultSessionPhase,
        vaultName: String,
        scope: LibraryScope,
        document: Document? = nil,
        vaultAvailable: Bool
    ) {
        isCollectionScope = phase == .open && vaultAvailable && document == nil
        let vault = Self.nonempty(vaultName, fallback: "Vault")
        switch phase {
        case .closed:
            title = "Noema"
            subtitle = ""
            return
        case .opening:
            title = "Opening Vault…"
        case .locking:
            title = "Locking Vault…"
        case .locked:
            title = "Vault Locked"
        case .unlocking:
            title = "Unlocking Vault…"
        case .open:
            // An open session can still be reconstructing resources, or its lease may have
            // been revoked before AppModel receives the corresponding observation.
            guard vaultAvailable else {
                title = "Opening Vault…"
                subtitle = vault
                return
            }
            switch document {
            case .page(let value): title = Self.nonempty(value, fallback: "Untitled Page")
            case .source(let value): title = Self.nonempty(value, fallback: "Untitled Source")
            case nil:
                switch scope {
                case .wiki: title = "Pages"
                case .sources: title = "Sources"
                case .semantic: title = "Semantic Blocks"
                case .trash: title = "Trash"
                case .tag(let tag): title = "#" + tag
                }
            }
            // The sidebar footer owns vault identity while the workspace is open and available.
            subtitle = ""
            return
        }
        subtitle = title.localizedCaseInsensitiveCompare(vault) == .orderedSame ? "" : vault
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}

extension AppModel {
    var windowTitle: WorkspaceWindowTitle {
        // Consult the admission gate synchronously so the title does not retain a private
        // page name while observation of a direct manager transition is still queued.
        let state = sessionManager.accessGate.currentState
        let name: String
        switch state {
        case .closed: name = "Noema"
        case .opening(let root, _): name = root.lastPathComponent
        case .open(let session), .locking(let session): name = session.vaultName
        case .locked(_, _, let vaultName, _), .unlocking(_, _, let vaultName, _): name = vaultName
        }

        let available = isVaultAvailable
        let document: WorkspaceWindowTitle.Document?
        if available, currentNote != nil {
            document = .page(title)
        } else if available, currentSource != nil {
            document = .source(title)
        } else {
            // Sources table row selection belongs to its inspector. Only an open primary
            // source document becomes the window identity, without reading source content.
            document = nil
        }
        return WorkspaceWindowTitle(
            phase: state.phase, vaultName: name, scope: scope,
            document: document, vaultAvailable: available
        )
    }
}
