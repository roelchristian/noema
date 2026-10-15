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
    @State private var showDiagnostics = false

    var body: some View {
        Section("Connection") {
            LabeledContent("Credential", value: credentialDescription)
            if service.credentialStatus?.presence == .inaccessible {
                Text("Noema cannot access this saved key. Remove it here, then save the key again. If removal fails, unlock the login Keychain in Keychain Access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let expiresAt = service.credentialStatus?.localPolicyExpiresAt {
                LabeledContent("Local policy ends") {
                    Text(expiresAt, format: .dateTime.year().month().day())
                }
            }
            SecureField(service.credentialStatus?.isAvailable == true ? "Replacement API key" : "OpenAI API key", text: $enteredKey)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(isBusy)
            Toggle("Limit this saved credential to 30 days locally", isOn: $thirtyDayPolicy)
                .disabled(isBusy)
            HStack {
                Button(service.credentialStatus?.isAvailable == true ? "Replace Key" : "Save Key", action: saveKey)
                    .disabled(isBusy || enteredKey.isEmpty)
                Button("Remove Key", role: .destructive) {
                    enteredKey = ""
                    perform(success: "API key removed from Keychain.") { try await service.removeCredential() }
                }
                .disabled(isBusy || service.credentialStatus?.presence == .missing || service.credentialStatus == nil)
            }
            LabeledContent("Model") {
                HStack {
                    TextField("Model", text: $modelEntry)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .disabled(isBusy)
                    Button("Apply Model", action: applyModel)
                        .disabled(isBusy || modelEntry == service.configuration.model)
                }
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
                 ? "Low is the default. Changes save automatically and revoke session access."
                 : "Reasoning effort selection is available for gpt-6-luna and retained across model switches.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Embedding model", selection: Binding(
                get: { service.embeddingConfiguration.model },
                set: { model in
                    do {
                        try service.setEmbeddingModel(model.rawValue)
                        feedback = "Embedding model saved. Existing content requires reindexing."
                        failed = false
                    } catch {
                        feedback = ExternalAIError.invalidConfiguration.errorDescription
                        failed = true
                    }
                })) {
                ForEach(OpenAIEmbeddingModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .disabled(isBusy)
            Text("Used for semantic indexing and similarity search. This is independent of the model used for summaries and other AI features. Changing the embedding model requires reindexing existing content.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Session authorization", value: authorizationDescription)
            HStack {
                Button("Validate Connection") {
                    perform(success: "OpenAI accepted the key and configured model.") { try await service.validateConnection() }
                }
                .disabled(isBusy || service.credentialStatus?.isAvailable != true)
                Button("Revoke Session Access") {
                    service.revokeAuthorization()
                    feedback = "Session access revoked. The next AI request requires macOS authentication."
                    failed = false
                }
            }
            if isBusy { ProgressView().controlSize(.small) }
            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
            }
        }
        Section("Content Sharing") {
            Picker("Confirmation policy", selection: Binding(
                get: { service.consentPolicy },
                set: { service.setConsentPolicy($0) })) {
                ForEach(OpenAIConsentPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
            Text(consentPolicyDescription)
                .font(.caption).foregroundStyle(.secondary)
            Text("Explicit OpenAI actions send only the selected content under your confirmation policy. Submitted text leaves this Mac and API usage may incur charges. Automatic intelligence remains on-device.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Diagnostics") {
            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                Toggle("OpenAI debug mode", isOn: Binding(
                    get: { service.debugModeEnabled }, set: { service.setDebugMode($0) }))
                    .disabled(!service.canEnableDebugMode)
                Text("Available while a vault is unlocked. Retains the latest rejected response in memory only until the vault locks, closes, or switches. No API keys or headers are captured.")
                    .font(.caption).foregroundStyle(.secondary)
                if service.debugModeEnabled {
                    if let report = service.debugReport {
                        DisclosureGroup("Latest rejected OpenAI response") {
                            ScrollView {
                                Text(report).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 220)
                        }
                        Button("Clear Debug Response") { service.clearDebugReport() }
                    } else {
                        Text("Waiting for a rejected response. Retry the failing action, then return here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            showDiagnostics = service.debugModeEnabled
        }
        .task {
            modelEntry = service.configuration.model
            showDiagnostics = service.debugModeEnabled
            // Status inspection does not renew authorization. Refresh while Settings is visible,
            // so expiry and revocation are represented without keeping any vault open.
            while !Task.isCancelled {
                await service.refreshStatus()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onDisappear {
            Self.sanitizeTransientState(
                enteredKey: &enteredKey,
                modelEntry: &modelEntry,
                configuredModel: service.configuration.model,
                operation: &operation,
                isBusy: &isBusy,
                feedback: &feedback,
                failed: &failed
            )
        }
    }

    @MainActor
    static func sanitizeTransientState(
        enteredKey: inout String,
        modelEntry: inout String,
        configuredModel: String,
        operation: inout Task<Void, Never>?,
        isBusy: inout Bool,
        feedback: inout String?,
        failed: inout Bool
    ) {
        enteredKey = ""
        modelEntry = configuredModel
        operation?.cancel()
        operation = nil
        isBusy = false
        feedback = nil
        failed = false
    }

    private var consentPolicyDescription: String {
        switch service.consentPolicy {
        case .always: "Review the exact selected text and confirm every OpenAI submission."
        case .oncePerSession: "Confirm the first explicit submission in each unlocked vault session. Locking, switching or closing the vault clears approval. macOS authentication remains required."
        case .neverAsk: "Explicit AI actions send selected content to OpenAI without a routine confirmation sheet. Content leaves this Mac and API charges may apply. macOS authentication remains required."
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
