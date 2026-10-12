import Foundation
import Testing
@testable import VaultCore
@testable import noema

@Test @MainActor func semanticOccurrencePreviewsRetainCapturedEvidenceForUnavailableAndInvalidLocations() throws {
    let pageID = UUID(), token = BlockStoreRevision(token: Data("occurrence-page".utf8))
    let block = EditorBlock(runs: [RichRun("Napoleon in Russia")])
    let snapshot = BlockStoreSnapshot(pageID: pageID, document: .init(blocks: [block]), revision: token)
    let record = NoteRecord(id: pageID, title: "Campaign", aliases: [], tags: [], inlineTags: [], createdAt: "", updatedAt: "", body: "", relativePath: "", contentHash: "", originalHeader: nil)
    let annotation = SemanticAnnotation(location: .inline(pageID: pageID, blockID: block.id, target: try InlineAnnotationTarget(text: block.text, range: .init(location: 0, length: 8), revision: token.token)), referent: .init(identity: .init(kind: "person", id: UUID())), designation: "person", expectedRevision: token.token)
    let verified = SemanticOccurrencePreview.make(annotation: annotation, record: record, snapshot: snapshot, trashed: false)
    #expect(verified.pageTitle == "Campaign" && verified.context == "Napoleon in Russia" && verified.canNavigate)
    #expect(SemanticOccurrencePreview.make(annotation: annotation, record: record, snapshot: snapshot, trashed: true).state == .trashed)
    let unavailable = SemanticOccurrencePreview.make(annotation: annotation, record: nil, snapshot: nil, trashed: false)
    #expect(unavailable.state == .unavailablePage && unavailable.context == verified.context && unavailable.id == annotation.id)
    var stale = annotation; stale.anchorDisposition = .stale
    #expect(SemanticOccurrencePreview.make(annotation: stale, record: record, snapshot: snapshot, trashed: false).state == .stale)
    var deleted = annotation; deleted.anchorDisposition = .deleted
    #expect(SemanticOccurrencePreview.make(annotation: deleted, record: record, snapshot: snapshot, trashed: false).state == .deleted)
    let absentBlock = BlockStoreSnapshot(pageID: pageID, document: .init(blocks: [EditorBlock(runs: block.runs)]), revision: token)
    #expect(SemanticOccurrencePreview.make(annotation: annotation, record: record, snapshot: absentBlock, trashed: false).state == .unavailableBlock)
    let newer = BlockStoreSnapshot(pageID: pageID, document: snapshot.document, revision: .init(token: Data("newer".utf8)))
    #expect(SemanticOccurrencePreview.make(annotation: annotation, record: record, snapshot: newer, trashed: false).state == .stale)
    var wrongQuote = annotation
    if case .inline(let page, let block, var target) = wrongQuote.location {
        target.quote = "Other"; wrongQuote.location = .inline(pageID: page, blockID: block, target: target)
    }
    #expect(!SemanticOccurrencePreview.make(annotation: wrongQuote, record: record, snapshot: snapshot, trashed: false).canNavigate)
}
