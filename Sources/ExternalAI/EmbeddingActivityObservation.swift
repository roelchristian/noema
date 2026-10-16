import Foundation
import Synchronization
import VaultCore

/// Numeric-only transport observation. Never stores inputs, vectors, capabilities or errors.
/// Dispatch callbacks run under authorization locks: they update these counters only.
final class EmbeddingActivityObservation: Sendable {
    private struct State: Sendable {
        var dispatches = 0
        var responses = 0
        var usage: AIActivityUsage?
    }
    private let state = Mutex(State())
    func dispatched() { state.withLock { $0.dispatches = min($0.dispatches + 1, ExternalAILimits.maximumRetryCount + 1) } }
    func received(usage: AIActivityUsage?) {
        state.withLock { $0.responses = min($0.responses + 1, ExternalAILimits.maximumRetryCount + 1); $0.usage = usage }
    }
    func flush(id: UUID, recorder: AIActivityRecorder?) async {
        guard let recorder else { return }
        let snapshot = state.withLock { let snapshot = $0; $0 = State(); return snapshot }
        for _ in 0..<snapshot.dispatches { await recorder.recordDispatch(id) }
        for _ in 0..<snapshot.responses { await recorder.recordProviderResponse(id) }
        if let usage = snapshot.usage {
            // No embedding pricing has been established. Retry dispatches without usage
            // remain unknown; reported tokens describe only the observed successful response.
            await recorder.recordUsage(id, usage: usage, estimatedCostUSD: nil)
        }
    }
}
