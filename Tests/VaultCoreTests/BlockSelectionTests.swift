import Foundation
import Testing
@testable import VaultCore

@Test func blockSelectionDeduplicatesSubtreesInDocumentOrder() {
    let child = EditorBlock(runs: [RichRun("child")])
    let parent = EditorBlock(runs: [RichRun("parent")], children: [child])
    let last = EditorBlock(runs: [RichRun("last")])
    let document = BlockDocument(blocks: [parent, last])
    let selection: Set<UUID> = [last.id, child.id, parent.id, UUID()]
    #expect(document.normalizedSelection(selection) == [parent.id, last.id])
    #expect(document.selectedBlocks(selection) == [parent, last])
}

@Test func blockSelectionMovesPreserveIdentityAndRelativeOrder() {
    let blocks = (0..<5).map { EditorBlock(runs: [RichRun("\($0)")]) }
    var document = BlockDocument(blocks: blocks)
    let selection: Set<UUID> = [blocks[1].id, blocks[3].id]
    #expect(document.apply(.move(1), to: selection) != nil)
    #expect(document.blocks.map(\.id) == [blocks[0], blocks[2], blocks[1], blocks[4], blocks[3]].map(\.id))
    #expect(document.apply(.reorder(before: blocks[0].id), to: selection) != nil)
    #expect(document.blocks.map(\.id) == [blocks[1], blocks[3], blocks[0], blocks[2], blocks[4]].map(\.id))
    #expect(document.blocks.first == blocks[1])
    #expect(document.apply(.reorderAfter(blocks[4].id), to: selection) != nil)
    #expect(document.blocks.map(\.id) == [blocks[0], blocks[2], blocks[4], blocks[1], blocks[3]].map(\.id))
}

@Test func blockSelectionRejectsMixedParentsStaleIDsAndSelectedTargetsAtomically() {
    let child = EditorBlock(runs: [RichRun("child")])
    let parent = EditorBlock(children: [child]), sibling = EditorBlock()
    var document = BlockDocument(blocks: [parent, sibling])
    document.originalSource = "preserved bytes"
    let before = document
    #expect(document.apply(.move(1), to: Set([child.id, sibling.id])) == nil)
    #expect(document.apply(.reorder(before: child.id), to: Set([parent.id, sibling.id])) == nil)
    #expect(document.apply(.reorder(before: sibling.id), to: Set([parent.id, sibling.id])) == nil)
    #expect(document.apply(.delete, to: Set([parent.id, UUID()])) == nil)
    #expect(document == before)
}

@Test func blockSelectionDuplicationRenewsEveryIdentityWithoutOverlap() {
    var metadata = BlockMetadata(); metadata.semantic = "future-label"; metadata.extra["future"] = "preserved"
    let grandchild = EditorBlock(runs: [RichRun("grandchild")], metadata: metadata)
    let child = EditorBlock(children: [grandchild])
    let parent = EditorBlock(runs: [RichRun("parent")], children: [child]), last = EditorBlock()
    var document = BlockDocument(blocks: [parent, last])
    let selection: Set<UUID> = [parent.id, child.id, grandchild.id, last.id]
    let cursor = document.apply(.duplicate, to: selection)
    #expect(document.blocks.count == 4)
    #expect(cursor?.id == document.blocks[1].id)
    #expect(document.blocks[0] == parent)
    #expect(document.blocks[1].children[0].children[0].metadata == metadata)
    #expect(document.flattened.count == 8)
    #expect(BlockDocumentCodec.valid(document))
    let originalIDs = Set([parent.id, child.id, grandchild.id, last.id])
    let copies = BlockDocument(blocks: [document.blocks[1], document.blocks[3]])
    #expect(Set(copies.flattened.map(\.id)).isDisjoint(with: originalIDs))
}

@Test func blockSelectionDeleteOwnsSubtreesAndKeepsAnEditableDocument() {
    let child = EditorBlock(), parent = EditorBlock(children: [EditorBlock()]), last = EditorBlock()
    var document = BlockDocument(blocks: [parent, child, last])
    #expect(document.apply(.delete, to: Set([parent.id, parent.children[0].id, child.id])) != nil)
    #expect(document.blocks == [last])
    #expect(document.apply(.delete, to: Set([last.id])) != nil)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].id != last.id)
}

@Test func blockSelectionTransformIncludesSubtreesAndPreservesMetadataAndText() {
    var metadata = BlockMetadata(); metadata.semantic = "future-label"; metadata.status = "future-status"
    let child = EditorBlock(runs: [RichRun("nested")], metadata: metadata)
    let parent = EditorBlock(runs: [RichRun("parent")], metadata: metadata, children: [child])
    var document = BlockDocument(blocks: [parent])
    #expect(document.apply(.transform(.heading2), to: Set([parent.id, child.id])) != nil)
    #expect(document.flattened.map(\.id) == [parent.id, child.id])
    #expect(document.flattened.map(\.text) == ["parent", "nested"])
    #expect(document.flattened.allSatisfy { $0.kind == .heading2 && $0.metadata == metadata })
}

@Test func blockSelectionBoundaryMovesPreserveTimestampsAndSource() {
    let child = EditorBlock(), parent = EditorBlock(children: [child])
    var document = BlockDocument(blocks: [parent])
    document.originalSource = "original"
    let before = document
    #expect(document.apply(.move(Int.min), to: Set([child.id])) == nil)
    #expect(document.apply(.move(0), to: Set([parent.id])) == nil)
    #expect(document == before)
}

@Test func blockSelectionValueSnapshotsRestoreEntireAtomicChange() {
    let a = EditorBlock(children: [EditorBlock()]), b = EditorBlock()
    var document = BlockDocument(blocks: [a, b])
    let before = document
    #expect(document.apply(.duplicate, to: Set([a.id, b.id])) != nil)
    let after = document
    document = before
    #expect(document.blocks == [a, b])
    document = after
    #expect(document.blocks.count == 4)
    #expect(BlockDocumentCodec.valid(document))
}
