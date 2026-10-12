import CryptoKit
import Foundation
import VaultCore

/// Closed operation set. No arbitrary prompts, tools, endpoints, or whole-vault operation.
public enum ExternalAIAction: String, Sendable, CaseIterable {
    case summarizePage
    case summarizeSource
    case suggestTitle
    case lccClassification
    case composePage
}

public enum ExternalAISummaryTarget: Sendable, Equatable, Hashable {
    case page(UUID)
    case source(UUID)

    public var action: ExternalAIAction {
        switch self {
        case .page: .summarizePage
        case .source: .summarizeSource
        }
    }

    public var id: UUID {
        switch self {
        case .page(let id), .source(let id): id
        }
    }
}

/// A claimed authority is not permission by itself. The gateway must match the live access gate
/// and session manager again immediately before dispatch and publication.
public struct ExternalAIVaultAuthority: Sendable, Equatable, Hashable {
    public let sessionID: UUID
    public let vaultID: UUID
    public let generation: UInt64

    public init(lease: VaultSessionLease) {
        sessionID = lease.sessionID
        vaultID = lease.vaultID
        generation = lease.generation
    }

    public init(session: VaultSession) { self.init(lease: session.lease) }

    public func matches(_ lease: VaultSessionLease?) -> Bool {
        guard let lease else { return false }
        return sessionID == lease.sessionID && vaultID == lease.vaultID && generation == lease.generation
    }
}

public enum ExternalAIEnrichmentMode: String, Sendable, Codable, CaseIterable {
    case initial, regenerate, compose
}

public enum ExternalAILimits {
    public static let maximumContentBytes = 64 * 1_024
    public static let maximumResponseBytes = 128 * 1_024
    public static let maximumSummaryBytes = 8 * 1_024
    public static let maximumBodyBytes = 64 * 1_024
    public static let maximumEnrichmentBytes = 80 * 1_024
    public static let maximumTitleCharacters = 120
    public static let maximumTitleWords = 8
    public static let maximumLCCRationaleBytes = 2 * 1_024
    public static let requestTimeout: TimeInterval = 60
    public static let maximumRetryCount = 1
}

/// An immutable snapshot of exactly one explicitly selected item. Content is intentionally
/// not Codable, and diagnostics redact it. Revision is local and must never be sent to OpenAI.
public struct ExternalAISummaryRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let authority: ExternalAIVaultAuthority
    public let target: ExternalAISummaryTarget
    public let contentRevision: UUID
    public let content: String
    public let action: ExternalAIAction
    public let mode: ExternalAIEnrichmentMode
    public var contentByteCount: Int { content.utf8.count }
    let contentDigest: Data

    public init(
        id: UUID = UUID(), authority: ExternalAIVaultAuthority,
        target: ExternalAISummaryTarget, contentRevision: UUID, content: String, action: ExternalAIAction? = nil, mode: ExternalAIEnrichmentMode? = nil
    ) throws {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExternalAIError.emptyContent
        }
        guard content.utf8.count <= ExternalAILimits.maximumContentBytes else {
            throw ExternalAIError.payloadTooLarge
        }
        let operation = action ?? target.action
        guard operation == target.action || operation == .suggestTitle || operation == .lccClassification || operation == .composePage else {
            throw ExternalAIError.unsupportedAction
        }
        let resolvedMode = mode ?? (operation == .composePage ? .compose : .regenerate)
        guard (operation == .composePage) == (resolvedMode == .compose) else { throw ExternalAIError.unsupportedAction }
        if operation == .composePage {
            guard case .page = target else { throw ExternalAIError.unsupportedAction }
        }
        self.mode = resolvedMode
        self.action = operation
        self.id = id
        self.authority = authority
        self.target = target
        self.contentRevision = contentRevision
        self.content = content
        contentDigest = Data(SHA256.hash(data: Data(content.utf8)))
    }

    public var description: String { "ExternalAISummaryRequest(\(action.rawValue), content: <redacted>)" }
    public var debugDescription: String { description }
}

/// Consent is separate from biometric authorization. Create only after the user confirms
/// the selected content disclosure. The gateway consumes each receipt once; retries remain
/// part of that same operation. This value is not a cryptographic proof of a UI interaction.
public struct ExternalAIContentConsent: Sendable, Equatable {
    public let id: UUID
    public let requestID: UUID
    public let authority: ExternalAIVaultAuthority
    public let target: ExternalAISummaryTarget
    public let contentRevision: UUID
    public let action: ExternalAIAction
    private let contentDigest: Data
    public let mode: ExternalAIEnrichmentMode

    public init(approving request: ExternalAISummaryRequest) {
        id = UUID()
        requestID = request.id
        authority = request.authority
        target = request.target
        contentRevision = request.contentRevision
        action = request.action
        mode = request.mode
        contentDigest = request.contentDigest
    }

