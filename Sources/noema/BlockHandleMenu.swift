import AppKit
import VaultCore

enum BlockHandleMenuAction: Equatable {
    case command(String)
    case insertBelow
    case delete
}

@MainActor struct BlockHandleMenuModel: Equatable {
    enum Row: Equatable {
        case turnInto
        case semantic
        case insertBelow
        case delete
        case timestamp(String)
    }

    enum Mark: Equatable {
        case off, on, mixed
    }

    struct Choice: Equatable {
        var title: String
        var symbol: String
        var commandID: String?
        var mark: Mark
        var enabled: Bool
    }

    var rows: [Row]
    var formatChoices: [Choice]
    var semanticChoices: [Choice]

    static func timestamp(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func make(handle: EditorBlock, targets: [EditorBlock], locale: Locale = .current) -> Self {
        let subjects = targets.isEmpty ? [handle] : targets
        let format = BlockCommand.all.filter { $0.semantic == nil }.map { choice($0, targets: subjects) }
        var semantic = BlockCommand.all.filter { $0.semantic != nil }.map { choice($0, targets: subjects) }
        let unknown = Set(subjects.compactMap(\.metadata.semantic)).filter { SemanticPresentation.find($0) == nil }.sorted()
        for designation in unknown {
            semantic.append(Choice(title: designation, symbol: "tag", commandID: nil, mark: .on, enabled: false))
        }
        return Self(rows: [.turnInto, .semantic, .insertBelow, .delete, .timestamp(timestamp(handle.modifiedAt, locale: locale))],
                    formatChoices: format, semanticChoices: semantic)
    }

    private static func choice(_ command: BlockCommand, targets: [EditorBlock]) -> Choice {
        let matches = targets.filter { matches($0, command) }.count
        let mark: Mark = matches == 0 ? .off : (matches == targets.count ? .on : .mixed)
        let symbol = SemanticPresentation.find(command.semantic)?.symbol ?? command.symbol
        return Choice(title: command.title, symbol: symbol, commandID: command.id, mark: mark, enabled: true)
    }

    private static func matches(_ block: EditorBlock, _ command: BlockCommand) -> Bool {
        if let semantic = command.semantic { return block.metadata.semantic == (semantic.isEmpty ? nil : semantic) }
        if case .transform(let kind) = command.mutation { return block.kind == kind }
        return false
    }
}

@MainActor final class BlockHandleMenuController {
    var onAction: ((BlockHandleMenuAction) -> Void)?
    var onDismiss: (() -> Void)?
    var isShown: Bool { panel.isVisible }

    private let panel = BlockHandleMenuPanel(label: "Block actions")
    private let submenu = BlockHandleMenuPanel(label: "Block actions")
    private let card = BlockHandleMenuCard()
    private let submenuCard = BlockHandleMenuCard()
    private var model: BlockHandleMenuModel?
    private var theme = NoemaTheme()
    private var windowActive = true
    private weak var host: NSView?
    private var highlight = 0
    private var submenuHighlight = 0
    private var submenuChoices: [BlockHandleMenuModel.Choice] = []
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    private enum MainKind { case turnInto, semantic, insertBelow, delete }
    private var mainKinds: [MainKind] = []

    init() {
        panel.contentView = card
        submenu.contentView = submenuCard
    }

    @discardableResult func show(model: BlockHandleMenuModel, anchor: NSRect, in view: NSView, theme: NoemaTheme, active: Bool) -> Bool {
        guard let window = view.window else { return false }
        self.model = model
        self.theme = theme
        self.windowActive = active
        host = view
        highlight = 0
        closeSubmenu()
        rebuildMain()
        let screenAnchor = window.convertToScreen(view.convert(anchor, to: nil))
        let viewport = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        let available = viewport.intersection(window.screen?.visibleFrame ?? window.frame)
        guard !available.isEmpty else { close(); return false }
        let frame = Self.frame(anchor: screenAnchor, available: available, desired: card.preferredSize)
        panel.setAccessibilityHelp(Self.footer(model))
        panel.show(frame: frame, of: window)
        installMonitors(parent: window)
        window.makeFirstResponder(view)
        return true
    }

