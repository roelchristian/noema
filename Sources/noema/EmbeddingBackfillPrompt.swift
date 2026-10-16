import SwiftUI
import VaultCore

/// Presents an explicit historical scope choice. The caller owns lease validation,
/// durable admission and fresh request authority; this view grants none of them.
struct EmbeddingBackfillPrompt: View {
    let pageCount: Int
    let sourceCount: Int
    let providerName: String
    let modelName: String
    let isCloud: Bool
    let isRebuild: Bool
    let allowsScopeChanges: Bool
    let onIndex: (Set<AIEntityKind>) -> Void
    let onNewAndChangedOnly: () -> Void
    let onNotNow: () -> Void

    @State private var includePages: Bool
    @State private var includeSources: Bool
    @State private var cloudSubmissionAcknowledged = false

    init(
        pageCount: Int,
        sourceCount: Int,
        providerName: String,
        modelName: String,
        isCloud: Bool,
        isRebuild: Bool = false,
        allowsScopeChanges: Bool = true,
        onIndex: @escaping (Set<AIEntityKind>) -> Void,
        onNewAndChangedOnly: @escaping () -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.pageCount = max(0, pageCount)
        self.sourceCount = max(0, sourceCount)
        self.providerName = providerName
        self.modelName = modelName
        self.isCloud = isCloud
        self.isRebuild = isRebuild
        self.allowsScopeChanges = allowsScopeChanges
        self.onIndex = onIndex
        self.onNewAndChangedOnly = onNewAndChangedOnly
        self.onNotNow = onNotNow
        _includePages = State(initialValue: pageCount > 0)
        _includeSources = State(initialValue: sourceCount > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isRebuild ? "Rebuild semantic index?" : "Index existing vault content?")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            Text(isRebuild
                 ? "The selected provider or model uses an incompatible vector space. Existing incompatible vectors cannot be reused. Choose which existing content to index with this model."
                 : "Choose which committed content to include in a historical indexing batch. You can index existing content later from Current Vault settings.")
                .foregroundStyle(.secondary)

            LabeledContent("Provider", value: providerName)
            LabeledContent("Embedding model", value: modelName)

            GroupBox("Existing content") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $includePages) {
                        HStack {
                            Text("Pages")
                            Spacer()
                            Text("\(pageCount) eligible").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(pageCount == 0 || !allowsScopeChanges)
                    .accessibilityLabel("Include existing Pages, \(pageCount) eligible")
                    .accessibilityIdentifier("embeddings.history.includePages")

                    Toggle(isOn: $includeSources) {
                        HStack {
                            Text("Sources")
                            Spacer()
                            Text("\(sourceCount) eligible").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(sourceCount == 0 || !allowsScopeChanges)
                    .accessibilityLabel("Include existing Sources, \(sourceCount) eligible")
                    .accessibilityIdentifier("embeddings.history.includeSources")
                }
                .padding(6)
            }

            Text("Counts use committed metadata. Unavailable originals or unsupported content are reported during indexing. Generated content and pending editor drafts are excluded. Canonical content is preserved.")
                .font(.caption).foregroundStyle(.secondary)

            if isCloud {
                GroupBox("OpenAI submission") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Original text from the selected Pages and Sources will be sent to OpenAI for embeddings. API charges may apply. Cost is unknown; metadata counts do not establish token usage or charges.")
                        Text("Approval applies to this selected historical batch and model. Search queries, enrichment, and future new or changed content require their own approval. Locking or a change of session, credentials, provider or model requires fresh authority to continue.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("I approve OpenAI submission for this historical batch", isOn: $cloudSubmissionAcknowledged)
                            .accessibilityIdentifier("embeddings.history.approveCloudSubmission")
                    }
                    .padding(6)
                }
            }

            if selectedScopes.isEmpty {
                Text(pageCount == 0 && sourceCount == 0
                     ? "There is no eligible existing content to index."
                     : "Select Pages, Sources, or both to begin.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("embeddings.history.scopeFeedback")
            }

            HStack {
                Button("Not Now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("embeddings.history.notNow")
                Button("New and Changed Content Only", action: onNewAndChangedOnly)
                    .accessibilityHint("Starts no historical indexing. Cloud processing still requires separate approval.")
                    .accessibilityIdentifier("embeddings.history.newAndChangedOnly")
                Spacer(minLength: 8)
                Button("Index Existing Content") {
                    guard canIndex else { return }
                    onIndex(selectedScopes)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canIndex)
                .accessibilityIdentifier("embeddings.history.indexExisting")
            }
        }
        .padding(24)
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedScopes: Set<AIEntityKind> {
        var scopes = Set<AIEntityKind>()
        if includePages && pageCount > 0 { scopes.insert(.page) }
        if includeSources && sourceCount > 0 { scopes.insert(.source) }
        return scopes
    }

    private var canIndex: Bool {
        !selectedScopes.isEmpty && (!isCloud || cloudSubmissionAcknowledged)
    }
}
