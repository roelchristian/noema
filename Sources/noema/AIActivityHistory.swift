import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// Resolved names are transient and must be checked against the synchronous gate on
/// every render and navigation, including the observation delay during locking.
@MainActor enum AIActivityPrivacy {
    static func accessibleVaultID(_ model: AppModel?) -> UUID? {
        guard let model, model.isVaultAvailable,
              let lease = model.sessionManager.accessGate.currentLease else { return nil }
        return lease.vaultID
    }

    static func title(for record: AIActivityRecord, model: AppModel?) -> String {
        guard let vaultID = accessibleVaultID(model), record.vaultID == vaultID else {
            return record.vaultID == nil ? "No vault target" : "Private vault item"
        }
        guard let target = record.target, let model else { return "No document target" }
        switch target.type {
        case .page: return model.notes.first { $0.id == target.id }?.title ?? "Unavailable page"
        case .source: return model.sources.first { $0.id == target.id }?.title ?? "Unavailable source"
        }
    }

    static func canNavigate(_ record: AIActivityRecord, model: AppModel?) -> Bool {
        guard let vaultID = accessibleVaultID(model), record.vaultID == vaultID,
              let target = record.target, let model else { return false }
        switch target.type {
        case .page: return model.notes.contains { $0.id == target.id }
        case .source: return model.sources.contains { $0.id == target.id }
        }
    }

    /// Export has an explicit schema: no titles, paths or payloads, and identifying
    /// vault/target metadata omitted even when the vault is accessible.
    struct ExportRecord: Encodable {
        let id: UUID
        let startedAt: Date
        let finishedAt: Date?
        let vaultID: UUID?
        let target: AIActivityTarget?
        let action: AIActivityAction
        let executionMode: AIActivityExecutionMode
        let provider: AIActivityProvider
        let modelID: String?
        let status: AIActivityStatus
        let outcome: AIActivityOutcome
        let failureCode: AIActivityFailureCode?
        let durationMilliseconds: Int?
        let usage: AIActivityUsage?
        let estimatedCostUSD: Double?
        let requestCount: Int
        let contentSizeBytes: Int?
    }

