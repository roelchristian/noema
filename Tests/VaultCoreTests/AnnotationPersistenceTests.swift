import Foundation
import Testing
@testable import VaultCore

private let anchorRevision = BlockStoreRevision(token: Data("revision-1".utf8))
private func anchorDocument(_ text: String = "ab😀cdef", ranges: [NSRange] = [NSRange(location: 2, length: 3)]) throws -> BlockDocument {
    let block = EditorBlock(runs: [RichRun(text)]), pageID = UUID()
    var document = BlockDocument(blocks: [block]); document.extensions = .init(requiredFeatures: ["annotationsV1"])
    document.extensions?.properties["annotations"] = .array(try ranges.map { range in
        var annotation = InlineAnnotation(pageID: pageID, blockID: block.id, designation: "semantic", expectedRevision: anchorRevision.token,
            target: try InlineAnnotationTarget(text: text, range: range, revision: anchorRevision.token))
        annotation.targetEntity = .init(kind: "source", id: UUID())
        annotation.payload = .init(properties: ["provenance": .string("accepted")])
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))
    })
    return document
}
private func anchors(_ document: BlockDocument) throws -> [InlineAnnotation] {
    guard case .array(let values) = document.extensions?.properties["annotations"] else { return [] }
    return try values.map { try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode($0)) }
}

@Test func annotationExactEditsHonorAffinitiesAndUnicodeWithoutNormalizing() throws {
    for (offset, expectedStart, expectedEnd, quote) in [(0, 3, 6, "😀c"), (2, 3, 6, "😀c"), (4, 2, 6, "😀Xc"), (5, 2, 5, "😀c"), (8, 2, 5, "😀c")] {
        var document = try anchorDocument(), prior = document
        let original = try anchors(prior)[0]
        try document.replaceText(in: document.blocks[0].id, range: NSRange(location: offset, length: 0), with: "X", expectedRevision: anchorRevision)
        let anchor = try anchors(document.preparingAnnotationsForPersistence(comparedTo: prior))[0]
        #expect(anchor.id == original.id && anchor.targetEntity == original.targetEntity)
        #expect(anchor.payload == original.payload && anchor.disposition == .resolved)
        #expect(anchor.target.start == expectedStart && anchor.target.end == expectedEnd && anchor.target.quote == quote)
        try document.validateWritablePayloads()
        prior = document
        #expect(try anchors(prior)[0].target.quote == quote)
    }
    var unicode = try anchorDocument("e\u{301}👩🏽‍🚀z", ranges: [NSRange(location: 0, length: 2)])
    let before = unicode
    #expect(throws: PersistencePayloadError.self) { try unicode.replaceText(in: unicode.blocks[0].id, range: NSRange(location: 1, length: 0), with: "x", expectedRevision: anchorRevision) }
    #expect(unicode == before)
    #expect(unicode.apply(.split(3), to: unicode.blocks[0].id) == nil)
    #expect(unicode == before)
    #expect(throws: PersistencePayloadError.self) { try unicode.replaceText(in: unicode.blocks[0].id, range: NSRange(location: 0, length: 0), with: "x", expectedRevision: .init(token: Data("other".utf8))) }
    #expect(unicode == before)
}

@Test func annotationDeletionAndBareReplacementPreserveOriginalEvidence() throws {
    var document = try anchorDocument(), previous = document
    let original = try anchors(document)[0]
    try document.replaceText(in: document.blocks[0].id, range: NSRange(location: 2, length: 2), with: "", expectedRevision: anchorRevision)
    let stale = try anchors(document)[0]
    #expect(stale.disposition == .stale && stale.target == original.target && stale.expectedRevision == original.expectedRevision)
    var bare = previous
    bare.update(bare.blocks[0].id) { $0.runs = [RichRun("ab😀changed")] }
    #expect(try anchors(bare.preparingAnnotationsForPersistence(comparedTo: previous))[0].disposition == .stale)
    // Tampering after an exact transformation invalidates its process-local evidence.
    previous = try anchorDocument()
    document = previous
    try document.replaceText(in: document.blocks[0].id, range: NSRange(location: 0, length: 0), with: "X", expectedRevision: anchorRevision)
    document.update(document.blocks[0].id) { $0.runs = [RichRun("tampered")] }
    #expect(try anchors(document.preparingAnnotationsForPersistence(comparedTo: previous))[0].disposition == .stale)
    var deleted = previous
    deleted.apply(.delete, to: deleted.blocks[0].id)
    #expect(try anchors(deleted)[0].disposition == .deleted)
    #expect(try anchors(deleted)[0].target == (try anchors(previous)[0].target))
}

