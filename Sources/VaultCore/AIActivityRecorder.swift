import Foundation

/// Best-effort metadata recording. Persistence failures never change inference or publication results.
public actor AIActivityRecorder {
    public static let shared = AIActivityRecorder(url: SQLiteAIActivityStore.defaultURL)
    private var store: (any AIActivityStore)?
    private let url: URL?
    private var attemptedOpen: Bool
    private var lastPrune: Date?
    public private(set) var recordingUnavailable: Bool

    public init(store: (any AIActivityStore)?) {
        self.store = store; url = nil; attemptedOpen = true; recordingUnavailable = store == nil
    }
    public init(url: URL) {
        self.url = url; store = nil; attemptedOpen = false; recordingUnavailable = false
    }
    private func availableStore() throws -> any AIActivityStore {
        if !attemptedOpen {
            attemptedOpen = true
            do { store = try SQLiteAIActivityStore(url: url!) }
            catch { recordingUnavailable = true; throw AIActivityStoreError.unavailable }
        }
        guard let store else { throw AIActivityStoreError.unavailable }; return store
    }
    @discardableResult
    public func begin(id: UUID = UUID(), vaultID: UUID? = nil, target: AIActivityTarget? = nil,
                      action: AIActivityAction, executionMode: AIActivityExecutionMode, provider: AIActivityProvider,
                      modelID: String? = nil, contentSizeBytes: Int? = nil, providerResponseCount: Int? = nil) async -> UUID {
        do {
            let store = try availableStore(), now = Date()
            try await store.insert(AIActivityRecord(id:id,startedAt:now,vaultID:vaultID,target:target,action:action,executionMode:executionMode,provider:provider,modelID:modelID,contentSizeBytes:contentSizeBytes,providerResponseCount:providerResponseCount))
            if lastPrune == nil || now.timeIntervalSince(lastPrune!) >= 86400 {
                lastPrune = now; try await store.prune(before:now)
            }
        } catch { recordingUnavailable = true }
        return id
    }
    public func recordDispatch(_ id: UUID) async {
        do { try await availableStore().recordDispatch(id) } catch { recordingUnavailable = true }
    }
    public func recordProviderResponse(_ id: UUID) async {
        do { try await availableStore().recordProviderResponse(id) } catch { recordingUnavailable = true }
    }
    public func recordUsage(_ id: UUID, usage: AIActivityUsage, estimatedCostUSD: Double? = nil) async {
        do { try await availableStore().recordUsage(id,usage:usage,estimatedCostUSD:estimatedCostUSD) } catch { recordingUnavailable = true }
    }
    public func finish(_ id: UUID, status: AIActivityStatus, outcome: AIActivityOutcome = .notApplicable,
                       failureCode: AIActivityFailureCode? = nil) async {
        do { try await availableStore().finish(id,at:Date(),status:status,outcome:outcome,failureCode:failureCode) }
        catch { recordingUnavailable = true }
    }
    /// Reviewed suggestions may be applied or dismissed without creating a second inference record.
    public func updateOutcome(_ id: UUID, outcome: AIActivityOutcome) async {
        guard outcome == .published || outcome == .rejected else { return }
        do { try await availableStore().updateOutcome(id,outcome:outcome) } catch { recordingUnavailable = true }
    }
    public func query(_ query: AIActivityQuery = .init()) async throws -> [AIActivityRecord] { try await availableStore().query(query) }
    public func count(_ query: AIActivityQuery = .init()) async throws -> Int { try await availableStore().count(query) }
    public func clearHistory() async throws { try await availableStore().clearHistory() }
    public func retentionDays() async throws -> Int? { try await availableStore().retentionDays() }
    public func setRetentionDays(_ days: Int?) async throws {
        let store = try availableStore(); try await store.setRetentionDays(days); try await store.prune(before:Date())
    }
    public func prune() async throws { try await availableStore().prune(before:Date()); lastPrune = Date() }
    /// A deliberately small export; callers choose any narrower vault/date filters and own destination I/O.
    public func exportMetadata(_ query: AIActivityQuery = .init(limit:1000)) async throws -> Data {
        var query = query; query.limit = min(1000,max(1,query.limit))
        let records = try await availableStore().query(query)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        return try encoder.encode(records)
    }
}
