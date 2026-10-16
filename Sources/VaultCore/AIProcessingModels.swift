import Foundation

public enum AIEntityKind: String, Codable, Sendable { case page, source }
public enum AIChangeKind: String, Codable, Sendable { case created, updated, removed, restored, reprocess }
public enum AIChangeOrigin: String, Codable, Sendable { case user, `import`, aiPublication, externalReconciliation }
public enum AIContentDimension: String, Codable, Sendable { case body, title, metadata, sourceContent, lifecycle }

/// Technical metadata only. Revisions must be opaque tokens/hashes, never document text.
public struct AIContentChange: Codable, Sendable, Equatable {
    public let vaultID: UUID
    public let entityKind: AIEntityKind
    public let entityID: UUID
    public let revision: String
    public let kind: AIChangeKind
    public let origin: AIChangeOrigin
    public let dimensions: Set<AIContentDimension>
    public init(vaultID: UUID, entityKind: AIEntityKind, entityID: UUID, revision: String,
                kind: AIChangeKind = .updated, origin: AIChangeOrigin = .user,
                dimensions: Set<AIContentDimension> = [.body]) {
        self.vaultID = vaultID; self.entityKind = entityKind; self.entityID = entityID
        self.revision = revision; self.kind = kind; self.origin = origin; self.dimensions = dimensions
    }
}

public struct AIWorkKey: Codable, Sendable, Hashable {
    public let vaultID: UUID
    public let entityKind: AIEntityKind
    public let entityID: UUID
    public let processorID: String
    public init(vaultID: UUID, entityKind: AIEntityKind, entityID: UUID, processorID: String) {
        self.vaultID = vaultID; self.entityKind = entityKind; self.entityID = entityID; self.processorID = processorID
    }
}