@Test func annotationSplitMergeMoveAndDuplicateRetainIdentitiesAndProvenance() throws {
    var document = try anchorDocument("abcdef", ranges: [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2), NSRange(location: 1, length: 4)])
    let original = try anchors(document), previous = document, owner = document.blocks[0].id
    let splitResult = document.apply(.split(3), to: owner)
    let suffix = try #require(splitResult).id
    let split = try anchors(document.preparingAnnotationsForPersistence(comparedTo: previous))
    #expect(split.map(\.id) == original.map(\.id))
    #expect(split[0].blockID == owner && split[0].target.start == 0)
    #expect(split[1].blockID == suffix && split[1].target.start == 1)
    #expect(split[2].disposition == .stale && split[2].target == original[2].target)
    document.apply(.mergeBackward, to: suffix)
    let merged = try anchors(document.preparingAnnotationsForPersistence(comparedTo: previous))
    #expect(merged[1].blockID == owner && merged[1].target.start == 4 && merged[1].disposition == .resolved)
    let duplicateResult = document.apply(.duplicate, to: owner)
    let duplicateID = try #require(duplicateResult).id
    let copied = try anchors(document)
    #expect(copied.count == 6 && Set(copied.map(\.id)).count == 6)
    #expect(copied[1].blockID == duplicateID && copied[1].targetEntity == nil)
    #expect(copied[1].payload?.properties["copiedFromAnnotationID"] == .string(original[0].id.uuidString))
    document.apply(.move(-1), to: duplicateID)
    #expect(try anchors(document).map(\.target) == copied.map(\.target))
    try document.validateWritablePayloads()
}

@Test func annotationTransformsPreserveUnknownRecordsTargetsAndRunScopes() throws {
    var document = try anchorDocument("abcd", ranges: [NSRange(location: 2, length: 2)])
    document.blocks[0].runs[0].unknownFields["futureRun"] = .object(["v": .number(3)])
    document.blocks[0].runs[0].style.unknownFields["futureStyle"] = .string("preserved")
    if case .array(var values) = document.extensions?.properties["annotations"], case .object(var fields) = values[0], case .object(var target) = fields["target"] {
        fields["futureAnnotation"] = .bool(true); target["futureTarget"] = .string("preserved"); fields["target"] = .object(target); values[0] = .object(fields)
        document.extensions?.properties["annotations"] = .array(values)
    }
    let previous = document
    document.apply(.split(2), to: document.blocks[0].id)
    #expect(document.blocks.allSatisfy { $0.runs[0].unknownFields["futureRun"] != nil && $0.runs[0].style.unknownFields["futureStyle"] != nil })
    if case .array(let values) = document.preparingAnnotationsForPersistence(comparedTo: previous).extensions?.properties["annotations"], case .object(let fields) = values[0], case .object(let target) = fields["target"] {
        #expect(fields["futureAnnotation"] == .bool(true) && target["futureTarget"] == .string("preserved"))
    } else { Issue.record("Missing annotation fields") }
}

@Test func annotationPublicationAdvancesExactRevisionAtomicallyAndReopens() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-persistence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("canonical.sqlite"), vaultID = UUID()
    let store = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID)
    var document = try anchorDocument()
    let initial = try anchors(document)[0]
    let pageID = initial.pageID
    var annotation = initial
    annotation.expectedRevision = Data()
    annotation.target = try InlineAnnotationTarget(text: document.blocks[0].text, range: NSRange(location: 2, length: 3), revision: Data())
    document.extensions?.properties["annotations"] = .array([try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))])
    let created = try await store.save(document, pageID: pageID, condition: .createOnly)
    document = created.document
    try document.replaceText(in: document.blocks[0].id, range: NSRange(location: 0, length: 0), with: "X", expectedRevision: created.revision)
    let saved = try await store.save(document, pageID: pageID, condition: .replace(expected: created.revision))
    #expect(try anchors(saved.document)[0].disposition == .resolved)
    #expect(try anchors(saved.document)[0].expectedRevision == saved.revision.token)
    #expect(try anchors(saved.document)[0].target.start == 3)
    await #expect(throws: VaultError.self) { try await store.save(document, pageID: pageID, condition: .replace(expected: created.revision)) }
    try await store.close()
    let reopened = try SQLiteBlockStore(canonicalStagingURL: url, vaultID: vaultID, createIfMissing: false)
    #expect(try await reopened.load(pageID: pageID) == saved)
    try await reopened.close()
}

@Test func annotationUnknownMergedOwnerSemanticsFailClosed() throws {
    var document = try anchorDocument()
    document.blocks.insert(EditorBlock(runs: [RichRun("prefix")]), at: 0)
    document.blocks[1].unknownFields["futureBlock"] = .string("opaque")
    let previous = document
    #expect(document.apply(.mergeBackward, to: document.blocks[1].id) == nil)
    #expect(document == previous)
}
