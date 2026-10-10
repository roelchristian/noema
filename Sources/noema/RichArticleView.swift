import SwiftUI
import AppKit
import VaultCore

struct RichArticleView: NSViewRepresentable {
    @Environment(\.noemaTheme) var theme
    @Binding var text: String
    var reading: Bool
    var locked: Bool
    var action: EditorAction?
    var onBegin: () -> Void
    var onEnd: () -> Void
    var onWikiLink: (String) -> Void
    var onWikiQuery: (String?) -> Void = { _ in }
    var noteID: UUID? = nil
    var onBlockLink: (URL) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = ArticleTextView(); view.isRichText = true; view.allowsUndo = true; view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 152, height: 24); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Article block editor")
        view.setAccessibilityHelp("Click to edit. Unlock a locked article first. Slash opens block commands. Use the Block context menu for structure, tags, and status. Command Option A selects the document.")
        view.registerForDraggedTypes([ArticleTextView.dragType])
        view.delegate = context.coordinator; context.coordinator.view = view; scroll.documentView = view
        context.coordinator.load(text)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let view = coordinator.view else { return }
        view.locked = locked || coordinator.document.unsupportedVersion
        view.isEditable = !reading && !view.locked; view.theme = theme
        view.begin = onBegin; view.end = onEnd
        view.lockedClick = onBegin
        view.handleKey = { [weak coordinator] in coordinator?.handleKey($0) ?? false }
        view.blockMenu = { [weak coordinator] in coordinator?.contextMenu() ?? NSMenu() }
        view.activateBlock = { [weak coordinator] id, command in coordinator?.mutate(command, id: id, name: "Change block") }
        view.canReorder = { [weak coordinator] in coordinator?.document.canReorder($0, before: $1) ?? false }
        view.pasteContent = { [weak coordinator] in coordinator?.paste($0) }
        view.insertionPointColor = theme.native(.accentPrimary)
        view.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
        if coordinator.lastText != text { coordinator.load(text); view.undoManager?.removeAllActions() }
        else if coordinator.lastTheme != theme { coordinator.render(selection: view.selectedRange()) }
        if let action, coordinator.lastAction != action.id {
            if case .block = action.operation { coordinator.lastAction = action.id; coordinator.perform(action.operation) }
            else if view.isEditable { coordinator.lastAction = action.id; coordinator.perform(action.operation) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.suggestions.close()
        coordinator.view?.delegate = nil
    }
}
