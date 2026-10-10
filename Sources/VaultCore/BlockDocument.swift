import Foundation

public struct InlineStyle: Codable, Equatable, Sendable {
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var code = false
    public var highlight = false
    public var link: String?
    public var wikiTarget: String?
    public init() {}
}

public struct RichRun: Codable, Equatable, Sendable {
    public var text: String
    public var style: InlineStyle
    public init(_ text: String, style: InlineStyle = .init()) { self.text = text; self.style = style }
}

// String-backed kinds allow future kinds to survive a decode without losing content.
public struct BlockKind: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let paragraph = Self(rawValue: "paragraph")
    public static let heading1 = Self(rawValue: "h1"), heading2 = Self(rawValue: "h2"), heading3 = Self(rawValue: "h3")
    public static let bullet = Self(rawValue: "bullet"), numbered = Self(rawValue: "numbered"), task = Self(rawValue: "task")
    public static let quote = Self(rawValue: "quote"), code = Self(rawValue: "code"), divider = Self(rawValue: "divider")
    public static let callout = Self(rawValue: "callout"), toggle = Self(rawValue: "toggle")
    public var isList: Bool { [Self.bullet, .numbered, .task].contains(self) }
}

public struct BlockMetadata: Codable, Equatable, Sendable {
    public var semantic: String?
    public var status: String?
    public var checked = false
    public var collapsed = false
    public var language: String?
    public var icon: String?
    public var extra: [String: String] = [:]
    public init() {}
}

public struct EditorBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: BlockKind
    public var runs: [RichRun]
    public var metadata: BlockMetadata
    public var children: [EditorBlock]
    public var createdAt: Date
    public var modifiedAt: Date
    // A preserved spelling lets unsupported Markdown and whitespace round-trip unchanged.
    public var originalMarkdown: String?
    public var originalSignature: String?
    public var originalIndentation: String?
    public var originalDepth: Int?
    public init(id: UUID = UUID(), kind: BlockKind = .paragraph, runs: [RichRun] = [], metadata: BlockMetadata = .init(), children: [EditorBlock] = []) {
        self.id = id; self.kind = kind; self.runs = runs; self.metadata = metadata; self.children = children
        createdAt = Date(); modifiedAt = createdAt
    }
    public var text: String { runs.map(\.text).joined() }
    public var utf16Count: Int { text.utf16.count }
    public var signature: String {
        // Do not include transient timestamps or identity in the source-spelling comparison.
        struct Content: Encodable { var kind: BlockKind; var runs: [RichRun]; var metadata: BlockMetadata }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Content(kind: kind, runs: runs, metadata: metadata))).map(digest) ?? ""
    }
    public func renewedIdentity() -> EditorBlock {
        var copy = self; copy.id = UUID(); copy.createdAt = Date(); copy.modifiedAt = copy.createdAt
        copy.children = children.map { $0.renewedIdentity() }; return copy
    }
    public var sourceUnchanged: Bool {
        guard let originalSignature else { return false }
        return originalSignature == signature || Data(base64Encoded: originalSignature).map(digest) == signature
    }
    public func slicing(_ range: NSRange) -> [RichRun] {
        var offset = 0, result: [RichRun] = []
        for run in runs {
            let length = run.text.utf16.count
            let intersection = NSIntersectionRange(range, NSRange(location: offset, length: length))
            if intersection.length > 0 {
                result.append(RichRun((run.text as NSString).substring(with: NSRange(location: intersection.location - offset, length: intersection.length)), style: run.style))
            }
            offset += length
        }
        return result
    }
}

public struct BlockDocument: Codable, Equatable, Sendable {
    public var blocks: [EditorBlock]
    public var trailingNewline: Bool
    public var recoveredMetadata: String?
    public var unsupportedVersion = false
    public var originalSource: String?
    public init(blocks: [EditorBlock] = [EditorBlock()], trailingNewline: Bool = false) {
        self.blocks = blocks; self.trailingNewline = trailingNewline
    }
    public func block(_ id: UUID) -> EditorBlock? {
        func find(_ list: [EditorBlock]) -> EditorBlock? {
            for block in list { if block.id == id { return block }; if let result = find(block.children) { return result } }
            return nil
        }
        return find(blocks)
    }
    public var flattened: [EditorBlock] {
        func walk(_ list: [EditorBlock]) -> [EditorBlock] { list.flatMap { [$0] + walk($0.children) } }
        return walk(blocks)
    }
    @discardableResult public mutating func update(_ id: UUID, _ change: (inout EditorBlock) -> Void) -> Bool {
        func visit(_ list: inout [EditorBlock]) -> Bool {
            for index in list.indices {
                if list[index].id == id { let before = list[index]; change(&list[index]); if list[index] != before { list[index].modifiedAt = Date() }; return true }
                if visit(&list[index].children) { return true }
            }
            return false
        }
        return visit(&blocks)
    }
}

public enum BlockDocumentCodec {
    private struct Envelope: Codable { var version: Int; var hash: String; var document: BlockDocument }
    private static let prefix = "<!--noema:document:"

