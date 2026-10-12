import Foundation
import NativeAuthentication
import Synchronization
import Testing
@testable import VaultCore

@Suite(.timeLimit(.minutes(1)))
struct VaultAuthenticationAdmissionTests {
    @Test
    func protectedOpenStaysClosedWithoutLeaseOrContentIOUntilAdmission() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let calls = AdmissionIORecorder()
        let provider = VaultStorageProvider { root in
            AdmissionRecordingStore(base: try PlaintextVaultContentStore(root: root), calls: calls)
        }
        let task = Task { try await f.manager.openRepository(root: f.root, storageProvider: provider) }
        await f.auth.waitForCalls(1)
        #expect(await f.manager.state == .closed)
        #expect(f.manager.currentLease == nil)
        #expect(f.manager.isAuthenticationPending)
        #expect(!calls.values.isEmpty)
        #expect(calls.values.allSatisfy { $0 == "read:vault.json" })
        #expect(await f.auth.purposes == [.openVault])
        await f.auth.resolve(0)
        let opened = try await task.value
        #expect(opened.session.vaultID == f.vaultID)
        #expect(opened.lease == f.manager.currentLease)
        #expect(!f.manager.isAuthenticationPending)
        try await f.manager.close()
    }

    @Test
    func protectedReopenRelaunchAndUnlockEachRequireFreshPurpose() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let first = Task { try await f.manager.open(root: f.root) }
        await f.auth.waitForCalls(1); await f.auth.resolve(0)
        let original = try await first.value
        try await f.manager.lock()
        let unlock = Task { try await f.manager.unlockRepository() }
        await f.auth.waitForCalls(2)
        #expect(await f.manager.state.phase == .locked)
        #expect(f.manager.currentLease == nil)
        await f.auth.resolve(1)
        let unlocked = try await unlock.value
        #expect(unlocked.session.id != original.id)
        #expect(unlocked.session.generation > original.generation)
        try await f.manager.close()
        let reopen = Task { try await f.manager.open(root: f.root) }
        await f.auth.waitForCalls(3); await f.auth.resolve(2)
        _ = try await reopen.value
        try await f.manager.close()
        // A fresh store/manager uses the persisted preference rather than an in-memory grant.
        let relaunched = VaultSessionManager(authenticator: f.auth,
            accessPolicy: VaultAccessPolicyStore(defaults: UserDefaults(suiteName: f.suite)!))
        let relaunch = Task { try await relaunched.openRepository(root: f.root) }
        await f.auth.waitForCalls(4)
        #expect(await relaunched.state == .closed)
        await f.auth.resolve(3)
        _ = try await relaunch.value
        #expect(await f.auth.purposes == [.openVault, .unlockVault, .openVault, .openVault])
        try await relaunched.close()
    }

    @Test
    func unprotectedProductionEntryPointsRemainPromptFree() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let initial = try await f.manager.open(root: f.root)
        let repository = try await f.manager.openRepository(root: f.root, create: true)
        #expect(repository.session == initial)
        try await f.manager.lock()
        _ = try await f.manager.unlock()
        try await f.manager.lock()
        _ = try await f.manager.unlockRepository()
        try await f.manager.close()
        _ = try await f.manager.openRepository(root: f.root)
        #expect(await f.auth.purposes.isEmpty)
        #expect(!f.manager.accessAuthenticationRequired(for: f.vaultID))
        try await f.manager.close()
    }

    @Test
    func duplicatePendingOpenCannotIssueSecondPromptAndCreateFlagCannotBypass() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let first = Task { try await f.manager.openRepository(root: f.root, create: true) }
        await f.auth.waitForCalls(1)
        await #expect(throws: VaultSessionError.transitionInProgress(current: .closed, requested: "open")) {
            _ = try await f.manager.openRepository(root: f.root)
        }
        #expect(await f.auth.purposes == [.openVault])
        #expect(await f.manager.state == .closed)
        await f.auth.resolve(0)
        _ = try await first.value
        try await f.manager.close()
    }

    @Test
    func closeCancelsPendingOpenBeforeLateSuccessAndRetryIsIndependent() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let original = Task { try await f.manager.openRepository(root: f.root) }
        await f.auth.waitForCalls(1)
        try await f.manager.close()
        await #expect(throws: VaultSessionError.cancelled(action: "open")) { _ = try await original.value }
        #expect(await f.manager.state == .closed)
        #expect(!f.manager.isAuthenticationPending)
        let retry = Task { try await f.manager.openRepository(root: f.root) }
        await f.auth.waitForCalls(2)
        // The first native adapter ignores task cancellation and completes during retry.
        await f.auth.resolve(0)
        #expect(await f.manager.state == .closed)
        #expect(f.manager.currentLease == nil)
        await f.auth.resolve(1)
        _ = try await retry.value
        #expect(await f.auth.purposes == [.openVault, .openVault])
        try await f.manager.close()
    }

    @Test
    func callerCancellationResolvesWithoutNativeCallbackAndLeavesLockedRetryable() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        _ = try await f.manager.openRepository(root: f.root)
        f.policy.setRequired(true, for: f.vaultID)
        try await f.manager.lock()
        let locked = await f.manager.state
        let task = Task { try await f.manager.unlock() }
        await f.auth.waitForCalls(1)
        task.cancel()
        await #expect(throws: VaultSessionError.cancelled(action: "unlock")) { _ = try await task.value }
        #expect(await f.manager.state == locked)
        #expect(f.manager.currentLease == nil)
        #expect(!f.manager.isAuthenticationPending)
        let retry = Task { try await f.manager.unlockRepository() }
        await f.auth.waitForCalls(2)
        await f.auth.resolve(0)
        #expect(await f.manager.state == locked)
        await f.auth.resolve(1)
        _ = try await retry.value
        try await f.manager.close()
    }

    @Test
    func sameUUIDAtDifferentRootCannotConsumePriorRootsAttempt() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let other = f.base.appendingPathComponent("Copy")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try FileVaultRepository.open(root: other, create: true)
        try JSONEncoder().encode(VaultManifest(id: f.vaultID)).write(to: other.appendingPathComponent("vault.json"))
        f.policy.setRequired(true, for: f.vaultID)
        let first = Task { try await f.manager.open(root: f.root) }
        await f.auth.waitForCalls(1)
        let second = Task { try await f.manager.open(root: other) }
        await f.auth.waitForCalls(2)
        await #expect(throws: VaultSessionError.cancelled(action: "open")) { _ = try await first.value }
        await f.auth.resolve(0)
        #expect(await f.manager.state == .closed)
        await f.auth.resolve(1)
        let opened = try await second.value
        #expect(opened.root == other.standardizedFileURL.resolvingSymlinksInPath())
        #expect(opened.vaultID == f.vaultID)
        try await f.manager.close()
    }

    @Test
    func manifestIdentityMutationDuringAuthenticationRejectsAdmission() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let task = Task { try await f.manager.openRepository(root: f.root) }
        await f.auth.waitForCalls(1)
        let replacement = UUID()
        try JSONEncoder().encode(VaultManifest(id: replacement)).write(to: f.root.appendingPathComponent("vault.json"))
        await f.auth.resolve(0)
        await #expect(throws: VaultSessionError.identityMismatch(expected: f.vaultID, actual: replacement)) {
            _ = try await task.value
        }
        #expect(await f.manager.state == .closed)
        #expect(f.manager.currentLease == nil)
    }

    @Test
    func lockedRootOverrideRejectsCopiedUUIDBeforeAnyNativePrompt() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        _ = try await f.manager.open(root: f.root)
        f.policy.setRequired(true, for: f.vaultID)
        try await f.manager.lock()
        let locked = await f.manager.state
        let other = f.base.appendingPathComponent("Copied Locked Vault")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try FileVaultRepository.open(root: other, create: true)
        try JSONEncoder().encode(VaultManifest(id: f.vaultID)).write(to: other.appendingPathComponent("vault.json"))
        await #expect(throws: VaultSessionError.cancelled(action: "unlock")) {
            _ = try await f.manager.unlockRepository(root: other)
        }
        #expect(await f.manager.state == locked)
        #expect(f.manager.currentLease == nil)
        #expect(await f.auth.purposes.isEmpty)
        #expect(!f.manager.isAuthenticationPending)
        try await f.manager.close()
    }

    @Test
    func sameValuePolicyRevisionChangeRejectsPendingAttempt() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let task = Task { try await f.manager.openRepository(root: f.root) }
        await f.auth.waitForCalls(1)
        f.policy.setRequired(true, for: f.vaultID)
        await f.auth.resolve(0)
        await #expect(throws: VaultSessionError.cancelled(action: "open")) { _ = try await task.value }
        #expect(await f.manager.state == .closed)
        #expect(f.manager.accessAuthenticationRequired(for: f.vaultID))
    }

    @Test
    func preferenceChangesAuthenticateBothDirectionsAndBindExactOpenSession() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let session = try await f.manager.open(root: f.root)
        let enable = Task { try await f.manager.setAccessAuthenticationRequired(true, expectedSession: session) }
        await f.auth.waitForCalls(1)
        #expect(!f.manager.accessAuthenticationRequired(for: f.vaultID))
        await f.auth.resolve(0); try await enable.value
        #expect(f.manager.accessAuthenticationRequired(for: f.vaultID))
        let disable = Task { try await f.manager.setAccessAuthenticationRequired(false, expectedSession: session) }
        await f.auth.waitForCalls(2)
        #expect(f.manager.accessAuthenticationRequired(for: f.vaultID))
        await f.auth.resolve(1); try await disable.value
        #expect(!f.manager.accessAuthenticationRequired(for: f.vaultID))
        #expect(await f.auth.purposes == [.changeVaultAccessPolicy, .changeVaultAccessPolicy])
        try await f.manager.lock()
        _ = try await f.manager.unlock()
        await #expect(throws: VaultSessionError.cancelled(action: "changeVaultAccessPolicy")) {
            try await f.manager.setAccessAuthenticationRequired(true, expectedSession: session)
        }
        #expect(await f.auth.purposes.count == 2)
        try await f.manager.close()
    }

    @Test
    func lifecycleGenerationChangeCannotCommitPendingPolicyWrite() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let original = try await f.manager.open(root: f.root)
        let change = Task { try await f.manager.setAccessAuthenticationRequired(true, expectedSession: original) }
        await f.auth.waitForCalls(1)
        try await f.manager.close()
        let replacement = try await f.manager.open(root: f.root)
        #expect(replacement.generation > original.generation)
        await f.auth.resolve(0)
        await #expect(throws: VaultSessionError.cancelled(action: "changeVaultAccessPolicy")) { try await change.value }
        #expect(!f.manager.accessAuthenticationRequired(for: f.vaultID))
        #expect(await f.manager.state == .open(replacement))
        try await f.manager.close()
    }

    @Test
    func staleScopedCloseAndLockCannotCancelCurrentSessionsPolicyAttempt() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let stale = try await f.manager.open(root: f.root)
        try await f.manager.lock()
        let current = try await f.manager.unlock()
        let change = Task { try await f.manager.setAccessAuthenticationRequired(true, expectedSession: current) }
        await f.auth.waitForCalls(1)
        do { try await f.manager.close(expectedSession: stale); Issue.record("Stale close succeeded") } catch {}
        #expect(f.manager.isAuthenticationPending)
        do { try await f.manager.lock(expectedSession: stale); Issue.record("Stale lock succeeded") } catch {}
        #expect(f.manager.isAuthenticationPending)
        #expect(await f.manager.state == .open(current))
        await f.auth.resolve(0)
        try await change.value
        #expect(f.manager.accessAuthenticationRequired(for: f.vaultID))
        #expect(await f.auth.purposes == [.changeVaultAccessPolicy])
        try await f.manager.close()
    }

    @Test(arguments: [false, true])
    func policyRevisionChangeAfterLoaderRejectsFinalOpenOrUnlockCommit(unlocking: Bool) async throws {
        let latch = AdmissionLatch(armed: false)
        let f = try AdmissionFixture(beforeAccessCommit: { _ in await latch.hold() })
        defer { f.finish() }
        if unlocking {
            _ = try await f.manager.open(root: f.root)
            try await f.manager.lock()
        }
        let fallback = await f.manager.state
        f.policy.setRequired(true, for: f.vaultID)
        await latch.arm()
        let operation = Task {
            if unlocking { return try await f.manager.unlock() }
            return try await f.manager.open(root: f.root)
        }
        await f.auth.waitForCalls(1)
        await f.auth.resolve(0)
        await latch.waitForEntry()
        #expect(await f.manager.state.phase == (unlocking ? .unlocking : .opening))
        #expect(f.manager.currentLease == nil)
        // Even the same preference value has a fresh revision from another settings writer.
        f.policy.setRequired(true, for: f.vaultID)
        await latch.release()
        do { _ = try await operation.value; Issue.record("Stale preference snapshot published an open session") }
        catch { #expect(error as? VaultSessionError == .cancelled(action: unlocking ? "unlock" : "open")) }
        #expect(await f.manager.state == fallback)
        #expect(f.manager.currentLease == nil)
        #expect(!f.manager.isAuthenticationPending)
    }

    @Test
    func optInCreationPersistsBeforeAdmissionAndCancelPreservesPublishedVault() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let root = try await f.manager.createVault(parent: f.base, name: "Protected New",
            encryptionRequested: false, accessAuthenticationRequested: true)
        let manifest = try FileVaultRepository.inspectManifest(at: root)
        #expect(manifest.formatVersion == 1)
        #expect(f.manager.accessAuthenticationRequired(for: manifest.id))
        #expect(await f.auth.purposes.isEmpty)
        let before = try Data(contentsOf: root.appendingPathComponent("vault.json"))
        let open = Task { try await f.manager.openRepository(root: root) }
        await f.auth.waitForCalls(1)
        await f.manager.cancelActiveTransition()
        await #expect(throws: VaultSessionError.cancelled(action: "open")) { _ = try await open.value }
        await f.auth.resolve(0)
        #expect(try Data(contentsOf: root.appendingPathComponent("vault.json")) == before)
        #expect(f.manager.accessAuthenticationRequired(for: manifest.id))
        #expect(await f.manager.state == .closed)
    }

    @Test(arguments: [NativeAuthenticationError.cancelled, .failed, .unavailable])
    func nativeFailureNeverOpensOrIssuesLease(_ failure: NativeAuthenticationError) async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let task = Task { try await f.manager.open(root: f.root) }
        await f.auth.waitForCalls(1)
        await f.auth.resolve(0, failure: failure)
        do { _ = try await task.value; Issue.record("Failed authentication admitted content") }
        catch {
            if failure == .cancelled { #expect(error as? VaultSessionError == .cancelled(action: "open")) }
            else { #expect(error as? NativeAuthenticationError == failure) }
        }
        #expect(await f.manager.state == .closed)
        #expect(f.manager.currentLease == nil)
        #expect(!f.manager.isAuthenticationPending)
    }

    @Test(arguments: [false, true])
    func compatibilityCreateCannotInitializeDifferentRootWhileOpenOrLocked(locked: Bool) async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        _ = try await f.manager.open(root: f.root)
        if locked { try await f.manager.lock() }
        let fresh = f.base.appendingPathComponent("Fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        do {
            _ = try await f.manager.openRepository(root: fresh, create: true)
            Issue.record("Invalid lifecycle initialized a new vault")
        } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
        #expect(await f.auth.purposes.isEmpty)
        try await f.manager.close()
    }

    @Test
    func compatibilityCreateCancellationCannotInitializeFreshRoot() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        let fresh = f.base.appendingPathComponent("Fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.manager.openRepository(root: fresh, create: true)
        }
        do { _ = try await task.value; Issue.record("Cancelled create initialized a new vault") } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
        #expect(await f.manager.state == .closed)
        #expect(await f.auth.purposes.isEmpty)
    }

    @Test
    func compatibilityCreateCannotInitializeFreshRootDuringCloseTeardown() async throws {
        let f = try AdmissionFixture()
        defer { f.finish() }
        _ = try await f.manager.open(root: f.root)
        let latch = AdmissionLatch()
        let close = Task { try await f.manager.close { _ in await latch.hold() } }
        await latch.waitForEntry()
        let fresh = f.base.appendingPathComponent("Fresh")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        do {
            _ = try await f.manager.openRepository(root: fresh, create: true)
            Issue.record("Closing lifecycle initialized a new vault")
        } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.path).isEmpty)
        await latch.release()
        try await close.value
        #expect(await f.manager.state == .closed)
    }
}

