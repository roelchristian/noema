import Foundation
import Testing
@testable import VaultCore

@MainActor @Test func semanticSessionExactStyledEditAndUndoPreserveAnchors() throws {
    let pageID = UUID(), revision = BlockStoreRevision(token: Data("canonical-r1".utf8))
    let block = EditorBlock(runs: [RichRun("Napoleon in Russia")])
    var document = BlockDocument(blocks: [block])
    let original = InlineAnnotation(pageID: pageID, blockID: block.id, designation: "person", expectedRevision: revision.token,
        target: try InlineAnnotationTarget(text: block.text, range: NSRange(location: 0, length: 8), revision: revision.token))
    document.extensions = .init(requiredFeatures: ["annotationsV1"], properties: ["annotations": .array([try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(original))])])
    let session = EditorSession(document: document, identity: .init(pageID: pageID))
    let before = session.snapshot()
    var style = InlineStyle(); style.bold = true
    try session.replaceText(block.id, range: NSRange(location: 0, length: 0), runs: [RichRun("Emperor ", style: style)], selection: NSRange(location: 8, length: 0), expectedRevision: revision)
    let inserted = session.document.preparingAnnotationsForPersistence(comparedTo: document)
    let shifted = try semanticEditorAnchors(inserted)[0]
    #expect(shifted.id == original.id && shifted.disposition == .resolved && shifted.target.start == 8)
    #expect(session.document.blocks[0].runs[0].style.bold)
    #expect(session.revision == 1)
    let edited = session.snapshot()
    try session.restore(before, name: "Undo", expectedRevision: revision)
    #expect(session.document.blocks[0].text == block.text)
    #expect(try semanticEditorAnchors(session.document.preparingAnnotationsForPersistence(comparedTo: edited.document))[0].disposition == .resolved)
    #expect(session.revision == 2)
    try session.restore(edited, name: "Redo", expectedRevision: revision)
    #expect(session.document.blocks[0].text == "Emperor Napoleon in Russia" && session.revision == 3)
}

@MainActor @Test func semanticSessionInvalidUnicodeOrRevisionPublishesNeitherTextNorAnchors() throws {
    let revision = BlockStoreRevision(token: Data("r1".utf8)), block = EditorBlock(runs: [RichRun("e\u{301}👩🏽‍🚀")])
    var document = BlockDocument(blocks: [block])
    let annotation = InlineAnnotation(pageID: UUID(), blockID: block.id, designation: "entity", expectedRevision: revision.token,
        target: try InlineAnnotationTarget(text: block.text, range: NSRange(location: 0, length: 2), revision: revision.token))
    document.extensions = .init(requiredFeatures: ["annotationsV1"], properties: ["annotations": .array([try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))])])
    let session = EditorSession(document: document)
    #expect(throws: PersistencePayloadError.self) { try session.replaceText(block.id, range: NSRange(location: 1, length: 0), runs: [RichRun("x")], selection: .init(), expectedRevision: revision) }
    #expect(session.document == document && session.revision == 0)
    #expect(throws: PersistencePayloadError.self) { try session.replaceText(block.id, range: NSRange(location: 0, length: 0), runs: [RichRun("x")], selection: .init(), expectedRevision: .init(token: Data("stale".utf8))) }
    #expect(session.document == document && session.revision == 0)
    var unsupported = RichRun("x"); unsupported.extensions = .init(version: 99)
    #expect(throws: PersistencePayloadError.self) { try session.replaceText(block.id, range: NSRange(location: 0, length: 0), runs: [unsupported], selection: .init(), expectedRevision: revision) }
    #expect(session.document == document && session.revision == 0)
}

private func semanticEditorAnchors(_ document: BlockDocument) throws -> [InlineAnnotation] {
    guard case .array(let values) = document.extensions?.properties["annotations"] else { return [] }
    return try values.map { try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode($0)) }
}

