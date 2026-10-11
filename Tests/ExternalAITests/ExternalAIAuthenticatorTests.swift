import Foundation
import NativeAuthentication
import Synchronization
import Testing
@testable import ExternalAI

@Suite
struct ExternalAIAuthenticatorTests {
    @Test
    func successRequestsOnlyExternalAISummaryPurpose() async throws {
        let native = NativeAuthenticationSpy()
        try await LocalExternalAIAuthenticator(native: native).authenticate()
        #expect(native.purposes == [.externalAISummary])
    }

    @Test(arguments: [NativeAuthenticationError.cancelled, .unavailable, .failed])
    func mapsNativeFailuresToExistingExternalAIContract(_ failure: NativeAuthenticationError) async {
        let native = NativeAuthenticationSpy(failure: failure)
        do { try await LocalExternalAIAuthenticator(native: native).authenticate(); Issue.record("Failure authenticated") }
        catch {
            #expect(error as? ExternalAIError == (failure == .cancelled ? .authenticationCancelled : .authenticationFailed))
        }
    }

    @Test
    func sanitizesUnexpectedNativeFailure() async {
        let native = NativeAuthenticationSpy(failure: NSError(domain: "private", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "secret context"]))
        do { try await LocalExternalAIAuthenticator(native: native).authenticate(); Issue.record("Failure authenticated") }
        catch { #expect(error as? ExternalAIError == .authenticationFailed) }
    }

    @Test
    func mapsInjectedTaskCancellationToExistingError() async {
        let native = NativeAuthenticationSpy(failure: CancellationError())
        do { try await LocalExternalAIAuthenticator(native: native).authenticate(); Issue.record("Cancelled task authenticated") }
        catch { #expect(error as? ExternalAIError == .authenticationCancelled) }
    }

    @Test
    func mapsTaskCancellationAndDoesNotStartAuthentication() async {
        let native = NativeAuthenticationSpy()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await LocalExternalAIAuthenticator(native: native).authenticate()
        }
        do { try await task.value; Issue.record("Cancelled task authenticated") }
        catch { #expect(error as? ExternalAIError == .authenticationCancelled) }
        #expect(native.purposes.isEmpty)
    }

    @Test
    func cancellationBeforeSuccessReturnDoesNotAuthorize() async {
        let native = NativeAuthenticationSpy(cancelBeforeReturn: true)
        let task = Task { try await LocalExternalAIAuthenticator(native: native).authenticate() }
        do { try await task.value; Issue.record("Cancelled task authenticated") }
        catch { #expect(error as? ExternalAIError == .authenticationCancelled) }
    }
}

private final class NativeAuthenticationSpy: NativeAuthenticating, Sendable {
    private let recordedPurposes = Mutex([NativeAuthenticationPurpose]())
    private let failure: (any Error)?
    private let cancelBeforeReturn: Bool

    init(failure: (any Error)? = nil, cancelBeforeReturn: Bool = false) {
        self.failure = failure
        self.cancelBeforeReturn = cancelBeforeReturn
    }

    var purposes: [NativeAuthenticationPurpose] { recordedPurposes.withLock { $0 } }
    func authenticate(for purpose: NativeAuthenticationPurpose) async throws {
        recordedPurposes.withLock { $0.append(purpose) }
        if cancelBeforeReturn { withUnsafeCurrentTask { $0?.cancel() } }
        if let failure { throw failure }
    }
}
