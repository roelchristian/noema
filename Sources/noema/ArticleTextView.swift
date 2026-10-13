import AppKit
import VaultCore

@MainActor final class ArticleTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateReadingGeometry()
    }

    func updateReadingGeometry() {
        let geometry = ReadingGeometry(availableWidth: bounds.width, reservesEditorGutter: true, maximumContentWidth: typography.readingMeasureWidth)
        if textContainerInset.width != geometry.horizontalInset {
            // Preserve vertical space reserved for a semantic heading.
            textContainerInset = NSSize(width: geometry.horizontalInset, height: textContainerInset.height)
        }
        textContainer?.lineFragmentPadding = 0
    }

    var openLink: ((URL) -> Void)?
    let semanticRangeIndex = BlockTextStorage.SemanticRangeIndex()
    var locked = false
    var theme = NoemaTheme()
    var typography = EditorTypography() { didSet { if typography != oldValue { updateReadingGeometry() } } }
    var showSemanticHeadings = false
    private(set) var semanticHeadingTopInset: CGFloat = 0
    func updateSemanticHeadingTopInset() {
        // AppKit ignores paragraphSpacingBefore on the document's first paragraph.
        let tag = textStorage.flatMap { $0.length > 0 ? $0.attribute(.semanticTag, at: 0, effectiveRange: nil) as? String : nil }
        let inset = showSemanticHeadings && SemanticPresentation.find(tag) != nil ? typography.semanticHeadingSpace + 1 : 0
        if inset != semanticHeadingTopInset {
            textContainerInset.height += inset - semanticHeadingTopInset
            semanticHeadingTopInset = inset
        }
    }
    // The delegate sees the first composition replacement before AppKit reports
    // hasMarkedText(). Reserve that call for the native input manager as well.
    private(set) var isSettingMarkedText = false
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        var replacement = replacementRange
        if !hasMarkedText(), let coordinator = delegate as? RichArticleView.Coordinator {
            let requested = replacement.location == NSNotFound ? self.selectedRange() : replacement
            replacement = coordinator.prepareMarkedReplacement(requested)
        }
        isSettingMarkedText = true
        defer { isSettingMarkedText = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacement)
    }
    var handleKey: ((NSEvent) -> Bool)?
    var annotationAction: (() -> Void)?
    var annotationAvailable: (() -> Bool)?
    var blockMenu: (() -> NSMenu)?
    var activateBlock: ((UUID, BlockMutation) -> Void)?
    var pasteContent: ((NSPasteboard) -> Void)?
    var canReorder: ((UUID, UUID) -> Bool)?
    var selectBlock: ((UUID, NSEvent.ModifierFlags) -> Void)?
    var selectedBlockIDs: Set<UUID> = [] {
        didSet {
            for id in oldValue.symmetricDifference(selectedBlockIDs) { invalidateDecoration(for: id) }
        }
    }
    var blockRangeIndex: BlockTextStorage.RangeIndex?
    private var metadataPresentationCache: [Data: BlockMetadata] = [:]
    private func metadata(at location: Int, storage: NSTextStorage) -> BlockMetadata {
        guard let data = storage.attribute(.blockMetadata, at: location, effectiveRange: nil) as? Data else { return .init() }
        if let cached = metadataPresentationCache[data] { return cached }
        let decoded = (try? JSONDecoder().decode(BlockMetadata.self, from: data)) ?? .init()
        if metadataPresentationCache.count >= 256 { metadataPresentationCache.removeAll(keepingCapacity: true) }
        metadataPresentationCache[data] = decoded
        return decoded
    }
    private func blockRange(for id: UUID, storage: NSTextStorage) -> NSRange? {
        blockRangeIndex?.range(for: id) ?? BlockTextStorage.ranges(storage).first(where: { $0.0 == id })?.1
    }
    func invalidateDecorations(in requested: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let location = min(max(0, requested.location), storage.length - 1)
        let range = NSRange(location: location, length: min(max(1, requested.length), storage.length - location))
        let affected = blockRangeIndex?.intersecting(range) ?? BlockTextStorage.ranges(storage).filter {
            NSIntersectionRange($0.1, range).length > 0
        }
        for (_, range) in affected {
            let rect = rect(for: range)
            setNeedsDisplay(NSRect(x: 0, y: rect.minY - typography.semanticHeadingSpace - 8,
                width: bounds.width, height: rect.height + typography.semanticHeadingSpace + 16))
        }
    }
    private func invalidateDecoration(for id: UUID?) {
        guard let id, let storage = textStorage, let range = blockRange(for: id, storage: storage) else { return }
        invalidateDecorations(in: range)
    }
    private func updateDropTarget(_ id: UUID?, after: Bool = false) {
        guard id != dropID || after != dropAfter else { return }
        invalidateDecoration(for: dropID)
        dropID = id; dropAfter = after
        invalidateDecoration(for: id)
    }
    var hoverID: UUID?
    var dropID: UUID?
    var dropAfter = false
    let dragScope = UUID().uuidString
    static let dragType = NSPasteboard.PasteboardType("com.noema.editor-block")
    private var tracking: NSTrackingArea?
    private var dragStart: (UUID, NSPoint)?
    private var dragScrollTimer: Timer?
    private var dragLocationInWindow: NSPoint?
    private var activeDraggedID: UUID?

    /// Shared hit/drawing geometry follows the first baseline and structural indent.
    func gutterRect(for range: NSRange) -> NSRect {
        let depth = textStorage?.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
        return NSRect(x: max(0, textContainerOrigin.x - 72 + CGFloat(depth * 24)),
                      y: firstBaseline(for: range) - 17, width: 22, height: 24)
    }

    private var focusedBlockID: UUID? {
        guard window?.firstResponder === self, selectedRange().length == 0,
              let storage = textStorage, storage.length > 0 else { return nil }
        return (storage.attribute(.blockID, at: min(selectedRange().location, storage.length - 1),
                                  effectiveRange: nil) as? String).flatMap(UUID.init(uuidString:))
    }

    override func setSelectedRange(_ charRange: NSRange) {
        let previous = focusedBlockID
        super.setSelectedRange(charRange)
        invalidateDecoration(for: previous)
        invalidateDecoration(for: focusedBlockID)
    }

    private func stopBlockDrag() {
        dragScrollTimer?.invalidate(); dragScrollTimer = nil
        dragLocationInWindow = nil; activeDraggedID = nil; dragStart = nil
        updateDropTarget(nil)
    }

    @objc private func scrollBlockDrag(_ timer: Timer) {
        guard let location = dragLocationInWindow, let id = activeDraggedID,
              let scroll = enclosingScrollView else { return }
        let point = convert(location, from: nil)
        let visible = visibleRect
        let edge: CGFloat = 44
        let distance: CGFloat
        if point.y < visible.minY + edge { distance = -min(18, max(2, (visible.minY + edge - point.y) / 3)) }
        else if point.y > visible.maxY - edge { distance = min(18, max(2, (point.y - visible.maxY + edge) / 3)) }
        else { return }
        let clip = scroll.contentView
        let proposed = NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + distance)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: proposed, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        _ = updateBlockDrop(id, at: convert(location, from: nil))
    }

    private func updateBlockDrop(_ id: UUID, at point: NSPoint) -> NSDragOperation {
        guard let target = blockAt(point), target != id, canReorder?(id, target) == true else {
            updateDropTarget(nil); return []
        }
        let after = textStorage.flatMap { storage in
            blockRange(for: target, storage: storage).map { point.y > rect(for: $0).midY }
        } ?? false
        updateDropTarget(target, after: after)
        return .move
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    func blockAt(_ point: NSPoint) -> UUID? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(characterIndexForInsertion(at: NSPoint(x: max(point.x, textContainerOrigin.x + 2), y: point.y)), storage.length - 1)
        return (storage.attribute(.blockID, at: index, effectiveRange: nil) as? String).flatMap(UUID.init(uuidString:))
    }
    func rect(for requestedRange: NSRange) -> NSRect {
        guard let layoutManager, let storage = textStorage, requestedRange.length > 0,
              requestedRange.location >= 0, requestedRange.location < storage.length else { return .zero }
        // AppKit can update focus during storage replacement before the UUID range
        // index has been rebuilt. Decoration geometry must use the current bytes.
        let range = NSRange(location: requestedRange.location,
                            length: min(requestedRange.length, storage.length - requestedRange.location))
        // Preserve all stored text, but don't draw an accent across trailing blank
        // lines or paragraph/line spacing. Empty blocks still get one text line.
        let text = (storage.string as NSString).substring(with: range) as NSString
        let lastContent = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        let content = NSRange(location: range.location, length: lastContent.location == NSNotFound ? 1 : NSMaxRange(lastContent))
        let glyphs = layoutManager.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
        if text.isEqual(to: "\n"), glyphs.length > 0 {
            // A newline glyph sits lower than the first typed glyph. Keep empty
            // block decoration on the native insertion line so it won't jump.
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? typography.font(for: .body)
            let paragraph = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            // The newline's fragment omits leading paragraph spacing after the first block.
            let leadingSpace = range.location > 0 ? (paragraph?.paragraphSpacingBefore ?? 0) : 0
            return NSRect(x: used.minX + textContainerOrigin.x, y: line.minY + textContainerOrigin.y + leadingSpace,
                          width: used.width, height: font.ascender - font.descender)
        }
        var bounds = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, used, _, lineGlyphs, _ in
            let included = NSIntersectionRange(lineGlyphs, glyphs)
            guard included.length > 0 else { return }
            let baseline = line.minY + layoutManager.location(forGlyphAt: included.location).y
            var ascender: CGFloat = 0, descender: CGFloat = 0
            let characters = layoutManager.characterRange(forGlyphRange: included, actualGlyphRange: nil)
            storage.enumerateAttribute(.font, in: characters) { value, _, _ in
                let font = value as? NSFont ?? self.typography.font(for: .body)
                ascender = max(ascender, font.ascender); descender = max(descender, -font.descender)
            }
            bounds = bounds.union(NSRect(x: used.minX, y: baseline - ascender, width: used.width, height: ascender + descender))
        }
        return bounds.isNull ? .zero : bounds.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
    override func mouseMoved(with event: NSEvent) {
        let next = blockAt(convert(event.locationInWindow, from: nil))
        guard next != hoverID else { return }
        invalidateDecoration(for: hoverID); hoverID = next; invalidateDecoration(for: next)
    }
    override func mouseExited(with event: NSEvent) { invalidateDecoration(for: hoverID); hoverID = nil }
    func semanticHeadingRect(for range: NSRange) -> NSRect? {
        guard showSemanticHeadings, let storage = textStorage, let layoutManager,
              SemanticPresentation.find(storage.attribute(.semanticTag, at: range.location, effectiveRange: nil) as? String) != nil else { return nil }
        let body = rect(for: range)
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = textContainerOrigin.x + line.minX + layoutManager.location(forGlyphAt: glyph).x
        return NSRect(x: x, y: body.minY - typography.semanticHeadingSpace,
                      width: max(0, bounds.width - textContainerOrigin.x - x),
                      height: typography.semanticLabelHeight)
    }
    /// Both drawn markers and their hit targets use the content's first baseline.
    func firstBaseline(for range: NSRange) -> CGFloat {
        guard let layoutManager, let storage = textStorage, range.length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if (storage.string as NSString).substring(with: range) == "\n" {
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? typography.font(for: .body)
            return rect(for: range).minY + font.ascender
        }
        return textContainerOrigin.y + line.minY + layoutManager.location(forGlyphAt: glyph).y
    }

    func markerRect(for range: NSRange, depth: Int, callout: Bool = false) -> NSRect {
        let font = typography.font(for: .semanticLabel)
        // The structural gutter is 24 pt. Enlarged icons remain inside it.
        let size = min(18, font.pointSize)
        return NSRect(x: textContainerOrigin.x + CGFloat(depth * 24) + (callout ? -23 : 1),
                      y: firstBaseline(for: range) - size * 0.8, width: size, height: size)
    }

    func semanticSymbolRect(for range: NSRange, depth: Int, heading: NSRect?) -> NSRect? {
        let labelFont = typography.font(for: .semanticLabel)
        let baseline = heading.map { $0.minY + labelFont.ascender } ?? firstBaseline(for: range)
        let size = min(18, labelFont.pointSize)
        let rect = NSRect(x: max(30, textContainerOrigin.x - 46) + CGFloat(depth * 24),
                          y: baseline - size * 0.8, width: size, height: size)
        // Tiny viewports may have no room between the drag and content gutters.
        guard rect.maxX <= textContainerOrigin.x + CGFloat(depth * 24) - 12 else { return nil }
        return rect
    }

    /// A preview occupies only unused horizontal space on a single raw-source line.
    /// At narrow widths, or for wrapped source, the source remains the sole display.
    func mathPreviewRect(for range: NSRange, rendered expression: String? = nil) -> NSRect? {
        guard let layoutManager, let storage = textStorage, range.length > 0 else { return nil }
        let raw = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered = expression ?? BlockTextStorage.renderedMath(raw, display: true)
        guard !rendered.isEmpty else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var lines = 0
        var fragment = NSRect.zero
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
            lines += 1; fragment = line
        }
        guard lines == 1 else { return nil }
        let content = rect(for: range)
        let start = content.maxX + typography.semanticLabelGap * 3
        let width = min(260, bounds.width - textContainerOrigin.x - start)
        guard width >= typography.pointSize(for: .semanticLabel) * 6 else { return nil }
        let font = typography.font(for: .math)
        let line = fragment.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // Source wrapping does not predict rendered wrapping: macros and TeX line
        // breaks can expand a short source into a wider or multiline expression.
        let measured = (rendered as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: mathPreviewAttributes)
        // Fallback glyphs may need slightly more height than the primary face.
        // Use their measured height only within this source line's existing box.
        let height = max(font.ascender - font.descender, measured.height)
        guard measured.width <= width, height <= line.height else { return nil }
        return NSRect(x: start, y: line.midY - height / 2, width: width, height: height)
    }

    private var mathPreviewAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle(); style.alignment = .right
        return [.font: typography.font(for: .math),
                .foregroundColor: theme.nativeText(.accentSecondary), .paragraphStyle: style]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let storage = textStorage else { super.draw(dirtyRect); return }
        // Include decoration above/below the affected glyphs while avoiding a
        // full-document range scan during caret, hover and local text redraws.
        let ranges: [(UUID, NSRange)]
        if let index = blockRangeIndex, let layoutManager, let textContainer {
            let expanded = dirtyRect.insetBy(dx: -8, dy: -(typography.semanticHeadingSpace + 16))
                .offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
            // Gutter-only invalidation must still find the adjacent text lines.
            let lineBand = NSRect(x: 0, y: expanded.minY,
                width: textContainer.containerSize.width, height: expanded.height)
            let glyphs = layoutManager.glyphRange(forBoundingRect: lineBand, in: textContainer)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            ranges = index.intersecting(characters)
        } else { ranges = BlockTextStorage.ranges(storage) }
        drawSemanticRanges(in: dirtyRect, blocks: ranges)
        var numberByDepth: [Int: Int] = [:]
        for (id, range) in ranges {
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let kind = BlockKind(rawValue: storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph")
            numberByDepth[depth] = kind == .numbered ? (numberByDepth[depth] ?? 0) + 1 : 0
            for key in numberByDepth.keys where key > depth { numberByDepth[key] = nil }
            let rect = rect(for: range)
            let headingRect = semanticHeadingRect(for: range)
            let decorationRect = (headingRect.map { rect.union($0) } ?? rect).union(gutterRect(for: range))
            guard decorationRect.intersects(dirtyRect) else { continue }
            let metadata = metadata(at: range.location, storage: storage)
            if selectedBlockIDs.contains(id) {
                theme.native(.accentPrimary).withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: NSRect(x: gutterRect(for: range).minX, y: rect.minY - 3,
                    width: max(22, bounds.width - textContainerOrigin.x - gutterRect(for: range).minX),
                    height: rect.height + 6), xRadius: 4, yRadius: 4).fill()
            }
            if kind == .code || kind == .callout || kind == .math {
                theme.native(.accentPrimary).withAlphaComponent(theme.dark ? 0.08 : 0.04).setFill()
                NSBezierPath(roundedRect: NSRect(x: textContainerOrigin.x - 8 + CGFloat(depth * 24), y: decorationRect.minY - 6, width: max(20, bounds.width - textContainerOrigin.x * 2 - CGFloat(depth * 24) + 16), height: decorationRect.height + 12), xRadius: 5, yRadius: 5).fill()
            }
            if kind == .quote || metadata.semantic != nil {
                (SemanticPresentation.find(metadata.semantic)?.accent ?? NSColor.separatorColor).setFill()
                NSRect(x: textContainerOrigin.x - 8 + CGFloat(depth * 24), y: decorationRect.minY, width: 2, height: decorationRect.height).fill()
            }
            if kind == .divider {
                theme.native(.border).setFill()
                NSRect(x: textContainerOrigin.x + CGFloat(depth * 24), y: rect.minY + 11, width: max(30, bounds.width - 2 * textContainerOrigin.x - CGFloat(depth * 24)), height: 1).fill()
            }
            let structuralX = textContainerOrigin.x + CGFloat(depth * 24) + (kind == .callout ? -23 : 1)
            var structureSymbol: String?, structureText: String?
            switch kind {
            case .bullet: structureText = "•"
            case .numbered: structureText = "\(blockRangeIndex?.number(for: id) ?? numberByDepth[depth] ?? 1)."
            case .task: structureSymbol = metadata.checked ? "checkmark.square" : "square"
            case .toggle: structureSymbol = metadata.collapsed ? "chevron.right" : "chevron.down"
            case .callout: structureSymbol = metadata.icon ?? "info.circle"
            default: break
            }
            if let symbol = structureSymbol { drawSymbol(symbol, at: markerRect(for: range, depth: depth, callout: kind == .callout), color: .secondaryLabelColor) }
            if let text = structureText {
                var font = typography.font(for: .semanticLabel, weight: .medium)
                let measured = (text as NSString).size(withAttributes: [.font: font]).width
                if measured > 21 { font = NSFontManager.shared.convert(font, toSize: font.pointSize * 21 / measured) }
                (text as NSString).draw(at: NSPoint(x: structuralX, y: firstBaseline(for: range) - font.ascender),
                                       withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            }
            if let semantic = SemanticPresentation.find(metadata.semantic) {
                if let headingRect {
                    (semantic.title as NSString).draw(in: headingRect, withAttributes: [.font: typography.font(for: .semanticLabel), .foregroundColor: theme.nativeText()])
                }
                if let icon = semanticSymbolRect(for: range, depth: depth, heading: headingRect) {
                    drawSymbol(semantic.symbol, at: icon, color: semantic.accent)
                }
            } else if kind == .code, let language = metadata.language {
                (language as NSString).draw(in: NSRect(x: 30, y: firstBaseline(for: range) - NSFont.systemFont(ofSize: 10).ascender, width: max(0, textContainerOrigin.x - 38), height: 34), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            } else if kind == .math {
                if let icon = semanticSymbolRect(for: range, depth: depth, heading: nil) {
                    drawSymbol("function", at: icon, color: .secondaryLabelColor)
                }
                let rawBlock = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                let rendered = BlockTextStorage.renderedMath(rawBlock, display: true)
                if let previewRect = mathPreviewRect(for: range, rendered: rendered) {
                    (rendered as NSString).draw(in: previewRect, withAttributes: mathPreviewAttributes)
                }
            }
            if (id == hoverID || id == focusedBlockID || selectedBlockIDs.contains(id)) && !locked && isEditable {
                let handle = gutterRect(for: range)
                theme.nativeText(.textMuted).setFill()
                for column in 0..<2 { for row in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: handle.midX - 4 + CGFloat(column * 5),
                        y: handle.midY - 6 + CGFloat(row * 5), width: 2, height: 2)).fill()
                } }
            }
            if id == dropID {
                theme.native(.accentPrimary).setFill()
                NSRect(x: textContainerOrigin.x - 8, y: dropAfter ? rect.maxY + 3 : rect.minY - 3, width: max(30, bounds.width - 2 * textContainerOrigin.x + 16), height: 2).fill()
            }
        }
        super.draw(dirtyRect)
    }
    private func drawSymbol(_ name: String, at rect: NSRect, color: NSColor) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            symbol.draw(in: bounds); color.setFill(); bounds.fill(using: .sourceAtop); return true
        }
        tinted.draw(in: rect)
    }
    /// Resolve a rendered glyph, rather than snapping whitespace to the nearest link.
    func link(at point: NSPoint) -> URL? {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: location, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(location) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        let value = storage.attribute(.link, at: index, effectiveRange: nil)
        return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let url = link(at: point), openLink != nil {
            openLink?(url); return
        }
        guard isEditable, !locked else { super.mouseDown(with: event); return }
        if !locked, let id = blockAt(point), let storage = textStorage,
           let range = blockRange(for: id, storage: storage) {
            if gutterRect(for: range).contains(point) {
                dragStart = (id, point)
                if !selectedBlockIDs.contains(id) || !event.modifierFlags.intersection([.shift, .command]).isEmpty {
                    selectBlock?(id, event.modifierFlags)
                }
                // Handle gestures have their own UUID selection and never move the caret.
                return
            }
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let accessoryX = textContainerOrigin.x + CGFloat(depth * 24) + 1
            let marker = markerRect(for: range, depth: depth).insetBy(dx: -3, dy: -3)
            if point.x >= accessoryX - 3 && point.x <= accessoryX + 19 && point.y >= marker.minY && point.y <= marker.maxY {
                let kind = storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String
                if kind == BlockKind.task.rawValue || kind == BlockKind.toggle.rawValue {
                    window?.makeFirstResponder(self); activateBlock?(id, kind == BlockKind.task.rawValue ? .checked : .collapse); return
                }
            }
        }
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { dragStart = nil; return }
        super.mouseUp(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let (id, point) = dragStart else { super.mouseDragged(with: event); return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - point.x, current.y - point.y) > 4 else { return }
        dragStart = nil
        let writer = NSPasteboardItem(); writer.setString(dragScope + ":" + id.uuidString, forType: Self.dragType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: NSSize(width: 150, height: 28), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            ("Move block" as NSString).draw(at: NSPoint(x: 12, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]); return true
        }
        item.setDraggingFrame(NSRect(origin: point, size: image.size), contents: image)
        activeDraggedID = id
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    private func draggedID(_ sender: NSDraggingInfo) -> UUID? {
        guard !locked, isEditable, let value = sender.draggingPasteboard.string(forType: Self.dragType), value.hasPrefix(dragScope + ":") else { return nil }
        return UUID(uuidString: String(value.dropFirst(dragScope.count + 1)))
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedID(sender) else { return super.draggingUpdated(sender) }
        activeDraggedID = id
        dragLocationInWindow = sender.draggingLocation
        if dragScrollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, target: self, selector: #selector(scrollBlockDrag(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            dragScrollTimer = timer
        }
        return updateBlockDrop(id, at: convert(sender.draggingLocation, from: nil))
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { stopBlockDrag() }
    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        stopBlockDrag()
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if draggedID(sender) != nil { return draggingUpdated(sender) == .move }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = draggedID(sender) else { return super.performDragOperation(sender) }
        guard let target = dropID else { stopBlockDrag(); return false }
        guard canReorder?(id, target) == true, activateBlock != nil else { stopBlockDrag(); return false }
        let after = dropAfter
        stopBlockDrag()
        activateBlock?(id, after ? .reorderAfter(target) : .reorder(before: target)); return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditable, !locked else {
            let menu = super.menu(for: event) ?? NSMenu()
            addSemanticAssociations(to: menu, at: convert(event.locationInWindow, from: nil))
            addOpenLinkItem(to: menu, at: convert(event.locationInWindow, from: nil))
            addDocumentSelectionItem(to: menu)
            return menu
        }
        let point = convert(event.locationInWindow, from: nil)
        if let id = blockAt(point), let storage = textStorage,
           let range = blockRange(for: id, storage: storage), gutterRect(for: range).contains(point) {
            if !selectedBlockIDs.contains(id) { selectBlock?(id, event.modifierFlags) }
            return blockMenu?()
        }
        let clicked = min(characterIndexForInsertion(at: point), string.utf16.count)
        // Contextual Copy/Paste on a partial native selection must keep it. A
        // click elsewhere chooses that insertion point for subsequent actions.
        if !NSLocationInRange(clicked, selectedRange()), clicked != NSMaxRange(selectedRange()) {
            setSelectedRange(NSRange(location: clicked, length: 0))
        }
        let menu = super.menu(for: event) ?? NSMenu()
        if let actions = blockMenu?() { menu.addItem(.separator()); let item = NSMenuItem(title: "Block", action: nil, keyEquivalent: ""); item.submenu = actions; menu.addItem(item) }
        addOpenLinkItem(to: menu, at: point)
        addAnnotationItem(to: menu)
        addSemanticAssociations(to: menu, at: point)
        addDocumentSelectionItem(to: menu)
        return menu
    }
    private func addOpenLinkItem(to menu: NSMenu, at point: NSPoint) {
        guard let url = link(at: point), openLink != nil else { return }
        let item = NSMenuItem(title: "Open Link", action: #selector(openContextLink(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = url
        menu.addItem(item)
    }
    @objc func openContextLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openLink?(url) }
    }
    private func addAnnotationItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Annotate Selection…", action: #selector(annotateSelection(_:)), keyEquivalent: "A")
        item.target = self; item.keyEquivalentModifierMask = [.command, .shift]
        item.isEnabled = annotationAvailable?() == true
        item.toolTip = item.isEnabled ? "Associate this text with an entity, question, or definition" : "Select complete characters within one editable block"
        menu.addItem(item)
    }
    @objc func annotateSelection(_ sender: Any?) { annotationAction?() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(annotateSelection(_:)) { return annotationAvailable?() == true }
        return super.validateUserInterfaceItem(item)
    }
    private func addDocumentSelectionItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Select Entire Document", action: #selector(selectEntireDocument(_:)), keyEquivalent: "a")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        menu.addItem(item)
    }
    @objc func selectEntireDocument(_ sender: Any?) { super.selectAll(sender) }
    override func selectAll(_ sender: Any?) {
        guard isEditable, !locked, !hasMarkedText(), let storage = textStorage,
              storage.length > 0 else { super.selectAll(sender); return }
        let index = min(selectedRange().location, storage.length - 1)
        var range = NSRange()
        guard storage.attribute(.blockID, at: index, longestEffectiveRange: &range,
                                in: NSRange(location: 0, length: storage.length)) != nil else {
            super.selectAll(sender); return
        }
        // Every rendered block has one presentation-only terminator.
        setSelectedRange(NSRange(location: range.location, length: max(0, range.length - 1)))
    }
    /// Keyboard/VoiceOver access uses the current text selection, without a pointer hit test.
    func accessibilityContextMenu() -> NSMenu {
        let menu = isEditable && !locked ? blockMenu?() ?? NSMenu() : NSMenu()
        if let storage = textStorage, selectedRange().location < storage.length {
            let value = storage.attribute(.link, at: selectedRange().location, effectiveRange: nil)
            if let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)), openLink != nil {
                let item = NSMenuItem(title: "Open Link", action: #selector(openContextLink(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = url; menu.addItem(item)
            }
        }
        addDocumentSelectionItem(to: menu)
        return menu
    }
    override func accessibilityPerformShowMenu() -> Bool {
        let menu = accessibilityContextMenu()
        let location = min(selectedRange().location, max(0, string.utf16.count - 1))
        let anchor = rect(for: NSRange(location: location, length: 1))
        menu.popUp(positioning: nil, at: NSPoint(x: textContainerOrigin.x, y: anchor.minY + 20), in: self); return true
    }
    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        guard let storage = textStorage, let window else { return children }
        for (id, range) in blockRangeIndex?.ordered ?? BlockTextStorage.ranges(storage) {
            let kind = storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph"
            let metadata = metadata(at: range.location, storage: storage)
            guard kind != "paragraph" || metadata.semantic != nil else { continue }
            let frame = rect(for: range); guard frame.intersects(visibleRect) else { continue }
            let element = BlockAccessibilityElement(action: { [weak self] in
                guard let self, self.isEditable, !self.locked, kind == "task" || kind == "toggle" else { return false }
                self.activateBlock?(id, kind == "task" ? .checked : .collapse); return true
            })
            element.setAccessibilityParent(self)
            let semantic = SemanticPresentation.find(metadata.semantic)?.title ?? ""
            let label = ([kind, semantic, metadata.status ?? "", kind == "task" ? (metadata.checked ? "checked" : "unchecked") : "", kind == "toggle" ? (metadata.collapsed ? "collapsed" : "expanded") : ""].filter { !$0.isEmpty }).joined(separator: ", ")
            element.setAccessibilityLabel(label); element.setAccessibilityRole(kind == "task" || kind == "toggle" ? .button : .staticText)
            element.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
            element.setAccessibilityEnabled(isEditable && !locked)
            children.append(element)
        }
        return children
    }
    override func paste(_ sender: Any?) {
        guard isEditable, !locked else { return }
        // Let the input manager finish active composition before a native paste.
        if hasMarkedText() || pasteContent == nil { super.paste(sender) }
        else { pasteContent?(NSPasteboard.general) }
    }
    override func keyDown(with event: NSEvent) {
        // Return, arrows, Tab and Escape belong to the input manager while it has
        // marked text. Structural shortcuts must not split or discard candidates.
        if hasMarkedText() { super.keyDown(with: event); return }
        if isEditable, !locked, handleKey?(event) == true { return }
        if event.keyCode == 53 { return }
        super.keyDown(with: event)
    }
    // Popovers and menus may temporarily move focus; they must not end an editing session.
    override func resignFirstResponder() -> Bool { super.resignFirstResponder() }
}

private final class BlockAccessibilityElement: NSAccessibilityElement {
    let action: @MainActor @Sendable () -> Bool
    init(action: @escaping @MainActor @Sendable () -> Bool) { self.action = action; super.init() }
    override func accessibilityPerformPress() -> Bool {
        let action = action
        Task { @MainActor in _ = action() }; return true
    }
}