    public func approves(_ request: ExternalAISummaryRequest) -> Bool {
        requestID == request.id && authority == request.authority && target == request.target
            && action == request.action && mode == request.mode && contentRevision == request.contentRevision && contentDigest == request.contentDigest
    }
}

public enum ExternalAIProvider: String, Codable, Sendable { case openAI }

/// Only these provider facts may be persisted beside the generated summary. Never persist
/// request text, consent, capability, session authority, credential, or HTTP response bodies.
public struct ExternalAIProvenance: Codable, Sendable, Equatable {
    public let provider: ExternalAIProvider
    public let model: String
    public let generatedAt: Date

    private enum CodingKeys: String, CodingKey { case provider, model, generatedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(provider: container.decode(ExternalAIProvider.self, forKey: .provider),
                      model: container.decode(String.self, forKey: .model),
                      generatedAt: container.decode(Date.self, forKey: .generatedAt))
    }

    public init(provider: ExternalAIProvider = .openAI, model: String, generatedAt: Date = Date()) throws {
        guard !model.isEmpty, model.utf8.count <= 100,
              model.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
            throw ExternalAIError.invalidConfiguration
        }
        self.provider = provider
        self.model = model
        self.generatedAt = generatedAt
    }
}

public struct ExternalAISummaryResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID: UUID
    public let authority: ExternalAIVaultAuthority
    public let target: ExternalAISummaryTarget
    public let contentRevision: UUID
    public let action: ExternalAIAction
    public let mode: ExternalAIEnrichmentMode
    public let summary: String
    public var title: String? { enrichment?.title ?? (action == .suggestTitle ? summary : nil) }
    public let lccSuggestion: ExternalAILCCSuggestion?
    public let enrichment: ExternalAIEnrichment?
    public let provenance: ExternalAIProvenance

    /// Compatibility for summary test doubles and historical independent metadata actions.
    /// The production gateway uses the structured initializer for enrichment and composition.
    public init(request: ExternalAISummaryRequest, summary: String, provenance: ExternalAIProvenance) throws {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= ExternalAILimits.maximumSummaryBytes else { throw ExternalAIError.invalidResponse }
        switch request.action {
        case .summarizePage, .summarizeSource: lccSuggestion = nil
        case .suggestTitle:
            try ExternalAIOutputValidation.validateTitle(summary)
            lccSuggestion = nil
        case .lccClassification: lccSuggestion = try ExternalAIOutputValidation.lccSuggestion(from: summary)
        case .composePage: throw ExternalAIError.invalidResponse
        }
        action = request.action
        mode = request.mode
        requestID = request.id
        authority = request.authority
        target = request.target
        contentRevision = request.contentRevision
        self.summary = summary
        enrichment = nil
        self.provenance = provenance
    }

    public init(request: ExternalAISummaryRequest, enrichment: ExternalAIEnrichment,
                provenance: ExternalAIProvenance) throws {
        guard [.summarizePage, .summarizeSource, .composePage].contains(request.action) else {
            throw ExternalAIError.unsupportedAction
        }
        let validated = try ExternalAIEnrichment(title: enrichment.title, summary: enrichment.summary,
            classification: enrichment.classification, body: enrichment.body, mode: request.mode)
        requestID = request.id
        authority = request.authority
        target = request.target
        contentRevision = request.contentRevision
        action = request.action
        mode = request.mode
        summary = validated.summary
        lccSuggestion = validated.classification
        self.enrichment = validated
        self.provenance = provenance
    }

    /// Bind every artifact, including explicit unavailable classification, to issued authority.
    var publicationDigest: Data {
        var parts = [action.rawValue, mode.rawValue, summary]
        if let enrichment {
            parts += ["structured", enrichment.title ?? "", enrichment.classification?.code ?? "",
                      enrichment.classification?.rationale ?? "", enrichment.body ?? ""]
        }
        let bytes = parts.reduce(into: Data()) { data, part in
            data.append(Data("\(part.utf8.count):".utf8)); data.append(Data(part.utf8))
        }
        return Data(SHA256.hash(data: bytes))
    }
    public var description: String { "ExternalAISummaryResult(enrichment: <redacted>)" }
    public var debugDescription: String { description }
}

/// Implementations must validate the corresponding target, consume consent, bind to a live
/// session, propagate Task cancellation, and return sanitized errors. No credential is exposed.
public protocol ExternalAISummarizing: Sendable {
    func summarizePage(_ request: ExternalAISummaryRequest, consent: ExternalAIContentConsent) async throws -> ExternalAISummaryResult
    func summarizeSource(_ request: ExternalAISummaryRequest, consent: ExternalAIContentConsent) async throws -> ExternalAISummaryResult
}

/// The three expressly invoked operations share one security boundary. Summary-only test
/// doubles and callers can continue to conform to ExternalAISummarizing.
public protocol ExternalAIEnriching: ExternalAISummarizing {
    func composePage(_ request: ExternalAISummaryRequest, consent: ExternalAIContentConsent) async throws -> ExternalAISummaryResult
}