private func semanticEditFixture(text: String = "Napoleon in Russia") throws -> SemanticPageSnapshot {
    let pageID = UUID(), revision = BlockStoreRevision(token: Data("semantic-edit-r1".utf8))
    let block = EditorBlock(runs: [RichRun(text)])
    let whole = SemanticAnnotation(location: .wholeBlock(pageID: pageID, blockID: block.id),
        referent: .init(identity: .init(kind: "question", id: UUID())), designation: "question", expectedRevision: revision.token)
    var target = try InlineAnnotationTarget(text: text, range: NSRange(location: 0, length: 8), revision: revision.token)
    target.unknownFields["futureAnchor"] = .string("retained")
    var inline = SemanticAnnotation(location: .inline(pageID: pageID, blockID: block.id, target: target),
        referent: .init(identity: .init(kind: "person", id: UUID())), designation: "person", expectedRevision: revision.token)
    inline.unknownFields["futureAnnotation"] = .number(42)
    let second = SemanticAnnotation(location: inline.location, referent: .init(identity: .init(kind: "concept", id: UUID())),
        designation: "concept", expectedRevision: revision.token)
    return .init(snapshot: .init(pageID: pageID, document: .init(blocks: [block]), revision: revision),
        annotations: [whole, inline, second].map { .init(annotation: $0, revision: .init(token: Data($0.id.uuidString.utf8))) })
}
private func semanticInlineTarget(_ value: SemanticAnnotation) throws -> InlineAnnotationTarget {
    guard case .inline(_, _, let target) = value.location else { throw PersistencePayloadError.invalidAnnotation }
    return target
}
@Test func semanticIndependentEditsPreserveWholeBlockNestedIdentityAndUnknownFields() throws {
    let original = try semanticEditFixture()
    let blockID = original.snapshot.document.blocks[0].id
    var edit = try original.replacingText(in: blockID, range: .init(location: 0, length: 0), with: [RichRun("Emperor ")])
    edit = edit.preparingAnnotationsForPersistence(comparedTo: original)
    #expect(edit.annotations.map(\.id) == original.annotations.map { $0.annotation.id })
    #expect(edit.annotations.allSatisfy { $0.anchorDisposition == .resolved })
    #expect(try semanticInlineTarget(edit.annotations[1]).start == 8)
    #expect(try semanticInlineTarget(edit.annotations[1]).unknownFields["futureAnchor"] == .string("retained"))
    #expect(edit.annotations[1].unknownFields["futureAnnotation"] == .number(42))
    #expect(edit.annotations[0].location == original.annotations[0].annotation.location)
}
@Test func semanticBareEditAndTamperedProofPreserveOriginalEvidenceAsStale() throws {
    let original = try semanticEditFixture(), blockID = original.snapshot.document.blocks[0].id
    var edit = try original.replacingText(in: blockID, range: .init(location: 0, length: 0), with: [RichRun("Emperor ")])
    edit.document.update(blockID) { $0.runs = [RichRun("A different Napoleon")] }
    let prepared = edit.preparingAnnotationsForPersistence(comparedTo: original)
    #expect(prepared.annotations[0].anchorDisposition == .resolved)
    #expect(prepared.annotations[1].anchorDisposition == .stale)
    #expect(prepared.annotations[1].location == original.annotations[1].annotation.location)
    var bare = original.edit
    bare.document.update(blockID) { $0.runs = [RichRun("Emperor Napoleon")] }
    #expect(bare.preparingAnnotationsForPersistence(comparedTo: original).annotations[2].anchorDisposition == .stale)
}
@Test func semanticStructuralSplitMergeAndDeletionKeepCapturedIdentities() throws {
    let original = try semanticEditFixture(), blockID = original.snapshot.document.blocks[0].id
    var edit = original.edit
    let cursor = try #require(try edit.apply(.split(8), to: blockID, expectedRevision: original.snapshot.revision))
    #expect(edit.annotations[0].anchorDisposition == .resolved)
    #expect(try semanticInlineTarget(edit.annotations[1]).quote == "Napoleon")
    _ = try edit.apply(.mergeBackward, to: cursor.id, expectedRevision: original.snapshot.revision)
    #expect(edit.document.blocks[0].text == "Napoleon in Russia")
    #expect(edit.preparingAnnotationsForPersistence(comparedTo: original).annotations.allSatisfy { $0.anchorDisposition == .resolved })
    _ = try edit.apply(.delete, to: blockID, expectedRevision: original.snapshot.revision)
    #expect(edit.annotations.allSatisfy { $0.anchorDisposition == .deleted })
    #expect(edit.annotations[0].location.blockID == blockID)
}
@Test func semanticCrossingSplitStalesWhileContainedSuffixRemaps() throws {
    let original = try semanticEditFixture(), blockID = original.snapshot.document.blocks[0].id
    var edit = original.edit
    let target = try InlineAnnotationTarget(text: original.snapshot.document.blocks[0].text, range: .init(location: 12, length: 6), revision: original.snapshot.revision.token)
    var suffix = edit.annotations[1]; suffix.id = UUID(); suffix.location = .inline(pageID: edit.pageID, blockID: blockID, target: target)
    edit.annotations.append(suffix)
    let cursor = try #require(try edit.apply(.split(4), to: blockID, expectedRevision: original.snapshot.revision))
    #expect(edit.annotations[1].anchorDisposition == .stale)
    #expect(edit.annotations[1].location == original.annotations[1].annotation.location)
    #expect(edit.annotations[3].location.blockID == cursor.id)
    #expect(try semanticInlineTarget(edit.annotations[3]).start == 8)
    _ = try edit.apply(.mergeBackward, to: cursor.id, expectedRevision: original.snapshot.revision)
    #expect(try semanticInlineTarget(edit.annotations[3]).start == 12)
}
@Test func semanticUnicodeAffinityAndInvalidBoundariesAreAtomic() throws {
    let original = try semanticEditFixture(text: "Napoleon👩🏽‍🚀e\u{301}")
    let blockID = original.snapshot.document.blocks[0].id
    var edit = original.edit
    guard case .inline(let page, let block, var target) = edit.annotations[1].location else { return }
    target.startAffinity = .before; target.endAffinity = .after
    edit.annotations[1].location = .inline(pageID: page, blockID: block, target: target)
    try edit.replaceText(in: blockID, range: .init(location: 0, length: 0), with: [RichRun("👨‍👩‍👧‍👦")], expectedRevision: original.snapshot.revision)
    #expect(try semanticInlineTarget(edit.annotations[1]).start == 0)
    #expect(try semanticInlineTarget(edit.annotations[1]).quote == "👨‍👩‍👧‍👦Napoleon")
    let before = edit
    #expect(throws: PersistencePayloadError.self) { try edit.replaceText(in: blockID, range: .init(location: 1, length: 0), with: [RichRun("x")], expectedRevision: original.snapshot.revision) }
    #expect(edit == before)
}
@Test func semanticPageAndBlockDuplicationCopyAnchoredObjectsAndRetainEntities() throws {
    let original = try semanticEditFixture(), questionID = original.annotations[0].annotation.referent.identity.id
    var question = SemanticObject(id: questionID, typeKey: "question", relatedEntityIDs: [original.annotations[1].annotation.referent.identity.id])
    question.unknownFields["futureObject"] = .bool(true)
    let objects = [SemanticObjectSnapshot(object: question, revision: .init(token: Data("object-r1".utf8)))]
    let copy = try original.edit.duplicatedPage(objects: objects)
    #expect(copy.pageID != original.snapshot.pageID)
    #expect(copy.document.blocks[0].id != original.snapshot.document.blocks[0].id)
    #expect(Set(copy.annotations.map(\.id)).isDisjoint(with: Set(original.annotations.map { $0.annotation.id })))
    #expect(copy.objects.count == 1 && copy.objects[0].id != questionID)
    #expect(copy.annotations[0].referent.identity.id == copy.objects[0].id)
    #expect(copy.annotations[1].referent == original.annotations[1].annotation.referent)
    #expect(copy.objects[0].relatedEntityIDs == question.relatedEntityIDs)
    #expect(copy.objects[0].unknownFields == question.unknownFields)
    #expect(try semanticInlineTarget(copy.annotations[1]).unknownFields["futureAnchor"] == .string("retained"))
    var blockCopy = original.edit
    _ = try blockCopy.duplicateBlock(original.snapshot.document.blocks[0].id, objects: objects, expectedRevision: original.snapshot.revision)
    #expect(blockCopy.annotations.count == 6 && blockCopy.objects.count == 1)
    #expect(blockCopy.annotations[4].referent == original.annotations[1].annotation.referent)
    var rejected = original.edit
    #expect(throws: KnowledgeStoreError.self) { try rejected.duplicateBlock(original.snapshot.document.blocks[0].id, objects: [], expectedRevision: original.snapshot.revision) }
    #expect(rejected == original.edit)
}
@Test func semanticUndoRebasesTextAndIndependentAnnotationsCoherently() throws {
    let original = try semanticEditFixture(), blockID = original.snapshot.document.blocks[0].id
    var edited = try original.replacingText(in: blockID, range: .init(location: 0, length: 0), with: [RichRun("Emperor ")])
    let nextRevision = BlockStoreRevision(token: Data("canonical-r2".utf8))
    let current = SemanticPageSnapshot(snapshot: .init(pageID: edited.pageID, document: edited.document, revision: nextRevision),
        annotations: edited.annotations.map { .init(annotation: $0, revision: .init(token: Data("annotation-r2".utf8))) })
    edited = current.edit
    let undone = try edited.restoring(original, expectedRevision: nextRevision)
    #expect(undone.document.blocks[0].text == original.snapshot.document.blocks[0].text)
    #expect(undone.annotations[1].expectedRevision == nextRevision.token)
    #expect(try semanticInlineTarget(undone.annotations[1]).start == 0)
    #expect(undone.expectedAnnotationRevisions == current.edit.expectedAnnotationRevisions)
    #expect(undone.preparingAnnotationsForPersistence(comparedTo: current).annotations.allSatisfy { $0.anchorDisposition == .resolved })
}

@Test func semanticDuplicationRetainsExternalAndUnresolvedObjectProvenance() throws {
    let original = try semanticEditFixture()
    var edit = original.edit
    edit.annotations[0].designation = "reference"
    let external = try edit.duplicatedPage(objects: [])
    #expect(external.objects.isEmpty)
    #expect(external.annotations[0].referent.identity == edit.annotations[0].referent.identity)
    edit.annotations[0].designation = "futureDesignation"
    let opaque = try edit.duplicatedPage(objects: [])
    #expect(opaque.annotations[0].referent.disposition == .unresolved)
    #expect(opaque.annotations[0].referent.identity == edit.annotations[0].referent.identity)
    edit.annotations[0].designation = "question"
    edit.annotations[0].referent.disposition = .unresolved
    edit.annotations[0].referent.payload = .init(properties: ["opaqueReference": .string("original")])
    let unresolved = try edit.duplicatedPage(objects: [])
    #expect(unresolved.annotations[0].referent == edit.annotations[0].referent)
}
