import Foundation

/// Scopes are deliberately distinct: a document grant never permits query or historical submission.
public enum EmbeddingProcessingScope: Sendable, Equatable {
    case document(EmbeddingEntityIdentity)
    case query(vaultID: UUID, queryID: UUID)
    case historicalBackfill(jobID: UUID, entity: EmbeddingEntityIdentity)

    public var vaultID: UUID {
        switch self {
        case .document(let entity), .historicalBackfill(_, let entity): entity.vaultID
        case .query(let vaultID, _): vaultID
        }
    }
}

/// Transient authority only. The validator must recheck lease, provider selection and consent.
/// ExternalAI adapters additionally require their own request-admission security boundary.
public struct EmbeddingExecutionContext: Sendable {
    public let lease: VaultSessionLease
    public let scope: EmbeddingProcessingScope
    public let model: EmbeddingModelDescriptor
    private let validateCurrentAuthority: @Sendable () throws -> Void

    public init(lease: VaultSessionLease, scope: EmbeddingProcessingScope, model: EmbeddingModelDescriptor,
                validateCurrentAuthority: @escaping @Sendable () throws -> Void) throws {
        guard scope.vaultID == lease.vaultID else { throw EmbeddingContractError.authorityDenied }
        self.lease = lease; self.scope = scope; self.model = model
        self.validateCurrentAuthority = validateCurrentAuthority
    }
    public func validate(scope requestedScope: EmbeddingProcessingScope, model requestedModel: EmbeddingModelDescriptor) throws {
        try Task.checkCancellation()
        guard scope == requestedScope, model == requestedModel, scope.vaultID == lease.vaultID else {
            throw EmbeddingContractError.authorityDenied
        }
        try validateCurrentAuthority()
    }
}

public protocol EmbeddingProcessingPolicyResolver: Sendable {
    /// Must fail closed for absent grants, stale sessions and provider changes, including after suspension.
    func authorize(scope: EmbeddingProcessingScope, model: EmbeddingModelDescriptor,
                   lease: VaultSessionLease) async throws -> EmbeddingExecutionContext
}

public protocol EmbeddingProvider: Sendable {
    var descriptor: EmbeddingModelDescriptor { get }
    /// Results preserve input order. Validate current authority before dispatch and after suspension;
    /// a derived-index writer must validate again inside its conditional publication window.
    func embed(_ inputs: [String], scope: EmbeddingProcessingScope,
               context: EmbeddingExecutionContext) async throws -> [EmbeddingVector]
}

/// Deterministic synthetic provider for contract tests; it performs no inference or I/O.
public struct MockEmbeddingProvider: EmbeddingProvider {
    public let descriptor: EmbeddingModelDescriptor
    public init(descriptor: EmbeddingModelDescriptor) { self.descriptor = descriptor }
    public func embed(_ inputs: [String], scope: EmbeddingProcessingScope,
                      context: EmbeddingExecutionContext) async throws -> [EmbeddingVector] {
        try context.validate(scope: scope, model: descriptor)
        guard !inputs.isEmpty, inputs.count <= descriptor.maximumBatchSize,
              inputs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  $0.utf8.count <= descriptor.maximumInputUTF8Bytes }) else {
            throw EmbeddingContractError.invalidInput
        }
        let vectors = try inputs.map { input in
            // Fixed FNV-1a seed; Swift's process-randomized Hasher is intentionally avoided.
            var state: UInt64 = 14_695_981_039_346_656_037
            for byte in input.utf8 { state = (state ^ UInt64(byte)) &* 1_099_511_628_211 }
            var values = (0..<descriptor.dimensions).map { _ -> Float in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return Float(Int((state >> 32) % 2001) - 1000) / 1000
            }
            if values.allSatisfy({ $0 == 0 }) { values[0] = 1 }
            return try EmbeddingVector(values: values, model: descriptor)
        }
        try context.validate(scope: scope, model: descriptor)
        return vectors
    }
}
