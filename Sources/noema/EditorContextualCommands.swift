import AppKit
import VaultCore

/// Immutable native interaction evidence; persistence acknowledgements do not retire it.
struct EditorInteractionContext: Equatable {
    let identity: EditorSession.Identity
    let generation: UUID
    let revision: UInt64
    let selection: NSRange
}

extension RichArticleView.Coordinator {
    var interactionContext: EditorInteractionContext? {
        guard !contextualInteractionsRetired, parent.editable, !parent.locked,
              parent.onSemanticLoad == nil || session.semanticEdit != nil,
              let view, view.isEditable, !view.locked, !view.hasMarkedText(),
              !view.isSettingMarkedText, !changing else { return nil }
        return .init(identity: session.identity, generation: session.generation,
                     revision: session.revision, selection: view.selectedRange())
    }

    func accepts(_ context: EditorInteractionContext, preservingSelection: Bool = true) -> Bool {
        guard let current = interactionContext else { return false }
        return current.identity == context.identity && current.generation == context.generation &&
            current.revision == context.revision && (!preservingSelection || current.selection == context.selection)
    }

    func insertionMenu(after blockID: UUID) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        activeInsertionMenu = menu
        guard let context = interactionContext, document.block(blockID) != nil else { return menu }
        var category = ""
        for command in BlockCommand.matching("") where command.id != "clear-tag" {
            if command.category != category {
                if !category.isEmpty { menu.addItem(.separator()) }
                category = command.category
                let label = NSMenuItem(title: category, action: nil, keyEquivalent: "")
                label.isEnabled = false; menu.addItem(label)
            }
            let item = NSMenuItem(title: command.title, action: #selector(insertContextBlock(_:)), keyEquivalent: "")
            item.target = self; item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)
            item.representedObject = ContextualBlockInsertion(blockID: blockID, command: command, context: context)
            menu.addItem(item)
        }
        return menu
    }

    @objc func insertContextBlock(_ item: NSMenuItem) {
        guard let request = item.representedObject as? ContextualBlockInsertion else { return }
        insert(request.command, after: request.blockID, context: request.context)
    }

    func insert(_ command: BlockCommand, after blockID: UUID, context: EditorInteractionContext) {
        guard accepts(context), document.block(blockID) != nil else { return }
        let kind: BlockKind
        if case .transform(let value) = command.mutation { kind = value } else { kind = .paragraph }
        transaction("Insert " + command.title) {
            document.apply(.insertAfter(kind, semantic: command.semantic), to: blockID)
        }
        clearBlockSelection()
        view?.window?.makeFirstResponder(view)
    }
}

private final class ContextualBlockInsertion {
    let blockID: UUID
    let command: BlockCommand
    let context: EditorInteractionContext
    init(blockID: UUID, command: BlockCommand, context: EditorInteractionContext) {
        self.blockID = blockID; self.command = command; self.context = context
    }
}
