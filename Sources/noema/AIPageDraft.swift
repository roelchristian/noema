import Foundation
import ExternalAI
import VaultCore

/// Transient, scoped composition input; never persisted as authority or diagnostics.
enum AIPageInput: Sendable {
    case source(UUID)
    case topic(String)
    case url(String, retainSource: Bool)
}

struct AIPageCompositionContext: Sendable {
    let id: UUID
    let authority: ExternalAIVaultAuthority
    let selection: UUID?
    let editorRevision: UUID
    let inputText: String
    let source: SourceSummarySnapshot?
    let references: String
    let fetched: WebSourceFetch?
    let address: String?
    let retainSource: Bool
}

struct AIPageSubmission: Sendable {
    let request: ExternalAISummaryRequest
    let context: AIPageCompositionContext
    let model: String
}

struct AIPageDraft: Identifiable, Sendable {
    let context: AIPageCompositionContext
    let enrichment: ExternalAIEnrichment
    let provenance: SummaryProvenance
    let validate: @Sendable () throws -> Void
    var id: UUID { context.id }
}
