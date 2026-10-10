import AppKit
import VaultCore

// Commands operate on the existing attributed document, never a parallel draft.
struct BlockCommand: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var detail: String
    var prefix: String?
    var semantic: String?
    var aliases: [String]
    var category: String { semantic == nil ? "Basic blocks" : "Semantic blocks" }

    static let all: [Self] = [
        .init(id: "text", title: "Text", symbol: "text.alignleft", detail: "Normal paragraph", prefix: "", aliases: ["paragraph", "plain"]),
        .init(id: "h1", title: "Heading 1", symbol: "textformat.size.larger", detail: "Large heading", prefix: "# ", aliases: ["h1", "title"]),
        .init(id: "h2", title: "Heading 2", symbol: "textformat.size", detail: "Medium heading", prefix: "## ", aliases: ["h2"]),
        .init(id: "h3", title: "Heading 3", symbol: "textformat.size.smaller", detail: "Small heading", prefix: "### ", aliases: ["h3"]),
        .init(id: "bullet", title: "Bulleted list", symbol: "list.bullet", detail: "Bullet item", prefix: "- ", aliases: ["ul", "bullet"]),
        .init(id: "number", title: "Numbered list", symbol: "list.number", detail: "Numbered item", prefix: "1. ", aliases: ["ol", "number"]),
        .init(id: "todo", title: "To-do", symbol: "checkmark.square", detail: "Task item", prefix: "- [ ] ", aliases: ["task", "checkbox"]),
        .init(id: "quote", title: "Quote", symbol: "text.quote", detail: "Indented quotation", prefix: "> ", aliases: ["blockquote"]),
        .init(id: "divider", title: "Divider", symbol: "minus", detail: "Horizontal separator", aliases: ["rule", "hr"]),
        .init(id: "toggle", title: "Toggle", symbol: "chevron.right", detail: "Collapsible nested content", aliases: ["fold", "details"]),
        .init(id: "code", title: "Code", symbol: "chevron.left.forwardslash.chevron.right", detail: "Monospaced code; Shift Return for newline", aliases: ["pre", "codeblock"]),
        .init(id: "callout", title: "Callout", symbol: "info.circle", detail: "Highlighted note", aliases: ["note", "aside"]),
        .init(id: "question", title: "Question", symbol: "questionmark.circle", detail: "An open question", semantic: "question", aliases: ["ques", "ask"]),
        .init(id: "idea", title: "Idea", symbol: "lightbulb", detail: "A thought or hypothesis", semantic: "idea", aliases: ["thought"]),
        .init(id: "important", title: "Important", symbol: "exclamationmark.circle", detail: "Requires attention", semantic: "important", aliases: ["priority"]),
        .init(id: "starred", title: "Starred", symbol: "star", detail: "Valuable material", semantic: "starred", aliases: ["favorite", "star"]),
        .init(id: "definition", title: "Definition", symbol: "book", detail: "Terminology or definition", semantic: "definition", aliases: ["term"]),
        .init(id: "example", title: "Example", symbol: "doc.text", detail: "An illustrative case", semantic: "example", aliases: ["case"]),
        .init(id: "insight", title: "Insight", symbol: "sparkles", detail: "A meaningful observation", semantic: "insight", aliases: ["observation"]),
        .init(id: "warning", title: "Warning", symbol: "exclamationmark.triangle", detail: "Caution or potential problem", semantic: "warning", aliases: ["caution"]),
        .init(id: "reference", title: "Reference", symbol: "bookmark", detail: "Supporting material", semantic: "reference", aliases: ["source", "link"]),
        .init(id: "summary", title: "Summary", symbol: "list.bullet.rectangle", detail: "Condensed synthesis", semantic: "summary", aliases: ["recap"]),
        .init(id: "clear-tag", title: "Remove semantic tag", symbol: "tag.slash", detail: "Keep text and structure", semantic: "", aliases: ["untag"])
    ]

    init(id: String, title: String, symbol: String, detail: String, prefix: String? = nil, semantic: String? = nil, aliases: [String]) {
        self.id = id; self.title = title; self.symbol = symbol; self.detail = detail
        self.prefix = prefix; self.semantic = semantic; self.aliases = aliases
    }

    var mutation: BlockMutation {
        if let semantic { return .semantic(semantic.isEmpty ? nil : semantic) }
        let kinds: [String: BlockKind] = ["text": .paragraph, "h1": .heading1, "h2": .heading2, "h3": .heading3, "bullet": .bullet, "number": .numbered, "todo": .task, "quote": .quote, "code": .code, "divider": .divider, "toggle": .toggle, "callout": .callout]
        return .transform(kinds[id] ?? .paragraph)
    }
    static func shortcut(_ text: String) -> Self? {
        let aliases = ["# ": "h1", "## ": "h2", "### ": "h3", "- ": "bullet", "* ": "bullet", "1. ": "number", "[] ": "todo", "[ ] ": "todo", "- [ ] ": "todo", "> ": "quote", "---": "divider", "```": "code"]
        return aliases[text].flatMap { id in all.first { $0.id == id } }
    }

    static func matching(_ query: String) -> [Self] {
        let query = query.lowercased()
        guard !query.isEmpty else { return all }
        func score(_ command: Self) -> Int? {
            let words = [command.id, command.title.lowercased()] + command.aliases
            if words.contains(query) { return 0 }
            if words.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if words.contains(where: { $0.contains(query) }) { return 2 }
            for word in words {
                var remaining = query[...]
                for character in word where remaining.first == character { remaining = remaining.dropFirst() }
                if remaining.isEmpty { return 3 }
            }
            return nil
        }
        var ranked: [(command: Self, score: Int, index: Int)] = []
        for (index, command) in all.enumerated() {
            if let value = score(command) { ranked.append((command, value, index)) }
        }
        ranked.sort { a, b in a.score == b.score ? a.index < b.index : a.score < b.score }
        return ranked.map { $0.command }
    }

    static func slashRange(in text: String, selection: NSRange) -> NSRange? {
        let ns = text as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let line = ns.lineRange(for: selection)
        let before = ns.substring(with: NSRange(location: line.location, length: selection.location - line.location)) as NSString
        let slash = before.range(of: "/", options: .backwards)
        guard slash.location != NSNotFound else { return nil }
        if slash.location > 0 {
            let previous = before.substring(with: NSRange(location: slash.location - 1, length: 1))
            guard previous.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        }
        let query = before.substring(from: slash.location + 1)
        guard query.count < 60, !query.contains(where: { $0.isWhitespace }) else { return nil }
        return NSRange(location: line.location + slash.location, length: before.length - slash.location)
    }
}