    public static func decode(_ source: String) -> BlockDocument {
        var markdown = source, recovered: String?
        if let range = source.range(of: "\n" + prefix, options: .backwards), source.hasSuffix("-->") {
            let encoded = String(source[range.upperBound...].dropLast(3))
            if let data = Data(base64Encoded: encoded),
               let header = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let version = header["version"] as? Int, version != 1 {
                var document = parse(String(source[..<range.lowerBound])); document.unsupportedVersion = true; document.originalSource = source; return document
            }
            if let data = Data(base64Encoded: encoded), let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
                if envelope.version != 1 {
                    var document = parse(source); document.unsupportedVersion = true; document.originalSource = source; return document
                }
                markdown = String(source[..<range.lowerBound])
                if envelope.hash == digest(Data(markdown.utf8)), valid(envelope.document) { return envelope.document }
                // External text wins. Keep the stale payload in the next save for manual recovery.
                recovered = encoded
            }
        }
        var document = parse(markdown); document.recoveredMetadata = recovered; document.originalSource = source
        return document
    }
    public static func encode(_ document: BlockDocument) -> String {
        if document.unsupportedVersion { return document.originalSource ?? "" }
        let markdown = readable(document)
        // Plain, unmodified imports remain byte-for-byte unchanged; opening never migrates files.
        if let original = document.originalSource, document.recoveredMetadata == nil,
           markdown == original, document.flattened.allSatisfy({ $0.sourceUnchanged }) { return original }
        var saved = document; saved.originalSource = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(version: 1, hash: digest(Data(markdown.utf8)), document: saved)
        guard let data = try? encoder.encode(envelope) else { return document.originalSource ?? markdown }
        return markdown + "\n" + prefix + data.base64EncodedString() + "-->"
    }
    public static func valid(_ document: BlockDocument) -> Bool {
        let ids = document.flattened.map(\.id)
        return !ids.isEmpty && Set(ids).count == ids.count
    }
    public static func readable(_ document: BlockDocument) -> String {
        func serialize(_ blocks: [EditorBlock], depth: Int) -> [String] {
            var number = 0
            return blocks.flatMap { block -> [String] in
                number = block.kind == .numbered ? number + 1 : 0
                let content: String
                if let original = block.originalMarkdown, block.sourceUnchanged { content = original }
                else {
                    let text = block.kind == .code ? block.text : block.runs.map { run -> String in
                        var text = run.text
                        if run.style.code { text = "`" + text + "`" }
                        else {
                            if run.style.bold { text = "**" + text + "**" }
                            if run.style.italic { text = "*" + text + "*" }
                            if run.style.strike { text = "~~" + text + "~~" }
                            if run.style.underline { text = "<u>" + text + "</u>" }
                            if run.style.highlight { text = "<mark>" + text + "</mark>" }
                        }
                        if let target = run.style.wikiTarget { text = "[[" + target + "|" + text + "]]" }
                        else if let link = run.style.link { text = "[" + text + "](" + link + ")" }
                        return text
                    }.joined()
                    switch block.kind {
                    case .heading1: content = "# " + text
                    case .heading2: content = "## " + text
                    case .heading3: content = "### " + text
                    case .bullet: content = "- " + text
                    case .numbered: content = "\(number). " + text
                    case .task: content = (block.metadata.checked ? "- [x] " : "- [ ] ") + text
                    case .quote: content = "> " + text
                    case .code: content = "```" + (block.metadata.language ?? "") + "\n" + text + "\n```"
                    case .divider: content = "---" + (text.isEmpty ? "" : "\n" + text)
                    default: content = text
                    }
                }
                let indentation = block.originalDepth == depth ? (block.originalIndentation ?? String(repeating: "    ", count: depth)) : String(repeating: "    ", count: depth)
                let own = content.components(separatedBy: "\n").map { indentation + $0 }.joined(separator: "\n")
                return [own] + serialize(block.children, depth: depth + 1)
            }
        }
        return serialize(document.blocks, depth: 0).joined(separator: "\n") + (document.trailingNewline ? "\n" : "")
    }
    // Strip only the trailing editor envelope from derived search/preview text.
    public static func markdownBody(_ source: String) -> String {
        guard let range = source.range(of: "\n" + prefix, options: .backwards), source.hasSuffix("-->"),
              Data(base64Encoded: String(source[range.upperBound...].dropLast(3))) != nil else { return source }
        return String(source[..<range.lowerBound])
    }
    public static func inline(_ text: String) -> [RichRun] {
        // Unsupported constructs stay literal and recoverable rather than disappearing in preview.
        if text.contains("<") || text.contains("![") || text.hasPrefix("|") { return [RichRun(text)] }
        guard let spans = MarkdownService.preview(text).first?.spans, !spans.isEmpty else { return text.isEmpty ? [] : [RichRun(text)] }
        return spans.map { span in
            var style = InlineStyle(); style.bold = span.bold; style.italic = span.italic; style.code = span.code
            style.link = span.url; style.wikiTarget = span.wikiTarget
            return RichRun(span.text, style: style)
        }
    }
    private static func parse(_ source: String) -> BlockDocument {
        var lines = source.components(separatedBy: "\n")
        let trailing = source.hasSuffix("\n")
        if trailing { lines.removeLast() }
        var flat: [(Int, EditorBlock)] = [], index = 0, indentationWidths = [0], seenIDs = Set<UUID>()
        while index < lines.count {
            let raw = lines[index]
            let indentation = String(raw.prefix(while: { $0 == " " || $0 == "\t" }))
            let width = indentation.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            while indentationWidths.count > 1 && width < indentationWidths.last! { indentationWidths.removeLast() }
            if width > indentationWidths.last! { indentationWidths.append(width) }
            let depth = indentationWidths.count - 1
            var text = String(raw.dropFirst(indentation.count)), kind = BlockKind.paragraph, metadata = BlockMetadata(), id = UUID()
            if let marker = text.range(of: #" <!--noema:block:([0-9A-Fa-f-]{36}):([a-z]*)-->$"#, options: .regularExpression) {
                let parts = String(text[marker]).dropLast(3).components(separatedBy: ":")
                if let parsed = UUID(uuidString: parts[2]) { id = parsed; metadata.semantic = parts[3].isEmpty ? nil : parts[3]; text = String(text[..<marker.lowerBound]) }
            }
            if !seenIDs.insert(id).inserted { id = UUID(); seenIDs.insert(id) }
            var original = text, literal = false
            if text.hasPrefix("```") || text.hasPrefix("~~~") {
                let fence = String(text.prefix(3)); metadata.language = String(text.dropFirst(3)); kind = .code
                var content: [String] = []; index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { content.append(String(lines[index].dropFirst(lines[index].hasPrefix(indentation) ? indentation.count : 0))); index += 1 }
                original += "\n" + content.joined(separator: "\n")
                if index < lines.count { original += "\n" + String(lines[index].dropFirst(lines[index].hasPrefix(indentation) ? indentation.count : 0)) }
                text = content.joined(separator: "\n"); literal = true
            } else {
                for (prefix, candidate) in [("### ", BlockKind.heading3), ("## ", .heading2), ("# ", .heading1), ("- [ ] ", .task), ("- [x] ", .task), ("- [X] ", .task), ("- ", .bullet), ("* ", .bullet), ("> ", .quote)] where text.hasPrefix(prefix) {
                    kind = candidate; metadata.checked = prefix.lowercased() == "- [x] "; text = String(text.dropFirst(prefix.count)); break
                }
                if kind == .paragraph, let range = text.range(of: #"^\d+\. "#, options: .regularExpression) { kind = .numbered; text = String(text[range.upperBound...]) }
                if ["---", "***", "___"].contains(text) { kind = .divider; text = "" }
            }
            var block = EditorBlock(id: id, kind: kind, runs: literal ? [RichRun(text)] : inline(text), metadata: metadata)
            block.originalMarkdown = original; block.originalSignature = block.signature; block.originalIndentation = indentation
            flat.append((depth, block)); index += 1
        }
        var cursor = 0
        func tree(_ depth: Int, actualDepth: Int = 0) -> [EditorBlock] {
            var result: [EditorBlock] = []
            while cursor < flat.count {
                let (level, value) = flat[cursor]
                if level < depth { break }
                if level > depth, !result.isEmpty { result[result.count - 1].children += tree(level, actualDepth: actualDepth + 1); continue }
                var block = value; block.originalDepth = actualDepth
                result.append(block); cursor += 1
            }
            return result
        }
        var document = BlockDocument(blocks: tree(flat.first?.0 ?? 0), trailingNewline: trailing)
        if document.blocks.isEmpty { document.blocks = [EditorBlock()] }
        document.originalSource = source
        return document
    }
}


extension EditorBlock {
    public var isAISummary: Bool { metadata.semantic == "summary" && metadata.extra["aiGenerated"] == "true" }
}

extension BlockDocument {
    public var aiSummary: EditorBlock? { blocks.first(where: \.isAISummary) }
    public var withoutAISummary: BlockDocument {
        var copy = self
        copy.blocks.removeAll(where: \.isAISummary)
        if copy.blocks.isEmpty { copy.blocks = [EditorBlock()] }
        return copy
    }
    @discardableResult public mutating func removeAISummary() -> Bool {
        guard !unsupportedVersion, aiSummary != nil else { return false }
        self = withoutAISummary; originalSource = nil
        return true
    }
    public mutating func setAISummary(_ text: String) {
        guard !unsupportedVersion else { return }
        var metadata = BlockMetadata()
        metadata.semantic = "summary"; metadata.extra["aiGenerated"] = "true"
        let summary = EditorBlock(id: aiSummary?.id ?? UUID(), runs: [RichRun(text)], metadata: metadata)
        blocks.removeAll(where: \.isAISummary)
        blocks.insert(summary, at: 0); originalSource = nil
    }
}
