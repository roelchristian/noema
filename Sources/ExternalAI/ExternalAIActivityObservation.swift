import Foundation
import Synchronization
import VaultCore

/// This observation boundary accepts only bounded counters. It cannot receive request or
/// response text, headers, credentials, authorization capabilities or arbitrary errors.
final class ExternalAIActivityObservation: Sendable {
    private struct State: Sendable {
        var dispatches = 0
        var usage: AIActivityUsage?
    }
    private let state = Mutex(State())
    private let date = Date()

    func dispatched() {
        state.withLock { $0.dispatches = min($0.dispatches + 1, ExternalAILimits.maximumRetryCount + 1) }
    }

    func received(_ usage: AIActivityUsage?) {
        guard let usage else { return }
        state.withLock { $0.usage = usage }
    }

    func flush(id: UUID, recorder: AIActivityRecorder?, model: String, pricing: AIUsagePricingCatalogue) async {
        guard let recorder else { return }
        let snapshot = state.withLock {
            let snapshot = ($0.dispatches, $0.usage)
            $0 = State()
            return snapshot
        }
        for _ in 0..<snapshot.0 { await recorder.recordDispatch(id) }
        if let usage = snapshot.1 {
            await recorder.recordUsage(id, usage: usage,
                estimatedCostUSD: pricing.estimatedCostUSD(model: model, at: date, usage: usage))
        }
    }
}

extension ExternalAIGateway {
    /// Optional usage has an independent decoder: malformed billing metadata cannot change
    /// an otherwise valid inference result. Only validated numeric metadata leaves the gateway.
    static func reportedUsage(from body: Data) -> AIActivityUsage? {
        guard body.count <= ExternalAILimits.maximumResponseBytes,
              let metadata = try? JSONDecoder().decode(UsageResponse.self, from: body),
              metadata.object == "response", ["completed", "incomplete"].contains(metadata.status),
              let usage = metadata.usage,
              (0...1_000_000_000).contains(usage.input_tokens),
              (0...1_000_000_000).contains(usage.output_tokens) else { return nil }
        let cached = usage.input_tokens_details?.cached_tokens
        guard cached.map({ (0...usage.input_tokens).contains($0) }) ?? true else { return nil }
        return AIActivityUsage(inputTokens: usage.input_tokens, outputTokens: usage.output_tokens,
                               cachedInputTokens: cached)
    }
}

private struct UsageResponse: Decodable {
    let object: String
    let status: String
    let usage: Usage?
    struct Usage: Decodable {
        let input_tokens: Int
        let output_tokens: Int
        let input_tokens_details: InputDetails?
    }
    struct InputDetails: Decodable { let cached_tokens: Int? }
}

extension ExternalAIError {
    var activityFailureCode: AIActivityFailureCode {
        switch self {
        case .cancelled, .authenticationCancelled: .cancelled
        case .credentialMissing, .credentialMalformed, .credentialUnavailable, .credentialExpired,
             .authenticationFailed, .authorizationRequired, .authorizationExpired, .authorizationRevoked: .authorization
        case .vaultUnavailable, .staleSession: .unavailable
        case .consentRequired, .consentAlreadyUsed: .consent
        case .networkUnavailable, .timedOut, .rateLimited, .providerUnavailable, .providerRejected, .redirectRejected: .network
        case .invalidResponse, .responseTooLarge, .summaryIncomplete, .summaryOutputLimitReached, .summaryRefused: .invalidResponse
        case .staleContent: .publication
        default: .unknown
        }
    }
}