    func close() {
        guard panel.isVisible || submenu.isVisible else { return }
        removeMonitors()
        closeSubmenu()
        panel.orderOut(nil)
        if let parent = panel.parent { parent.removeChildWindow(panel) }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard isShown else { return false }
        switch event.keyCode {
        case 126: move(-1)
        case 125: move(1)
        case 123: closeSubmenu()
        case 124: if submenu.isVisible == false { openSubmenu() }
        case 36, 76: activate()
        default: onDismiss?()
        }
        return true
    }

    private func rebuildMain() {
        guard let model else { return }
        let primary = theme.nativeText(for: .textPrimary, on: .elevated, active: windowActive)
        let destructive = theme.native(for: .destructive, active: windowActive)
        let hover = theme.native(for: .hover, active: windowActive)
        var entries: [BlockHandleMenuCard.Entry] = []
        mainKinds = []
        func add(_ title: String, symbol: String, kind: MainKind, destructiveRow: Bool = false, chevron: Bool = false) {
            let color = destructiveRow ? destructive : primary
            entries.append(.init(title: title, symbol: symbol, trailing: chevron ? "chevron.right" : nil,
                                  titleColor: color, iconColor: color, hover: hover, enabled: true,
                                  accessibilityLabel: title))
            mainKinds.append(kind)
        }
        add("Turn into", symbol: "arrow.triangle.2.circlepath", kind: .turnInto, chevron: true)
        add("Semantic", symbol: "tag", kind: .semantic, chevron: true)
        add("Insert below", symbol: "plus", kind: .insertBelow)
        add("Delete", symbol: "trash", kind: .delete, destructiveRow: true)
        let footer = Self.footer(model)
        card.show(entries: entries, separatorsBefore: [3], footer: footer,
                  footerColor: theme.native(for: .textTertiary, active: windowActive),
                  separator: theme.native(for: .separator, active: windowActive))
        card.onPress = { [weak self] index in
            self?.highlight = index
            self?.card.setHighlight(index)
            self?.activate()
        }
        card.onHover = { [weak self] index in
            guard let self else { return }
            if index != highlight { closeSubmenu() }
            highlight = index
            card.setHighlight(index)
        }
        card.setHighlight(highlight)
        card.setAccessibilityHelp(footer)
    }

