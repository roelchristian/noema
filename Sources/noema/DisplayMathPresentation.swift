import AppKit
import VaultCore

/// A display-only projection: native storage keeps every TeX character and its
/// offsets, so EditorSession, selection, copy and undo still see the source.
@MainActor final class DisplayMathPresentation {
    private static let original = NSAttributedString.Key("noema.displayMathOriginalPresentation")
    private struct Entry {
        var key: String
        var result: MathTypesetResult?
    }
    private weak var view: ArticleTextView?
    private var entries: [UUID: Entry] = [:]
    private var reading: Set<UUID> = []
    private var visibleIDs: Set<UUID> = []
    private let maximumImageBytes = 32 * 1024 * 1024
    private var refreshing = false

    init(view: ArticleTextView) { self.view = view }

    func refresh() {
        guard !refreshing, let view, !view.locked, let storage = view.textStorage,
              !view.hasMarkedText(), !view.isSettingMarkedText else { return }
        refreshing = true
        let coordinator = view.delegate as? RichArticleView.Coordinator
        let wasChanging = coordinator?.changing
        coordinator?.changing = true
        defer {
            if let wasChanging { coordinator?.changing = wasChanging }
            refreshing = false
        }
        let blocks = view.blockRangeIndex?.ordered ?? BlockTextStorage.ranges(storage)
        let visibleArea = view.visibleRect.insetBy(dx: 0, dy: -512)
        visibleIDs = Set(blocks.compactMap { id, range in
            guard range.location < storage.length,
                  storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String == BlockKind.math.rawValue,
                  view.rect(for: range).intersects(visibleArea) else { return nil }
            return id
        })
        // Restore only presentation attributes. Block IDs, inline styles and
        // annotations are never replaced or inferred from the projected fonts.
        var originals: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttribute(Self.original, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attributes = value as? [NSAttributedString.Key: Any] { originals.append((range, attributes)) }
        }
        storage.beginEditing()
        for (range, attributes) in originals {
            storage.addAttributes(attributes, range: range)
            storage.removeAttribute(Self.original, range: range)
        }
        reading.removeAll(keepingCapacity: true)
        let liveIDs = Set(blocks.map(\.0))
        entries = entries.filter { liveIDs.contains($0.key) && ($0.value.result != nil || visibleIDs.contains($0.key)) }
        for (id, range) in blocks {
            guard range.length > 0, range.location < storage.length,
                  NSMaxRange(range) <= storage.length,
                  storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String == BlockKind.math.rawValue else { continue }
            var source = (storage.string as NSString).substring(with: range)
            if source.hasSuffix("\n") { source.removeLast() }
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let width = max(40, view.bounds.width - 2 * view.textContainerOrigin.x - CGFloat(depth * 24))
            let color = view.theme.nativeText()
            let key = source + "\u{0}" + String(Double(width)) + "\u{0}" + String(Double(view.typography.size))
                + "\u{0}" + color.description + "\u{0}" + (UserDefaults.standard.string(forKey: TeXMacroStore.defaultsKey) ?? "")
            if entries[id]?.key != key { entries[id] = nil }
            if entries[id] == nil, visibleIDs.contains(id) {
                entries[id] = Entry(key: key)
                MathTypesetter.shared.render(tex: source, display: true,
                    fontSize: view.typography.pointSize(for: .math), color: color, width: width) { [weak self] result in
                    guard let self, self.entries[id]?.key == key else { return }
                    if case .success(let rendered) = result {
                        self.retain(rendered, for: id)
                    }
                    // A failed expression keeps its legible source instead of an
                    // empty equation; another edit retries with a new cache key.
                    self.refresh()
                    self.view?.needsDisplay = true
                }
            }
            guard let result = entries[id]?.result else { continue }
            let selection = view.selectedRange()
            let editing = view.isEditable && !view.locked && view.window?.firstResponder === view
                && NSLocationInRange(selection.location, range) && NSMaxRange(selection) <= NSMaxRange(range)
            if !editing { reading.insert(id) }
            project(range: range, imageHeight: result.size.height, reading: !editing, storage: storage)
            if editing { highlightSource(in: range, storage: storage, color: view.theme.native(.accentPrimary)) }
        }
        storage.endEditing()
        view.needsDisplay = true
    }

    private func retain(_ result: MathTypesetResult, for id: UUID) {
        var bytes = entries.values.compactMap(\.result).reduce(0) { $0 + $1.estimatedMemoryCost }
        for candidate in Array(entries.keys) where bytes + result.estimatedMemoryCost > maximumImageBytes {
            guard candidate != id, !visibleIDs.contains(candidate), let previous = entries[candidate]?.result else { continue }
            bytes -= previous.estimatedMemoryCost
            entries[candidate] = nil
        }
        // If even the visible expressions exceed the budget, keep this source
        // legible. It can retry after leaving and reentering the viewport.
        guard bytes + result.estimatedMemoryCost <= maximumImageBytes else { return }
        entries[id]?.result = result
    }

