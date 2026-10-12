import AppKit
import VaultCore

extension BlockTextStorage {
    /// Derived presentation only. Multiple records may share or cross the same range.
    @MainActor final class SemanticRangeIndex {
        struct Entry: Equatable {
            let annotation: SemanticAnnotation
            let range: NSRange
        }
        private(set) var entriesByBlock: [UUID: [Entry]] = [:]
        private(set) var generation: UInt64 = 0
        @discardableResult func update(document: BlockDocument, annotations: [SemanticAnnotation],
            pageID: UUID?, revision: BlockStoreRevision?, storage: NSAttributedString, blocks: RangeIndex) -> [NSRange] {
            var next: [UUID: [Entry]] = [:]
            if let pageID, let revision {
                for annotation in annotations where annotation.anchorDisposition == .resolved && annotation.expectedRevision == revision.token {
                    guard annotation.location.pageID == pageID, let id = annotation.location.blockID,
                          let block = document.block(id), let rendered = blocks.range(for: id), rendered.length > 0,
                          rendered.location >= 0, NSMaxRange(rendered) <= storage.length,
                          (storage.string as NSString).substring(with: NSRange(location: rendered.location, length: rendered.length - 1)) == block.text else { continue }
                    let local: NSRange
                    switch annotation.location {
                    case .inline(_, _, let target):
                        guard target.start >= 0, target.end > target.start, target.end <= block.text.utf16.count else { continue }
                        local = NSRange(location: target.start, length: target.end - target.start)
                        guard InlineAnnotationTarget.validRange(local, in: block.text),
                              (block.text as NSString).substring(with: local) == target.quote,
                              target.digest == (try? InlineAnnotationTarget(text: block.text, range: local, revision: revision.token))?.digest else { continue }
                    case .wholeBlock: local = NSRange(location: 0, length: block.text.utf16.count)
                    default: continue
                    }
                    guard local.length > 0 else { continue }
                    next[id, default: []].append(Entry(annotation: annotation,
                        range: NSRange(location: rendered.location + local.location, length: local.length)))
                }
            }
            for id in next.keys { next[id]?.sort { $0.annotation.id.uuidString < $1.annotation.id.uuidString } }
            let changed = Set(entriesByBlock.keys).union(next.keys).filter { entriesByBlock[$0] != next[$0] }
            let dirty = changed.flatMap { (entriesByBlock[$0] ?? []).map(\.range) + (next[$0] ?? []).map(\.range) }
            if !changed.isEmpty { entriesByBlock = next; generation &+= 1 }
            return dirty
        }
        func entries(in blocks: [(UUID, NSRange)]) -> [Entry] { blocks.flatMap { entriesByBlock[$0.0] ?? [] } }
        func associations(in range: NSRange, blocks: RangeIndex) -> [Entry] {
            guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return [] }
            return entries(in: blocks.intersecting(range)).filter {
                range.length == 0 ? NSLocationInRange(range.location, $0.range) : NSIntersectionRange(range, $0.range).length > 0
            }
        }
    }
}

extension RichArticleView.Coordinator {
    func refreshSemanticRanges() {
        guard let view, let storage = view.textStorage, let blocks = rangeIndex else { return }
        let dirty = view.semanticRangeIndex.update(document: document,
            annotations: session.semanticEdit?.annotations ?? [], pageID: session.identity.pageID,
            revision: session.pageRevision, storage: storage, blocks: blocks)
        for range in dirty { view.invalidateDecorations(in: range) }
    }
}

extension ArticleTextView {
    func semanticAssociations(in range: NSRange) -> [BlockTextStorage.SemanticRangeIndex.Entry] {
        guard !hasMarkedText(), !isSettingMarkedText, (delegate as? RichArticleView.Coordinator)?.deferredComposition != true, let blockRangeIndex else { return [] }
        return semanticRangeIndex.associations(in: range, blocks: blockRangeIndex)
    }
    /// AppKit glyph geometry, rather than text/quote searches, determines the hit.
    func semanticAssociations(at point: NSPoint) -> [BlockTextStorage.SemanticRangeIndex.Entry] {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return [] }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return [] }
        return semanticAssociations(in: NSRange(location: layoutManager.characterIndexForGlyph(at: glyph), length: 0))
    }
    func drawSemanticRanges(in dirtyRect: NSRect, blocks: [(UUID, NSRange)]) {
        guard !hasMarkedText(), !isSettingMarkedText, (delegate as? RichArticleView.Coordinator)?.deferredComposition != true, let layoutManager, let textContainer else { return }
        let entries = semanticRangeIndex.entries(in: blocks)
        var ordered: [NSRange] = entries.map { $0.range }
        ordered.sort { (lhs: NSRange, rhs: NSRange) -> Bool in
            if lhs.location == rhs.location { return lhs.length < rhs.length }
            return lhs.location < rhs.location
        }
        var painted: [NSRange] = []
        for range in ordered {
            if let last = painted.last, range.location <= NSMaxRange(last) {
                painted[painted.count - 1] = NSUnionRange(last, range)
            } else { painted.append(range) }
        }
        for range in painted {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                let rect = rect.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                guard rect.intersects(dirtyRect) else { return }
                self.theme.native(.accentPrimary).withAlphaComponent(self.theme.dark ? 0.12 : 0.07).setFill()
                rect.fill()
                self.theme.native(.accentPrimary).withAlphaComponent(0.55).setFill()
                NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
            }
        }
    }
    func addSemanticAssociations(to menu: NSMenu, at point: NSPoint) {
        let entries = selectedRange().length > 0 ? semanticAssociations(in: selectedRange()) : semanticAssociations(at: point)
        guard !entries.isEmpty else { return }
        let associations = NSMenu(title: "Associations")
        associations.autoenablesItems = false
        for entry in entries {
            let identity = entry.annotation.referent.identity
            let title = "Inspect \(entry.annotation.designation.capitalized) · \(identity.id.uuidString.prefix(8)) · \(entry.annotation.id.uuidString.prefix(8))"
            let item = NSMenuItem(title: title, action: #selector(showSemanticAssociation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = entry.annotation.id.uuidString
            associations.addItem(item)
        }
        let item = NSMenuItem(title: "Associations (\(entries.count))", action: nil, keyEquivalent: "")
        item.submenu = associations; menu.addItem(item)
    }
    @objc func showSemanticAssociation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let entry = semanticRangeIndex.entriesByBlock.values.joined().first(where: { $0.annotation.id.uuidString == id }) else { return }
        (delegate as? RichArticleView.Coordinator)?.parent.onInspectAssociation?(entry.annotation.id)
    }
}