    private func openSubmenu() {
        guard let model, mainKinds.indices.contains(highlight) else { return }
        let choices: [BlockHandleMenuModel.Choice]
        let label: String
        switch mainKinds[highlight] {
        case .turnInto: choices = model.formatChoices; label = "Turn into"
        case .semantic: choices = model.semanticChoices; label = "Semantic"
        default: closeSubmenu(); return
        }
        guard let host, let window = host.window, let row = card.row(highlight) else { return }
        submenuChoices = choices
        submenuHighlight = choices.firstIndex { $0.enabled && $0.mark == .on } ?? choices.firstIndex { $0.enabled } ?? 0
        let primary = theme.nativeText(for: .textPrimary, on: .elevated, active: windowActive)
        let disabled = theme.native(for: .disabledText, active: windowActive)
        let hover = theme.native(for: .hover, active: windowActive)
        let entries = choices.map { choice -> BlockHandleMenuCard.Entry in
            let trailing: String? = switch choice.mark {
            case .on: "checkmark"
            case .mixed: "minus"
            case .off: nil
            }
            let suffix: String = switch choice.mark {
            case .on: ", selected"
            case .mixed: ", mixed"
            case .off: ""
            }
            let titleColor = choice.enabled ? primary : disabled
            let iconColor = choice.enabled ? (SemanticPresentation.find(choice.commandID)?.accent ?? primary) : disabled
            return .init(title: choice.title, symbol: choice.symbol, trailing: trailing,
                          titleColor: titleColor, iconColor: iconColor, hover: hover, enabled: choice.enabled,
                          accessibilityLabel: choice.title + suffix)
        }
        submenuCard.show(entries: entries, separatorsBefore: [], footer: nil, footerColor: primary, separator: theme.native(for: .separator, active: windowActive))
        submenuCard.onPress = { [weak self] index in
            self?.submenuHighlight = index
            self?.submenuCard.setHighlight(index)
            self?.activateSubmenu()
        }
        submenuCard.onHover = { [weak self] index in
            self?.submenuHighlight = index
            self?.submenuCard.setHighlight(index)
        }
        submenuCard.setHighlight(submenuHighlight)
        submenu.setAccessibilityLabel(label)
        card.layoutSubtreeIfNeeded()
        let rowRect = row.window?.convertToScreen(row.convert(row.bounds, to: nil)) ?? .zero
        let viewport = window.convertToScreen(host.convert(host.visibleRect, to: nil))
        let available = viewport.intersection(window.screen?.visibleFrame ?? window.frame)
        guard !available.isEmpty else { return }
        let frame = Self.sideFrame(row: rowRect, available: available, desired: submenuCard.preferredSize)
        submenu.show(frame: frame, of: window)
    }

    private func closeSubmenu() {
        submenuChoices = []
        guard submenu.isVisible else { return }
        submenu.orderOut(nil)
        if let parent = submenu.parent { parent.removeChildWindow(submenu) }
    }

    private func move(_ delta: Int) {
        if submenu.isVisible { moveSubmenu(delta); return }
        guard !mainKinds.isEmpty else { return }
        highlight = min(max(0, highlight + delta), mainKinds.count - 1)
        card.setHighlight(highlight)
        closeSubmenu()
    }

    private func moveSubmenu(_ delta: Int) {
        let enabled = submenuChoices.indices.filter { submenuChoices[$0].enabled }
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex(of: submenuHighlight) ?? 0
        let next = min(max(0, current + delta), enabled.count - 1)
        submenuHighlight = enabled[next]
        submenuCard.setHighlight(submenuHighlight)
    }

    private func activate() {
        if submenu.isVisible { activateSubmenu(); return }
        guard mainKinds.indices.contains(highlight) else { return }
        switch mainKinds[highlight] {
        case .turnInto, .semantic: openSubmenu()
        case .insertBelow: onAction?(.insertBelow)
        case .delete: onAction?(.delete)
        }
    }

    private func activateSubmenu() {
        guard submenuChoices.indices.contains(submenuHighlight) else { return }
        let choice = submenuChoices[submenuHighlight]
        guard choice.enabled, let id = choice.commandID else { return }
        onAction?(.command(id))
    }

    private static func footer(_ model: BlockHandleMenuModel) -> String {
        model.rows.compactMap { if case .timestamp(let text) = $0 { return text }; return nil }.first ?? ""
    }

