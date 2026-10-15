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
        let matchCount = targets.filter { matches($0, command) }.count
        let mark: Mark = matchCount == 0 ? .off : (matchCount == targets.count ? .on : .mixed)
        let symbol = SemanticPresentation.find(command.semantic)?.symbol ?? command.symbol
        return Choice(title: command.title, symbol: symbol, commandID: command.id, mark: mark, enabled: true)
    }

    private static func matches(_ block: EditorBlock, _ command: BlockCommand) -> Bool {
        if let semantic = command.semantic { return block.metadata.semantic == (semantic.isEmpty ? nil : semantic) }
        if case .transform(let kind) = command.mutation { return block.kind == kind }
        return false
    }
}

@MainActor final class BlockHandleMenuController: NSObject {
    var onAction: ((BlockHandleMenuAction) -> Void)?
    var onDismiss: (() -> Void)?
    private var menu: NSMenu?
    var isShown: Bool { menu != nil }

    @discardableResult func show(model: BlockHandleMenuModel, anchor: NSRect, in view: NSView) -> Bool {
        guard view.window != nil else { return false }
        close()
        let popup = makeMenu(model: model)
        menu = popup
        // Let the caller finish installing its interaction context before AppKit tracks events.
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.menu === popup else { return }
            defer {
                if self.menu === popup {
                    self.menu = nil
                    self.onDismiss?()
                }
            }
            guard let view, view.window != nil else { return }
            popup.popUp(positioning: nil, at: NSPoint(x: anchor.maxX, y: anchor.minY), in: view)
        }
        return true
    }

    func close() {
        let current = menu
        menu = nil
        current?.cancelTracking()
    }

    func makeMenu(model: BlockHandleMenuModel) -> NSMenu {
        let popup = NSMenu(title: "Block actions")
        popup.autoenablesItems = false
        for row in model.rows {
            switch row {
            case .turnInto, .semantic:
                let format = row == .turnInto
                let item = NSMenuItem(title: format ? "Turn into" : "Semantic", action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: format ? "textformat" : "tag", accessibilityDescription: nil)
                let submenu = NSMenu(title: item.title)
                submenu.autoenablesItems = false
                for choice in format ? model.formatChoices : model.semanticChoices {
                    let entry = actionItem(choice.title, symbol: choice.symbol, action: choice.commandID.map { .command($0) })
                    if let accent = SemanticPresentation.find(choice.commandID)?.accent {
                        entry.image = entry.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [accent]))
                    }
                    entry.isEnabled = choice.enabled && choice.commandID != nil
                    entry.state = choice.mark == .on ? .on : (choice.mark == .mixed ? .mixed : .off)
                    submenu.addItem(entry)
                }
                item.submenu = submenu
                popup.addItem(item)
            case .insertBelow:
                popup.addItem(actionItem("Insert below", symbol: "plus", action: .insertBelow))
            case .delete:
                popup.addItem(.separator())
                popup.addItem(actionItem("Delete", symbol: "trash", action: .delete))
            case .timestamp(let text):
                popup.addItem(.separator())
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                popup.addItem(item)
            }
        }
        return popup
    }

    private func actionItem(_ title: String, symbol: String, action: BlockHandleMenuAction?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = action
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard sender.isEnabled, let action = sender.representedObject as? BlockHandleMenuAction else { return }
        onAction?(action)
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
        guard let view, view.window != nil else { return }
        guard let model = beginHandleMenu(for: blockID) else { return }
        presentingHandleMenu = true
        let shown = handleMenu.show(model: model, anchor: view.handleMenuAnchor(for: blockID), in: view)
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
