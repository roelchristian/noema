import SwiftUI
import AppKit
import VaultCore

struct MarkdownEditor: NSViewRepresentable {
    @Environment(\.noemaTheme) private var theme
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
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
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
    var blocks: [PreviewBlock]
    var onWikiLink: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onWikiLink) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.textContainerInset = NSSize(width: 28, height: 24)
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
        guard let view = scroll.documentView as? NSTextView else { return }
        view.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.selectedTextAttributes = [
            .foregroundColor: NSColor.selectedTextColor,
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        guard context.coordinator.blocks != blocks || context.coordinator.theme != theme else { return }
        let selection = view.selectedRange()
        context.coordinator.blocks = blocks
        context.coordinator.theme = theme
        let result = NSMutableAttributedString(string: "")
        for block in blocks {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 16
            var size: CGFloat = 16, weight: NSFont.Weight = .regular, color = theme.nativeText()
            switch block.style {
            case .heading(let level): size = [30, 24, 20, 18, 17, 16][min(max(level - 1, 0), 5)]; weight = .semibold; paragraph.paragraphSpacingBefore = 16
            case .quote: color = theme.nativeText(.textMuted); paragraph.headIndent = 16; paragraph.firstLineHeadIndent = 16
            case .code: size = 14; paragraph.lineSpacing = 3
            case .rule: color = theme.native(.border)
            case .paragraph: break
            }
            for span in block.spans {
                var font = span.code ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: span.bold ? .semibold : .regular) : NSFont.systemFont(ofSize: size, weight: span.bold ? .semibold : weight)
                if span.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                if span.code { attributes[.backgroundColor] = theme.native(.accentPrimary).withAlphaComponent(theme.dark ? 0.18 : 0.08) }
                if let target = span.wikiTarget {
                    var components = URLComponents(); components.scheme = "noema"; components.host = "wiki"
                    components.queryItems = [URLQueryItem(name: "title", value: target)]
                    attributes[.link] = components.url
                } else if let address = span.url, let url = URL(string: address), ["http", "https", "mailto"].contains(url.scheme ?? "") { attributes[.link] = url }
                result.append(NSAttributedString(string: span.text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        }
        view.textStorage?.setAttributedString(result)
        view.setSelectedRange(NSRange(location: min(selection.location, result.length),
                                      length: min(selection.length, max(0, result.length - selection.location))))
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var follow: (String) -> Void
        var blocks: [PreviewBlock]?
        var theme: NoemaTheme?
        init(_ follow: @escaping (String) -> Void) { self.follow = follow }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            if url.scheme == "noema", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value { follow(target); return true }
            NSWorkspace.shared.open(url); return true
        }
    }
}
