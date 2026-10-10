import Foundation
import Testing
@testable import VaultCore

@Test func blockModelRoundTripsRichTextAndNestedMetadata() throws {
    var style = InlineStyle(); style.bold = true; style.italic = true; style.underline = true; style.strike = true; style.highlight = true; style.link = "https://example.com"
    var metadata = BlockMetadata(); metadata.semantic = "question"; metadata.status = "answered"; metadata.extra["future"] = "kept"
    let child = EditorBlock(kind: .task, runs: [RichRun("child")], metadata: metadata)
    let parent = EditorBlock(kind: .heading2, runs: [RichRun("😀研究", style: style)], metadata: metadata, children: [child])
    let document = BlockDocument(blocks: [parent])
    let source = BlockDocumentCodec.encode(document)
    #expect(source.hasPrefix("## "))
    #expect(BlockDocumentCodec.decode(source) == document)
    #expect(BlockDocumentCodec.valid(document))
    let future = EditorBlock(kind: .init(rawValue: "future-kind"), runs: [RichRun("recoverable")])
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(BlockDocument(blocks: [future]))).blocks.first == future)
}

@Test func blockMarkdownCompatibilityAndExternalChanges() {
    for source in ["", "\n", "# Title\n\nHello **bold** and *italic*. [[Rome|the city]]\n", "- First\n    - Second\n        - Third\n", "```swift\nlet x = 1\n\nprint(x)\n```\n", "| A | B |\n|---|---|\n| 1 | 2 |\n", "<details>unsupported HTML</details>\n", "![original image](photo.png)", "trailing  \n", "~~~\nunclosed"] {
        let document = BlockDocumentCodec.decode(source)
        #expect(BlockDocumentCodec.encode(document) == source)
    }
    var document = BlockDocumentCodec.decode("- Parent\n    - Child\n"); let id = document.blocks[0].id
    _ = document.apply(.semantic("question"), to: id)
    let saved = BlockDocumentCodec.encode(document)
    let changed = saved.replacingOccurrences(of: "Parent", with: "External edit")
    let reload = BlockDocumentCodec.decode(changed)
    #expect(reload.blocks[0].text == "External edit")
    #expect(reload.recoveredMetadata != nil)
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(reload)).recoveredMetadata != nil)
}

@Test func blockCommandsPreserveRunsAndTreeIdentity() {
    var style = InlineStyle(); style.bold = true
    let a = EditorBlock(runs: [RichRun("ab😀cd", style: style)], children: [EditorBlock(runs: [RichRun("nested")])])
    let b = EditorBlock(kind: .bullet, runs: [RichRun("second")])
    var document = BlockDocument(blocks: [a, b])
    _ = document.apply(.semantic("starred"), to: a.id)
    _ = document.apply(.transform(.heading2), to: a.id)
    #expect(document.blocks[0].id == a.id)
    #expect(document.blocks[0].runs == a.runs)
    #expect(document.blocks[0].children == a.children)
    #expect(document.blocks[0].metadata.semantic == "starred")
    let next = document.apply(.split(4), to: a.id)!
    #expect(document.blocks[0].text == "ab😀")
    #expect(document.block(next.id)?.text == "cd")
    #expect(document.block(next.id)?.runs.first?.style.bold == true)
    #expect(document.blocks[0].children == a.children)
    _ = document.apply(.mergeBackward, to: next.id)
    #expect(document.blocks[0].text == a.text)
    #expect(document.blocks[0].children == a.children)
    let duplicate = document.apply(.duplicate, to: a.id)!
    #expect(document.block(duplicate.id)?.children.first?.id != a.children.first?.id)
    #expect(BlockDocumentCodec.valid(document))
    _ = document.apply(.delete, to: duplicate.id)
    _ = document.apply(.indent, to: b.id)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].children.last?.id == b.id)
    _ = document.apply(.outdent, to: b.id)
    #expect(document.blocks.last?.id == b.id)
    _ = document.apply(.reorder(before: a.id), to: b.id)
    #expect(document.blocks.first?.id == b.id)
    #expect(document.apply(.reorder(before: a.children[0].id), to: b.id) == nil)
}

@Test func emptyListExitAndStructuralBackspace() {
    let item = EditorBlock(kind: .task)
    var document = BlockDocument(blocks: [item])
    _ = document.apply(.split(0), to: item.id)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].kind == .paragraph)
    _ = document.apply(.transform(.quote), to: item.id)
    _ = document.apply(.mergeBackward, to: item.id)
    #expect(document.blocks[0].kind == .paragraph)
    _ = document.apply(.delete, to: item.id)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].id != item.id)
}

@Test func blockFutureFormatAndMalformedDataRemainRecoverable() throws {
    let newer: [String: Any] = ["version": 2, "document": ["differentSchema": true]]
    let source = "Visible text\n<!--noema:document:" + (try JSONSerialization.data(withJSONObject: newer)).base64EncodedString() + "-->"
    var decoded = BlockDocumentCodec.decode(source)
    #expect(decoded.unsupportedVersion)
    #expect(BlockDocumentCodec.encode(decoded) == source)
    #expect(decoded.apply(.delete, to: decoded.blocks[0].id) == nil)
    let malformed = "Visible\n<!--noema:document:broken-->"
    #expect(BlockDocumentCodec.encode(BlockDocumentCodec.decode(malformed)) == malformed)
    let first = EditorBlock(runs: [RichRun("First")]), second = EditorBlock(runs: [RichRun("Second")])
    var document = BlockDocument(blocks: [first, second])
    _ = document.apply(.reorderAfter(second.id), to: first.id)
    #expect(document.blocks.last?.id == first.id)
    #expect(document.canReorder(first.id, before: second.id))
}

@Test func markdownIndentationAndRepeatedLegacyIDsStaySafe() {
    for source in ["- Parent\n  - Child\n    - Grandchild\n- Sibling\n", "- Parent\n\t- Child\n\t\t- Grandchild\n- Sibling\n"] {
        var document = BlockDocumentCodec.decode(source)
        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].children[0].children[0].text == "Grandchild")
        #expect(BlockDocumentCodec.encode(document) == source)
        _ = document.apply(.semantic("question"), to: document.blocks[1].id)
        #expect(BlockDocumentCodec.readable(document) == source)
        #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(document)) == document)
    }
    let id = UUID().uuidString
    let repeated = "First <!--noema:block:\(id):question-->\nSecond <!--noema:block:\(id):idea-->"
    let document = BlockDocumentCodec.decode(repeated)
    #expect(BlockDocumentCodec.valid(document))
    #expect(document.blocks[0].metadata.semantic == "question")
    #expect(document.blocks[1].metadata.semantic == "idea")
}