// Keep native button drawing/interaction, with a shared icon column and title inset.
@MainActor final class BlockCommandButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 7, y: rect.midY - 8, width: 16, height: 16)
    }
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var title = super.titleRect(forBounds: rect)
        title.origin.x = rect.minX + 31
        title.size.width = max(0, rect.maxX - 8 - title.minX)
        return title
    }
}

@MainActor final class BlockPalette: NSViewController {
    let stack = NSStackView()
    let scroll = NSScrollView()
    var choose: ((BlockCommand) -> Void)?
    var commands: [BlockCommand] = []
    var selected = 0
    override func loadView() {
        let material = NSVisualEffectView(); material.material = .menu; material.state = .active
        view = material
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        material.addSubview(scroll); scroll.documentView = stack
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: material.topAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -10),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
    }
    func update(_ matches: [BlockCommand]) {
        loadViewIfNeeded(); commands = matches; selected = 0; drawRows()
    }
    func move(_ delta: Int) {
        guard !commands.isEmpty else { return }
        selected = (selected + delta + commands.count) % commands.count; drawRows()
        revealSelection()
    }
    func revealSelection() {
        view.layoutSubtreeIfNeeded(); stack.layoutSubtreeIfNeeded()
        if selected == 0 {
            let y = stack.isFlipped ? 0 : max(0, stack.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        if let button = stack.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == selected }) { stack.scrollToVisible(button.frame) }
    }
    func execute() { if commands.indices.contains(selected) { choose?(commands[selected]) } }
    private func drawRows() {
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        var category = ""
        for (index, command) in commands.enumerated() {
            if command.category != category {
                category = command.category
                if index > 0 {
                    if let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(8, after: previous) }
                    let separator = NSBox(); separator.boxType = .separator
                    stack.addArrangedSubview(separator)
                    separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    stack.setCustomSpacing(7, after: separator)
                }
                let label = NSTextField(labelWithString: category); label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
                stack.addArrangedSubview(label)
                stack.setCustomSpacing(6, after: label)
            }
            let button = NSButton(title: command.title, target: self, action: #selector(clicked(_:)))
            button.cell = BlockCommandButtonCell(textCell: command.title)
            button.target = self; button.action = #selector(clicked(_:))
            button.tag = index; button.bezelStyle = .recessed; button.isBordered = index == selected
            button.font = .systemFont(ofSize: 14)
            button.attributedTitle = NSAttributedString(string: command.title, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
            button.imageScaling = .scaleProportionallyDown
            let presentation = SemanticPresentation.find(command.semantic)
            let image = NSImage(systemSymbolName: presentation?.symbol ?? command.symbol, accessibilityDescription: command.title)
            if let presentation {
                button.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [presentation.accent]))
            } else { button.image = image }
            button.imagePosition = .imageLeading; button.alignment = .left
            button.toolTip = command.detail
            button.setAccessibilityLabel(command.title + ". " + command.detail)
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        if commands.isEmpty { stack.addArrangedSubview(NSTextField(labelWithString: "No matching commands")) }
        let sections = commands.enumerated().filter { index, command in index == 0 || commands[index - 1].category != command.category }.count
        let rowHeight = CGFloat(max(1, commands.count) * 24)
        let sectionHeight = CGFloat(sections * 21 + max(0, sections - 1) * 15)
        preferredContentSize = NSSize(width: 240, height: min(405, rowHeight + sectionHeight + 20))
    }
    @objc private func clicked(_ button: NSButton) { selected = button.tag; execute() }
}

