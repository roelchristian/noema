import Foundation
import Security
import Synchronization
import Testing
@testable import ExternalAI

private final class InteractionPolicy: ExternalAIKeychainInteraction, Sendable {
    private struct State {
        var allowed: Bool
        var setStatuses: [OSStatus]
        var changes: [Bool] = []
    }
    private let state: Mutex<State>
    private let getStatus: OSStatus

    init(allowed: Bool = true, getStatus: OSStatus = errSecSuccess, setStatuses: [OSStatus] = []) {
        state = Mutex(State(allowed: allowed, setStatuses: setStatuses))
        self.getStatus = getStatus
    }
    var allowed: Bool { state.withLock { $0.allowed } }
    var changes: [Bool] { state.withLock { $0.changes } }
    func getAllowed() -> (OSStatus, Bool) { (getStatus, allowed) }
    func setAllowed(_ allowed: Bool) -> OSStatus {
        state.withLock {
            $0.changes.append(allowed)
            let status = $0.setStatuses.isEmpty ? errSecSuccess : $0.setStatuses.removeFirst()
            if status == errSecSuccess { $0.allowed = allowed }
            return status
        }
    }
}

@Test(arguments: [true, false])
func keychainInteractionRestoresPriorPolicyAfterSuccessAndFailure(wasAllowed: Bool) throws {
    let policy = InteractionPolicy(allowed: wasAllowed)
    let guardScope = ExternalAIKeychainInteractionGuard(interaction: policy)
    let value = try guardScope.perform {
        #expect(!policy.allowed)
        return "synthetic-result"
    }
    #expect(value == "synthetic-result")
    #expect(policy.allowed == wasAllowed)
    #expect(throws: ExternalAIError.credentialUnavailable) {
        try guardScope.perform {
            #expect(!policy.allowed)
            throw ExternalAIError.credentialUnavailable
        }
    }
    #expect(policy.allowed == wasAllowed)
    #expect(policy.changes == [false, wasAllowed, false, wasAllowed])
}

@Test func keychainInteractionSetupFailuresNeverExecuteCredentialOperations() {
    for policy in [InteractionPolicy(getStatus: errSecAuthFailed),
                   InteractionPolicy(setStatuses: [errSecAuthFailed])] {
        let ran = Mutex(false)
        let guardScope = ExternalAIKeychainInteractionGuard(interaction: policy)
        #expect(throws: ExternalAIError.credentialUnavailable) {
            try guardScope.perform { ran.withLock { $0 = true } }
        }
        #expect(!ran.withLock { $0 })
    }
}

@Test func keychainInteractionRestoreFailureDoesNotReturnCredentialBytes() {
    let policy = InteractionPolicy(setStatuses: [errSecSuccess, errSecAuthFailed])
    let guardScope = ExternalAIKeychainInteractionGuard(interaction: policy)
    #expect(throws: ExternalAIError.credentialUnavailable) {
        try guardScope.perform { Data("synthetic-credential".utf8) }
    }
    #expect(policy.changes == [false, true])
    #expect(!policy.allowed) // A failed restoration cannot broaden access.
}

@Test func keychainInteractionScopesSerializeAcrossIndependentAdapters() {
    let policy = InteractionPolicy()
    let overlap = Mutex((active: 0, maximum: 0, failures: 0))
    DispatchQueue.concurrentPerform(iterations: 24) { _ in
        let guardScope = ExternalAIKeychainInteractionGuard(interaction: policy)
        do {
            try guardScope.perform {
                overlap.withLock { $0.active += 1; $0.maximum = max($0.maximum, $0.active) }
                if policy.allowed { overlap.withLock { $0.failures += 1 } }
                Thread.sleep(forTimeInterval: 0.002)
                if policy.allowed { overlap.withLock { $0.failures += 1 } }
                overlap.withLock { $0.active -= 1 }
            }
        } catch { overlap.withLock { $0.failures += 1 } }
    }
    #expect(overlap.withLock { $0.maximum } == 1)
    #expect(overlap.withLock { $0.failures } == 0)
    #expect(policy.allowed)
}
