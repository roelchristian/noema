import Foundation
import Synchronization
import VaultCore

enum VaultSearchRetrievalMode: String, CaseIterable, Identifiable, Sendable {
    case keywords = "Keywords", meaning = "Meaning"
    var id: Self { self }
}
enum SemanticSearchStatus: Equatable, Sendable {
    case idle, needsSubmission, preparing, awaitingApproval, searching, completed, declined
    case unavailable(String), failed(String)
    var isRunning: Bool { self == .preparing || self == .awaitingApproval || self == .searching }
    var message: String? {
        switch self {
        case .idle: nil
        case .needsSubmission: "Submit to search by meaning. Keyword results remain available."
        case .preparing: "Checking the semantic index…"
        case .awaitingApproval: "Approve this query before sending it to OpenAI."
        case .searching: "Finding related passages…"
        case .completed: "Text and meaning results. Limited coverage: only current completed passages are included. Older Source indexes may need rebuilding."
        case .declined: "Query not sent. Keyword results remain available."
        case .unavailable(let message), .failed(let message): message
        }
    }
}
struct SemanticQueryDisclosure: Identifiable, Equatable, Sendable {
    let id: UUID
    let query: String
    let provider: String
    let model: String
}
final class MeaningSearchEpoch: Sendable {
    private let valid = Mutex(true)
    func invalidate() { valid.withLock { $0 = false } }
    func validate() throws {
        try Task.checkCancellation()
        guard valid.withLock({ $0 }) else { throw CancellationError() }
    }
}
struct MeaningSearchEvidence: Sendable {
    let completion: EmbeddingDocumentCompletion
    var identity: EmbeddingEntityIdentity { completion.identity }
    var canonicalRevision: BlockStoreRevision { .init(token: Data(base64Encoded: identity.revision) ?? Data()) }
    let passage: SemanticSearchPassage
    let generation: EmbeddingIndexGeneration
}
