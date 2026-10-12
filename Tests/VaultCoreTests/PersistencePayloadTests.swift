import Foundation
import Testing
@testable import VaultCore

@Test func optionalJSONFieldsSurviveEveryDocumentScope() throws {
    let encoder = JSONEncoder(), decoder = JSONDecoder()
    var document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("text")])])
    let opaque: JSONValue = .object(["nested": .array([.null, .bool(true), .number(Decimal(12)), .string("value")])])
    document.unknownFields["futureDocument"] = opaque
    document.blocks[0].unknownFields["futureBlock"] = opaque
    document.blocks[0].metadata.unknownFields["futureMetadata"] = opaque
    document.blocks[0].runs[0].unknownFields["futureRun"] = opaque
    document.blocks[0].runs[0].style.unknownFields["futureStyle"] = opaque
    document.extensions = PersistencePayload(properties: ["custom": opaque])
    let saved = try encoder.encode(document)
    var read = try decoder.decode(BlockDocument.self, from: saved)
    #expect(read == document)
    read.blocks[0].runs[0].text = "edited"
    let second = try decoder.decode(BlockDocument.self, from: encoder.encode(read))
    #expect(second.blocks[0].runs[0].unknownFields["futureRun"] == opaque)
    #expect(second.blocks[0].runs[0].style.unknownFields["futureStyle"] == opaque)
    #expect(second.extensions == document.extensions)
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(document)) == document)
}

@Test func payloadAdmissionRejectsRequiredSemanticsCollisionsAndExcess() throws {
    var document = BlockDocument()
    document.extensions = PersistencePayload(version: 2)
    #expect(throws: PersistencePayloadError.unsupportedVersion(2)) { try document.validateWritablePayloads() }
    document.extensions = PersistencePayload(requiredFeatures: ["futureSemantics"])
    #expect(throws: PersistencePayloadError.requiredFeature("futureSemantics")) { try document.validateWritablePayloads() }
    document.extensions = PersistencePayload(properties: ["huge": .string(String(repeating: "x", count: 262_144))])
    #expect(throws: PersistencePayloadError.limitExceeded) { try document.validateWritablePayloads() }
    document.extensions = nil; document.unknownFields["blocks"] = .null
    #expect(throws: PersistencePayloadError.fieldCollision("blocks")) { _ = try JSONEncoder().encode(document) }
    document.unknownFields = [:]; document.blocks[0].kind = .init(rawValue: "unsupported")
    #expect(throws: PersistencePayloadError.unsupportedBlockKind("unsupported")) { try document.validateWritablePayloads() }
}

@Test func annotationUTF16AnchorsPreserveUnicodeAndFailAmbiguousReplacement() throws {
    let text = "A👩🏽‍💻e\u{301}Z"
    #expect(!InlineAnnotationTarget.validRange(NSRange(location: 2, length: 1), in: text))
    #expect(!InlineAnnotationTarget.validRange(NSRange(location: 8, length: 1), in: text))
    let range = NSRange(location: 1, length: "👩🏽‍💻".utf16.count)
    let revision = Data("opaque-revision".utf8)
    let target = try InlineAnnotationTarget(text: text, range: range, revision: revision)
    let owner = EditorBlock(runs: [RichRun(text)])
    let annotation = InlineAnnotation(pageID: UUID(), blockID: owner.id, designation: "term", expectedRevision: revision, target: target)
    var value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))
    if case .object(var fields) = value { fields["future"] = .array([.string("preserved")]); value = .object(fields) }
    var document = BlockDocument(blocks: [owner])
    document.extensions = PersistencePayload(requiredFeatures: ["annotationsV1"], properties: ["annotations": .array([value])])
    try document.validateWritablePayloads()
    var styled = document; styled.blocks[0].runs[0].style.bold = true
    #expect(styled.preparingAnnotationsForPersistence(comparedTo: document).extensions == document.extensions)
    var edited = document; edited.blocks[0].runs[0].text = "similar words"
    edited = edited.preparingAnnotationsForPersistence(comparedTo: document)
    try edited.validateWritablePayloads()
    guard case .array(let records) = edited.extensions?.properties["annotations"], case .object(let record) = records[0] else { Issue.record("Missing annotation"); return }
    #expect(record["disposition"] == .string("stale")); #expect(record["future"] == .array([.string("preserved")]))
    #expect(record["target"] != nil)
    edited = document; edited.blocks = []
    edited = edited.preparingAnnotationsForPersistence(comparedTo: document)
    guard case .array(let deleted) = edited.extensions?.properties["annotations"], case .object(let deletedRecord) = deleted[0] else { Issue.record("Missing deleted anchor"); return }
    #expect(deletedRecord["disposition"] == .string("deleted"))
}

@Test func annotationRevisionAndScopeAdmissionRejectReplay() throws {
    let pageID = UUID(), revision = BlockStoreRevision(token: Data("expected".utf8))
    let block = EditorBlock(runs: [RichRun("word")])
    let target = try InlineAnnotationTarget(text: block.text, range: NSRange(location: 0, length: 4), revision: revision.token)
    let annotation = InlineAnnotation(pageID: pageID, blockID: block.id, designation: "term", expectedRevision: revision.token, target: target)
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))
    var document = BlockDocument(blocks: [block]); document.extensions = PersistencePayload(properties: ["annotations": .array([value])])
    try document.validatingAnnotations(pageID: pageID, expectedRevision: revision)
    #expect(throws: PersistencePayloadError.invalidAnnotation) { try document.validatingAnnotations(pageID: UUID(), expectedRevision: revision) }
    #expect(throws: PersistencePayloadError.invalidAnnotation) { try document.validatingAnnotations(pageID: pageID, expectedRevision: .init(token: Data("wrong".utf8))) }
    let next = BlockStoreRevision(token: Data("next".utf8))
    let advanced = document.advancingAnnotationRevision(to: next)
    try advanced.validateWritablePayloads(); try advanced.validatingAnnotations(pageID: pageID, expectedRevision: next)
    document.blocks[0].extensions = PersistencePayload(requiredFeatures: ["annotationsV1"])
    #expect(throws: PersistencePayloadError.requiredFeature("annotationsV1")) { try document.validateWritablePayloads() }
}

@Test func requiredFutureEnvelopeRemainsPreservationOnly() {
    var document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("original")])])
    document.extensions = PersistencePayload(version: 42, properties: ["future": .object(["value": .bool(true)])])
    let source = BlockDocumentCodec.encode(document), read = BlockDocumentCodec.decode(source)
    #expect(read.unsupportedVersion)
    #expect(read.extensions == document.extensions)
    #expect(BlockDocumentCodec.encode(read) == source)
}