    private func installMonitors(parent: NSWindow) {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel || event.window === self.submenu { return event }
            self.onDismiss?()
            return event
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onDismiss?() }
            })
        }
    }

    private func removeMonitors() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
    }

    static func frame(anchor: NSRect, available: NSRect, desired: NSSize) -> NSRect {
        let gap: CGFloat = 6
        let width = min(desired.width, max(0, available.width))
        let height = min(desired.height, max(0, available.height))
        let left = anchor.minX - gap - width
        let x = left >= available.minX ? left : min(max(available.minX, anchor.maxX + gap), max(available.minX, available.maxX - width))
        let aligned = anchor.maxY - height
        let y = min(max(aligned, available.minY), max(available.minY, available.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func sideFrame(row: NSRect, available: NSRect, desired: NSSize) -> NSRect {
        let gap: CGFloat = 4
        let width = min(desired.width, max(0, available.width))
        let height = min(desired.height, max(0, available.height))
        let right = row.maxX + gap
        let x = right + width <= available.maxX ? right : max(available.minX, row.minX - gap - width)
        let y = min(max(row.maxY - height, available.minY), max(available.minY, available.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor private final class BlockHandleMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(label: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = true
        setAccessibilityLabel(label)
    }

    func show(frame: NSRect, of parent: NSWindow) {
        if self.parent !== parent {
            orderOut(nil)
            parent.addChildWindow(self, ordered: .above)
        }
        setFrame(frame, display: true)
        orderFront(nil)
    }
}

@MainActor private final class BlockHandleMenuCard: NSVisualEffectView {
    struct Entry {
        var title: String
        var symbol: String
        var trailing: String?
        var titleColor: NSColor
        var iconColor: NSColor
        var hover: NSColor
        var enabled: Bool
        var accessibilityLabel: String
    }

    var onPress: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private let stack = NSStackView()
    private var actionRows: [BlockHandleMenuRowView] = []
    private let width: CGFloat = 240

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .menu
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor)
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Block actions")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(entries: [Entry], separatorsBefore: Set<Int>, footer: String?, footerColor: NSColor, separator: NSColor) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        actionRows = []
        for (index, entry) in entries.enumerated() {
            if separatorsBefore.contains(index) { addSeparator(separator) }
            let row = BlockHandleMenuRowView(entry: entry)
            row.onHover = { [weak self] in self?.onHover?(index) }
            row.onPress = { [weak self] in self?.onPress?(index) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            actionRows.append(row)
        }
        if footer != nil { addSeparator(separator) }
        if let footer { addFooter(footer, color: footerColor) }
    }

    func row(_ index: Int) -> NSView? { actionRows.indices.contains(index) ? actionRows[index] : nil }

    func setHighlight(_ index: Int?) {
        for (rowIndex, row) in actionRows.enumerated() { row.highlighted = rowIndex == index }
    }

    var preferredSize: NSSize {
        let rows = CGFloat(actionRows.count) * NoemaMetrics.comfortableRowHeight
        let separators = CGFloat(stack.arrangedSubviews.filter { $0 is BlockHandleMenuSeparator }.count) * 9
        let footer: CGFloat = stack.arrangedSubviews.contains { !($0 is BlockHandleMenuRowView) && !($0 is BlockHandleMenuSeparator) } ? 32 : 0
        return NSSize(width: width, height: max(44, rows + separators + footer + 12))
    }

    private func addSeparator(_ color: NSColor) {
        let line = BlockHandleMenuSeparator()
        line.color = color
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addFooter(_ text: String, color: NSColor) {
        let box = NSView()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = color
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = width - 44
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(text)
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6)
        ])
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

@MainActor private final class BlockHandleMenuSeparator: NSView {
    var color: NSColor = .separatorColor { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 9) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSRect(x: 8, y: bounds.midY - 0.5, width: max(0, bounds.width - 16), height: 1).fill()
    }
}

@MainActor private final class BlockHandleMenuRowView: NSView {
    var highlighted = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    var onHover: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let trailing = NSImageView()
    private let entry: BlockHandleMenuCard.Entry

    init(entry: BlockHandleMenuCard.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: NoemaMetrics.comfortableRowHeight).isActive = true
        icon.imageScaling = .scaleProportionallyDown
        icon.image = symbol(entry.symbol, color: entry.iconColor)
        label.cell = BlockHandleMenuLabelCell(textCell: entry.title)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = entry.titleColor
        label.stringValue = entry.title
        label.lineBreakMode = .byTruncatingTail
        label.cell?.lineBreakMode = .byTruncatingTail
        trailing.imageScaling = .scaleProportionallyDown
        if let name = entry.trailing { trailing.image = symbol(name, color: entry.titleColor) }
        else { trailing.isHidden = true }
        for item in [icon, label, trailing] {
            item.translatesAutoresizingMaskIntoConstraints = true
            item.setAccessibilityElement(false)
            addSubview(item)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(entry.accessibilityLabel)
        setAccessibilityEnabled(entry.enabled)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted, entry.enabled else { return }
        entry.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: NoemaSpacing.xs, dy: 1), xRadius: NoemaMetrics.radiusSmall, yRadius: NoemaMetrics.radiusSmall).fill()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        icon.frame = NSRect(x: NoemaSpacing.sm, y: (height - 16) / 2, width: 16, height: 16)
        trailing.frame = NSRect(x: bounds.width - NoemaSpacing.sm - 14, y: (height - 12) / 2, width: 14, height: 12)
        let labelX = NoemaSpacing.sm + 16 + NoemaSpacing.sm
        label.frame = NSRect(x: labelX, y: 0, width: max(0, trailing.frame.minX - labelX - NoemaSpacing.xs), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onHover?() }
    override func mouseUp(with event: NSEvent) {
        guard entry.enabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard entry.enabled else { return false }
        onPress?()
        return true
    }

    private func symbol(_ name: String, color: NSColor) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let sized = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        return sized?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }
}

@MainActor private final class BlockHandleMenuLabelCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: rect)
        let height = (font ?? .systemFont(ofSize: 13)).boundingRectForFont.height
        guard rect.height > height else { return rect }
        rect.origin.y += (rect.height - height) / 2
        rect.size.height = height
        return rect
    }
}

