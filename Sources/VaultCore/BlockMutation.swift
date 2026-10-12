import Foundation

public enum BlockMutation: Sendable {
    case transform(BlockKind), semantic(String?), status(String?), checked, collapse, language(String?)
    case split(Int), mergeBackward, duplicate, delete, removeKeepingChildren, move(Int), indent, outdent
    case reorder(before: UUID), reorderAfter(UUID)
}

public struct BlockCursor: Equatable, Sendable {
    public var id: UUID
    public var offset: Int
    public init(_ id: UUID, offset: Int = 0) { self.id = id; self.offset = offset }
}

extension BlockDocument {
    // Every structural operation is atomic on the value document, including entire subtrees.
    @discardableResult public mutating func apply(_ command: BlockMutation, to id: UUID) -> BlockCursor? {
        guard !unsupportedVersion, let path = path(to: id) else { return nil }
        let before = blocks
        var cursor = BlockCursor(id)
        switch command {
        case .transform(let kind): update(id) { $0.kind = kind }
        case .semantic(let semantic): update(id) { if $0.metadata.semantic != semantic { $0.metadata.status = nil }; $0.metadata.semantic = semantic }
        case .status(let status): update(id) { $0.metadata.status = status }
        case .checked: update(id) { $0.metadata.checked.toggle() }
        case .collapse: update(id) { $0.metadata.collapsed.toggle() }
        case .language(let language): update(id) { $0.metadata.language = language }
        case .split(let requested):
            siblings(at: Array(path.dropLast())) { list in
                let index = path.last!, block = list[index], offset = min(max(requested, 0), block.utf16Count)
                if block.text.isEmpty && block.kind.isList { list[index].kind = .paragraph; return }
                var next = EditorBlock(kind: block.kind.isList ? block.kind : .paragraph, runs: block.slicing(NSRange(location: offset, length: block.utf16Count - offset)))
                if block.kind.isList { next.metadata.semantic = block.metadata.semantic }
                list[index].runs = block.slicing(NSRange(location: 0, length: offset)); list[index].modifiedAt = Date()
                list.insert(next, at: index + 1); cursor = BlockCursor(next.id)
            }
        case .mergeBackward:
            siblings(at: Array(path.dropLast())) { list in
                let index = path.last!
                if list[index].kind != .paragraph { list[index].kind = .paragraph; return }
                guard index > 0 else { return }
                let removed = list.remove(at: index), offset = list[index - 1].utf16Count
                list[index - 1].runs += removed.runs; list[index - 1].children += removed.children
                list[index - 1].modifiedAt = Date(); cursor = BlockCursor(list[index - 1].id, offset: offset)
            }
        case .duplicate:
            func fresh(_ block: EditorBlock) -> EditorBlock {
                var copy = block; copy.id = UUID(); copy.createdAt = Date(); copy.modifiedAt = copy.createdAt
                copy.children = block.children.map(fresh); return copy
            }
            siblings(at: Array(path.dropLast())) { list in let copy = fresh(list[path.last!]); list.insert(copy, at: path.last! + 1); cursor = BlockCursor(copy.id) }
        case .removeKeepingChildren:
            siblings(at: Array(path.dropLast())) { list in
                let index = path.last!, removed = list.remove(at: index)
                list.insert(contentsOf: removed.children, at: index)
                if !list.isEmpty { cursor = BlockCursor(list[min(index, list.count - 1)].id) }
            }
            if blocks.isEmpty { let block = EditorBlock(); blocks = [block]; cursor = BlockCursor(block.id) }
        case .delete:
            siblings(at: Array(path.dropLast())) { list in
                let index = path.last!; list.remove(at: index)
                if !list.isEmpty { cursor = BlockCursor(list[min(index, list.count - 1)].id) }
            }
            if blocks.isEmpty { let block = EditorBlock(); blocks = [block]; cursor = BlockCursor(block.id) }
            if block(cursor.id) == nil { cursor = BlockCursor(flattened.first!.id) }
        case .move(let delta):
            siblings(at: Array(path.dropLast())) { list in
                let from = path.last!, to = min(max(0, from + delta), list.count - 1)
                guard from != to else { return }; let value = list.remove(at: from); list.insert(value, at: to)
            }
        case .indent:
            siblings(at: Array(path.dropLast())) { list in
                let index = path.last!; guard index > 0 else { return }
                let value = list.remove(at: index); list[index - 1].children.append(value); list[index - 1].metadata.collapsed = false
            }
        case .outdent:
            guard path.count > 1 else { return nil }
            let parentIndex = path[path.count - 2], childIndex = path.last!
            siblings(at: Array(path.dropLast(2))) { list in
                let value = list[parentIndex].children.remove(at: childIndex); list.insert(value, at: parentIndex + 1)
            }
        case .reorder(let target), .reorderAfter(let target):
            // A drag only reorders siblings; no child can be silently promoted or orphaned.
            guard let targetPath = self.path(to: target), Array(path.dropLast()) == Array(targetPath.dropLast()), id != target else { return nil }
            siblings(at: Array(path.dropLast())) { list in
                let value = list.remove(at: path.last!); let targetIndex = list.firstIndex { $0.id == target }!
                let after: Bool; if case .reorderAfter = command { after = true } else { after = false }
                list.insert(value, at: targetIndex + (after ? 1 : 0))
            }
        }
        // Invalid and ineffective commands preserve source bytes, identities and timestamps.
        guard blocks != before else { return nil }
        originalSource = nil
        return cursor
    }
    public func canReorder(_ id: UUID, before target: UUID) -> Bool {
        guard id != target, let source = path(to: id), let destination = path(to: target) else { return false }
        return source.dropLast() == destination.dropLast()
    }
    private func path(to id: UUID) -> [Int]? {
        func visit(_ list: [EditorBlock], prefix: [Int]) -> [Int]? {
            for index in list.indices {
                let path = prefix + [index]
                if list[index].id == id { return path }
                if let result = visit(list[index].children, prefix: path) { return result }
            }
            return nil
        }
        return visit(blocks, prefix: [])
    }
    private mutating func siblings(at path: [Int], _ change: (inout [EditorBlock]) -> Void) {
        func visit(_ list: inout [EditorBlock], _ path: ArraySlice<Int>) {
            guard let first = path.first else { change(&list); return }
            visit(&list[first].children, path.dropFirst())
        }
        visit(&blocks, path[...])
    }
}
