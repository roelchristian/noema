import Foundation
import Observation
import Synchronization
import Testing
@testable import noema

struct SourcesStatusPresentationTests {
    @Test @MainActor func availabilityUpdateNotifiesOnlyTheAffectedAvailabilityCell() {
        let firstID = UUID(), secondID = UUID()
        let presentation = SourcesStatusPresentation()
        var snapshot = SourcesStatusSnapshot(sourceIDs: [firstID, secondID])
        #expect(presentation.synchronize(snapshot).isEmpty)
        let first = presentation.status(for: firstID)
        let second = presentation.status(for: secondID)
        let firstAvailabilityChanges = Mutex(0)
        let firstTitleChanges = Mutex(0)
        let secondAvailabilityChanges = Mutex(0)
        withObservationTracking { _ = first.availabilityState } onChange: {
            firstAvailabilityChanges.withLock { $0 += 1 }
        }
        withObservationTracking { _ = first.titleState } onChange: {
            firstTitleChanges.withLock { $0 += 1 }
        }
        withObservationTracking { _ = second.availabilityState } onChange: {
            secondAvailabilityChanges.withLock { $0 += 1 }
        }

        snapshot.availability[firstID] = "Original unavailable"
        #expect(presentation.synchronize(snapshot) == [firstID])
        #expect(presentation.status(for: firstID) === first)
        #expect(presentation.status(for: secondID) === second)
        #expect(firstAvailabilityChanges.withLock { $0 } == 1)
        #expect(firstTitleChanges.withLock { $0 } == 0)
        #expect(secondAvailabilityChanges.withLock { $0 } == 0)
        #expect(presentation.synchronize(snapshot).isEmpty)
    }

    @Test @MainActor func statusPrecedenceMatchesExistingTableIndicators() {
        let id = UUID()
        let presentation = SourcesStatusPresentation()
        var snapshot = SourcesStatusSnapshot(sourceIDs: [id], issues: [id: "Missing"],
                                             downloading: [id], generatingTitles: [id], checking: [id],
                                             availability: [id: "Checked"])
        presentation.synchronize(snapshot)
        let state = presentation.status(for: id)
        #expect(state.titleState == .downloading)
        #expect(state.availabilityState == .downloading)

        snapshot.downloading = []
        presentation.synchronize(snapshot)
        #expect(state.titleState == .generating)
        #expect(state.availabilityState == .checking)
        snapshot.generatingTitles = []
        snapshot.checking = []
        presentation.synchronize(snapshot)
        #expect(state.titleState == .ready)
        #expect(state.availabilityState == .available("Checked"))
        snapshot.availability = [:]
        presentation.synchronize(snapshot)
        #expect(state.availabilityState == .available("Missing"))
    }

    @Test @MainActor func removedRowsAndClearedStateDoNotKeepAvailabilityLabels() {
        let id = UUID()
        let presentation = SourcesStatusPresentation()
        presentation.synchronize(SourcesStatusSnapshot(sourceIDs: [id], availability: [id: "Sensitive status"]))
        let oldState = presentation.status(for: id)
        presentation.synchronize(SourcesStatusSnapshot(sourceIDs: []))
        let replacement = presentation.status(for: id)
        #expect(oldState.availabilityState == .available("Available"))
        #expect(replacement !== oldState)
        #expect(replacement.availabilityState == .available("Available"))
        presentation.synchronize(SourcesStatusSnapshot(sourceIDs: [id], availability: [id: "Restored status"]))
        presentation.clear()
        #expect(replacement.availabilityState == .available("Available"))
        #expect(presentation.status(for: id) !== replacement)
        #expect(presentation.status(for: id).availabilityState == .available("Available"))
    }
}
