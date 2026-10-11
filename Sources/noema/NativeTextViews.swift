import SwiftUI
import AppKit
import VaultCore

struct MarkdownEditor: NSViewRepresentable {
    @Environment(\.noemaTheme) private var theme
    @AppStorage(EditorPreferences.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorPreferences.fontSizeKey) private var fontSize = EditorTypography.defaultSize
    @Binding var text: String
    var action: EditorAction?
    var onWikiQuery: (String?) -> Void
    var editable = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = NSTextView()
        view.isRichText = false; view.allowsUndo = editable; view.isEditable = editable
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.font = EditorTypography(family: fontFamily, size: fontSize).font(for: .code)
        view.textColor = theme.nativeText(); view.backgroundColor = theme.native(.surfaceElevated)
        view.textContainerInset = NSSize(width: 28, height: 24)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.string = text
        scroll.documentView = view; context.coordinator.view = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        // Recolour in place, retaining selection, undo history, and the current draft.
        view.textColor = theme.nativeText()
        view.backgroundColor = theme.native(.surfaceElevated)
        view.insertionPointColor = theme.native(.accentPrimary)
        view.selectedTextAttributes = [
            .foregroundColor: NSColor.selectedTextColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        view.isEditable = editable
        let typography = EditorTypography(family: fontFamily, size: fontSize)
        if context.coordinator.typography != typography {
            context.coordinator.typography = typography
            let selections = view.selectedRanges
            let origin = scroll.contentView.bounds.origin
            view.font = typography.font(for: .code)
            view.defaultParagraphStyle = typography.paragraphStyle(for: .code, previous: nil)
            if let storage = view.textStorage, storage.length > 0 {
                storage.addAttribute(.paragraphStyle, value: view.defaultParagraphStyle!, range: NSRange(location: 0, length: storage.length))
            }
            view.selectedRanges = selections
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            view.undoManager?.removeAllActions()
        }
        if let action, action.id != context.coordinator.lastAction {
            context.coordinator.lastAction = action.id
            context.coordinator.perform(action.operation)
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var view: NSTextView?
        var lastAction: UUID?
        var typography: EditorTypography?
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string
            updateQuery()
        }
        func textViewDidChangeSelection(_ notification: Notification) { updateQuery() }
        private func wikiRange() -> NSRange? {
            guard let view else { return nil }
            let cursor = view.selectedRange().location
            let before = (view.string as NSString).substring(to: cursor)
            guard let open = before.range(of: "[[", options: .backwards) else { return nil }
            let suffix = String(before[open.upperBound...])
            guard !suffix.contains("]"), !suffix.contains("\n"), suffix.count < 100 else { return nil }
            return NSRange(open.lowerBound..<before.endIndex, in: before)
        }
        private func updateQuery() {
            guard let range = wikiRange(), let view else { parent.onWikiQuery(nil); return }
            let query = (view.string as NSString).substring(with: range).dropFirst(2)
            parent.onWikiQuery(String(query))
        }
        func perform(_ operation: EditorAction.Operation) {
            guard let view else { return }
            view.window?.makeFirstResponder(view)
            let range = view.selectedRange()
            switch operation {
            case .wrap(let prefix, let suffix):
                let selection = (view.string as NSString).substring(with: range)
                view.insertText(prefix + selection + suffix, replacementRange: range)
                view.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: (selection as NSString).length))
            case .block: break
            case .wikiLink(let title):
                var replacement = wikiRange() ?? range
                let ns = view.string as NSString
                if NSMaxRange(replacement) + 2 <= ns.length, ns.substring(with: NSRange(location: NSMaxRange(replacement), length: 2)) == "]]" { replacement.length += 2 }
                view.insertText("[[" + title + "]]", replacementRange: replacement)
            }
            parent.text = view.string; parent.onWikiQuery(nil)
        }
    }
}

struct MarkdownPreview: NSViewRepresentable {
    @Environment(\.noemaTheme) private var theme
    @AppStorage(EditorPreferences.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorPreferences.fontSizeKey) private var fontSize = EditorTypography.defaultSize
    var blocks: [PreviewBlock]
    var onWikiLink: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onWikiLink) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = ReadingTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 24, height: 24)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.follow = onWikiLink
        guard let view = scroll.documentView as? ReadingTextView else { return }
        view.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.selectedTextAttributes = [
            .foregroundColor: NSColor.selectedTextColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        let typography = EditorTypography(family: fontFamily, size: fontSize)
        guard context.coordinator.blocks != blocks || context.coordinator.theme != theme || context.coordinator.typography != typography else { return }
        context.coordinator.blocks = blocks
        context.coordinator.theme = theme
        context.coordinator.typography = typography
        view.replacePresentation(SourceTextPresentation.markdown(blocks, typography: typography, theme: theme), typography: typography)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var follow: (String) -> Void
        var blocks: [PreviewBlock]?
        var theme: NoemaTheme?
        var typography: EditorTypography?
        init(_ follow: @escaping (String) -> Void) { self.follow = follow }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if url.scheme == "noema", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value { follow(target); return true }
            NSWorkspace.shared.open(url); return true
        }
    }
}