private struct AdmissionFixture: Sendable {
    let base: URL
    let root: URL
    let vaultID: UUID
    let suite: String
    let policy: VaultAccessPolicyStore
    let auth: AdmissionAuthenticator
    let manager: VaultSessionManager

    init(beforeAccessCommit: (@Sendable (VaultSession) async -> Void)? = nil) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        base = repositoryRoot.appendingPathComponent(".local/agent-runs/d03b-admission-fixture-\(UUID())")
        root = base.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent(".active"))
        vaultID = try FileVaultRepository.open(root: root, create: true).manifest.id
        suite = "noema.d03b.admission.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        policy = VaultAccessPolicyStore(defaults: defaults)
        auth = AdmissionAuthenticator()
        manager = VaultSessionManager(authenticator: auth, accessPolicy: policy, beforeAccessCommit: beforeAccessCommit)
    }

    func finish() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? Data().write(to: base.appendingPathComponent(".complete"))
        try? FileManager.default.removeItem(at: base.appendingPathComponent(".active"))
    }
}

/// Deliberately ignores cancellation so stale successful device replies are reproducible.
private actor AdmissionAuthenticator: NativeAuthenticating {
    private(set) var purposes: [NativeAuthenticationPurpose] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func authenticate(for purpose: NativeAuthenticationPurpose) async throws {
        let index = purposes.count
        purposes.append(purpose)
        try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { purposes.count >= $0.0 }
            observers.removeAll { purposes.count >= $0.0 }
            for observer in ready { observer.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if purposes.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func resolve(_ index: Int, failure: NativeAuthenticationError? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
    }
}

private actor AdmissionLatch {
    private var armed: Bool
    private var entered = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    init(armed: Bool = true) { self.armed = armed }
    func arm() { armed = true }
    func hold() async {
        guard armed else { return }
        entered = true
        for waiter in arrival { waiter.resume() }
        arrival.removeAll()
        await withCheckedContinuation { held = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { arrival.append($0) }
    }
    func release() { held?.resume(); held = nil }
}

private final class AdmissionIORecorder: Sendable {
    private let calls = Mutex([String]())
    var values: [String] { calls.withLock { $0 } }
    func record(_ operation: String) { calls.withLock { $0.append(operation) } }
}

private final class AdmissionRecordingStore: VaultContentStore, Sendable {
    let base: any VaultContentStore
    let calls: AdmissionIORecorder
    init(base: any VaultContentStore, calls: AdmissionIORecorder) { self.base = base; self.calls = calls }
    func read(at path: String) throws -> Data { calls.record("read:\(path)"); return try base.read(at: path) }
    func snapshot(at path: String) throws -> VaultContentSnapshot { calls.record("snapshot:\(path)"); return try base.snapshot(at: path) }
    func changeToken(at path: String) throws -> VaultContentChangeToken? { try base.changeToken(at: path) }
    func createDirectory(at path: String) throws { calls.record("mkdir:\(path)"); try base.createDirectory(at: path) }
    func write(_ data: Data, at path: String, condition: VaultWriteCondition) throws { calls.record("write:\(path)"); try base.write(data, at: path, condition: condition) }
    func move(from source: String, to destination: String, expected: VaultContentSnapshot) throws { calls.record("move:\(source)"); try base.move(from: source, to: destination, expected: expected) }
    func delete(at path: String, expected: VaultContentSnapshot) throws { calls.record("delete:\(path)"); try base.delete(at: path, expected: expected) }
}
