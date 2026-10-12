import Foundation
import Testing
@testable import VaultCore

@MainActor private func annotationSession(_ text: String = "Ada 😀 Lovelace") -> (EditorSession, UUID, BlockStoreRevision) {
    let block = EditorBlock(runs: [RichRun(text)])
    let page = UUID(), token = BlockStoreRevision(token: Data("sqlite-page-7".utf8))
    let snapshot = SemanticPageSnapshot(snapshot: .init(pageID: page, document: .init(blocks: [block]), revision: token), annotations: [])
    let session = EditorSession()
    session.load(snapshot, identity: .init(pageID: page), selection: .init(location: 0, length: 3))
    return (session, block.id, token)
}

@Test @MainActor func editorAnnotationCommandsPreserveTextAndCanonicalRevisionThroughUndo() throws {
    let (session, block, token) = annotationSession()
    let original = session.snapshot(), entity = EntityIdentity(kind: "person", id: UUID())
    let id = try session.applyAnnotation(.create(blockID: block, range: .init(location: 0, length: 3), referent: .init(identity: entity), designation: "person", startAffinity: .before, endAffinity: .after), expectedLocalRevision: 0, expectedReferentRevision: token)
    let annotated = session.snapshot()
    #expect(session.revision == 1)
    #expect(session.pageRevision == token)
    #expect(session.document == original.document)
    if case .inline(_, _, let target) = session.semanticEdit?.annotations.first?.location {
        #expect(target.quote == "Ada")
        #expect(target.start == 0 && target.end == 3)
        #expect(target.startAffinity == .before && target.endAffinity == .after)
        #expect(target.suffix == " 😀 Lovelace")
    } else { Issue.record("Missing inline target") }
    session.restore(original, name: "Undo annotation")
    #expect(session.semanticEdit?.annotations.isEmpty == true)
    session.restore(annotated, name: "Redo annotation")
    #expect(session.semanticEdit?.annotations.first?.id == id)
    try session.applyAnnotation(.remove(annotationID: id), expectedLocalRevision: session.revision)
    #expect(session.semanticEdit?.annotations.first?.anchorDisposition == .deleted)
    #expect(session.semanticEdit?.annotations.first?.referent.identity == entity)
}

@Test @MainActor func editorAnnotationRejectsInvalidAndStaleSelectionsWithoutMutation() throws {
    let (session, block, token) = annotationSession()
    #expect(throws: PersistencePayloadError.self) { try session.annotationSelection(blockID: block, range: .init(location: 0, length: 0)) }
    #expect(throws: PersistencePayloadError.self) { try session.annotationSelection(blockID: block, range: .init(location: 4, length: 1)) }
    #expect(throws: PersistencePayloadError.self) { try session.annotationSelection(blockID: UUID(), range: .init(location: 0, length: 3)) }
    #expect(throws: KnowledgeStoreError.self) { try session.applyAnnotation(.create(blockID: block, range: .init(location: 0, length: 3), referent: .init(identity: .init(kind: "person", id: UUID())), designation: "person"), expectedLocalRevision: 99, expectedReferentRevision: token) }
    #expect(session.revision == 0)
    #expect(session.semanticEdit?.annotations.isEmpty == true)
}

@Test @MainActor func editorExactTextMutationTransformsIndependentAnnotation() throws {
    let (session, block, token) = annotationSession()
    try session.applyAnnotation(.create(blockID: block, range: .init(location: 0, length: 3), referent: .init(identity: .init(kind: "person", id: UUID())), designation: "person"), expectedLocalRevision: 0, expectedReferentRevision: token)
    try session.replaceText(block, range: .init(location: 0, length: 0), runs: [RichRun("Lady ")], selection: .init(location: 5, length: 0), expectedRevision: token)
    #expect(session.document.block(block)?.text == "Lady Ada 😀 Lovelace")
    if case .inline(_, _, let target) = session.semanticEdit?.annotations.first?.location {
        #expect(target.start == 5 && target.end == 8)
        #expect(target.quote == "Ada")
    } else { Issue.record("Missing transformed annotation") }
}
