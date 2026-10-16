import Foundation
import Synchronization
import VaultCore

/// Transient query evidence. Keep until the final synchronous UI publication check;
/// neither the query vector nor its validation closure belongs in durable work state.
public struct CompletedSemanticQuery: Sendable {
    public let vector: EmbeddingVector
    public let usage: AIActivityUsage?
    public let requestCount: Int
    private let validate: @Sendable () throws -> Void

    fileprivate init(vector: EmbeddingVector, usage: AIActivityUsage?, requestCount: Int,
                     validate: @escaping @Sendable () throws -> Void) {
        self.vector = vector; self.usage = usage; self.requestCount = requestCount
        self.validate = validate
    }
    /// Includes live vault/session checks: call outside canonical publication barriers.
    public func validatePublication() throws { try validate() }
}

/// One explicit submitted query per instance. Replacing A with B and then A requires
/// fresh instances and fresh cloud approval. Invalidation is synchronous and permanent.
public final class SemanticQueryExecution: Sendable {
    public let descriptor: EmbeddingModelDescriptor
    private enum Backend: Sendable {
        case native(any EmbeddingProvider)
        case cloud(EmbeddingRequestExecutor)
    }
    private struct State: Sendable { var valid = true; var started = false }
    private let state = Mutex(State())
    private let backend: Backend

    public init(native: any EmbeddingProvider) {
        descriptor = native.descriptor; backend = .native(native)
    }
    public init(cloud: EmbeddingRequestExecutor) {
        descriptor = cloud.descriptor; backend = .cloud(cloud)
    }
    public func invalidate() {
        state.withLock { $0.valid = false }
        if case .cloud(let executor) = backend { executor.invalidate() }
    }
    private func validate() throws {
        try Task.checkCancellation()
        guard state.withLock({ $0.valid }) else { throw CancellationError() }
    }

    public func execute(query: String, queryID: UUID,
                        context: EmbeddingExecutionContext) async throws -> CompletedSemanticQuery {
        let scope = EmbeddingProcessingScope.query(vaultID: context.lease.vaultID, queryID: queryID)
        try validate()
        try context.validate(scope: scope, model: descriptor)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= descriptor.maximumInputUTF8Bytes else {
            throw EmbeddingContractError.invalidInput
        }
        try state.withLock {
            guard $0.valid, !$0.started else { throw EmbeddingContractError.authorityDenied }
            $0.started = true
        }
        // Also bind every provider-side suspension and dispatch check to this lifetime.
        let execution = try EmbeddingExecutionContext(lease: context.lease, scope: scope, model: descriptor) { [self] in
            try validate(); try context.validate(scope: scope, model: descriptor)
        }
        let result: CompletedSemanticQuery
        switch backend {
        case .native(let provider):
            guard descriptor.providerID != "openai" else { throw EmbeddingContractError.authorityDenied }
            let vectors = try await provider.embed([query], scope: scope, context: execution)
            try execution.validate(scope: scope, model: descriptor)
            guard vectors.count == 1, let vector = vectors.first, vector.model == descriptor else {
                throw EmbeddingContractError.invalidVector
            }
            result = CompletedSemanticQuery(vector: vector, usage: nil, requestCount: 0) {
                try execution.validate(scope: scope, model: self.descriptor)
            }
        case .cloud(let executor):
            let completed = try await executor.embedWithEvidence([query], scope: scope, context: execution)
            try execution.validate(scope: scope, model: descriptor)
            guard completed.result.vectors.count == 1, let vector = completed.result.vectors.first,
                  vector.model == descriptor else { throw EmbeddingContractError.invalidVector }
            result = CompletedSemanticQuery(vector: vector, usage: completed.result.usage,
                requestCount: completed.result.requestCount) {
                try execution.validate(scope: scope, model: self.descriptor)
                try completed.validatePublication()
            }
        }
        try result.validatePublication()
        return result
    }
}
