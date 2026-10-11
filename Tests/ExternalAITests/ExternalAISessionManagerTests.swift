import Foundation
import Synchronization
import Testing
@testable import ExternalAI
@testable import VaultCore

@Suite
struct ExternalAISessionManagerTests {
    private struct Fixture {
        let vault: VaultSessionManager
        let session: VaultSession
        let broker: ExternalAICredentialBroker
        let authenticator: SessionTestAuthenticator
        let clock: SessionTestClock
        let manager: ExternalAISessionManager
        var authority: ExternalAIVaultAuthority { ExternalAIVaultAuthority(session: session) }
    }

    private func fixture(held: Bool = false,
                         policy: ExternalAISessionPolicy = .default) async throws -> Fixture {
        let vault = VaultSessionManager()
        let session = try await vault.open(root: URL(fileURLWithPath: "/tmp/noema-session-test-\(UUID())")) { _ in UUID() }
        let broker = ExternalAICredentialBroker(keychain: SessionTestKeychain())
        try await broker.store("synthetic-key-for-session-tests")
        let authenticator = SessionTestAuthenticator(held: held)
        let clock = SessionTestClock()
        let manager = ExternalAISessionManager(accessGate: vault.accessGate, credentialBroker: broker,
            authenticator: authenticator, policy: policy, now: { clock.now }, observeSystemEvents: false)
        return Fixture(vault: vault, session: session, broker: broker, authenticator: authenticator,
                       clock: clock, manager: manager)
    }

    @Test
    func testAuthorizationReusedWithoutAnotherPrompt() async throws {
        let f = try await fixture()
        let initial = await f.manager.state
        #expect(initial == .unauthorized)
        let capability = try await f.manager.authorize(f.authority)
        let reused = try await f.manager.authorize(f.authority)
        #expect(capability == reused)
        let count = await f.authenticator.count
        #expect(count == 1)
        let state = await f.manager.state
        #expect(state == .authorized)
    }

    @Test
    func testConcurrentPromptsCoalesce() async throws {
        let f = try await fixture(held: true)
        let first = Task { try await f.manager.authorize(f.authority) }
        await f.authenticator.waitUntilStarted()
        let second = Task { try await f.manager.authorize(f.authority) }
        // Both queued callers can join the same actor-owned authentication task.
        for _ in 0..<100 { await Task.yield() }
        let state = await f.manager.state
        #expect(state == .authorising)
        await f.authenticator.succeed()
        let one = try await first.value
        let two = try await second.value
        #expect(one == two)
        let count = await f.authenticator.count
        #expect(count == 1)
    }

