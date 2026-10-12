import Foundation
import ExternalAI
import VaultCore

/// A caller-owned logical operation. Helper model calls share this scope; only
/// bounded metadata crosses into the recorder. Early publication guards default
/// to cancellation, while exceptions are mapped to a finite failure code.
@MainActor final class AIActivityOperation {
    let id: UUID
    private let recorder: AIActivityRecorder
    private let vaultID: UUID?
    private let target: AIActivityTarget?
    private let action: AIActivityAction
    private let executionMode: AIActivityExecutionMode
    private var started = false
    private var status: AIActivityStatus = .cancelled
    private var outcome: AIActivityOutcome = .notApplicable
    private var failureCode: AIActivityFailureCode? = .publication

    init(id: UUID = UUID(), recorder: AIActivityRecorder, vaultID: UUID?, target: AIActivityTarget?,
         action: AIActivityAction, executionMode: AIActivityExecutionMode) {
        self.id = id; self.recorder = recorder; self.vaultID = vaultID; self.target = target
        self.action = action; self.executionMode = executionMode
    }

    func start(contentSizeBytes: Int? = nil) async throws {
        guard !started else { return }
        started = true
        await recorder.begin(id: id, vaultID: vaultID, target: target, action: action,
            executionMode: executionMode, provider: .onDevice, modelID: "apple-foundation-models",
            contentSizeBytes: contentSizeBytes)
        try Task.checkCancellation()
    }

    func complete(outcome: AIActivityOutcome = .published) {
        status = .completed; self.outcome = outcome; failureCode = nil
    }

    func fail(_ error: Error) {
        if status == .completed {
            if outcome == .suggested { outcome = .rejected }
            return
        }
        let failure = Self.failure(error)
        status = failure.status; failureCode = failure.code; outcome = .notApplicable
    }

    func finalize() async {
        guard started else { return }
        if status == .cancelled, Task.isCancelled { failureCode = .cancelled }
        await recorder.finish(id, status: status, outcome: outcome, failureCode: failureCode)
        if outcome == .rejected { await recorder.updateOutcome(id, outcome: .rejected) }
    }

    static func failure(_ error: Error) -> (status: AIActivityStatus, code: AIActivityFailureCode) {
        if error is CancellationError || Task.isCancelled { return (.cancelled, .cancelled) }
        guard let error = error as? ExternalAIError else { return (.failed, .unknown) }
        switch error {
        case .cancelled: return (.cancelled, .cancelled)
        case .staleContent, .staleSession: return (.cancelled, .publication)
        case .invalidResponse: return (.failed, .invalidResponse)
        case .credentialMissing, .credentialMalformed, .credentialUnavailable, .credentialExpired,
             .authenticationFailed, .authenticationCancelled, .authorizationRequired, .authorizationExpired,
             .authorizationRevoked: return (.failed, .authorization)
        case .consentRequired, .consentAlreadyUsed: return (.failed, .consent)
        case .networkUnavailable, .timedOut, .rateLimited, .redirectRejected: return (.failed, .network)
        case .summaryIncomplete, .summaryOutputLimitReached, .summaryRefused, .responseTooLarge:
            return (.failed, .invalidResponse)
        default: return (.failed, .unavailable)
        }
    }
}

extension AppModel {
    func withLocalAIActivity<T>(id: UUID = UUID(), target: ExternalAISummaryTarget? = nil,
        action: AIActivityAction, executionMode: AIActivityExecutionMode = .userInvoked,
        operation: @MainActor (AIActivityOperation) async -> T) async -> T {
        let target = target.map { AIActivityTarget(type: $0.isPage ? .page : .source, id: $0.id) }
        let activity = AIActivityOperation(id: id, recorder: activityRecorder,
            vaultID: sessionManager.accessGate.currentLease?.vaultID, target: target,
            action: action, executionMode: executionMode)
        let result = await operation(activity)
        await activity.finalize()
        return result
    }
}

extension ExternalAISummaryTarget {
    var isPageActivityTarget: Bool { if case .page = self { return true }; return false }
    fileprivate var isPage: Bool { isPageActivityTarget }
}

extension ExternalAIAction {
    var activityAction: AIActivityAction {
        switch self {
        case .summarizePage: .summarizePage
        case .summarizeSource: .summarizeSource
        case .suggestTitle: .suggestTitle
        case .lccClassification: .classifyLCC
        case .composePage: .composePage
        }
    }
}
