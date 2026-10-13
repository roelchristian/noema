import AppKit

/// Presentation only: geometry and all document commands remain in the native editor.
@MainActor final class EditorBlockControls: NSView {
    private let plus = NSButton()
    private let handle = EditorBlockHandleButton()
    weak var editor: ArticleTextView?
    var blockID: UUID?
    override var isFlipped: Bool { true }

    init(editor: ArticleTextView) {
        self.editor = editor
        super.init(frame: .zero)
        for button in [plus, handle] {
            button.bezelStyle = .recessed
            button.isBordered = false
            button.refusesFirstResponder = true
            button.imageScaling = .scaleProportionallyDown
            addSubview(button)
        }
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Insert block after this block")
        plus.setAccessibilityLabel("Insert block after this block")
        plus.toolTip = "Insert block after this block"
        plus.target = self; plus.action = #selector(insert(_:))
        handle.image = NSImage(size: NSSize(width: 14, height: 18), flipped: false) { rect in
            NSColor.secondaryLabelColor.setFill()
            for column in 0..<2 { for row in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: 3 + CGFloat(column * 5), y: 3 + CGFloat(row * 5), width: 2, height: 2)).fill()
            } }
            return true
        }
        handle.setAccessibilityLabel("Block actions; drag to reorder")
        handle.toolTip = "Click for block actions; drag to move"
        handle.editor = editor
        handle.target = self; handle.action = #selector(actions(_:))
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(blockID: UUID, handleRect: NSRect) {
        self.blockID = blockID
        let plusOnLeft = handleRect.minX >= 24
        frame = NSRect(x: plusOnLeft ? handleRect.minX - 24 : handleRect.minX, y: handleRect.minY, width: 46, height: 24)
        plus.frame = NSRect(x: plusOnLeft ? 0 : 24, y: 0, width: 22, height: 24)
        handle.frame = NSRect(x: plusOnLeft ? 24 : 0, y: 0, width: 22, height: 24)
        isHidden = false
    }
    @objc private func insert(_ sender: Any?) {
        guard let editor, let id = blockID, editor.isEditable, !editor.locked,
              let menu = editor.insertBlockMenu?(id) else { return }
        editor.contextualInteractionDismiss?()
        menu.popUp(positioning: nil, at: NSPoint(x: plus.frame.minX, y: bounds.maxY), in: self)
    }
    @objc private func actions(_ sender: Any?) {
        editor?.showFocusedBlockMenu()
    }
}

/// Forward pointer gestures to the existing drag engine; accessibility activation
/// uses the regular button action and therefore opens the same command menu.
@MainActor private final class EditorBlockHandleButton: NSButton {
    weak var editor: ArticleTextView?
    override func mouseDown(with event: NSEvent) { editor?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { editor?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { editor?.mouseUp(with: event) }
}
