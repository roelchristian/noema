import Foundation
import Testing
@testable import VaultCore

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivedCount = 0
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivedCount += 1
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilArrived(_ count: Int = 1) async {
        while arrivedCount < count {
            await withCheckedContinuation { continuation in
                arrivalWaiters.append(continuation)
            }
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor CallCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

struct VaultSessionManagerTests {
    private let rootA = URL(fileURLWithPath: "/tmp/noema-session-test-vault-a")
    private let rootB = URL(fileURLWithPath: "/tmp/noema-session-test-vault-b")
    private let vaultIDA = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let vaultIDB = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    @Test func validFullLifecycleTransitionsAndObservationStream() async throws {
        let manager = VaultSessionManager()
        let stream = await manager.observations()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == .closed)
        #expect(await manager.state == .closed)
        #expect(await manager.generation == 0)
        #expect(await manager.epoch == 0)
        #expect(await manager.currentSession == nil)

        let firstSession = try await manager.open(root: rootA) { _ in self.vaultIDA }
        let normalizedA = rootA.standardizedFileURL.resolvingSymlinksInPath()
        #expect(firstSession.vaultID == vaultIDA)
        #expect(firstSession.root == normalizedA)
        #expect(firstSession.vaultName == normalizedA.lastPathComponent)
        #expect(firstSession.generation == 1)
        #expect(firstSession.epoch == 1)
        #expect(await manager.generation == 1)
        #expect(await manager.currentSession == firstSession)

        #expect(await iterator.next() == .opening(root: normalizedA, generation: 1))
        #expect(await iterator.next() == .open(firstSession))

        try await manager.lock()
        #expect(await manager.currentSession == nil)
        #expect(await manager.state == .locked(vaultID: vaultIDA, root: normalizedA, vaultName: normalizedA.lastPathComponent, generation: 1))
        #expect(await iterator.next() == .locking(firstSession))
        #expect(await iterator.next() == .locked(vaultID: vaultIDA, root: normalizedA, vaultName: normalizedA.lastPathComponent, generation: 1))

        let unlockedSession = try await manager.unlock { _ in self.vaultIDA }
        #expect(unlockedSession.vaultID == vaultIDA)
        #expect(unlockedSession.root == normalizedA)
        #expect(unlockedSession.id != firstSession.id)
        #expect(unlockedSession.generation == 2)
        #expect(await manager.generation == 2)
        #expect(await manager.currentSession == unlockedSession)

        #expect(await iterator.next() == .unlocking(vaultID: vaultIDA, root: normalizedA, vaultName: normalizedA.lastPathComponent, generation: 2))
        #expect(await iterator.next() == .open(unlockedSession))

        try await manager.close()
        #expect(await manager.state == .closed)
        #expect(await manager.currentSession == nil)
        #expect(await manager.generation == 2)
        #expect(await iterator.next() == .closed)

        let secondVaultSession = try await manager.open(root: rootB) { _ in self.vaultIDB }
        let normalizedB = rootB.standardizedFileURL.resolvingSymlinksInPath()
        #expect(secondVaultSession.vaultID == vaultIDB)
        #expect(secondVaultSession.root == normalizedB)
        #expect(secondVaultSession.generation == 3)
        #expect(await iterator.next() == .opening(root: normalizedB, generation: 3))
        #expect(await iterator.next() == .open(secondVaultSession))
    }

    @Test func rejectedTransitionsPreserveStateAndEmitTypedErrors() async throws {
        let manager = VaultSessionManager()

        await #expect(throws: VaultSessionError.invalidTransition(from: .closed, action: "lock")) {
            try await manager.lock()
        }
        await #expect(throws: VaultSessionError.invalidTransition(from: .closed, action: "unlock")) {
            _ = try await manager.unlock { _ in self.vaultIDA }
        }
        #expect(await manager.state == .closed)

        let session = try await manager.open(root: rootA) { _ in self.vaultIDA }
        await #expect(throws: VaultSessionError.invalidTransition(from: .open, action: "unlock")) {
            _ = try await manager.unlock { _ in self.vaultIDA }
        }
        await #expect(throws: VaultSessionError.invalidTransition(from: .open, action: "open")) {
            _ = try await manager.open(root: self.rootB) { _ in self.vaultIDB }
        }
        #expect(await manager.state == .open(session))

        try await manager.lock()
        await #expect(throws: VaultSessionError.invalidTransition(from: .locked, action: "open")) {
            _ = try await manager.open(root: self.rootA) { _ in self.vaultIDA }
        }
        await #expect(throws: VaultSessionError.invalidTransition(from: .locked, action: "open")) {
            _ = try await manager.open(root: self.rootB) { _ in self.vaultIDB }
        }

        try await manager.close()
        #expect(await manager.state == .closed)
    }

    @Test func duplicateRequestsCoalesceAndRemainIdempotent() async throws {
        let manager = VaultSessionManager()
        let openGate = Gate()
        let openCalls = CallCounter()

        async let firstOpen = manager.open(root: rootA) { _ in
            _ = await openCalls.increment()
            await openGate.arriveAndWait()
            return self.vaultIDA
        }
        await openGate.waitUntilArrived(1)

        async let duplicateOpenInFlight = manager.open(root: rootA) { _ in
            _ = await openCalls.increment()
            return self.vaultIDA
        }

        await openGate.release()
        let (session1, session2) = try await (firstOpen, duplicateOpenInFlight)
        #expect(session1 == session2)
        #expect(await openCalls.count == 1)
        #expect(await manager.generation == 1)

        let repeatOpenWhenAlreadyOpen = try await manager.open(root: rootA) { _ in
            _ = await openCalls.increment()
            return self.vaultIDA
        }
        #expect(repeatOpenWhenAlreadyOpen == session1)
        #expect(await openCalls.count == 1)
        #expect(await manager.generation == 1)

        let lockGate = Gate()
        let lockCalls = CallCounter()
        async let firstLock: Void = manager.lock { _ in
            _ = await lockCalls.increment()
            await lockGate.arriveAndWait()
        }
        await lockGate.waitUntilArrived(1)
        async let duplicateLock: Void = manager.lock { _ in
            _ = await lockCalls.increment()
        }
        await lockGate.release()
        _ = try await (firstLock, duplicateLock)
        #expect(await lockCalls.count == 1)

        try await manager.lock { _ in
            _ = await lockCalls.increment()
        }
        #expect(await lockCalls.count == 1)

        let unlockGate = Gate()
        let unlockCalls = CallCounter()
        async let firstUnlock = manager.unlock { _ in
            _ = await unlockCalls.increment()
            await unlockGate.arriveAndWait()
            return self.vaultIDA
        }
        await unlockGate.waitUntilArrived(1)
        async let duplicateUnlock = manager.unlock { _ in
            _ = await unlockCalls.increment()
            return self.vaultIDA
        }
        await unlockGate.release()
        let (unlocked1, unlocked2) = try await (firstUnlock, duplicateUnlock)
        #expect(unlocked1 == unlocked2)
        #expect(await unlockCalls.count == 1)
        #expect(await manager.generation == 2)
    }

    @Test func concurrentConflictingTransitionRequestsDoNotInterleave() async throws {
        let manager = VaultSessionManager()
        let openGate = Gate()

        let openTask = Task {
            try await manager.open(root: rootA) { _ in
                await openGate.arriveAndWait()
                return self.vaultIDA
            }
        }
        await openGate.waitUntilArrived(1)
        #expect(await manager.state.phase == .opening)

        await #expect(throws: VaultSessionError.transitionInProgress(current: .opening, requested: "open")) {
            _ = try await manager.open(root: self.rootB) { _ in self.vaultIDB }
        }
        await #expect(throws: VaultSessionError.transitionInProgress(current: .opening, requested: "lock")) {
            try await manager.lock()
        }
        await #expect(throws: VaultSessionError.transitionInProgress(current: .opening, requested: "unlock")) {
            _ = try await manager.unlock { _ in self.vaultIDA }
        }
        await #expect(throws: VaultSessionError.transitionInProgress(current: .opening, requested: "close")) {
            try await manager.close()
        }

        await openGate.release()
        let opened = try await openTask.value
        #expect(await manager.state == .open(opened))

        let lockGate = Gate()
        let lockTask = Task {
            try await manager.lock { _ in
                await lockGate.arriveAndWait()
            }
        }
        await lockGate.waitUntilArrived(1)
        #expect(await manager.state.phase == .locking)

        await #expect(throws: VaultSessionError.transitionInProgress(current: .locking, requested: "open")) {
            _ = try await manager.open(root: self.rootB) { _ in self.vaultIDB }
        }
        await #expect(throws: VaultSessionError.transitionInProgress(current: .locking, requested: "unlock")) {
            _ = try await manager.unlock { _ in self.vaultIDA }
        }
        await #expect(throws: VaultSessionError.transitionInProgress(current: .locking, requested: "close")) {
            try await manager.close()
        }

        await lockGate.release()
        try await lockTask.value
        #expect(await manager.state.phase == .locked)
    }

    @Test func cancellationRollsBackOpeningLockingAndUnlockingCleanly() async throws {
        let manager = VaultSessionManager()
        let openGate = Gate()

        let openingTask = Task {
            try await manager.open(root: rootA) { _ in
                await openGate.arriveAndWait()
                try Task.checkCancellation()
                return self.vaultIDA
            }
        }
        await openGate.waitUntilArrived(1)
        #expect(await manager.state.phase == .opening)

        openingTask.cancel()
        await openGate.release()

        await #expect(throws: VaultSessionError.cancelled(action: "open")) {
            _ = try await openingTask.value
        }
        #expect(await manager.state == .closed)
        #expect(await manager.generation == 0)

        let session = try await manager.open(root: rootA) { _ in self.vaultIDA }
        #expect(session.generation == 1)

        let lockGate = Gate()
        let lockingTask = Task {
            try await manager.lock { _ in
                await lockGate.arriveAndWait()
                try Task.checkCancellation()
            }
        }
        await lockGate.waitUntilArrived(1)
        #expect(await manager.state == .locking(session))

        await manager.cancelActiveTransition()
        await lockGate.release()

        await #expect(throws: VaultSessionError.cancelled(action: "lock")) {
            try await lockingTask.value
        }
        #expect(await manager.state == .open(session))
        #expect(await manager.generation == 1)

        try await manager.lock()
        #expect(await manager.state.phase == .locked)

        let unlockGate = Gate()
        let unlockingTask = Task {
            try await manager.unlock { _ in
                await unlockGate.arriveAndWait()
                try Task.checkCancellation()
                return self.vaultIDA
            }
        }
        await unlockGate.waitUntilArrived(1)
        #expect(await manager.state.phase == .unlocking)

        unlockingTask.cancel()
        await unlockGate.release()

        await #expect(throws: VaultSessionError.cancelled(action: "unlock")) {
            _ = try await unlockingTask.value
        }
        let normalizedA = rootA.standardizedFileURL.resolvingSymlinksInPath()
        #expect(await manager.state == .locked(vaultID: vaultIDA, root: normalizedA, vaultName: normalizedA.lastPathComponent, generation: 1))
        #expect(await manager.generation == 1)
    }

    @Test func failedOpeningUnlockingLockingAndClosingRecoverDeterministically() async throws {
        let manager = VaultSessionManager()
        let normalizedA = rootA.standardizedFileURL.resolvingSymlinksInPath()

        await #expect(throws: VaultSessionError.openFailed(root: normalizedA, message: "Missing vault.json")) {
            _ = try await manager.open(root: self.rootA) { _ in
                throw VaultError.invalid("Missing vault.json")
            }
        }
        #expect(await manager.state == .closed)
        #expect(await manager.generation == 0)

        let session = try await manager.open(root: rootA) { _ in self.vaultIDA }
        #expect(session.generation == 1)

        await #expect(throws: VaultSessionError.lockAborted(root: normalizedA, message: "Save failed before lock")) {
            try await manager.lock { _ in
                throw VaultError.storage("Save failed before lock")
            }
        }
        #expect(await manager.state == .open(session))
        #expect(await manager.generation == 1)

        await #expect(throws: VaultSessionError.closeAborted(root: normalizedA, message: "Save failed before close")) {
            try await manager.close { _ in
                throw VaultError.storage("Save failed before close")
            }
        }
        #expect(await manager.state == .open(session))

        try await manager.lock()
        #expect(await manager.state.phase == .locked)

        await #expect(throws: VaultSessionError.unlockFailed(root: normalizedA, message: "Vault unavailable")) {
            _ = try await manager.unlock { _ in
                throw VaultError.unavailable("Vault unavailable")
            }
        }
        #expect(await manager.state == .locked(vaultID: vaultIDA, root: normalizedA, vaultName: normalizedA.lastPathComponent, generation: 1))
        #expect(await manager.generation == 1)

        await #expect(throws: VaultSessionError.identityMismatch(expected: vaultIDA, actual: vaultIDB)) {
            _ = try await manager.unlock { _ in self.vaultIDB }
        }
        #expect(await manager.state == .locked(vaultID: vaultIDA, root: normalizedA, vaultName: normalizedA.lastPathComponent, generation: 1))

        let recovered = try await manager.unlock { _ in self.vaultIDA }
        #expect(recovered.generation == 2)
        #expect(await manager.state == .open(recovered))
    }
}
