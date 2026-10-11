import Foundation
import Observation

/// Lightweight input for status observation, containing no source text or metadata formatting.
struct SourcesStatusSnapshot: Equatable {
    var sourceIDs: Set<UUID>
    var issues: [UUID: String] = [:]
    var downloading: Set<UUID> = []
    var generatingTitles: Set<UUID> = []
    var checking: Set<UUID> = []
    var availability: [UUID: String] = [:]
}

@MainActor @Observable final class SourceRowStatus {
    enum TitleState: Equatable { case ready, downloading, generating }
    enum AvailabilityState: Equatable { case downloading, checking, available(String) }

    private(set) var titleState: TitleState = .ready
    private(set) var availabilityState: AvailabilityState = .available("Available")

    @discardableResult
    func update(title: TitleState, availability: AvailabilityState) -> Bool {
        var changed = false
        if titleState != title { titleState = title; changed = true }
        if availabilityState != availability { availabilityState = availability; changed = true }
        return changed
    }
}

/// The dictionary itself is deliberately not observable. Its per-ID objects stay stable while
/// metadata rows change, and only changed status properties notify cell observers.
@MainActor final class SourcesStatusPresentation {
    private var states: [UUID: SourceRowStatus] = [:]

    func status(for id: UUID) -> SourceRowStatus {
        if let state = states[id] { return state }
        let state = SourceRowStatus()
        states[id] = state
        return state
    }

    @discardableResult
    func synchronize(_ snapshot: SourcesStatusSnapshot) -> Set<UUID> {
        SourcesPerformance.measure("SourceStatusUpdate") {
            for (id, state) in states where !snapshot.sourceIDs.contains(id) {
                state.update(title: .ready, availability: .available("Available"))
                states.removeValue(forKey: id)
            }
            var changed: Set<UUID> = []
            for id in snapshot.sourceIDs {
                let title: SourceRowStatus.TitleState = snapshot.downloading.contains(id) ? .downloading
                    : snapshot.generatingTitles.contains(id) ? .generating : .ready
                let availability: SourceRowStatus.AvailabilityState
                if snapshot.downloading.contains(id) { availability = .downloading }
                else if snapshot.checking.contains(id) { availability = .checking }
                else { availability = .available(snapshot.availability[id] ?? snapshot.issues[id] ?? "Available") }
                if status(for: id).update(title: title, availability: availability) { changed.insert(id) }
            }
            return changed
        }
    }

    func clear() {
        // A cell can temporarily retain its status object while SwiftUI removes the table.
        // Clear labels on those objects as well as dropping our dictionary references.
        for state in states.values {
            state.update(title: .ready, availability: .available("Available"))
        }
        states.removeAll()
    }
}
