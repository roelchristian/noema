import Foundation
import Testing
import VaultCore
@testable import ExternalAI

@Test func debugInspectionIsOptInBoundedRedactedAndSessionScoped() throws {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/debug-tests"), generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    let lease = try #require(gate.currentLease)
    let diagnostics = ExternalAIDebugDiagnostics()
    let body = Data("synthetic-private-output".utf8)
    diagnostics.record(body: body, status: 200, failure: .invalidResponse, action: .summarizePage, lease: lease)
    #expect(diagnostics.report == nil)
    diagnostics.enable(for: lease)
    let observation = gate.registerSessionInvalidator(lease: lease) { diagnostics.disable() }
    defer { gate.removeSessionInvalidator(observation) }
    diagnostics.record(body: body, status: 200, failure: .invalidResponse, action: .summarizePage, lease: lease)
    #expect(diagnostics.report?.contains("synthetic-private-output") == true)
    #expect(diagnostics.report?.contains("invalidResponse") == true)
    #expect(!String(reflecting: diagnostics).contains("synthetic-private-output"))
    diagnostics.clear()
    #expect(diagnostics.report == nil)
    diagnostics.record(body: Data(repeating: 65, count: ExternalAILimits.maximumResponseBytes + 1),
        status: 200, failure: .invalidResponse, action: .summarizePage, lease: lease)
    #expect(diagnostics.report?.contains("Response truncated at byte limit") == true)
    gate.updateState(.closed)
    diagnostics.record(body: body, status: 200, failure: .invalidResponse, action: .summarizePage, lease: lease)
    #expect(diagnostics.report == nil)
    #expect(!diagnostics.isEnabled)
}

@Test(arguments: ["locking", "close", "switch", "reopen"])
func rejectedResponseIsClearedSynchronouslyAndOldSessionCannotRecapture(transition: String) throws {
    let session = VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/debug-lifecycle"), generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    let lease = try #require(gate.currentLease)
    let diagnostics = ExternalAIDebugDiagnostics()
    diagnostics.enable(for: lease)
    let observation = gate.registerSessionInvalidator(lease: lease) { diagnostics.disable() }
    defer { gate.removeSessionInvalidator(observation) }
    let privateBody = Data("synthetic-rejected-private-output".utf8)
    diagnostics.record(body: privateBody, status: 200, failure: .invalidResponse, action: .summarizePage, lease: lease)
    #expect(diagnostics.report != nil)
    switch transition {
    case "locking": gate.updateState(.locking(session))
    case "close": gate.updateState(.closed)
    case "switch": gate.updateState(.open(VaultSession(vaultID: UUID(), root: URL(fileURLWithPath: "/tmp/debug-other"), generation: 2)))
    default: gate.updateState(.open(VaultSession(vaultID: session.vaultID, root: session.root, generation: 2)))
    }
    #expect(!diagnostics.isEnabled)
    #expect(diagnostics.report == nil)
    if let nextLease = gate.currentLease, transition != "locking" {
        diagnostics.enable(for: nextLease)
    }
    diagnostics.record(body: privateBody, status: 200, failure: .invalidResponse, action: .summarizePage, lease: lease)
    #expect(diagnostics.report == nil)
}
