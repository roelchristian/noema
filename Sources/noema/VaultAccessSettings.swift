import SwiftUI
import VaultCore

/// Shared feedback for an operation awaiting the native macOS authentication dialog.
struct VaultAuthenticationProgress: View {
    @Bindable var model: AppModel
    @State private var cancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                NoemaLoadingStatus(cancelling ? "Cancelling authentication…" : "Waiting for macOS authentication…")
                Button("Cancel Authentication") {
                    guard !cancelling else { return }
                    cancelling = true
                    Task {
                        await model.cancelVaultAuthentication()
                        cancelling = false
                    }
                }
                .disabled(cancelling)
                .accessibilityHint("Cancel this attempt and keep vault access unchanged.")
            }
            Text("Complete the macOS dialog using Touch ID or your Mac login password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct VaultAccessSettings: View {
    var model: AppModel?
    @State private var changing = false

    init(model: AppModel? = nil) {
        self.model = model
    }

    private func authenticationRequired(for model: AppModel) -> Binding<Bool> {
        Binding(get: { model.vaultAccessAuthenticationRequired }, set: { required in
            guard model.isVaultAvailable, !changing, !model.isVaultAuthenticationPending else { return }
            changing = true
            Task {
                _ = await model.setVaultAccessAuthenticationRequired(required)
                changing = false
            }
        })
    }

    private var vaultDisplayName: String {
        guard let model else { return "No vault open" }
        if model.isVaultAvailable || model.isLocked {
            return model.vaultName
        }
        switch model.sessionState {
        case .open, .opening, .locking, .locked, .unlocking:
            return model.vaultName
        case .closed:
            return "No vault open"
        }
    }

    private var accessStatusDescription: String {
        guard let model else { return "Closed" }
        switch model.sessionState {
        case .opening:
            return "Opening…"
        case .locking:
            return "Locking…"
        case .unlocking:
            return "Unlocking…"
        case .locked:
            return "Locked"
        case .open:
            return model.isVaultAvailable ? "Unlocked" : "Opening…"
        case .closed:
            if model.isVaultAvailable {
                return "Unlocked"
            }
            if model.isLocked {
                return "Locked"
            }
            return "Closed"
        }
    }

    var body: some View {
        Section("Current Vault") {
            LabeledContent("Vault", value: vaultDisplayName)
            LabeledContent("Status", value: accessStatusDescription)
        }

        Section("Authentication") {
            if let model, model.isVaultAvailable {
                Toggle("Require authentication to open or unlock this vault", isOn: authenticationRequired(for: model))
                    .disabled(changing || model.busy || model.isVaultAuthenticationPending)
                Text("Changing this preference requires macOS authentication. It applies to this vault on this Mac when opening, unlocking, or reopening it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Open and unlock a vault to view or change its access authentication preference on this Mac.")
                    .foregroundStyle(.secondary)
            }

            if let model, model.isVaultAuthenticationPending {
                VaultAuthenticationProgress(model: model)
            } else if changing {
                NoemaLoadingStatus("Updating vault access preference…")
            }

            if let error = model?.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Section("Security Limitations") {
            Text("This setting is an application access gate in Noema, not filesystem encryption. Vault files, SQLite databases, search indexes, and recovery drafts remain plaintext and readable on disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
