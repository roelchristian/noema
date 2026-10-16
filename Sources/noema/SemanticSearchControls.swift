import SwiftUI
import AppKit

/// Shared toolbar and full-results controls. Rendering and editing this view
/// cannot dispatch a semantic query; execution is confined to explicit actions.
struct SemanticSearchControls: View {
    @Bindable var model: AppModel
    var announcesStatus = true
    var onQueryDecision: (() -> Void)? = nil
    private enum FocusAction: Hashable { case search, cancel }
    @FocusState private var focusedAction: FocusAction?
    @State private var showingIndexing = false

    var body: some View {
        if model.searchMode != .quickOpen {
            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                HStack {
                    Picker("Search method", selection: Binding(
                        get: { model.searchRetrievalMode },
                        set: { model.setSearchRetrievalMode($0) }
                    )) {
                        ForEach(VaultSearchRetrievalMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Search method")
                    if model.searchRetrievalMode == .meaning {
                        Button("Search") { model.submitMeaningSearch() }
                            .focused($focusedAction, equals: .search)
                            .disabled(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      model.semanticSearchStatus.isRunning ||
                                      model.pendingSemanticQueryDisclosure != nil)
                            .help("Submit this query to search by meaning")
                            .accessibilityLabel("Search by meaning")
                    }
                }
                if model.searchRetrievalMode == .meaning {
                    if model.semanticSearchStatus.isRunning && model.semanticSearchStatus != .awaitingApproval {
                        HStack {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Searching by meaning")
                            Text(model.semanticSearchStatus.message ?? "Searching by meaning…")
                            Spacer()
                            Button("Cancel") {
                                model.cancelMeaningSearch()
                                restoreDecisionFocus(running: false)
                            }
                                .focused($focusedAction, equals: .cancel)
                                .accessibilityLabel("Cancel meaning search")
                        }
                        .font(NoemaTypography.metadata)
                        .accessibilityElement(children: .contain)
                    } else if let message = model.semanticSearchStatus.message {
                        Text(message)
                            .font(NoemaTypography.metadata)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showsIndexingControls {
                        Button("Semantic Indexing…") { showingIndexing = true }
                            .accessibilityLabel("Open semantic indexing and rebuild controls")
                    }
                    if let disclosure = model.pendingSemanticQueryDisclosure {
                        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                            Text("Send this search query to \(disclosure.provider)?")
                                .font(NoemaTypography.interfaceEmphasis)
                            ScrollView {
                                Text(disclosure.query)
                                    .font(NoemaTypography.metadata)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                            .accessibilityLabel("Query to send")
                            Text("Your query will leave this device and be sent to \(disclosure.provider), using \(disclosure.model). API charges may apply. Keyword results remain available if you decline.")
                                .font(NoemaTypography.metadata)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Send query") {
                                    model.approveSemanticQuery(queryID: disclosure.id)
                                    restoreDecisionFocus(running: true)
                                }
                                .accessibilityLabel("Send this query to \(disclosure.provider)")
                                Button("Use keywords") {
                                    model.declineSemanticQuery(queryID: disclosure.id)
                                    restoreDecisionFocus(running: false)
                                }
                                .accessibilityLabel("Decline sending query and keep keyword results")
                            }
                        }
                        .padding(NoemaSpacing.sm)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityElement(children: .contain)
                    }
                }
            }
            .sheet(isPresented: $showingIndexing) { EmbeddingQueueView(model: model) }
            .onChange(of: model.sessionManager.accessGate.currentLease) { showingIndexing = false }
            .onChange(of: model.semanticSearchStatus) {
                if focusedAction == .cancel && !model.semanticSearchStatus.isRunning {
                    focusedAction = .search
                }
                guard announcesStatus, model.searchRetrievalMode == .meaning,
                      let message = model.semanticSearchStatus.message,
                      let application = NSApp else { return }
                NSAccessibility.post(element: application,
                                     notification: .announcementRequested,
                                     userInfo: [.announcement: message,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
    }

    private var showsIndexingControls: Bool {
        switch model.semanticSearchStatus {
        case .unavailable, .completed: true
        default: false
        }
    }

    private func restoreDecisionFocus(running: Bool) {
        if let onQueryDecision { onQueryDecision() }
        else { focusedAction = running ? .cancel : .search }
    }
}
