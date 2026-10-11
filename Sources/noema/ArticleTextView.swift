import AppKit
import VaultCore

@MainActor final class ArticleTextView: NSTextView {
    var begin: (() -> Void)?
    var lockedClick: (() -> Void)?
    var end: (() -> Void)?
    var locked = false
    var theme = NoemaTheme()
    var showSemanticHeadings = false
    private(set) var semanticHeadingTopInset: CGFloat = 0
    func updateSemanticHeadingTopInset() {
        // AppKit ignores paragraphSpacingBefore on the document's first paragraph.
        let tag = textStorage.flatMap { $0.length > 0 ? $0.attribute(.semanticTag, at: 0, effectiveRange: nil) as? String : nil }
        let inset = showSemanticHeadings && SemanticPresentation.find(tag) != nil ? BlockTextStorage.semanticHeadingSpace + 1 : 0
        if inset != semanticHeadingTopInset {
            textContainerInset.height += inset - semanticHeadingTopInset
            semanticHeadingTopInset = inset
        }
    }
    var handleKey: ((NSEvent) -> Bool)?
    var blockMenu: (() -> NSMenu)?
    var activateBlock: ((UUID, BlockMutation) -> Void)?
    var pasteContent: ((NSPasteboard) -> Void)?
    var canReorder: ((UUID, UUID) -> Bool)?
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
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? EditorTypography.current.font()
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
                let font = value as? NSFont ?? EditorTypography.current.font()
                ascender = max(ascender, font.ascender); descender = max(descender, -font.descender)
            }
            bounds = bounds.union(NSRect(x: used.minX, y: baseline - ascender, width: used.width, height: ascender + descender))
        }
        return bounds.isNull ? .zero : bounds.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
    override func mouseMoved(with event: NSEvent) { hoverID = blockAt(convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hoverID = nil; needsDisplay = true }
    func semanticHeadingRect(for range: NSRange) -> NSRect? {
        guard showSemanticHeadings, let storage = textStorage, let layoutManager,
              SemanticPresentation.find(storage.attribute(.semanticTag, at: range.location, effectiveRange: nil) as? String) != nil else { return nil }
        let body = rect(for: range)
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = textContainerOrigin.x + line.minX + layoutManager.location(forGlyphAt: glyph).x
        return NSRect(x: x, y: body.minY - BlockTextStorage.semanticHeadingSpace,
                      width: max(0, bounds.width - textContainerOrigin.x - x),
                      height: BlockTextStorage.semanticHeadingSpace - 8)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let storage = textStorage else { super.draw(dirtyRect); return }
        let ranges = BlockTextStorage.ranges(storage)
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
            let metadata = (storage.attribute(.blockMetadata, at: range.location, effectiveRange: nil) as? Data).flatMap { try? JSONDecoder().decode(BlockMetadata.self, from: $0) } ?? .init()
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
            case .numbered: structureText = "\(numberByDepth[depth] ?? 1)."
            case .task: structureSymbol = metadata.checked ? "checkmark.square" : "square"
            case .toggle: structureSymbol = metadata.collapsed ? "chevron.right" : "chevron.down"
            case .callout: structureSymbol = metadata.icon ?? "info.circle"
            default: break
            }
            if let symbol = structureSymbol { drawSymbol(symbol, at: NSRect(x: structuralX, y: rect.minY + 3, width: 14, height: 14), color: .secondaryLabelColor) }
            if let text = structureText { (text as NSString).draw(at: NSPoint(x: structuralX, y: rect.minY + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]) }
            if let semantic = SemanticPresentation.find(metadata.semantic) {
                if let headingRect {
                    (semantic.title as NSString).draw(in: headingRect, withAttributes: [.font: BlockTextStorage.semanticHeadingFont, .foregroundColor: theme.nativeText()])
                }
                drawSymbol(semantic.symbol, at: NSRect(x: textContainerOrigin.x - 46, y: headingRect == nil ? rect.minY + 3 : decorationRect.midY - 7, width: 14, height: 14), color: semantic.accent)
            } else if kind == .code, let language = metadata.language {
                (language as NSString).draw(in: NSRect(x: 30, y: rect.minY + 3, width: max(0, textContainerOrigin.x - 38), height: 34), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            } else if kind == .math {
                drawSymbol("function", at: NSRect(x: textContainerOrigin.x - 46, y: rect.minY + 3, width: 14, height: 14), color: .secondaryLabelColor)
                let rawBlock = (storage.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                let rendered = TeXMath.render(rawBlock, display: true)
                if !rendered.isEmpty {
                    let previewStyle = NSMutableParagraphStyle(); previewStyle.alignment = .right
                    let previewRect = NSRect(x: max(textContainerOrigin.x + 120, bounds.width - textContainerOrigin.x - 260), y: decorationRect.minY, width: 260, height: decorationRect.height)
                    (rendered as NSString).draw(in: previewRect, withAttributes: [
                        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                        .foregroundColor: theme.nativeText(.accentSecondary),
                        .paragraphStyle: previewStyle
                    ])
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
        if locked { requestEditingFromClick(); super.mouseDown(with: event); return }
        if !locked, let id = blockAt(point), let storage = textStorage,
           let (_, range) = BlockTextStorage.ranges(storage).first(where: { $0.0 == id }) {
            if point.x < 29, isEditable { dragStart = (id, point); setSelectedRange(NSRange(location: range.location, length: 0)); return }
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let accessoryX = textContainerOrigin.x + CGFloat(depth * 24) + 1
            if point.x >= accessoryX - 3 && point.x <= accessoryX + 19 {
                let kind = storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String
                if kind == BlockKind.task.rawValue || kind == BlockKind.toggle.rawValue {
                    if !isEditable { isEditable = true; begin?() }
                    window?.makeFirstResponder(self); activateBlock?(id, kind == BlockKind.task.rawValue ? .checked : .collapse); return
                }
            }
        }
        if !isEditable {
            // Entering edit mode from read mode: place a plain caret at the click
            // instead of letting the tracking loop start a selection.
            let index = characterIndexForInsertion(at: point)
            requestEditingFromClick()
            let caret = NSRange(location: min(index, (string as NSString).length), length: 0)
            setSelectedRange(caret)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEditable, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.setSelectedRange(NSRange(location: min(caret.location, (self.string as NSString).length), length: 0))
            }
            return
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
        if let storage = textStorage, let range = BlockTextStorage.ranges(storage).first(where: { $0.0 == target })?.1 { dropAfter = point.y > rect(for: range).midY }
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
        guard isEditable, !locked else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        if let id = blockAt(point), let storage = textStorage, let range = BlockTextStorage.ranges(storage).first(where: { $0.0 == id })?.1,
           !NSLocationInRange(range.location, selectedRange()) { setSelectedRange(NSRange(location: range.location, length: 0)) }
        let menu = super.menu(for: event) ?? NSMenu()
        if let actions = blockMenu?() { menu.addItem(.separator()); let item = NSMenuItem(title: "Block", action: nil, keyEquivalent: ""); item.submenu = actions; menu.addItem(item) }
        return menu
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
        for (id, range) in BlockTextStorage.ranges(storage) {
            let kind = storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph"
            let metadata = (storage.attribute(.blockMetadata, at: range.location, effectiveRange: nil) as? Data).flatMap { try? JSONDecoder().decode(BlockMetadata.self, from: $0) } ?? .init()
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
    override func paste(_ sender: Any?) { if isEditable, !locked { pasteContent?(NSPasteboard.general) } }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true { return }
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