    static func export(_ records: [AIActivityRecord]) throws -> Data {
        let safeRecords = records.map { record in
            return ExportRecord(id: record.id, startedAt: record.startedAt, finishedAt: record.finishedAt,
                vaultID: nil, target: nil,
                action: record.action, executionMode: record.executionMode, provider: record.provider,
                modelID: record.modelID, status: record.status, outcome: record.outcome,
                failureCode: record.failureCode, durationMilliseconds: record.durationMilliseconds,
                usage: record.usage, estimatedCostUSD: record.estimatedCostUSD,
                requestCount: record.requestCount, contentSizeBytes: record.contentSizeBytes)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(safeRecords)
    }
}

private struct AIActivityExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct AIActivityHistoryView: View {
    var model: AppModel?
    var recorder: AIActivityRecorder = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var records: [AIActivityRecord] = []
    @State private var selection: UUID?
    @State private var provider: AIActivityProvider?
    @State private var action: AIActivityAction?
    @State private var status: AIActivityStatus?
    @State private var outcome: AIActivityOutcome?
    @State private var dateDays = 30
    @State private var currentVaultOnly = false
    @State private var page = 0
    @State private var total = 0
    @State private var retention = 90
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showClearConfirmation = false
    @State private var exporting = false
    @State private var exportDocument = AIActivityExportDocument(data: Data())
    // A lock/session change invalidates asynchronous queries and metadata exports.
    private var accessibleVaultID: UUID? { AIActivityPrivacy.accessibleVaultID(model) }
    private var query: AIActivityQuery {
        AIActivityQuery(vaultID: currentVaultOnly ? accessibleVaultID : nil,
            provider: provider, action: action, status: status, outcome: outcome,
            startedAfter: dateDays == 0 ? nil : Date().addingTimeInterval(-Double(dateDays) * 86_400),
            limit: 50, offset: page * 50)
    }
    private var queryKey: String {
        "\(provider?.rawValue ?? "all")/\(action?.rawValue ?? "all")/\(status?.rawValue ?? "all")/\(outcome?.rawValue ?? "all")/\(dateDays)/\(currentVaultOnly)/\(accessibleVaultID?.uuidString ?? "none")/\(page)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Activity").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("History is stored locally and records technical metadata only. Recording is best effort; this is not a complete or tamper-proof audit. Cost estimates are available only when reported usage and applicable pricing are known.")
                .font(.caption).foregroundStyle(.secondary)
            filters
            HSplitView {
                Table(records, selection: $selection) {
                    TableColumn("Item") { record in
                        Text(AIActivityPrivacy.title(for: record, model: model))
                    }
                    TableColumn("Operation") { record in Text(label(record.action.rawValue)) }
                    TableColumn("Provider") { record in Text(record.provider == .openAI ? "OpenAI" : "On-device") }
                    TableColumn("Started") { record in Text(record.startedAt, format: .dateTime.month().day().hour().minute()) }
                    TableColumn("Status") { record in Text(label(record.status.rawValue)) }
                }
                .frame(minWidth: 500, minHeight: 240)
                if let record = records.first(where: { $0.id == selection }) {
                    inspector(record).frame(width: 240)
                }
            }
            HStack {
                Text("\(total) matching operations").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Previous") { page -= 1 }.disabled(page == 0 || loading)
                Text("Page \(page + 1)").font(.caption)
                Button("Next") { page += 1 }.disabled((page + 1) * 50 >= total || loading)
                Button("Refresh") { Task { await load() } }.disabled(loading)
            }
            Divider()
            HStack {
                Picker("Keep history", selection: $retention) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Forever").tag(0)
                }.frame(width: 235)
                .onChange(of: retention) { _, value in
                    Task {
                        do { try await recorder.setRetentionDays(value == 0 ? nil : value); await load() }
                        catch { errorMessage = "History retention could not be updated." }
                    }
                }
                Spacer()
                Button("Export metadata…") { Task { await prepareExport() } }.disabled(loading || total == 0)
                Button("Clear History…", role: .destructive) { showClearConfirmation = true }
            }
            Text("Exports contain at most 1,000 matching records. Vault and target identifiers are omitted. Clearing or pruning history does not remove AI results from your pages and sources; ordinary deletion is not secure erasure.")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20).frame(minWidth: 900, idealWidth: 1050, minHeight: 560)
        .task(id: queryKey) { await load() }
        .task {
            do { retention = try await recorder.retentionDays() ?? 0 }
            catch { errorMessage = "Activity history is unavailable. AI operations can still continue." }
        }
        .onChange(of: accessibleVaultID) { _, _ in
            // Drop the pending export immediately; re-export requires a fresh access check.
            exporting = false
            exportDocument = AIActivityExportDocument(data: Data())
            selection = nil
            currentVaultOnly = false
            page = 0
        }
        .confirmationDialog("Clear all AI activity history?", isPresented: $showClearConfirmation) {
            Button("Clear History", role: .destructive) {
                Task {
                    do { try await recorder.clearHistory(); page = 0; await load() }
                    catch { errorMessage = "Activity history could not be cleared." }
                }
            }
        } message: { Text("This removes history for every vault. Saved AI results remain in your documents.") }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "Noema AI Activity") { result in
            if case .failure = result { errorMessage = "Activity metadata could not be exported." }
            exportDocument = AIActivityExportDocument(data: Data())
        }
    }

    private var filters: some View {
        VStack {
            HStack {
                Picker("Provider", selection: $provider) {
                    Text("All providers").tag(nil as AIActivityProvider?)
                    Text("On-device").tag(AIActivityProvider.onDevice as AIActivityProvider?)
                    Text("OpenAI").tag(AIActivityProvider.openAI as AIActivityProvider?)
                }
                Picker("Action", selection: $action) {
                    Text("All actions").tag(nil as AIActivityAction?)
                    ForEach(AIActivityAction.allCases, id: \.self) { Text(label($0.rawValue)).tag($0 as AIActivityAction?) }
                }
                Picker("Status", selection: $status) {
                    Text("All statuses").tag(nil as AIActivityStatus?)
                    ForEach(AIActivityStatus.allCases, id: \.self) { Text(label($0.rawValue)).tag($0 as AIActivityStatus?) }
                }
            }
            HStack {
                Picker("Outcome", selection: $outcome) {
                    Text("All outcomes").tag(nil as AIActivityOutcome?)
                    ForEach(AIActivityOutcome.allCases, id: \.self) { Text(label($0.rawValue)).tag($0 as AIActivityOutcome?) }
                }
                Picker("Date", selection: $dateDays) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                    Text("All dates").tag(0)
                }
                Picker("Vault", selection: $currentVaultOnly) {
                    Text("All vaults (private items concealed)").tag(false)
                    if accessibleVaultID != nil { Text("Current open vault").tag(true) }
                }
            }
        }
        .onChange(of: provider) { _, _ in page = 0 }
        .onChange(of: action) { _, _ in page = 0 }
        .onChange(of: status) { _, _ in page = 0 }
        .onChange(of: outcome) { _, _ in page = 0 }
        .onChange(of: dateDays) { _, _ in page = 0 }
        .onChange(of: currentVaultOnly) { _, _ in page = 0 }
    }

    private func inspector(_ record: AIActivityRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(AIActivityPrivacy.title(for: record, model: model)).font(.headline)
                detail("Action", label(record.action.rawValue))
                detail("Mode", label(record.executionMode.rawValue))
                detail("Model", record.modelID ?? "Unknown")
                detail("Outcome", label(record.outcome.rawValue))
                detail("Duration", record.durationMilliseconds.map { String(format: "%.2f s", Double($0) / 1000) } ?? "In progress")
                detail("API dispatches", "\(record.requestCount)")
                detail("Input tokens", record.usage?.inputTokens.map(String.init) ?? "Unknown")
                detail("Cached input tokens", record.usage?.cachedInputTokens.map(String.init) ?? "Unknown")
                detail("Output tokens", record.usage?.outputTokens.map(String.init) ?? "Unknown")
                detail("Estimated USD", record.estimatedCostUSD.map { String(format: "$%.6f", $0) } ?? (record.provider == .openAI ? "Unknown" : "—"))
                if let code = record.failureCode { detail("Failure code", code.rawValue) }
                if let target = record.target {
                    Button(target.type == .page ? "Open Page" : "Open Source") {
                        guard AIActivityPrivacy.canNavigate(record, model: model), let model else { return }
                        if target.type == .page { model.select(target.id, scope: .wiki) }
                        else { model.openSource(target.id) }
                    }.disabled(!AIActivityPrivacy.canNavigate(record, model: model))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func label(_ raw: String) -> String {
        raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }

    @MainActor private func load() async {
        let key = queryKey
        loading = true
        defer { if key == queryKey { loading = false } }
        do {
            let requestedQuery = query
            let result = try await recorder.query(requestedQuery)
            let count = try await recorder.count(requestedQuery)
            guard !Task.isCancelled, key == queryKey else { return }
            records = result; total = count; selection = nil
            errorMessage = await recorder.recordingUnavailable ? "Some activity could not be recorded. History may be incomplete." : nil
        } catch {
            guard !Task.isCancelled, key == queryKey else { return }
            records = []; total = 0
            errorMessage = "Activity history is unavailable. AI operations can still continue."
        }
    }

    @MainActor private func prepareExport() async {
        let vaultID = accessibleVaultID
        var exportQuery = query
        exportQuery.limit = 1000
        exportQuery.offset = 0
        do {
            let result = try await recorder.query(exportQuery)
            guard vaultID == accessibleVaultID else { return }
            exportDocument = AIActivityExportDocument(data: try AIActivityPrivacy.export(result))
            exporting = true
        } catch { errorMessage = "Activity metadata could not be exported." }
    }
}
