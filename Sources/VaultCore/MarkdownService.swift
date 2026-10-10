import Foundation
import Markdown

public struct PreviewSpan: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var url: String?
    public var wikiTarget: String?
}
public struct PreviewBlock: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case paragraph, heading(Int), quote, code, rule }
    public var style: Style
    public var spans: [PreviewSpan]
}
public enum MarkdownService {
    private static let wikiPattern = #"\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#
    public static func analyze(_ text: String) -> TextAnalysis {
        let doc = Document(parsing: BlockDocumentCodec.markdownBody(text))
        var links: [WikiLink] = [], tags: Set<String> = []
        func visit(_ node: any Markup) {
            if node is CodeBlock || node is InlineCode { return }
            if let text = node as? Markdown.Text {
                for span in wikiSpans(text.string) {
                    if let target = span.wikiTarget { links.append(WikiLink(target: target, label: span.text)) }
                }
                let regex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_/#])#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)"#)
                let ns = text.string as NSString
                for match in regex.matches(in: text.string, range: NSRange(location: 0, length: ns.length)) {
                    tags.insert(normalized(ns.substring(with: match.range(at: 1))))
                }
            }
            for child in node.children { visit(child) }
        }
        visit(doc)
        return TextAnalysis(links: links, tags: tags.sorted())
    }
    public static func wikiSpans(_ text: String) -> [PreviewSpan] {
        let ns = text as NSString
        let regex = try! NSRegularExpression(pattern: wikiPattern)
        var spans: [PreviewSpan] = [], cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor { spans.append(PreviewSpan(text: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))) }
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = match.range(at: 2).location == NSNotFound ? target : ns.substring(with: match.range(at: 2))
            spans.append(PreviewSpan(text: label, wikiTarget: target))
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length { spans.append(PreviewSpan(text: ns.substring(from: cursor))) }
        return spans
    }
    public static func preview(_ text: String) -> [PreviewBlock] {
        var blocks: [PreviewBlock] = []
        func inline(_ node: any Markup, bold: Bool = false, italic: Bool = false, url: String? = nil) -> [PreviewSpan] {
            if let t = node as? Markdown.Text {
                return wikiSpans(t.string).map { var s = $0; s.bold = bold; s.italic = italic; s.url = url; return s }
            }
            if let code = node as? InlineCode { return [PreviewSpan(text: code.code, bold: bold, italic: italic, code: true, url: url)] }
            if node is SoftBreak { return [PreviewSpan(text: " ")] }
            if node is LineBreak { return [PreviewSpan(text: "\n")] }
            if let image = node as? Markdown.Image { return [PreviewSpan(text: "[Image: \(image.plainText)]")] }
            let linkURL = (node as? Markdown.Link)?.destination ?? url
            return node.children.flatMap { inline($0, bold: bold || node is Strong, italic: italic || node is Emphasis, url: linkURL) }
        }
        func visit(_ node: any Markup, quote: Bool = false, prefix: String = "") {
            if let heading = node as? Heading { blocks.append(PreviewBlock(style: .heading(heading.level), spans: inline(heading))); return }
            if let code = node as? CodeBlock { blocks.append(PreviewBlock(style: .code, spans: [PreviewSpan(text: code.code, code: true)])); return }
            if node is ThematicBreak { blocks.append(PreviewBlock(style: .rule, spans: [PreviewSpan(text: "────────────────────")])); return }
            if let p = node as? Paragraph {
                blocks.append(PreviewBlock(style: quote ? .quote : .paragraph, spans: (prefix.isEmpty ? [] : [PreviewSpan(text: prefix)]) + inline(p))); return
            }
            if let list = node as? UnorderedList {
                for item in list.children { for (i, c) in item.children.enumerated() { visit(c, quote: quote, prefix: i == 0 ? prefix + "•  " : "   ") } }; return
            }
            if let list = node as? OrderedList {
                for (n, item) in list.children.enumerated() { for (i, c) in item.children.enumerated() { visit(c, quote: quote, prefix: i == 0 ? "\(Int(list.startIndex) + n).  " : "   ") } }; return
            }
            if let html = node as? HTMLBlock { blocks.append(PreviewBlock(style: .code, spans: [PreviewSpan(text: html.rawHTML, code: true)])); return }
            for child in node.children { visit(child, quote: quote || node is BlockQuote, prefix: prefix) }
        }
        visit(Document(parsing: BlockDocumentCodec.markdownBody(text)))
        return blocks
    }
}
