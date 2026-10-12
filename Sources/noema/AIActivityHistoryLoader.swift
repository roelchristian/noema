import Foundation
import Observation
import VaultCore

/// Latest-request ownership keeps delayed reads from undoing a clear, prune or
/// newer refresh. This state contains technical records only; titles stay in the view.
@MainActor @Observable final class AIActivityHistoryLoader {
    private(set) var records: [AIActivityRecord] = []
    private(set) var total = 0
    private(set) var loading = false
    var errorMessage: String?
    @ObservationIgnored private var requestID = UUID()

    func invalidate() {
        requestID = UUID()
        records = []
        total = 0
        loading = false
    }

    /// Return true only when this request commits the currently displayed snapshot.
    @discardableResult
    func load(recorder: AIActivityRecorder, query: AIActivityQuery,
              isCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        let identity = UUID()
        requestID = identity
        loading = true
        defer { if requestID == identity { loading = false } }
        do {
            let result = try await recorder.query(query)
            let count = try await recorder.count(query)
            let unavailable = await recorder.recordingUnavailable
            guard requestID == identity, !Task.isCancelled, isCurrent() else { return false }
            records = result
            total = count
            errorMessage = unavailable ? "Some activity could not be recorded. History may be incomplete." : nil
            return true
        } catch {
            guard requestID == identity, !Task.isCancelled, isCurrent() else { return false }
            records = []
            total = 0
            errorMessage = "Activity history is unavailable. AI operations can still continue."
            return true
        }
    }
}
