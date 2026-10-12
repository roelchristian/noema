import AppKit
import Testing
import VaultCore
@testable import noema

@Suite("EDT.BLK04 incremental block rendering", .serialized)
@MainActor struct IncrementalBlockRenderingTests {
    @Test func nativeEditShiftsIndexedUTF16Offsets() throws {
        let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("A😀")]), EditorBlock(runs: [RichRun("Next")])])
        let storage = NSMutableAttributedString(attributedString: BlockTextStorage.render(document, theme: NoemaTheme()))
        let index = BlockTextStorage.RangeIndex(storage)
        let first = document.blocks[0].id, second = document.blocks[1].id
        #expect(index.range(for: second)?.location == 4)
        storage.replaceCharacters(in: NSRange(location: 1, length: 2), with: "é中")
        index.applyLocalEdit(blockID: first, delta: 0)
        #expect(index.range(for: second)?.location == 4)
        storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "👨‍👩‍👧")
        index.applyLocalEdit(blockID: first, delta: "👨‍👩‍👧".utf16.count)
        #expect(index.ordered.map(\.1) == BlockTextStorage.ranges(storage).map(\.1))
        #expect(index.block(at: try #require(index.range(for: second)).location)?.0 == second)
        #expect(index.block(at: storage.length) == nil)
    }

    @Test func changedBlockKeepsUnrelatedAttributesAndMatchesFullRender() throws {
        var before = BlockDocument(blocks: [EditorBlock(kind: .heading1, runs: [RichRun("Title")]), EditorBlock(runs: [RichRun("Body")]), EditorBlock(runs: [RichRun("Tail")])])
        before.blocks[0].metadata.semantic = "idea"
        let storage = NSMutableAttributedString(attributedString: BlockTextStorage.render(before, theme: NoemaTheme(), showSemanticHeadings: true))
        let index = BlockTextStorage.RangeIndex(storage)
        let sentinel = NSAttributedString.Key("test.unrelated")
        let head = try #require(index.range(for: before.blocks[0].id))
        storage.addAttribute(sentinel, value: "retained", range: head)
        var after = before
        after.update(before.blocks[1].id) { $0.runs = [RichRun("Body extended 😀")] }
        let affected = BlockTextStorage.apply(document: after, previous: before, to: storage, index: index, theme: NoemaTheme(), showSemanticHeadings: true)
        #expect(affected.location == NSMaxRange(head))
        #expect(storage.attribute(sentinel, at: 0, effectiveRange: nil) as? String == "retained")
        let full = BlockTextStorage.render(after, theme: NoemaTheme(), showSemanticHeadings: true)
        #expect(storage.string == full.string)
        for (id, range) in index.ordered {
            let actual = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let expected = full.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(actual == expected)
            #expect(index.range(for: id) == range)
        }
        #expect(BlockTextStorage.capture(storage, previous: after) == after)
    }

    @Test func structuralDeletionAndInsertionRebuildIndex() throws {
        let before = BlockDocument(blocks: [EditorBlock(runs: [RichRun("One")]), EditorBlock(runs: [RichRun("Two")]), EditorBlock(runs: [RichRun("Three")])])
        let storage = NSMutableAttributedString(attributedString: BlockTextStorage.render(before, theme: NoemaTheme()))
        let index = BlockTextStorage.RangeIndex(storage)
        var after = before
        after.blocks.remove(at: 1)
        BlockTextStorage.apply(document: after, previous: before, to: storage, index: index, theme: NoemaTheme())
        #expect(index.range(for: before.blocks[1].id) == nil)
        #expect(storage.string == BlockTextStorage.render(after, theme: NoemaTheme()).string)
        var inserted = after
        inserted.blocks.insert(EditorBlock(kind: .heading2, runs: [RichRun("Inserted")]), at: 1)
        BlockTextStorage.apply(document: inserted, previous: after, to: storage, index: index, theme: NoemaTheme())
        #expect(index.count == 3)
        #expect(index.ordered.map(\.1) == BlockTextStorage.ranges(storage).map(\.1))
        #expect(storage.isEqual(to: BlockTextStorage.render(inserted, theme: NoemaTheme())))
    }
}