public protocol ExternalAIActionPerforming: ExternalAIEnriching {
    func suggestTitle(_ request: ExternalAISummaryRequest, consent: ExternalAIContentConsent) async throws -> ExternalAISummaryResult
    func classifyLCC(_ request: ExternalAISummaryRequest, consent: ExternalAIContentConsent) async throws -> ExternalAISummaryResult
}

public extension ExternalAIEnriching {
    func composePage(_ request: ExternalAISummaryRequest, consent: ExternalAIContentConsent) async throws -> ExternalAISummaryResult {
        throw ExternalAIError.unsupportedAction
    }
}

/// Opaque in-process capability; only security components in this module can mint it.
/// Possession still requires live validation by its issuing session manager.
public struct ExternalAICapability: Sendable, Equatable {
    public let id: UUID
    public let authority: ExternalAIVaultAuthority
    public let credentialVersion: UUID

    init(id: UUID = UUID(), authority: ExternalAIVaultAuthority, credentialVersion: UUID) {
        self.id = id
        self.authority = authority
        self.credentialVersion = credentialVersion
    }
}

public struct ExternalAISessionPolicy: Sendable, Equatable {
    public let idleTimeout: TimeInterval
    public let maximumLifetime: TimeInterval

    public init(idleTimeout: TimeInterval = 30 * 60, maximumLifetime: TimeInterval = 4 * 60 * 60) throws {
        guard idleTimeout.isFinite, maximumLifetime.isFinite, idleTimeout > 0,
              idleTimeout <= 30 * 60, maximumLifetime > 0, maximumLifetime <= 4 * 60 * 60,
              idleTimeout <= maximumLifetime else { throw ExternalAIError.invalidConfiguration }
        self.idleTimeout = idleTimeout
        self.maximumLifetime = maximumLifetime
    }

    public static let `default` = try! ExternalAISessionPolicy()
}

/// Finite errors prevent underlying Keychain, LA, HTTP, or provider text leaking content/secrets.
public enum ExternalAIError: String, Error, Sendable, Equatable, CaseIterable, LocalizedError {
    case credentialMissing, credentialMalformed, credentialUnavailable, credentialExpired
    case authenticationFailed, authenticationCancelled, authorizationRequired, authorizationExpired, authorizationRevoked
    case vaultUnavailable, staleSession, consentRequired, consentAlreadyUsed, unsupportedAction
    case emptyContent, payloadTooLarge, responseTooLarge, invalidConfiguration, invalidResponse
    case summaryIncomplete, summaryOutputLimitReached, summaryRefused
    case networkUnavailable, timedOut, rateLimited, providerUnavailable, providerRejected, redirectRejected
    case cancelled, staleContent

    public var errorDescription: String? {
        switch self {
        case .credentialMissing: "Add an OpenAI API key in External AI settings."
        case .credentialMalformed: "The API key format is invalid."
        case .credentialUnavailable: "The API key is unavailable in Keychain."
        case .credentialExpired: "Local credential authorization has expired. Replace or reauthorize the key."
        case .authenticationFailed: "External AI authentication failed."
        case .authenticationCancelled: "External AI authentication was cancelled."
        case .authorizationRequired: "Authorize external AI access to continue."
        case .authorizationExpired: "External AI authorization has expired."
        case .authorizationRevoked: "External AI authorization was revoked."
        case .vaultUnavailable: "Open and unlock a vault to use OpenAI."
        case .staleSession: "The original vault session is no longer active."
        case .consentRequired: "Confirm the selected content before sending it to OpenAI."
        case .consentAlreadyUsed: "This content submission was already approved and used."
        case .unsupportedAction: "This external AI operation is unsupported."
        case .emptyContent: "The selected item has no text for this AI action."
        case .payloadTooLarge: "The selected text exceeds the external AI size limit."
        case .responseTooLarge: "OpenAI returned a response exceeding the size limit."
        case .invalidConfiguration: "The external AI configuration is invalid."
        case .invalidResponse: "OpenAI returned an invalid AI result."
        case .summaryIncomplete: "OpenAI did not finish generating the result. Try again."
        case .summaryOutputLimitReached: "OpenAI reached the generation limit before finishing. Try shorter content or another model."
        case .summaryRefused: "OpenAI declined this AI action."
        case .networkUnavailable: "OpenAI could not be reached."
        case .timedOut: "The OpenAI request timed out."
        case .rateLimited: "OpenAI is temporarily rate limited."
        case .providerUnavailable: "OpenAI is temporarily unavailable."
        case .providerRejected: "OpenAI rejected the request. Check External AI settings."
        case .redirectRejected: "The OpenAI request attempted an unsupported redirect."
        case .cancelled: "The external AI action was cancelled."
        case .staleContent: "The selected content changed before the AI result could be applied."
        }
    }
}