    @Test
    func testLockRevokesAndCancelsSynchronouslyBeforeObservation() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        let cancelled = Mutex(false)
        _ = try f.manager.registerCancellation(for: capability) { cancelled.withLock { $0 = true } }
        // Direct gate transition demonstrates no asynchronous stream delivery is required.
        f.vault.accessGate.updateState(.locking(f.session))
        #expect(cancelled.withLock { $0 })
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .vaultUnavailable)
        }
        let state = await f.manager.state
        #expect(state == .revoked)
    }

    @Test
    func testSessionReplacementAtSamePathRejectsOldAuthority() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        let replacement = VaultSession(vaultID: f.session.vaultID, root: f.session.root,
                                       generation: f.session.generation + 1)
        f.vault.accessGate.updateState(.open(replacement))
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .vaultUnavailable)
        }
        do {
            _ = try await f.manager.authorize(f.authority)
            Issue.record("Stale authority must not authenticate")
        } catch { #expect(error as? ExternalAIError == .vaultUnavailable) }
        let count = await f.authenticator.count
        #expect(count == 1)
    }

    @Test
    func testIdleExpiryCancelsOutstandingRequestAndRequiresFreshPrompt() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        let cancelled = Mutex(false)
        _ = try f.manager.registerCancellation(for: capability) { cancelled.withLock { $0 = true } }
        f.clock.advance(30 * 60)
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .authorizationExpired)
        }
        #expect(cancelled.withLock { $0 })
        let expired = await f.manager.state
        #expect(expired == .expired)
        let refreshed = try await f.manager.authorize(f.authority)
        #expect(capability != refreshed)
        let count = await f.authenticator.count
        #expect(count == 2)
    }

    @Test
    func testValidationDoesNotRefreshIdleButAuthorizedOperationDoes() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        f.clock.advance(29 * 60)
        try await f.manager.validate(capability, activity: true)
        f.clock.advance(29 * 60)
        try await f.manager.validate(capability)
        f.clock.advance(60)
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .authorizationExpired)
        }
    }

    @Test
    func testFourHourMaximumExpiresDespiteActivity() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        for _ in 0..<8 {
            f.clock.advance(29 * 60)
            try f.manager.validateSynchronously(capability, activity: true)
        }
        f.clock.advance(8 * 60)
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .authorizationExpired)
        }
    }

    @Test
    func testCredentialReplacementAndRemovalImmediatelyCancel() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        let cancelled = Mutex(false)
        _ = try f.manager.registerCancellation(for: capability) { cancelled.withLock { $0 = true } }
        try await f.broker.replace("replacement-synthetic-session-key")
        #expect(cancelled.withLock { $0 })
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .authorizationRevoked)
        }
        let second = try await f.manager.authorize(f.authority)
        try await f.broker.remove()
        expectError(try f.manager.validateSynchronously(second)) {
            #expect($0 as? ExternalAIError == .authorizationRevoked)
        }
    }

    @Test
    func testCancellationFailsClosedEvenIfAuthenticatorLaterSucceeds() async throws {
        let f = try await fixture(held: true)
        let authorization = Task { try await f.manager.authorize(f.authority) }
        await f.authenticator.waitUntilStarted()
        authorization.cancel()
        // Injected authenticators may ignore cancellation; the registry still rejects completion.
        await f.authenticator.succeed()
        do { _ = try await authorization.value; Issue.record("Cancelled prompt issued authority") }
        catch { #expect(error as? ExternalAIError == .cancelled) }
        let state = await f.manager.state
        #expect(state == .revoked)
    }

    @Test
    func testLockDuringPromptFailsClosed() async throws {
        let f = try await fixture(held: true)
        let authorization = Task { try await f.manager.authorize(f.authority) }
        await f.authenticator.waitUntilStarted()
        f.vault.accessGate.updateState(.locking(f.session))
        await f.authenticator.succeed()
        do { _ = try await authorization.value; Issue.record("Revoked prompt issued authority") }
        catch { #expect([ExternalAIError.cancelled, .vaultUnavailable, .authorizationRevoked].contains(where: { $0 == error as? ExternalAIError })) }
        let state = await f.manager.state
        #expect(state == .revoked)
    }

    @Test
    func testAtomicDispatchRejectsLockedOrRevokedAuthorityWithoutCallingBody() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        let dispatched = Mutex(0)
        try f.vault.accessGate.withOpenSession(lease: f.session.lease, operation: "testCloudDispatch") {
            try f.manager.withValidatedAuthorization(capability) { dispatched.withLock { $0 += 1 } }
        }
        #expect(dispatched.withLock { $0 } == 1)
        try await f.broker.replace("replacement-synthetic-session-key")
        expectError(try f.vault.accessGate.withOpenSession(lease: f.session.lease, operation: "testCloudDispatch") {
            try f.manager.withValidatedAuthorization(capability) { dispatched.withLock { $0 += 1 } }
        })
        f.vault.accessGate.updateState(.locking(f.session))
        expectError(try f.vault.accessGate.withOpenSession(lease: f.session.lease, operation: "testCloudDispatch") {
            dispatched.withLock { $0 += 1 }
        })
        #expect(dispatched.withLock { $0 } == 1)
    }

    @Test
    func testAuthenticationFailureUsesBoundedErrorAndIssuesNoCapability() async throws {
        let f = try await fixture()
        let manager = ExternalAISessionManager(accessGate: f.vault.accessGate, credentialBroker: f.broker,
                                               authenticator: FailingSessionAuthenticator(), observeSystemEvents: false)
        do { _ = try await manager.authorize(f.authority); Issue.record("Failed authentication issued authority") }
        catch { #expect(error as? ExternalAIError == .authenticationFailed) }
        let state = await manager.state
        #expect(state == .revoked)
    }

    @Test
    func testCredentialReplacementDuringPromptRejectsLateSuccess() async throws {
        let f = try await fixture(held: true)
        let authorization = Task { try await f.manager.authorize(f.authority) }
        await f.authenticator.waitUntilStarted()
        try await f.broker.replace("replacement-synthetic-session-key")
        await f.authenticator.succeed()
        do { _ = try await authorization.value; Issue.record("Credential change issued stale authority") }
        catch { #expect([ExternalAIError.cancelled, .authorizationRevoked].contains(where: { $0 == error as? ExternalAIError })) }
        let state = await f.manager.state
        #expect(state == .revoked)
    }

    @Test
    func testUnregisteredCompletedRequestIsNotCancelled() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        let cancelled = Mutex(false)
        let id = try f.manager.registerCancellation(for: capability) { cancelled.withLock { $0 = true } }
        f.manager.unregisterCancellation(id)
        f.manager.revoke(reason: .deviceSleep)
        #expect(!(cancelled.withLock { $0 }))
    }

    @Test
    func testExplicitLifecycleRevocationAndClockRollbackFailClosed() async throws {
        let f = try await fixture()
        let capability = try await f.manager.authorize(f.authority)
        f.clock.advance(-1)
        expectError(try f.manager.validateSynchronously(capability)) {
            #expect($0 as? ExternalAIError == .authorizationExpired)
        }
        let second = try await f.manager.authorize(f.authority)
        f.manager.revoke(reason: .screenLocked)
        expectError(try f.manager.validateSynchronously(second)) {
            #expect($0 as? ExternalAIError == .authorizationRevoked)
        }
    }
}

private final class SessionTestClock: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    var now: Date { date.withLock { $0 } }
    func advance(_ interval: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(interval) } }
}

private final class SessionTestKeychain: ExternalAIKeychain, Sendable {
    private let data = Mutex<Data?>(nil)
    func read() throws -> Data? { data.withLock { $0 } }
    func write(_ value: Data) throws { data.withLock { $0 = value } }
    func delete() throws { data.withLock { $0 = nil } }
}

private actor SessionTestAuthenticator: ExternalAIAuthenticating {
    private let held: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    init(held: Bool) { self.held = held }
    func authenticate() async throws {
        count += 1
        if held {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                for waiter in startedWaiters { waiter.resume() }
                startedWaiters.removeAll()
            }
        }
    }
    func waitUntilStarted() async {
        if count > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func succeed() { continuation?.resume(); continuation = nil }
}

private struct FailingSessionAuthenticator: ExternalAIAuthenticating {
    func authenticate() async throws { throw NSError(domain: "untrusted-auth-error", code: 1) }
}

private func expectError(_ body: @autoclosure () throws -> Void, verify: (Error) -> Void = { _ in }) {
    do {
        try body()
        Issue.record("Expected operation to throw")
    } catch {
        verify(error)
    }
}