extension RichArticleView.Coordinator {
    func handleMenuModel(for blockID: UUID, locale: Locale = .current) -> BlockHandleMenuModel? {
        guard let handle = document.block(blockID) else { return nil }
        let targets = selectedBlockIDs.contains(blockID) ? actionBlocks : [handle]
        return BlockHandleMenuModel.make(handle: handle, targets: targets, locale: locale)
    }

    @discardableResult func beginHandleMenu(for blockID: UUID) -> BlockHandleMenuModel? {
        guard let context = interactionContext, let model = handleMenuModel(for: blockID) else { return nil }
        handleMenuContext = context
        handleMenuBlockID = blockID
        return model
    }

    func presentHandleMenu(for blockID: UUID) {
        dismissPalette()
        guard let view, let window = view.window else { return }
        guard let model = beginHandleMenu(for: blockID) else { return }
        presentingHandleMenu = true
        let shown = handleMenu.show(model: model, anchor: view.handleMenuAnchor(for: blockID), in: view,
                                     theme: parent.theme, active: window.isKeyWindow)
        presentingHandleMenu = false
        if !shown { dismissHandleMenu() }
    }

    func performHandleMenu(_ action: BlockHandleMenuAction) {
        guard let context = handleMenuContext, let blockID = handleMenuBlockID else { return }
        guard accepts(context, preservingSelection: false), document.block(blockID) != nil else {
            dismissHandleMenu()
            return
        }
        dismissHandleMenu()
        switch action {
        case .command(let id):
            guard let command = BlockCommand.all.first(where: { $0.id == id }) else { return }
            mutate(command.mutation, id: blockID, name: command.title)
        case .insertBelow:
            transaction("Insert below") {
                document.apply(.insertAfter(.paragraph, semantic: nil), to: blockID)
            }
            clearBlockSelection()
            view?.window?.makeFirstResponder(view)
        case .delete:
            mutate(.delete, id: blockID, name: "Delete block")
        }
    }

    func dismissHandleMenu() {
        guard !presentingHandleMenu, !dismissingHandleMenu else { return }
        guard handleMenuContext != nil || handleMenu.isShown else { return }
        dismissingHandleMenu = true
        handleMenuContext = nil
        handleMenuBlockID = nil
        handleMenu.close()
        dismissingHandleMenu = false
    }
}