// A nonactivating native panel keeps the editor's keyboard focus and gives us
// deterministic vertical placement, without NSPopover's sideways fallback.
@MainActor final class BlockSuggestionPanel: NSPanel {
    var dismiss: (() -> Void)?
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    var isShown: Bool { isVisible }
    init(palette: BlockPalette) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; hasShadow = true; isOpaque = false
        backgroundColor = .clear; hidesOnDeactivate = true
        contentViewController = palette
        palette.loadViewIfNeeded(); palette.view.wantsLayer = true
        palette.view.layer?.cornerRadius = 10; palette.view.layer?.masksToBounds = true
        setAccessibilityLabel("Block suggestions")
    }
    func show(frame: NSRect, of parent: NSWindow) {
        if self.parent !== parent {
            close(); parent.addChildWindow(self, ordered: .above)
        }
        setFrame(frame, display: true); orderFront(nil)
        (contentViewController as? BlockPalette)?.revealSelection()
        if eventMonitor == nil {
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
                if let self, event.window !== self { self.dismiss?() }
                return event
            }
            for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.dismiss?() }
                })
            }
        }
    }
    override func close() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll(); parent?.removeChildWindow(self)
        super.close()
    }
    static func frame(caret: NSRect, available: NSRect, desired: NSSize) -> NSRect {
        let gap: CGFloat = 6
        let below = max(0, caret.minY - available.minY - gap)
        let above = max(0, available.maxY - caret.maxY - gap)
        let placeBelow = below >= desired.height || below >= above
        let height = min(desired.height, placeBelow ? below : above)
        let width = min(desired.width, available.width)
        let x = max(available.minX, min(caret.minX, available.maxX - width))
        return NSRect(x: x, y: placeBelow ? caret.minY - gap - height : caret.maxY + gap, width: width, height: height)
    }
}
