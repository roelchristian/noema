import Foundation
import Testing
@testable import VaultCore

private enum NapoleonicSemanticFixture {
    static let pageID = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
    static let blockID = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
    static let revision = BlockStoreRevision(token: Data("napoleonic-fixture-1".utf8))
    static let text = "Napoleon invaded Russia."

    static func document() throws -> BlockDocument {
        var block = EditorBlock(runs: [RichRun(text)])
        block.id = blockID
        var document = BlockDocument(blocks: [block])
        // Nested, overlapping and identical ranges have independent identities.
        let ranges = [NSRange(location: 0, length: 8), NSRange(location: 17, length: 6),
                      NSRange(location: 0, length: 23), NSRange(location: 0, length: 8),
                      NSRange(location: 6, length: 13)]
        document.extensions = .init(requiredFeatures: ["annotationsV1"])
        document.extensions?.properties["annotations"] = .array(try ranges.enumerated().map { index, range in
            var annotation = InlineAnnotation(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 30 + index))!,
                pageID: pageID, blockID: blockID, designation: "semantic",
                expectedRevision: revision.token,
                target: try InlineAnnotationTarget(text: text, range: range, revision: revision.token))
            annotation.createdAt = KnowledgeFixtures.timestamp
            annotation.modifiedAt = KnowledgeFixtures.timestamp
            return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(annotation))
        })
        return document
    }

    static func annotations(_ document: BlockDocument) throws -> [InlineAnnotation] {
        guard case .array(let values) = document.extensions?.properties["annotations"] else { return [] }
        return try values.map { try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode($0)) }
    }
}

@Test func napoleonicOverlappingAnchorsTransformIndependently() throws {
    var document = try NapoleonicSemanticFixture.document()
    let previous = document
    let original = try NapoleonicSemanticFixture.annotations(document)
    #expect(original[0].target.quote == "Napoleon")
    #expect(original[1].target.quote == "Russia")
    #expect(original[0].target == original[3].target)
    #expect(Set(original.map(\.id)).count == 5)
    try document.replaceText(in: NapoleonicSemanticFixture.blockID,
                             range: NSRange(location: 0, length: 0), with: "In 1812, ",
                             expectedRevision: NapoleonicSemanticFixture.revision)
    let transformed = try NapoleonicSemanticFixture.annotations(document.preparingAnnotationsForPersistence(comparedTo: previous))
    #expect(transformed.map(\.id) == original.map(\.id))
    #expect(transformed.map(\.target.quote) == original.map(\.target.quote))
    #expect(transformed.map(\.target.start) == original.map { $0.target.start + 9 })
    #expect(transformed.allSatisfy { $0.disposition == .resolved })
    try document.validateWritablePayloads()
}

@Test func napoleonicFormattingPreservesAnchorEvidenceWithoutCreatingReferences() throws {
    var document = try NapoleonicSemanticFixture.document()
    let previous = document
    let original = try NapoleonicSemanticFixture.annotations(document)
    var emphasis = InlineStyle(); emphasis.bold = true; emphasis.highlight = true
    document.update(NapoleonicSemanticFixture.blockID) {
        $0.runs = [RichRun("Napoleon", style: emphasis), RichRun(" invaded Russia.")]
    }
    let preserved = document.preparingAnnotationsForPersistence(comparedTo: previous)
    #expect(try NapoleonicSemanticFixture.annotations(preserved) == original)
    #expect(original.allSatisfy { $0.targetEntity == nil })
    #expect(preserved.blocks[0].text == NapoleonicSemanticFixture.text)
    try preserved.validateWritablePayloads()
}
