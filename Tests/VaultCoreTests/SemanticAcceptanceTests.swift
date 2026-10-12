import Foundation
import Testing
@testable import VaultCore

/// The contract's durable end-to-end fixture uses real independent records.
@Test func semanticNapoleonicQuestionEntityOccurrencesRemainIndependentAndDurable() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-acceptance-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID(), pageID = UUID()
    let store = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID)
    var napoleon = try await store.createEntity(KnowledgeFixtures.entities[0], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let russia = try await store.createEntity(KnowledgeFixtures.entities[1], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    var questionValue = SemanticObject(typeKey: "question")
    questionValue.unknownFields["futureObject"] = .object(["retained": .bool(true)])
    let question = try await store.createObject(questionValue, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let block = EditorBlock(runs: [RichRun("Why did Napoleon invade Russia?")])
    let sibling = EditorBlock(runs: [RichRun("The Napoleonic Wars")])
    let page = try await store.save(BlockDocument(blocks: [block, sibling]), pageID: pageID, condition: .createOnly)
    let questionID = UUID(), personID = UUID(), placeID = UUID()
    var person = SemanticAnnotation(id: personID, location: .inline(pageID: pageID, blockID: block.id, target: try InlineAnnotationTarget(text: block.text, range: NSRange(location: 8, length: 8), revision: page.revision.token)), referent: .init(identity: .init(kind: "person", id: napoleon.entity.id)), designation: "person", expectedRevision: page.revision.token)
    person.unknownFields["futureAnnotation"] = .array([.string("preserve")])
    person.referent.payload = .init(properties: ["futureReference": .bool(true)])
    let annotations = [
        SemanticAnnotation(id: questionID, location: .wholeBlock(pageID: pageID, blockID: block.id), referent: .init(identity: .init(kind: "question", id: question.object.id)), designation: "question", expectedRevision: page.revision.token),
        person,
        SemanticAnnotation(id: placeID, location: .inline(pageID: pageID, blockID: block.id, target: try InlineAnnotationTarget(text: block.text, range: NSRange(location: 24, length: 6), revision: page.revision.token)), referent: .init(identity: .init(kind: "place", id: russia.entity.id)), designation: "place", expectedRevision: page.revision.token)
    ]
    var semantic = try await store.saveSemanticPage(.init(pageID: pageID, document: page.document, annotations: annotations), condition: .replace(expected: page.revision), expectedObjectRevisions: [question.object.id: question.revision], expectedEntityRevisions: [napoleon.entity.id: napoleon.revision, russia.entity.id: russia.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(semantic.annotations.count == 3)
    #expect(try await store.loadObject(id: question.object.id).object.questionStatus == .unanswered)
    #expect(try await store.occurrences(entityID: napoleon.entity.id).map(\.annotation.id) == [personID])
    #expect(try await store.questions(entityID: napoleon.entity.id, association: .explicit).isEmpty)
    #expect(try await store.questions(entityID: napoleon.entity.id, association: .derivedOccurrences).map(\.object.id) == [question.object.id])
    napoleon = try await store.updateEntity(id: napoleon.entity.id, patch: .init(label: "Napoleon I"), expected: napoleon.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    var moved = semantic.snapshot.document
    moved.blocks.reverse()
    var bold = InlineStyle(); bold.bold = true
    moved.update(block.id) { $0.runs = [RichRun(block.text, style: bold)] }
    semantic = try await store.saveSemanticPage(.init(pageID: pageID, document: moved, annotations: semantic.annotations.map(\.annotation), expectedAnnotationRevisions: Dictionary(uniqueKeysWithValues: semantic.annotations.map { ($0.annotation.id, $0.revision) })), condition: .replace(expected: semantic.snapshot.revision), expectedObjectRevisions: [question.object.id: question.revision], expectedEntityRevisions: [napoleon.entity.id: napoleon.revision, russia.entity.id: russia.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(semantic.annotations.allSatisfy { $0.annotation.anchorDisposition == .resolved })
    var shifted = try semantic.replacingText(in: block.id, range: NSRange(location: 0, length: 0), with: [RichRun("In 1812, ")])
    semantic = try await store.saveSemanticPage(shifted, condition: .replace(expected: semantic.snapshot.revision), expectedObjectRevisions: [question.object.id: question.revision], expectedEntityRevisions: [napoleon.entity.id: napoleon.revision, russia.entity.id: russia.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    let shiftedPerson = try #require(semantic.annotations.first { $0.annotation.id == personID }).annotation
    guard case .inline(_, _, let target) = shiftedPerson.location else { Issue.record("Expected person inline location"); return }
    #expect(target.start == 17 && target.quote == "Napoleon")
    #expect(shiftedPerson.unknownFields == person.unknownFields)
    #expect(shiftedPerson.referent.payload == person.referent.payload)
    shifted = try semantic.replacingText(in: block.id, range: NSRange(location: 17, length: 8), with: [RichRun("Bonaparte")])
    semantic = try await store.saveSemanticPage(shifted, condition: .replace(expected: semantic.snapshot.revision), expectedObjectRevisions: [question.object.id: question.revision], expectedEntityRevisions: [napoleon.entity.id: napoleon.revision, russia.entity.id: russia.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(semantic.annotations.first { $0.annotation.id == personID }?.annotation.anchorDisposition == .stale)
    #expect(semantic.annotations.first { $0.annotation.id == questionID }?.annotation.anchorDisposition == .resolved)
    let unclassified = SemanticPageEdit(pageID: pageID, document: semantic.snapshot.document, annotations: semantic.annotations.filter { $0.annotation.id != questionID }.map(\.annotation), expectedAnnotationRevisions: Dictionary(uniqueKeysWithValues: semantic.annotations.map { ($0.annotation.id, $0.revision) }))
    // Classification removal is independent of the surviving semantic object.
    semantic = try await store.saveSemanticPage(unclassified, condition: .replace(expected: semantic.snapshot.revision), expectedObjectRevisions: [question.object.id: question.revision], expectedEntityRevisions: [napoleon.entity.id: napoleon.revision, russia.entity.id: russia.revision], expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
    #expect(semantic.annotations.first { $0.annotation.id == questionID }?.annotation.anchorDisposition == .deleted)
    #expect(semantic.annotations.first { $0.annotation.id == placeID }?.annotation.anchorDisposition == .resolved)
    #expect(try await store.loadObject(id: question.object.id) == question)
    try await store.close()
    let reopen = try VaultStorageProvider.plaintext.makeSemanticStagingStore(url: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopen.loadSemanticPage(pageID: pageID) == semantic)
    #expect(try await reopen.loadEntity(id: napoleon.entity.id) == napoleon)
    #expect(try await reopen.loadObject(id: question.object.id) == question)
    try await reopen.close()
}
