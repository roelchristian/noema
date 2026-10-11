import Foundation

/// Activity metadata has no field for document text, titles, credentials, errors or HTTP bodies.
public enum AIActivityAction: String, Codable, CaseIterable, Hashable, Sendable {
    case summarizePage, summarizeSource, suggestTitle, classifyLCC, processSource
    case createPageFromSource, createPageFromTopic, validateConnection
}
public enum AIActivityProvider: String, Codable, CaseIterable, Hashable, Sendable { case onDevice, openAI }
public enum AIActivityExecutionMode: String, Codable, CaseIterable, Hashable, Sendable { case automatic, userInvoked }
public enum AIActivityStatus: String, Codable, CaseIterable, Hashable, Sendable { case running, completed, failed, cancelled, interrupted }
public enum AIActivityOutcome: String, Codable, CaseIterable, Hashable, Sendable { case published, suggested, rejected, notApplicable }
public enum AIActivityFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case cancelled, interrupted, unavailable, authorization, consent, network, invalidResponse, publication, unknown
}
public struct AIActivityTarget: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable { case page, source }
    public let type: Kind
    public let id: UUID
    public init(type: Kind, id: UUID) { self.type = type; self.id = id }
}
public struct AIActivityUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cachedInputTokens: Int? = nil) {
        let input = Self.bounded(inputTokens)
        self.inputTokens = input
        self.outputTokens = Self.bounded(outputTokens)
        self.cachedInputTokens = Self.bounded(cachedInputTokens).flatMap { cached in
            guard let input, cached <= input else { return nil }; return cached
        }
    }
    private static func bounded(_ value: Int?) -> Int? { value.flatMap { (0...1_000_000_000).contains($0) ? $0 : nil } }
}
public struct AIActivityRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let vaultID: UUID?
    public let target: AIActivityTarget?
    public let action: AIActivityAction
    public let executionMode: AIActivityExecutionMode
    public let provider: AIActivityProvider
    public let modelID: String?
    public let status: AIActivityStatus
    public let failureCode: AIActivityFailureCode?
    public let durationMilliseconds: Int?
    public let usage: AIActivityUsage?
    public let estimatedCostUSD: Double?
    public let requestCount: Int
    public let contentSizeBytes: Int?
    public let outcome: AIActivityOutcome

    public init(id: UUID = UUID(), startedAt: Date = Date(), finishedAt: Date? = nil,
                vaultID: UUID? = nil, target: AIActivityTarget? = nil, action: AIActivityAction,
                executionMode: AIActivityExecutionMode, provider: AIActivityProvider, modelID: String? = nil,
                status: AIActivityStatus = .running, failureCode: AIActivityFailureCode? = nil,
                durationMilliseconds: Int? = nil, usage: AIActivityUsage? = nil, estimatedCostUSD: Double? = nil,
                requestCount: Int = 0, contentSizeBytes: Int? = nil, outcome: AIActivityOutcome = .notApplicable) {
        self.id = id; self.startedAt = startedAt; self.finishedAt = finishedAt; self.vaultID = vaultID
        self.target = target; self.action = action; self.executionMode = executionMode; self.provider = provider
        self.modelID = Self.validatedModelID(modelID); self.status = status; self.failureCode = failureCode
        self.durationMilliseconds = durationMilliseconds.flatMap { $0 >= 0 ? $0 : nil }
        self.usage = provider == .openAI ? usage.map { AIActivityUsage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens, cachedInputTokens: $0.cachedInputTokens) } : nil
        self.estimatedCostUSD = provider == .openAI ? estimatedCostUSD.flatMap { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 ? $0 : nil } : nil
        self.requestCount = provider == .openAI ? min(1_000_000, max(0, requestCount)) : 0
        self.contentSizeBytes = contentSizeBytes.flatMap { (0...1_000_000_000).contains($0) ? $0 : nil }
        self.outcome = outcome
    }
    public static func validatedModelID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else { return nil }
        return value
    }
}

public struct AIActivityQuery: Sendable {
    public var vaultID: UUID?
    public var target: AIActivityTarget?
    public var provider: AIActivityProvider?
    public var action: AIActivityAction?
    public var status: AIActivityStatus?
    public var outcome: AIActivityOutcome?
    public var startedAfter: Date?
    public var startedBefore: Date?
    public var limit: Int
    public var offset: Int
    public init(vaultID: UUID? = nil, target: AIActivityTarget? = nil, provider: AIActivityProvider? = nil,
                action: AIActivityAction? = nil, status: AIActivityStatus? = nil, outcome: AIActivityOutcome? = nil,
                startedAfter: Date? = nil, startedBefore: Date? = nil, limit: Int = 50, offset: Int = 0) {
        self.vaultID = vaultID; self.target = target; self.provider = provider; self.action = action
        self.status = status; self.outcome = outcome; self.startedAfter = startedAfter; self.startedBefore = startedBefore
        self.limit = limit; self.offset = offset
    }
}
public enum AIActivityStoreError: Error, Equatable, Sendable { case unavailable, unsupportedSchema, invalidMetadata, invalidRetention }

public protocol AIActivityStore: Sendable {
    func insert(_ record: AIActivityRecord) async throws
    func recordDispatch(_ id: UUID) async throws
    func recordUsage(_ id: UUID, usage: AIActivityUsage, estimatedCostUSD: Double?) async throws
    func finish(_ id: UUID, at: Date, status: AIActivityStatus, outcome: AIActivityOutcome, failureCode: AIActivityFailureCode?) async throws
    func updateOutcome(_ id: UUID, outcome: AIActivityOutcome) async throws
    func query(_ query: AIActivityQuery) async throws -> [AIActivityRecord]
    func count(_ query: AIActivityQuery) async throws -> Int
    func retentionDays() async throws -> Int?
    func setRetentionDays(_ days: Int?) async throws
    func prune(before now: Date) async throws
    func clearHistory() async throws
}
