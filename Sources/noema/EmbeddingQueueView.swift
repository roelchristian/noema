import SwiftUI
import VaultCore

struct EmbeddingQueueIndicator: View {
    let model: AppModel
    @State private var snapshot = EmbeddingQueueSnapshot.empty
    @State private var showingQueue = false
    var body: some View {
        Button { showingQueue = true } label: {
            Label(snapshot.activeCount > 0 ? "Indexing \(snapshot.activeCount)" : "Semantic Indexing", systemImage: "square.stack.3d.up")
        }
        .help("View semantic indexing progress and controls")
        .accessibilityIdentifier("embeddings.queue.open")
        .sheet(isPresented: $showingQueue) { EmbeddingQueueView(model: model) }
        .task(id: model.sessionManager.accessGate.currentLease) {
            snapshot = .empty
            guard let lease = model.sessionManager.accessGate.currentLease else { return }
            while !Task.isCancelled {
                if let value = try? await model.embeddingQueueSnapshot(for: lease) { snapshot = value }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct EmbeddingQueueView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = EmbeddingQueueSnapshot.empty
    @State private var feedback: String?
    @State private var busy = false
    @State private var approval: EmbeddingQueueBatch?
    @State private var retrying = false
    @State private var approvalLease: VaultSessionLease?
    @State private var incrementalApprovalModel: EmbeddingModelDescriptor?
    @State private var showingIncrementalApproval = false
    @State private var retryingIncremental = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Semantic Indexing").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Review indexing progress for this vault, pause work or continue when you’re ready.")
                .font(.caption).foregroundStyle(.secondary)
            if let lease = model.sessionManager.accessGate.currentLease {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("New and Changed Content") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(snapshot.incrementalPaused ? "Paused on this Mac" : "Ready to index approved content").font(.caption).foregroundStyle(.secondary)
                                incrementalControls(lease)
                                if snapshot.incremental.isEmpty { Text("No new or changed content waiting to be indexed.").foregroundStyle(.secondary) }
                                ForEach(snapshot.incremental) { item in
                                    workRow(kind: item.key.entityKind, id: item.key.entityID,
                                            status: EmbeddingQueueSnapshot.status(item) + (item.possibleTransmittedUsage == true ? " · usage possible" : ""), failure: item.failure)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                        }
                        ForEach(snapshot.batches) { value in batchSection(value, lease: lease) }
                    }
                }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                Text("Cloud cost is unknown. Requests already sent may incur charges after cancellation. Completed indexing is preserved while remaining work stops.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Open and unlock a vault to inspect semantic indexing work.") }
        }
        .padding(24).frame(width: 720, height: 600)
        .task(id: model.sessionManager.accessGate.currentLease) {
            snapshot = .empty; feedback = nil; approval = nil
            guard let lease = model.sessionManager.accessGate.currentLease else { return }
            while !Task.isCancelled {
                do { snapshot = try await model.embeddingQueueSnapshot(for: lease) }
                catch { snapshot = .empty; feedback = "Queue unavailable. Reopen the vault and try again."; return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .sheet(item: $approval) { value in
            EmbeddingBackfillPrompt(pageCount: value.members.filter { $0.entityKind == .page }.count,
                sourceCount: value.members.filter { $0.entityKind == .source }.count,
                providerName: value.batch.generation.model.providerID, modelName: value.batch.generation.model.modelID,
                isCloud: value.batch.generation.model.providerID == "openai", isRebuild: value.batch.mode == .rebuild,
                allowsScopeChanges: false, onIndex: { _ in
                    approval = nil
                    guard let lease = approvalLease, model.sessionManager.accessGate.currentLease == lease, lease.vaultID == value.batch.vaultID else { return }
                    perform(lease) {
                        if retrying { try await model.retryEmbeddingBackfill(batchID: value.id, for: lease) }
                        else { try await model.resumeEmbeddingBackfill(batchID: value.id, for: lease) }
                    }
                }, onNewAndChangedOnly: { approval = nil }, onNotNow: { approval = nil })
        }
        .confirmationDialog("Allow OpenAI embeddings for new and changed content?", isPresented: $showingIncrementalApproval,
                            titleVisibility: .visible) {
            Button("Allow and Resume This Session") {
                guard let lease = approvalLease, model.sessionManager.accessGate.currentLease == lease,
                      model.semanticProcessingGeneration?.model == incrementalApprovalModel else { return }
                perform(lease) {
                    try await model.approveIncrementalEmbeddingDocuments(for: lease)
                    if retryingIncremental { try await model.retryIncrementalEmbeddingQueue(for: lease) }
                    else { try await model.resumeIncrementalEmbeddingQueue(for: lease) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Committed Page and Source text may be sent to OpenAI for embeddings using the selected model. API charges may apply; cost is unknown. Permission covers new and changed content in this unlocked session. Existing-content batches and queries require separate approval. Locking or changing provider, model or credentials requires fresh approval.")
        }
    }

    private func incrementalControls(_ lease: VaultSessionLease) -> some View {
        HStack {
            Button("Pause") { perform(lease) { try await model.pauseIncrementalEmbeddingQueue(for: lease) } }
            Button("Resume…") {
                if model.semanticProcessingGeneration?.model.providerID == "openai" { retryingIncremental = false; approvalLease = lease; incrementalApprovalModel = model.semanticProcessingGeneration?.model; showingIncrementalApproval = true }
                else { perform(lease) { try await model.resumeIncrementalEmbeddingQueue(for: lease) } }
            }
            Button("Cancel Remaining") { perform(lease) { try await model.cancelIncrementalEmbeddingQueue(for: lease) } }
            Button("Retry Eligible…") {
                if model.semanticProcessingGeneration?.model.providerID == "openai" { retryingIncremental = true; approvalLease = lease; incrementalApprovalModel = model.semanticProcessingGeneration?.model; showingIncrementalApproval = true }
                else { perform(lease) { try await model.retryIncrementalEmbeddingQueue(for: lease) } }
            }
        }.disabled(busy)
    }

    private func batchSection(_ value: EmbeddingQueueBatch, lease: VaultSessionLease) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(value.batch.generation.model.modelID) · \(EmbeddingQueueSnapshot.batchStatus(value.batch.state))")
                Text("\(value.batch.scopes.map { $0 == .page ? "Pages" : "Sources" }.sorted().joined(separator: ", ")) · \(value.members.count) items")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Pause") { perform(lease) { try await model.pauseEmbeddingBackfill(batchID: value.id, for: lease) } }
                        .disabled(value.batch.state != .active)
                    Button("Resume…") { retrying = false; approvalLease = lease; approval = value }
                        .disabled(![.active, .paused, .awaitingApproval].contains(value.batch.state))
                    Button("Cancel Remaining") { perform(lease) { try await model.cancelEmbeddingBackfill(batchID: value.id, for: lease) } }
                        .disabled([.completed, .cancelled, .incompatible, .cancellationRequested].contains(value.batch.state))
                    Button("Retry Eligible…") { retrying = true; approvalLease = lease; approval = value }
                        .disabled(![.active, .paused, .awaitingApproval].contains(value.batch.state) || !value.members.contains { [.blocked, .interrupted, .failed, .unavailable].contains($0.state) })
                }.disabled(busy)
                ForEach(value.members) { member in
                    let work = value.work.first { $0.id == member.workID }
                    workRow(kind: member.entityKind, id: member.entityID,
                            status: member.state.isTerminal ? EmbeddingQueueSnapshot.memberStatus(member.state) : work.map(EmbeddingQueueSnapshot.status) ?? EmbeddingQueueSnapshot.memberStatus(member.state),
                            failure: member.failure ?? work?.failure)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: { Text(value.batch.mode == .rebuild ? "Rebuild Index" : "Existing Content") }
    }

    private func workRow(kind: AIEntityKind, id: UUID, status: String, failure: AIWorkFailure?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contentTitle(kind: kind, id: id)).lineLimit(2)
                Text(kind == .page ? "Page" : "Source").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(status + (failure.map { " · " + EmbeddingQueueSnapshot.failureLabel($0) } ?? "")).font(.caption)
        }.accessibilityElement(children: .combine)
    }

    private func contentTitle(kind: AIEntityKind, id: UUID) -> String {
        let title = kind == .page ? model.notes.first { $0.id == id }?.title : model.sources.first { $0.id == id }?.title
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return kind == .page ? "Page unavailable" : "Source unavailable"
        }
        return title
    }

    private func perform(_ lease: VaultSessionLease, action: @escaping @MainActor () async throws -> Void) {
        busy = true; feedback = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await action()
                snapshot = try await model.embeddingQueueSnapshot(for: lease)
            } catch {
                guard model.sessionManager.accessGate.currentLease == lease else { snapshot = .empty; return }
                feedback = "Work could not continue. Check provider readiness and fresh approval; completed work remains preserved."
            }
        }
    }
}
