import SwiftUI
import VaultCore

struct VaultCreationSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.noemaTheme) private var theme
    @State private var name = "My Knowledge Vault"
    @State private var parent: URL?
    @State private var creating = false
    @State private var failure: String?
    @State private var confirmPlaintext = false
    @FocusState private var nameFocused: Bool

    private var validName: String? { try? VaultCreation.validatedName(name) }
    private var secondaryText: Color { theme.text(.textMuted, on: .background) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Create a vault").font(.title2.bold())
                Text("Choose a name and location for your knowledge vault.")
                    .foregroundStyle(secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Vault name").font(.subheadline.weight(.semibold))
                TextField("Vault name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .accessibilityLabel("Vault name")
                if validName == nil {
                    Text("Enter a folder name without slashes, colons, or control characters.")
                        .font(.callout).foregroundStyle(secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Save location").font(.subheadline.weight(.semibold))
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(theme.text()).accessibilityHidden(true)
                    Text(parent?.path ?? "No folder selected")
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(parent == nil ? theme.text() : theme.text(.textPrimary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(parent?.path ?? "Choose the parent folder for your vault.")
                        .accessibilityLabel("Save location")
                        .accessibilityValue(parent?.path ?? "No folder selected")
                    Button("Choose…") {
                        model.chooseVaultParent { parent = $0; failure = nil }
                    }
                    .accessibilityLabel("Choose save location")
                }
                .padding(10)
                .background(theme.color(.surfaceElevated), in: RoundedRectangle(cornerRadius: 8))
                if let parent, let validName {
                    Text("Vault folder: \(parent.appendingPathComponent(validName).path)")
                        .font(.callout).foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Choose where your vault will be stored. Suggested: iCloud Drive / Noema.")
                        .font(.callout).foregroundStyle(secondaryText)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Security").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Coming soon").font(.callout).foregroundStyle(secondaryText)
                }
                Toggle("Encrypted vault", isOn: .constant(false))
                    .toggleStyle(.switch)
                    .disabled(true)
                    .accessibilityHint("Encryption is not available in this release.")
                Text("This vault will not be encrypted. Touch ID and recovery-key protection are not yet available.")
                    .font(.callout).foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if creating { ProgressView().controlSize(.small); Text("Creating vault…").font(.callout) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Vault") { confirmPlaintext = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parent == nil || validName == nil || creating)
            }
        }
        .padding(24).frame(width: 540)
        .controlSize(.large)
        .foregroundStyle(theme.text(.textPrimary, on: .background))
        .background(theme.color(.background))
        .disabled(creating)
        .interactiveDismissDisabled(creating)
        .task { nameFocused = true }
        .alert("Create an unencrypted vault?", isPresented: $confirmPlaintext) {
            Button("Cancel", role: .cancel) { }
            Button("Create Vault") {
                guard let parent, let validName, !creating else { return }
                creating = true; failure = nil
                Task {
                    do { try await model.createVault(parent: parent, name: validName, encryptionRequested: false) }
                    catch { failure = error.localizedDescription }
                    creating = false
                }
            }
        } message: {
            Text("Create \(validName ?? name) in \(parent?.path ?? "the selected folder")? Its files and search index will be readable without Touch ID or a recovery key.")
        }
    }
}
