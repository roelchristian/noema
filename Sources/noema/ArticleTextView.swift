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

    var begin: (() -> Void)?
    var lockedClick: (() -> Void)?
    var end: (() -> Void)?
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
        isSettingMarkedText = true
        defer { isSettingMarkedText = false }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    var handleKey: ((NSEvent) -> Bool)?
    var blockMenu: (() -> NSMenu)?
    var activateBlock: ((UUID, BlockMutation) -> Void)?
    var pasteContent: ((NSPasteboard) -> Void)?
    var canReorder: ((UUID, UUID) -> Bool)?
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
    private func invalidateDecoration(for id: UUID?) {
        guard let id, let storage = textStorage, let range = blockRange(for: id, storage: storage) else { return }
        let rect = rect(for: range)
        setNeedsDisplay(NSRect(x: 0, y: rect.minY - typography.semanticHeadingSpace - 8,
                              width: bounds.width, height: rect.height + typography.semanticHeadingSpace + 16))
    }
    var hoverID: UUID?
    var dropID: UUID?
    var dropAfter = false
    let dragScope = UUID().uuidString
    static let dragType = NSPasteboard.PasteboardType("com.noema.editor-block")
    private var tracking: NSTrackingArea?
    private var dragStart: (UUID, NSPoint)?
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
    func rect(for range: NSRange) -> NSRect {
        guard let layoutManager, let storage = textStorage, range.length > 0 else { return .zero }
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
        var numberByDepth: [Int: Int] = [:]
        for (id, range) in ranges {
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let kind = BlockKind(rawValue: storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph")
            numberByDepth[depth] = kind == .numbered ? (numberByDepth[depth] ?? 0) + 1 : 0
            for key in numberByDepth.keys where key > depth { numberByDepth[key] = nil }
            let rect = rect(for: range)
            let headingRect = semanticHeadingRect(for: range)
            let decorationRect = headingRect.map { rect.union($0) } ?? rect
            guard decorationRect.intersects(dirtyRect) else { continue }
            let metadata = metadata(at: range.location, storage: storage)
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
            if id == hoverID && !locked && isEditable {
                theme.nativeText(.textMuted).setFill()
                for column in 0..<2 { for row in 0..<3 { NSBezierPath(ovalIn: NSRect(x: 14 + column * 5, y: Int(rect.minY) + 4 + row * 5, width: 2, height: 2)).fill() } }
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
    func requestEditingFromClick() {
        if locked { lockedClick?(); return }
        if !isEditable { isEditable = true; begin?(); window?.makeFirstResponder(self) }
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Reading uses AppKit's normal selection and link tracking. Editing is
        // an explicit action, so an ordinary pointer gesture never consumes it.
        if !isEditable {
            if event.modifierFlags.contains(.option) {
                requestEditingFromClick()
                if isEditable {
                    let index = characterIndexForInsertion(at: point)
                    setSelectedRange(NSRange(location: min(index, string.utf16.count), length: 0))
                    return
                }
            }
            super.mouseDown(with: event)
            return
        }
        if locked { super.mouseDown(with: event); return }
        if !locked, let id = blockAt(point), let storage = textStorage,
           let range = blockRange(for: id, storage: storage) {
            if point.x < 29, isEditable { dragStart = (id, point); setSelectedRange(NSRange(location: range.location, length: 0)); return }
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let accessoryX = textContainerOrigin.x + CGFloat(depth * 24) + 1
            let marker = markerRect(for: range, depth: depth).insetBy(dx: -3, dy: -3)
            if point.x >= accessoryX - 3 && point.x <= accessoryX + 19 && point.y >= marker.minY && point.y <= marker.maxY {
                let kind = storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String
                if kind == BlockKind.task.rawValue || kind == BlockKind.toggle.rawValue {
                    if !isEditable { isEditable = true; begin?() }
                    window?.makeFirstResponder(self); activateBlock?(id, kind == BlockKind.task.rawValue ? .checked : .collapse); return
                }
            }
        }
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { dragStart = nil; if let menu = blockMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }; return }
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
        beginDraggingSession(with: [item], event: event, source: self)
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
        let point = convert(sender.draggingLocation, from: nil)
        guard let target = blockAt(point), canReorder?(id, target) == true else { dropID = nil; needsDisplay = true; return [] }
        dropID = target
        if let storage = textStorage, let range = blockRange(for: target, storage: storage) { dropAfter = point.y > rect(for: range).midY }
        needsDisplay = true; return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropID = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if draggedID(sender) != nil { return draggingUpdated(sender) == .move }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = draggedID(sender), let target = dropID else { return super.performDragOperation(sender) }
        dropID = nil; needsDisplay = true; activateBlock?(id, dropAfter ? .reorderAfter(target) : .reorder(before: target)); return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEditable, !locked else {
            let menu = super.menu(for: event) ?? NSMenu()
            if !locked {
                menu.addItem(.separator())
                let edit = NSMenuItem(title: "Edit Article", action: #selector(beginEditingArticle(_:)), keyEquivalent: "")
                edit.target = self
                menu.addItem(edit)
            }
            addDocumentSelectionItem(to: menu)
            return menu
        }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = min(characterIndexForInsertion(at: point), string.utf16.count)
        // Contextual Copy/Paste on a partial native selection must keep it. A
        // click elsewhere chooses that insertion point for subsequent actions.
        if !NSLocationInRange(clicked, selectedRange()), clicked != NSMaxRange(selectedRange()) {
            setSelectedRange(NSRange(location: clicked, length: 0))
        }
        let menu = super.menu(for: event) ?? NSMenu()
        if let actions = blockMenu?() { menu.addItem(.separator()); let item = NSMenuItem(title: "Block", action: nil, keyEquivalent: ""); item.submenu = actions; menu.addItem(item) }
        addDocumentSelectionItem(to: menu)
        return menu
    }
    private func addDocumentSelectionItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Select Entire Document", action: #selector(selectEntireDocument(_:)), keyEquivalent: "a")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        menu.addItem(item)
    }
    @objc func beginEditingArticle(_ sender: Any?) { requestEditingFromClick() }
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
    override func accessibilityPerformShowMenu() -> Bool {
        guard isEditable, !locked, let menu = blockMenu?() else { return false }
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
                guard let self, !self.locked, kind == "task" || kind == "toggle" else { return false }
                if !self.isEditable { self.isEditable = true; self.begin?() }
                self.activateBlock?(id, kind == "task" ? .checked : .collapse); return true
            })
            element.setAccessibilityParent(self)
            let semantic = SemanticPresentation.find(metadata.semantic)?.title ?? ""
            let label = ([kind, semantic, metadata.status ?? "", kind == "task" ? (metadata.checked ? "checked" : "unchecked") : "", kind == "toggle" ? (metadata.collapsed ? "collapsed" : "expanded") : ""].filter { !$0.isEmpty }).joined(separator: ", ")
            element.setAccessibilityLabel(label); element.setAccessibilityRole(kind == "task" || kind == "toggle" ? .button : .staticText)
            element.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
            element.setAccessibilityEnabled(!locked)
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
        if event.keyCode == 53, isEditable { end?(); return }
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
