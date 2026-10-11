import SwiftUI

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
    @Bindable var model: AppModel
    @State private var changing = false

    private var authenticationRequired: Binding<Bool> {
        Binding(get: { model.vaultAccessAuthenticationRequired }, set: { required in
            guard model.isVaultAvailable, !changing, !model.isVaultAuthenticationPending else { return }
            changing = true
            Task {
                _ = await model.setVaultAccessAuthenticationRequired(required)
                changing = false
            }
        })
    }

    var body: some View {
        Section("Vault access on this Mac") {
            if model.isVaultAvailable {
                Text(model.vaultName).font(.headline)
                Toggle("Require authentication to open or unlock this vault", isOn: authenticationRequired)
                    .disabled(changing || model.busy || model.isVaultAuthenticationPending)
                Text("Changing this preference requires macOS authentication. It applies to this vault on this Mac, including reopening it and restarting Noema.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Open and unlock a vault to view or change its access preference.")
                    .foregroundStyle(.secondary)
            }
            Text("This gate protects against casual access through Noema. Vault files, search indexes, and recovery drafts remain plaintext and readable on disk. It does not protect against filesystem or process access.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isVaultAuthenticationPending {
                VaultAuthenticationProgress(model: model)
            } else if changing {
                NoemaLoadingStatus("Updating vault access preference…")
            }
            if let error = model.errorMessage {
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