public enum AIWorkState: String, Codable, Sendable {
    case pending, scheduled, running, completed, superseded, suspended, retryable, blocked, failed, cancelled
    public func permits(_ next: Self) -> Bool {
        if self == next { return true }
        switch self {
        case .pending, .scheduled, .retryable: return [.scheduled, .running, .superseded, .suspended, .blocked, .cancelled, .failed].contains(next)
        case .running: return [.completed, .superseded, .suspended, .retryable, .blocked, .failed, .cancelled].contains(next)
        case .suspended, .blocked: return [.pending, .superseded, .cancelled].contains(next)
        case .completed, .superseded, .failed, .cancelled: return false
        }
    }
}
public enum AIWorkFailure: String, Codable, Sendable, Error {
    case authority, consent, unavailable, transient, unsupported, corruptContent, validation, ledger, attemptsExhausted
}
public enum AIWorkCompletionDisposition: String, Codable, Sendable { case completed, skipped }
public struct AIWorkItem: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var key: AIWorkKey
    public var revision: String
    public var processorVersion: String
    public var state: AIWorkState
    public var attemptCount: Int
    public var eligibleAt: Date
    public var inputFingerprint: String?
    public var failure: AIWorkFailure?
    public var updatedAt: Date
    public var batchID: UUID?
    public var completionDisposition: AIWorkCompletionDisposition?
    public init(id: UUID = UUID(), key: AIWorkKey, revision: String, processorVersion: String,
                state: AIWorkState = .pending, attemptCount: Int = 0, eligibleAt: Date,
                inputFingerprint: String? = nil, failure: AIWorkFailure? = nil, updatedAt: Date = Date(),
                batchID: UUID? = nil, completionDisposition: AIWorkCompletionDisposition? = nil) {
        self.id = id; self.key = key; self.revision = revision; self.processorVersion = processorVersion
        self.state = state; self.attemptCount = attemptCount; self.eligibleAt = eligibleAt
        self.inputFingerprint = inputFingerprint; self.failure = failure; self.updatedAt = updatedAt
        self.batchID = batchID; self.completionDisposition = completionDisposition
    }
}
public protocol AIWorkLedger: Sendable {
    func existingWorkItem(key: AIWorkKey) async throws -> AIWorkItem?
    func load(vaultID: UUID) async throws -> [AIWorkItem]
    func save(_ item: AIWorkItem) async throws
    func checkpoint(vaultID: UUID) async throws -> [AIContentChange]?
    func saveCheckpoint(vaultID: UUID, changes: [AIContentChange]) async throws
}
public extension AIWorkLedger {
    func existingWorkItem(key: AIWorkKey) async throws -> AIWorkItem? { nil }
}
public enum AIProcessingProvider: String, Codable, Sendable { case cloud, onDevice }
public struct AIProcessorDescriptor: Sendable {
    public let identifier: String
    public let version: String
    public let targets: Set<AIEntityKind>
    public let dependencies: Set<AIContentDimension>
    public let provider: AIProcessingProvider
    public let recoverOnVersionChange: Bool
    public let observesCommittedChanges: Bool
    public init(identifier: String, version: String, targets: Set<AIEntityKind>,
                dependencies: Set<AIContentDimension>, provider: AIProcessingProvider, recoverOnVersionChange: Bool = true, observesCommittedChanges: Bool = true) {
        self.identifier = identifier; self.version = version; self.targets = targets
        self.dependencies = dependencies; self.provider = provider
        self.recoverOnVersionChange = recoverOnVersionChange
        self.observesCommittedChanges = observesCommittedChanges
    }
}
/// Snapshot lifetime and protected memory retirement belong to the processor. Never persisted.
public protocol AIWorkSnapshot: Sendable {
    var revision: String { get }
    var inputFingerprint: String { get }
}
public enum AIWorkOutcome: Sendable { case completed, skipped, retryable(AIWorkFailure), blocked(AIWorkFailure), failed(AIWorkFailure) }
public struct AIProcessingExecutionContext: Sendable {
    public let lease: VaultSessionLease
    /// Must also be invoked by the processor inside conditional canonical publication.
    public let validate: @Sendable () throws -> Void
}
public protocol AIWorkProcessor: Sendable {
    var descriptor: AIProcessorDescriptor { get }
    func isEligible(_ change: AIContentChange) -> Bool
    func prepare(_ item: AIWorkItem, lease: VaultSessionLease) async throws -> any AIWorkSnapshot
    func execute(_ snapshot: any AIWorkSnapshot, context: AIProcessingExecutionContext) async throws -> AIWorkOutcome
    /// Re-read authoritative revision/input metadata; false for deletion or stale inputs.
    func isCurrent(_ item: AIWorkItem, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async throws -> Bool
}
public extension AIWorkProcessor {
    func isEligible(_ change: AIContentChange) -> Bool {
        descriptor.targets.contains(change.entityKind) && change.origin != .aiPublication
            && (change.kind == .restored || !descriptor.dependencies.isDisjoint(with: change.dimensions))
    }
}
public enum AIProcessingAuthority: Sendable { case allowed, blocked(AIWorkFailure) }
public protocol AIProcessingPolicyResolver: Sendable {
    func authorize(_ descriptor: AIProcessorDescriptor, lease: VaultSessionLease) async -> AIProcessingAuthority
    func authorize(_ descriptor: AIProcessorDescriptor, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async -> AIProcessingAuthority
    /// Revalidates current configuration/grant. External requests still require D02A request authorization.
    func validateExecution(lease: VaultSessionLease) throws
}
public extension AIProcessingPolicyResolver {
    func authorize(_ descriptor: AIProcessorDescriptor, snapshot: any AIWorkSnapshot, lease: VaultSessionLease) async -> AIProcessingAuthority {
        await authorize(descriptor, lease: lease)
    }
}
public struct AIProcessingClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void
    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }
    public static let continuous = Self(now: { Date() }, sleep: { delay in
        try await Task.sleep(for: .seconds(max(0, delay)))
    })
}
public struct AIProcessingConfiguration: Sendable {
    public var newPageDelay: TimeInterval = 5
    public var updatedPageDelay: TimeInterval = 15
    public var newSourceDelay: TimeInterval = 5
    public var updatedSourceDelay: TimeInterval = 10
    public var recoveryDelay: TimeInterval = 30
    public var initialRetryDelay: TimeInterval = 30
    public var maximumRetryDelay: TimeInterval = 900
    public var maximumAttempts: Int = 4
    public init() {}
}
public struct AIProcessingStatus: Sendable {
    public let pendingCount: Int
    public let runningCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let activeWork: [AIWorkKey]
    public let reason: AIWorkFailure?
    public let lastSuccessfulAt: Date?
}
