import AppKit
import VaultCore

/// TextKit-only inline layout: character indexes and canonical rich runs never
/// change when an asynchronous typeset result replaces the fallback glyphs.
@MainActor final class MathLayoutProjection: NSObject, @preconcurrency NSLayoutManagerDelegate, NSPopoverDelegate, NSTextViewDelegate {
    private weak var view: ArticleTextView?
    private struct Expression {
        var range: NSRange
        var source: String
        var key: String
        var result: MathTypesetResult?
    }
    private var expressions: [Expression] = []
    private var pending: Set<String> = []
    private var results: [String: MathTypesetResult] = [:]
    private var failures: Set<String> = []
    private var generation = UUID()
    private var popover: NSPopover?
    private var sourceEditor: NSTextView?
    private var editing: Expression?
    private var cancelled = false
    private var editingIsCurrent: (() -> Bool)?
    var makeCommitValidator: (() -> (() -> Bool))?
    var commit: ((NSRange, String, String) -> Void)?

    init(view: ArticleTextView) {
        self.view = view
        super.init()
        view.layoutManager?.delegate = self
    }

    func refresh() {
        guard let view, !view.locked, let storage = view.textStorage else { return }
        var values: [Expression] = []
        let macros = UserDefaults.standard.string(forKey: TeXMacroStore.defaultsKey) ?? ""
        // Distinct equal-style equations are separate model runs. Their unique
        // markers retain those boundaries even when AppKit coalesces styles.
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.originalRichRun, in: NSRange(location: 0, length: storage.length)) { marker, range, _ in
            if marker != nil { ranges.append(range) }
            else {
                storage.enumerateAttributes(in: range) { _, part, _ in ranges.append(part) }
            }
        }
        for range in ranges {
            guard range.length > 0,
                  storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String != BlockKind.math.rawValue else { continue }
            let attrs = storage.attributes(at: range.location, effectiveRange: nil)
            let style = BlockTextStorage.style(attrs)
            guard style.math else { continue }
            let source: String
            if let rawMath = style.rawMath {
                source = rawMath
            } else {
                source = (storage.string as NSString).substring(with: range)
            }
            let font = attrs[.font] as? NSFont ?? view.typography.font(for: .body)
            let color = view.theme.nativeText()
            let width = max(40, view.textContainer?.containerSize.width ?? view.typography.readingMeasureWidth)
            let keyParts: [String] = [source, String(Double(font.pointSize)), String(Double(width)), color.description, macros]
            let key = keyParts.joined(separator: "\u{0}")
            values.append(Expression(range: range, source: source, key: key, result: results[key]))
            // The fallback remains readable while the bounded local renderer is
            // busy. A completion schedules the next pending expression.
            guard results[key] == nil, pending.count < 4,
                  !pending.contains(key), !failures.contains(key) else { continue }
            pending.insert(key)
            let token = generation
            MathTypesetter.shared.render(tex: source, display: false,
                fontSize: font.pointSize, color: color, width: width) { [weak self] result in
                guard let self, self.generation == token else { return }
                self.pending.remove(key)
                switch result {
                case .success(let rendered):
                    let cost = self.imageCost(rendered)
                    let retained = self.results.values.reduce(0) { $0 + self.imageCost($1) }
                    if cost <= 4 * 1024 * 1024, retained + cost <= 32 * 1024 * 1024 {
                        self.results[key] = rendered
                    } else {
                        // Do not immediately requeue images rejected by the
                        // projection budget; retain the Unicode fallback.
                        self.failures.insert(key)
                    }
                case .failure: self.failures.insert(key)
                }
                self.refresh()
            }
        }
        let changed = values.count != expressions.count || zip(values, expressions).contains {
            $0.range != $1.range || $0.key != $1.key || ($0.result == nil) != ($1.result == nil)
        }
        expressions = values
        let active = Set(values.map(\.key))
        results = results.filter { active.contains($0.key) }
        failures = failures.intersection(active)
        if changed {
            view.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            view.needsDisplay = true
        }
    }

    var renderedRanges: [NSRange] { expressions.compactMap { $0.result == nil ? nil : $0.range } }
    var sourceEditingView: NSTextView? { sourceEditor }
    func presentationRect(at characterIndex: Int) -> NSRect? {
        guard let view, let expression = expressions.first(where: { NSLocationInRange(characterIndex, $0.range) }) else { return nil }
        return rect(for: expression, in: view)
    }

    private func imageCost(_ result: MathTypesetResult) -> Int {
        result.estimatedMemoryCost
    }

    func dismissSource() {
        cancelled = true
        popover?.close()
    }

    func invalidate() {
        dismissSource()
        generation = UUID()
        pending.removeAll(); results.removeAll(); failures.removeAll(); expressions.removeAll()
        if let view, let storage = view.textStorage {
            view.layoutManager?.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
            view.needsDisplay = true
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes indexes: UnsafePointer<Int>, font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        var properties = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var copied = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var changed = false
        for offset in 0..<glyphRange.length {
            guard let expression = expressions.first(where: { $0.result != nil && NSLocationInRange(indexes[offset], $0.range) }) else { continue }
            properties[offset] = indexes[offset] == expression.range.location ? .controlCharacter : .null
            copied[offset] = 0
            changed = true
        }
        guard changed else { return 0 }
        copied.withUnsafeBufferPointer { glyphBuffer in
            properties.withUnsafeBufferPointer { propertyBuffer in
                layoutManager.setGlyphs(glyphBuffer.baseAddress!, properties: propertyBuffer.baseAddress!, characterIndexes: indexes, font: font, forGlyphRange: glyphRange)
            }
        }
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        expressions.contains { $0.result != nil && $0.range.location == charIndex } ? .whitespace : action
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard let result = expressions.first(where: { $0.range.location == charIndex })?.result else { return .zero }
        return NSRect(x: 0, y: -(result.size.height - result.baseline), width: result.size.width, height: result.size.height)
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let range = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let images = expressions.compactMap { expression -> MathTypesetResult? in
            NSIntersectionRange(expression.range, range).length > 0 ? expression.result : nil
        }
        guard !images.isEmpty else { return false }
        let ascent = images.map { $0.size.height - $0.baseline }.max() ?? 0
        let descent = images.map { $0.baseline }.max() ?? 0
        let extra = max(0, ascent - baselineOffset.pointee)
        baselineOffset.pointee += extra
        let height = max(lineFragmentRect.pointee.height + extra, baselineOffset.pointee + descent)
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        return true
    }

    private func rect(for expression: Expression, in view: ArticleTextView) -> NSRect? {
        guard let layout = view.layoutManager, let container = view.textContainer,
              expression.range.location < view.string.utf16.count else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: expression.range.location)
        guard let result = expression.result else {
            let range = layout.glyphRange(forCharacterRange: expression.range, actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: range, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        }
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = layout.location(forGlyphAt: glyph)
        return NSRect(x: view.textContainerOrigin.x + line.minX + position.x,
            y: view.textContainerOrigin.y + line.minY + position.y - (result.size.height - result.baseline),
            width: result.size.width, height: result.size.height)
    }

    func draw(in view: ArticleTextView) {
        for expression in expressions {
            guard let image = expression.result?.image, let rect = rect(for: expression, in: view), rect.intersects(view.visibleRect) else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    func activate(at point: NSPoint) -> Bool {
        guard let view, view.isEditable, !view.locked,
              let expression = expressions.first(where: { rect(for: $0, in: view)?.insetBy(dx: -2, dy: -3).contains(point) == true }),
              let anchor = rect(for: expression, in: view) else { return false }
        popover?.close()
        cancelled = false; editing = expression
        editingIsCurrent = makeCommitValidator?()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 96))
        editor.string = expression.source
        editor.font = view.typography.font(for: .mathSource)
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.delegate = self
        editor.setAccessibilityLabel("Inline equation LaTeX source")
        let scroll = NSScrollView(frame: editor.frame)
        scroll.hasVerticalScroller = true; scroll.documentView = editor
        let controller = NSViewController(); controller.view = scroll
        let popup = NSPopover(); popup.contentViewController = controller
        popup.behavior = .transient; popup.delegate = self
        sourceEditor = editor; popover = popup
        highlightSource(editor)
        popup.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        popup.contentViewController?.view.window?.makeFirstResponder(editor)
        return true
    }

    private func highlightSource(_ editor: NSTextView) {
        guard let storage = editor.textStorage, let view else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttribute(.foregroundColor, value: view.theme.nativeText(), range: full)
        guard let regex = try? NSRegularExpression(pattern: #"\\(?:[A-Za-z]+|.)|[{}_^&]"#) else { return }
        for match in regex.matches(in: editor.string, range: full) {
            storage.addAttribute(.foregroundColor, value: view.theme.native(.accentPrimary), range: match.range)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = sourceEditor, !editor.hasMarkedText() else { return }
        highlightSource(editor)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true; popover?.close(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !NSEvent.modifierFlags.contains(.shift) {
            popover?.close(); return true
        }
        return false
    }

    func popoverDidClose(_ notification: Notification) {
        let original = editing, source = sourceEditor?.string
        let isCurrent = editingIsCurrent?() ?? false
        editing = nil; sourceEditor = nil; popover = nil; editingIsCurrent = nil
        guard !cancelled, isCurrent, let original, let source, source != original.source else { return }
        commit?(original.range, original.source, source)
    }
}
