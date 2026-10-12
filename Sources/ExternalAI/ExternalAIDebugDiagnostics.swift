import Foundation
import Synchronization
import VaultCore

/// Explicit, session-bound inspection only. Never written to logs or persistent storage.
public final class ExternalAIDebugDiagnostics: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private struct State {
        var lease: VaultSessionLease?
        var report: String?
    }
    private let state = Mutex(State())
    public init() {}
    public var isEnabled: Bool { state.withLock { $0.lease != nil } }
    public var report: String? { state.withLock { $0.report } }
    public var description: String { "ExternalAIDebugDiagnostics(<redacted>)" }
    public var debugDescription: String { description }

    public func enable(for lease: VaultSessionLease) {
        state.withLock { $0 = State(lease: lease) }
    }
    public func clear() { state.withLock { $0.report = nil } }
    public func disable() { state.withLock { $0 = State() } }

    func record(body: Data, status: Int, failure: ExternalAIError, action: ExternalAIAction,
                lease: VaultSessionLease, stage: String = "Action output validation") {
        state.withLock {
            guard $0.lease == lease else { return }
            let bounded = body.prefix(ExternalAILimits.maximumResponseBytes)
            let suffix = body.count > bounded.count ? "\n[Response truncated at byte limit]" : ""
            $0.report = "Action: \(action.rawValue)\nHTTP status: \(status)\nValidation failure: \(failure.rawValue)\nStage: \(stage)\nResponse bytes: \(body.count)\n\nExact response body:\n"
                + String(decoding: bounded, as: UTF8.self) + suffix
        }
    }
}