    func invalidate() {
        guard let view, let storage = view.textStorage else { entries.removeAll(); reading.removeAll(); return }
        let coordinator = view.delegate as? RichArticleView.Coordinator
        let wasChanging = coordinator?.changing
        coordinator?.changing = true
        var originals: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttribute(Self.original, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let attributes = value as? [NSAttributedString.Key: Any] { originals.append((range, attributes)) }
        }
        storage.beginEditing()
        for (range, attributes) in originals {
            storage.addAttributes(attributes, range: range)
            storage.removeAttribute(Self.original, range: range)
        }
        storage.endEditing()
        entries.removeAll(); reading.removeAll(); visibleIDs.removeAll()
        if let wasChanging { coordinator?.changing = wasChanging }
        view.needsDisplay = true
    }

    private func project(range: NSRange, imageHeight: CGFloat, reading: Bool, storage: NSTextStorage) {
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range) { attributes, part, _ in
            var saved: [NSAttributedString.Key: Any] = [:]
            for key in [NSAttributedString.Key.font, .foregroundColor, .paragraphStyle] {
                if let value = attributes[key] { saved[key] = value }
            }
            runs.append((part, saved))
        }
        for (part, attributes) in runs {
            storage.addAttribute(Self.original, value: attributes, range: part)
            if reading {
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear], range: part)
            }
        }
        let text = storage.string as NSString
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = NSIntersectionRange(text.paragraphRange(for: NSRange(location: location, length: 0)), range)
            guard paragraph.length > 0 else { break }
            let original = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            let style = (original?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            if reading {
                // Only the first source paragraph reserves the image; explicit
                // TeX newlines keep their offsets without producing tall gaps.
                let height = location == range.location ? max(1, imageHeight) : CGFloat(0.01)
                style.minimumLineHeight = height; style.maximumLineHeight = height
                style.lineSpacing = 0; style.paragraphSpacing = 0
                if location != range.location { style.paragraphSpacingBefore = 0 }
                style.lineBreakMode = .byClipping
            } else if NSMaxRange(paragraph) == NSMaxRange(range) {
                style.paragraphSpacing += imageHeight + 8
            }
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            location = NSMaxRange(paragraph)
        }
    }

    private func highlightSource(in range: NSRange, storage: NSTextStorage, color: NSColor) {
        guard let commands = try? NSRegularExpression(pattern: #"\\(?:[A-Za-z]+|.)|[{}_^&]"#) else { return }
        for match in commands.matches(in: storage.string, range: range) {
            storage.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    func readingRect(for range: NSRange) -> NSRect? {
        guard let view, let storage = view.textStorage, range.location >= 0, range.length > 0,
              range.location < storage.length,
              let raw = storage.attribute(.blockID, at: range.location, effectiveRange: nil) as? String,
              let id = UUID(uuidString: raw), reading.contains(id), let result = entries[id]?.result,
              let manager = view.layoutManager else { return nil }
        let fullRange = view.blockRangeIndex?.range(for: id) ?? BlockTextStorage.ranges(storage).first(where: { $0.0 == id })?.1
        guard fullRange == range else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
        let x = view.textContainerOrigin.x + CGFloat(depth * 24)
        let width = max(40, view.bounds.width - view.textContainerOrigin.x - x)
        return NSRect(x: x + max(0, (width - result.size.width) / 2),
            y: line.minY + view.textContainerOrigin.y, width: result.size.width, height: result.size.height)
    }

    func activate(at point: NSPoint) -> Bool {
        guard let view, let storage = view.textStorage, view.isEditable, !view.locked else { return false }
        for (_, range) in view.blockRangeIndex?.ordered ?? BlockTextStorage.ranges(storage) {
            guard let frame = readingRect(for: range), frame.insetBy(dx: -8, dy: -5).contains(point) else { continue }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: range.location, length: 0))
            refresh()
            return true
        }
        return false
    }

    func draw() {
        guard let view, let storage = view.textStorage else { return }
        for (id, range) in view.blockRangeIndex?.ordered ?? BlockTextStorage.ranges(storage) {
            guard range.location < storage.length, let result = entries[id]?.result else { continue }
            let rect: NSRect
            if let frame = readingRect(for: range) { rect = frame }
            else {
                let source = view.rect(for: range)
                let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
                let x = view.textContainerOrigin.x + CGFloat(depth * 24)
                let width = max(40, view.bounds.width - view.textContainerOrigin.x - x)
                rect = NSRect(x: x + max(0, (width - result.size.width) / 2), y: source.maxY + 8,
                    width: result.size.width, height: result.size.height)
            }
            guard rect.intersects(view.visibleRect) else { continue }
            result.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
