import Foundation
import LocalAuthentication
import Synchronization
import Testing
@testable import NativeAuthentication

@Suite(.timeLimit(.minutes(1)))
struct NativeAuthenticationTests {
    @Test
    func successUsesOperationReasonAndInvalidatesContext() async throws {
        let context = ControlledAuthenticationContext()
        let authenticator = LocalNativeAuthenticator(makeContext: { context })
        let task = Task { try await authenticator.authenticate(for: .externalAIAuthorization) }
        await context.waitForEvaluation()
        #expect(context.reasons == ["Authorize AI actions on selected content with OpenAI"])
        context.reply(.success(()))
        try await task.value
        #expect(context.invalidations == 1)
    }

    @Test(arguments: [NativeAuthenticationError.cancelled, .unavailable, .failed])
    func nativeFailuresRemainTypedAndInvalidate(_ failure: NativeAuthenticationError) async {
        let context = ControlledAuthenticationContext()
        let authenticator = LocalNativeAuthenticator(makeContext: { context })
        let task = Task { try await authenticator.authenticate(for: .unlockVault) }
        await context.waitForEvaluation()
        context.reply(.failure(failure))
        do { try await task.value; Issue.record("Failure reported success") }
        catch { #expect(error as? NativeAuthenticationError == failure) }
        #expect(context.invalidations == 1)
    }

    @Test
    func unavailableNeverStartsPromptAndInvalidates() async {
        let context = ControlledAuthenticationContext(availability: .unavailable)
        let authenticator = LocalNativeAuthenticator(makeContext: { context })
        do { try await authenticator.authenticate(for: .openVault); Issue.record("Unavailable authentication succeeded") }
        catch { #expect(error as? NativeAuthenticationError == .unavailable) }
        #expect(context.reasons.isEmpty)
        #expect(context.invalidations == 1)
    }

    @Test
    func cancellationBeforeAttemptAllocatesNoContext() async {
        let contexts = Mutex(0)
        let authenticator = LocalNativeAuthenticator(makeContext: {
            contexts.withLock { $0 += 1 }
            return ControlledAuthenticationContext()
        })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await authenticator.authenticate(for: .openVault)
        }
        do { try await task.value; Issue.record("Cancelled task authenticated") }
        catch { #expect(error as? NativeAuthenticationError == .cancelled) }
        #expect(contexts.withLock { $0 } == 0)
    }

    @Test
    func cancellationAfterContextCreationPreventsPrompt() async {
        let context = ControlledAuthenticationContext()
        let authenticator = LocalNativeAuthenticator(makeContext: {
            withUnsafeCurrentTask { $0?.cancel() }
            return context
        })
        let task = Task { try await authenticator.authenticate(for: .openVault) }
        do { try await task.value; Issue.record("Cancelled task authenticated") }
        catch { #expect(error as? NativeAuthenticationError == .cancelled) }
        #expect(context.reasons.isEmpty)
        #expect(context.invalidations == 1)
    }

    @Test
    func cancellationDuringAvailabilityPreventsPrompt() async {
        let context = ControlledAuthenticationContext(cancelDuringAvailability: true)
        let authenticator = LocalNativeAuthenticator(makeContext: { context })
        let task = Task { try await authenticator.authenticate(for: .unlockVault) }
        do { try await task.value; Issue.record("Cancelled task authenticated") }
        catch { #expect(error as? NativeAuthenticationError == .cancelled) }
        #expect(context.reasons.isEmpty)
        #expect(context.invalidations == 1)
    }

    @Test
    func cancellationResolvesWithoutNativeCallbackAndIgnoresLateReplies() async {
        let context = ControlledAuthenticationContext()
        let replies = DispatchQueue(label: "NativeAuthenticationTests.cancelledReplies")
        let authenticator = LocalNativeAuthenticator(makeContext: { context }, replyQueue: replies)
        let task = Task { try await authenticator.authenticate(for: .unlockVault) }
        await context.waitForEvaluation()
        task.cancel()
        // Deliberately await the cancelled result before delivering any callback. Relying
        // on invalidate to produce a callback would leave this test suspended.
        do { try await task.value; Issue.record("Cancelled attempt succeeded") }
        catch { #expect(error as? NativeAuthenticationError == .cancelled) }
        #expect(context.invalidations == 1)
        context.reply(.success(()))
        context.reply(.failure(.failed))
        await drain(replies)
        #expect(context.invalidations == 1)
    }

    @Test
    func synchronousAndDuplicateCallbacksCompleteOnce() async throws {
        let context = ControlledAuthenticationContext(synchronousReplies: [.success(()), .failure(.failed)])
        let replies = DispatchQueue(label: "NativeAuthenticationTests.duplicateReplies")
        let authenticator = LocalNativeAuthenticator(makeContext: { context }, replyQueue: replies)
        try await authenticator.authenticate(for: .changeVaultAccessPolicy)
        context.reply(.success(()))
        await drain(replies)
        #expect(context.invalidations == 1)
    }

    @Test
    func differentPurposesOwnSeparateContextsAndResults() async throws {
        let contexts = Mutex([ControlledAuthenticationContext]())
        let created = AsyncStream<ControlledAuthenticationContext>.makeStream()
        let authenticator = LocalNativeAuthenticator(makeContext: {
            let context = ControlledAuthenticationContext()
            contexts.withLock { $0.append(context) }
            created.continuation.yield(context)
            return context
        })
        let first = Task { try await authenticator.authenticate(for: .externalAIAuthorization) }
        var iterator = created.stream.makeAsyncIterator()
        let one = await iterator.next()!
        await one.waitForEvaluation()
        let second = Task { try await authenticator.authenticate(for: .openVault) }
        let two = await iterator.next()!
        await two.waitForEvaluation()
        #expect(one !== two)
        one.reply(.success(()))
        try await first.value
        #expect(two.invalidations == 0)
        #expect(two.reasons == ["Open this vault in Noema"])
        two.reply(.failure(.cancelled))
        do { try await second.value; Issue.record("Different purpose reused prior success") }
        catch { #expect(error as? NativeAuthenticationError == .cancelled) }
        #expect(contexts.withLock { $0.count } == 2)
        #expect(one.invalidations == 1)
        #expect(two.invalidations == 1)
        created.continuation.finish()
    }

    @Test(arguments: [LAError.Code.userCancel, .appCancel, .systemCancel])
    func classifiesAllNativeCancellationCodes(_ code: LAError.Code) {
        let diagnostic = NSError(domain: LAErrorDomain, code: code.rawValue,
                                 userInfo: [NSLocalizedDescriptionKey: "private diagnostic"])
        #expect(classifyNativeAuthenticationError(diagnostic) == .cancelled)
    }

    @Test(arguments: [LAError.Code.biometryNotAvailable, .biometryNotEnrolled, .biometryLockout,
                      .passcodeNotSet, .notInteractive])
    func classifiesUnavailableNativeErrors(_ code: LAError.Code) {
        #expect(classifyNativeAuthenticationError(NSError(domain: LAErrorDomain, code: code.rawValue)) == .unavailable)
    }

    @Test
    func sanitizesUnknownAndAbsentNativeErrors() {
        let unknown = NSError(domain: "private native service", code: LAError.Code.userCancel.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "secret diagnostic"])
        #expect(classifyNativeAuthenticationError(unknown) == .failed)
        #expect(classifyNativeAuthenticationError(nil) == .failed)
        #expect(classifyNativeAuthenticationError(nil, unavailable: true) == .unavailable)
        #expect(classifyNativeAuthenticationError(NSError(domain: LAErrorDomain,
            code: LAError.Code.authenticationFailed.rawValue)) == .failed)
        #expect(NativeAuthenticationError.failed.localizedDescription == "Authentication failed.")
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

private final class ControlledAuthenticationContext: NativeAuthenticationContext, Sendable {
    private struct State {
        var reasons: [String] = []
        var invalidations = 0
        var reply: (@Sendable (Result<Void, NativeAuthenticationError>) -> Void)?
    }
    private let state = Mutex(State())
    private let evaluated = AsyncStream<Void>.makeStream()
    private let availability: NativeAuthenticationError?
    private let cancelDuringAvailability: Bool
    private let synchronousReplies: [Result<Void, NativeAuthenticationError>]

    init(availability: NativeAuthenticationError? = nil, cancelDuringAvailability: Bool = false,
         synchronousReplies: [Result<Void, NativeAuthenticationError>] = []) {
        self.availability = availability
        self.cancelDuringAvailability = cancelDuringAvailability
        self.synchronousReplies = synchronousReplies
    }

    var reasons: [String] { state.withLock { $0.reasons } }
    var invalidations: Int { state.withLock { $0.invalidations } }

    func availabilityFailure() -> NativeAuthenticationError? {
        if cancelDuringAvailability { withUnsafeCurrentTask { $0?.cancel() } }
        return availability
    }

    func evaluate(reason: String, reply: @escaping @Sendable (Result<Void, NativeAuthenticationError>) -> Void) {
        state.withLock { $0.reasons.append(reason); $0.reply = reply }
        evaluated.continuation.yield(())
        for result in synchronousReplies { reply(result) }
    }

    func invalidate() { state.withLock { $0.invalidations += 1 } }
    func reply(_ result: Result<Void, NativeAuthenticationError>) {
        let reply = state.withLock { $0.reply }
        reply?(result)
    }
    func waitForEvaluation() async { for await _ in evaluated.stream { return } }
}
