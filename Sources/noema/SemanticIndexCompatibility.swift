import Foundation
import VaultCore
import ExternalAI

enum SemanticIndexCompatibility: Equatable {
    case unavailable, notIndexed, compatible, requiresRebuild
    var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .notIndexed: "Not indexed"
        case .compatible: "Compatible model"
        case .requiresRebuild: "Rebuild required for selected model"
        }
    }
}

extension AppModel {
    /// Metadata-only inspection. A model change never admits content or grants inference.
    func refreshSemanticIndexCompatibility(for lease: VaultSessionLease) async {
        guard sessionManager.accessGate.currentLease == lease else { return }
        guard let index = semanticIndex else { semanticIndexCompatibility = .unavailable; return }
        let configuration = externalAIService.embeddingConfiguration
        let expected = configuration.embeddingDescriptor
        do {
            let generations = try await index.generations()
            guard !Task.isCancelled, sessionManager.accessGate.currentLease == lease,
                  semanticIndex === index, externalAIService.embeddingConfiguration == configuration else { return }
            if generations.isEmpty { semanticIndexCompatibility = .notIndexed }
            else if generations.contains(where: { $0.model == expected && $0.chunkingVersion == EmbeddingChunker.version }) {
                semanticIndexCompatibility = .compatible
            } else { semanticIndexCompatibility = .requiresRebuild }
        } catch {
            guard !Task.isCancelled, sessionManager.accessGate.currentLease == lease,
                  semanticIndex === index, externalAIService.embeddingConfiguration == configuration else { return }
            semanticIndexCompatibility = .unavailable
        }
    }
}
