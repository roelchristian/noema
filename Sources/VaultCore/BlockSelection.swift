import Foundation

extension BlockDocument {
    /// Selected roots in document order. A selected ancestor owns its complete subtree.
    public func normalizedSelection(_ ids: Set<UUID>) -> [UUID] {
        func visit(_ list: [EditorBlock]) -> [UUID] {
            list.flatMap { block in ids.contains(block.id) ? [block.id] : visit(block.children) }
        }
        return visit(blocks)
    }

    /// Copy/export uses these roots, retaining children once and preserving source order.
    public func selectedBlocks(_ ids: Set<UUID>) -> [EditorBlock] {
        normalizedSelection(ids).compactMap { block($0) }
    }

    /// The caller records one before/after document snapshot for one undo registration.
    /// Invalid structural targets leave the complete document unchanged.
    @discardableResult public mutating func apply(_ command: BlockMutation, to ids: Set<UUID>) -> BlockCursor? {
        guard !unsupportedVersion, ids.allSatisfy({ block($0) != nil }) else { return nil }
        let roots = normalizedSelection(ids), selected = Set(roots)
        guard let first = roots.first else { return nil }
        var next = self
        var cursor = BlockCursor(first)
        switch command {
        case .transform, .semantic, .status, .checked, .collapse, .language:
            func subtreeIDs(_ list: [EditorBlock]) -> [UUID] { list.flatMap { [$0.id] + subtreeIDs($0.children) } }
            for id in subtreeIDs(selectedBlocks(selected)) { _ = next.apply(command, to: id) }
        case .delete, .duplicate:
            var firstCopy: UUID?
            func edit(_ list: [EditorBlock]) -> [EditorBlock] {
                list.flatMap { block -> [EditorBlock] in
                    if selected.contains(block.id) {
                        if case .delete = command { return [] }
                        let copy = block.renewedIdentity()
                        if firstCopy == nil { firstCopy = copy.id }
                        return [block, copy]
                    }
                    var value = block; value.children = edit(block.children)
                    if value.children != block.children { value.modifiedAt = Date() }
                    return [value]
                }
            }
            next.blocks = edit(blocks)
            if next.blocks.isEmpty { next.blocks = [EditorBlock()] }
            cursor = BlockCursor(firstCopy ?? next.flattened.first!.id)
        case .move, .reorder, .reorderAfter:
            let parent = selectionParent(first)
            guard roots.allSatisfy({ selectionParent($0) == parent }) else { return nil }
            var destination: UUID?
            var delta = 0
            var after = false
            switch command {
            case .move(let amount): delta = amount
            case .reorder(let id): destination = id
            case .reorderAfter(let id): destination = id; after = true
            default: break
            }
            if let destination {
                guard !selected.contains(destination), block(destination) != nil,
                      selectionParent(destination) == parent else { return nil }
            }
            next.editSelectionSiblings(parent: parent) { list in
                if let destination {
                    let moving = list.filter { selected.contains($0.id) }
                    list.removeAll { selected.contains($0.id) }
                    let insertion = list.firstIndex { $0.id == destination }! + (after ? 1 : 0)
                    list.insert(contentsOf: moving, at: insertion)
                } else {
                    // Stable adjacent swaps support discontiguous selections and preserve
                    // both selected and unselected order without crossing parent boundaries.
                    let steps = min(delta.magnitude, UInt(list.count))
                    for _ in 0..<steps {
                        if delta > 0, list.count > 1 {
                            for index in stride(from: list.count - 2, through: 0, by: -1)
                            where selected.contains(list[index].id) && !selected.contains(list[index + 1].id) {
                                list.swapAt(index, index + 1)
                            }
                        } else if delta < 0, list.count > 1 {
                            for index in 1..<list.count
                            where selected.contains(list[index].id) && !selected.contains(list[index - 1].id) {
                                list.swapAt(index, index - 1)
                            }
                        }
                    }
                }
            }
        default:
            // Text-specific and nesting commands require a single explicit root.
            guard roots.count == 1, let result = next.apply(command, to: first) else { return nil }
            cursor = result
        }
        guard next.blocks != blocks else { return nil }
        next.originalSource = nil
        self = next
        return cursor
    }

    private func selectionParent(_ id: UUID) -> UUID? {
        func visit(_ list: [EditorBlock], parent: UUID?) -> UUID? {
            for block in list {
                if block.id == id { return parent }
                if block.children.contains(where: { $0.id == id }) { return block.id }
                if let found = visit(block.children, parent: block.id) { return found }
            }
            return nil
        }
        return visit(blocks, parent: nil)
    }

    private mutating func editSelectionSiblings(parent: UUID?, _ edit: (inout [EditorBlock]) -> Void) {
        if let parent { _ = update(parent) { edit(&$0.children) } }
        else { edit(&blocks) }
    }
}
