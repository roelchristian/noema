import SwiftUI
import ExternalAI

/// A credential can only enter through this transient masked field; stored keys are never read
/// back into SwiftUI. Connection configuration never authorizes an AI action.
struct ExternalAISettings: View {
    let service: ExternalAIService

    @State private var enteredKey = ""
    @State private var modelEntry = ""
    @State private var thirtyDayPolicy = false
    @State private var operation: Task<Void, Never>?
    @State private var isBusy = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        Section("OpenAI connection") {
            LabeledContent("Credential", value: credentialDescription)
            if service.credentialStatus?.presence == .inaccessible {
                Text("Noema cannot access this saved key. Remove it here, then save the key again. If removal fails, unlock the login Keychain in Keychain Access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Session authorization", value: authorizationDescription)
            if let expiresAt = service.credentialStatus?.localPolicyExpiresAt {
                LabeledContent("Local policy ends") {
                    Text(expiresAt, format: .dateTime.year().month().day())
                }
            }
            HStack {
                TextField("Model", text: $modelEntry)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Apply model", action: applyModel)
                    .disabled(isBusy || modelEntry == service.configuration.model)
            }
            Text("Configured model: \(service.configuration.model). Changing it revokes current session authorization.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Reasoning effort", selection: Binding(
                get: { service.configuration.reasoningEffort },
                set: { effort in
                    service.setReasoningEffort(effort)
                    feedback = "Reasoning effort saved. Session access revoked."
                    failed = false
                })) {
                ForEach(ExternalAIReasoningEffort.allCases, id: \.self) { effort in
                    Text(effort.displayName).tag(effort)
                }
            }
            .pickerStyle(.menu)
            .disabled(isBusy || !service.configuration.supportsReasoningEffort)
            Text(service.configuration.supportsReasoningEffort
                 ? "Low is Noema's default. None uses no reasoning; Medium allows more reasoning and can take longer and use more tokens. Changes are saved automatically and revoke session access."
                 : "Reasoning effort selection is available for gpt-6-luna. Your selection is retained when switching models.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField(service.credentialStatus?.isAvailable == true ? "Replacement API key" : "OpenAI API key", text: $enteredKey)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(isBusy)
            Toggle("Limit this saved credential to 30 days locally", isOn: $thirtyDayPolicy)
                .disabled(isBusy)
            Text("The optional 30-day policy starts when you save or replace the key. It only limits Noema's use; OpenAI key expiry, revocation and hard spending limits must be configured with the issuer.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(service.credentialStatus?.isAvailable == true ? "Replace key" : "Save key", action: saveKey)
                    .disabled(isBusy || enteredKey.isEmpty)
                Button("Remove key", role: .destructive) {
                    enteredKey = ""
                    perform(success: "API key removed from Keychain.") { try await service.removeCredential() }
                }
                .disabled(isBusy || service.credentialStatus?.presence == .missing || service.credentialStatus == nil)
            }
            HStack {
                Button("Validate connection") {
                    perform(success: "OpenAI accepted the key and configured model.") { try await service.validateConnection() }
                }
                .disabled(isBusy || service.credentialStatus?.isAvailable != true)
                Button("Revoke session access") {
                    service.revokeAuthorization()
                    feedback = "Session access revoked. The next AI request requires macOS authentication."
                    failed = false
                }
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            Text("When OpenAI is chosen for a summary, title suggestion or LCC classification, only the selected page or source text is sent after your confirmation. Submitted text leaves this Mac and API usage may incur charges. Preferences and connection settings do not authorize a submission. Automatic intelligence remains on-device.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Connection validation sends a model metadata request with no vault content. Session access lasts at most four hours and expires after 30 minutes without external AI activity. Removing a key here does not revoke the key at OpenAI.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            modelEntry = service.configuration.model
            // Status inspection does not renew authorization. Refresh while Settings is visible,
            // so expiry and revocation are represented without keeping any vault open.
            while !Task.isCancelled {
                await service.refreshStatus()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onDisappear {
            enteredKey = ""
            operation?.cancel()
            operation = nil
            isBusy = false
            feedback = nil
        }
    }

    private var credentialDescription: String {
        switch service.credentialStatus?.presence {
        case .missing: "Not configured"
        case .available: "Saved in Keychain"
        case .expired: "Local policy expired — enter a key again"
        case .malformed: "Invalid Keychain credential — replace or remove"
        case .inaccessible: "Keychain credential unavailable"
        case nil: "Checking Keychain…"
        }
    }

    private var authorizationDescription: String {
        switch service.authorizationState {
        case .unauthorized: "Not authorized"
        case .authorising: "Waiting for macOS authentication"
        case .authorized: "Authorized for the current vault session"
        case .expired: "Expired"
        case .revoked: "Revoked"
        }
    }

    private func saveKey() {
        let key = enteredKey
        enteredKey = ""
        let policy = thirtyDayPolicy
        perform(success: "API key saved in Keychain. Session access requires authentication on the next AI request.") {
            try await service.saveCredential(key, thirtyDayPolicy: policy)
        }
    }

    private func applyModel() {
        do {
            try service.setModel(modelEntry)
            feedback = "Model saved. Session access revoked."
            failed = false
        } catch {
            feedback = ExternalAIError.invalidConfiguration.errorDescription
            failed = true
        }
    }

    private func perform(success: String, action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        feedback = nil
        operation = Task { @MainActor in
            defer { isBusy = false; operation = nil }
            do {
                try await action()
                guard !Task.isCancelled else { return }
                feedback = success
                failed = false
            } catch {
                await service.refreshStatus()
                guard !Task.isCancelled else { return }
                feedback = ((error as? ExternalAIError) ?? .credentialUnavailable).errorDescription
                failed = true
            }
        }
    }
}
