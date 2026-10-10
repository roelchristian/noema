import Foundation
import Markdown

public struct PreviewSpan: Sendable, Equatable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var math = false
    public var rawMath: String?
    public var url: String?
    public var wikiTarget: String?
}
public struct PreviewBlock: Sendable, Equatable {
    public enum Style: Sendable, Equatable { case paragraph, heading(Int), quote, code, math, rule }
    public var style: Style
    public var spans: [PreviewSpan]
}
public enum MarkdownService {
    private static let wikiPattern = #"\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#

    private struct MathExtraction {
        var text: String
        var inline: [String] = []
        var display: [String] = []
    }

    private static func extractMath(_ source: String) -> MathExtraction {
        var result = MathExtraction(text: "")
        let chars = Array(source)
        var i = 0
        var out = ""
        while i < chars.count {
            if (i == 0 || chars[i - 1] == "\n"), i + 2 < chars.count,
               (chars[i] == "`" && chars[i + 1] == "`" && chars[i + 2] == "`") ||
               (chars[i] == "~" && chars[i + 1] == "~" && chars[i + 2] == "~") {
                let fence = chars[i]
                var lineEnd = i
                while lineEnd < chars.count && chars[lineEnd] != "\n" { out.append(chars[lineEnd]); lineEnd += 1 }
                if lineEnd < chars.count { out.append("\n"); lineEnd += 1 }
                i = lineEnd
                while i < chars.count {
                    var check = i
                    while check < chars.count && (chars[check] == " " || chars[check] == "\t") { check += 1 }
                    let closed = check + 2 < chars.count && chars[check] == fence && chars[check + 1] == fence && chars[check + 2] == fence
                    while i < chars.count && chars[i] != "\n" { out.append(chars[i]); i += 1 }
                    if i < chars.count { out.append("\n"); i += 1 }
                    if closed { break }
                }
                continue
            }
            if chars[i] == "`" {
                out.append(chars[i]); i += 1
                while i < chars.count && chars[i] != "`" && chars[i] != "\n" { out.append(chars[i]); i += 1 }
                if i < chars.count && chars[i] == "`" { out.append(chars[i]); i += 1 }
                continue
            }
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                out.append("\\"); out.append("$"); i += 2
                continue
            }
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "[" {
                var end = i + 2
                var found: Int?
                while end + 1 < chars.count {
                    if chars[end] == "\\" && chars[end + 1] == "]" { found = end; break }
                    end += 1
                }
                if let close = found {
                    let raw = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let idx = result.display.count
                    result.display.append(raw)
                    out += "\n\nNOEMADISPLAYMATH\(idx)END\n\n"
                    i = close + 2
                    continue
                }
            }
            if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                var end = i + 2
                var found: Int?
                while end + 1 < chars.count && chars[end] != "\n" {
                    if chars[end] == "\\" && chars[end + 1] == ")" { found = end; break }
                    end += 1
                }
                if let close = found {
                    let raw = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespaces)
                    if !raw.isEmpty {
                        let idx = result.inline.count
                        result.inline.append(raw)
                        out += "NOEMAINLINEMATH\(idx)END"
                        i = close + 2
                        continue
                    }
                }
            }
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "$" {
                var end = i + 2
                var found: Int?
                while end + 1 < chars.count {
                    if chars[end] == "$" && chars[end + 1] == "$" { found = end; break }
                    end += 1
                }
                if let close = found {
                    let raw = String(chars[(i + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let idx = result.display.count
                    result.display.append(raw)
                    out += "\n\nNOEMADISPLAYMATH\(idx)END\n\n"
                    i = close + 2
                    continue
                }
            }
            if chars[i] == "$" {
                var end = i + 1
                var found: Int?
                while end < chars.count && chars[end] != "\n" {
                    if chars[end] == "\\", end + 1 < chars.count { end += 2; continue }
                    if chars[end] == "$" {
                        if end + 1 < chars.count && chars[end + 1] == "$" { break }
                        found = end
                        break
                    }
                    end += 1
                }
                if let close = found, close > i + 1 {
                    let raw = String(chars[(i + 1)..<close])
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let idx = result.inline.count
                        result.inline.append(trimmed)
                        out += "NOEMAINLINEMATH\(idx)END"
                        i = close + 1
                        continue
                    }
                }
            }
            out.append(chars[i])
            i += 1
        }
        result.text = out
        return result
    }

    public static func analyze(_ text: String) -> TextAnalysis {
        let extracted = extractMath(BlockDocumentCodec.markdownBody(text))
        let doc = Document(parsing: extracted.text)
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
    private static func expandInlineMathSpans(_ spans: [PreviewSpan], inlineMath: [String]) -> [PreviewSpan] {
        guard !inlineMath.isEmpty else { return spans }
        let regex = try! NSRegularExpression(pattern: #"NOEMAINLINEMATH(\d+)END"#)
        var output: [PreviewSpan] = []
        for span in spans {
            guard span.wikiTarget == nil, !span.code else { output.append(span); continue }
            let text = span.text
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { output.append(span); continue }
            var cursor = 0
            for match in matches {
                if match.range.location > cursor {
                    var prefix = span
                    prefix.text = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    output.append(prefix)
                }
                if let index = Int(ns.substring(with: match.range(at: 1))), inlineMath.indices.contains(index) {
                    let raw = inlineMath[index]
                    let rendered = TeXMath.render(raw, display: false)
                    output.append(PreviewSpan(text: rendered.isEmpty ? raw : rendered, bold: span.bold, italic: span.italic, math: true, rawMath: raw, url: span.url))
                }
                cursor = NSMaxRange(match.range)
            }
            if cursor < ns.length {
                var suffix = span
                suffix.text = ns.substring(from: cursor)
                output.append(suffix)
            }
        }
        return output
    }
    public static func preview(_ text: String) -> [PreviewBlock] {
        let extracted = extractMath(BlockDocumentCodec.markdownBody(text))
        let displayRegex = try! NSRegularExpression(pattern: #"^NOEMADISPLAYMATH(\d+)END$"#)
        var blocks: [PreviewBlock] = []
        func inline(_ node: any Markup, bold: Bool = false, italic: Bool = false, url: String? = nil) -> [PreviewSpan] {
            if let t = node as? Markdown.Text {
                let base = wikiSpans(t.string).map { var s = $0; s.bold = bold; s.italic = italic; s.url = url; return s }
                return expandInlineMathSpans(base, inlineMath: extracted.inline)
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
                let plain = p.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                let ns = plain as NSString
                if let match = displayRegex.firstMatch(in: plain, range: NSRange(location: 0, length: ns.length)),
                   let idx = Int(ns.substring(with: match.range(at: 1))),
                   extracted.display.indices.contains(idx) {
                    let raw = extracted.display[idx]
                    let rendered = TeXMath.render(raw, display: true)
                    blocks.append(PreviewBlock(style: .math, spans: [PreviewSpan(text: rendered.isEmpty ? raw : rendered, math: true, rawMath: raw)]))
                    return
                }
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
        visit(Document(parsing: extracted.text))
        return blocks
    }
}
