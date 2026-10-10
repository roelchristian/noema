import AppKit
import VaultCore

extension NSAttributedString.Key {
    static let blockID = Self("noema.blockID")
    static let blockKind = Self("noema.blockKind")
    static let blockMetadata = Self("noema.blockMetadata")
    static let blockDepth = Self("noema.blockDepth")
    static let inlineStyle = Self("noema.inlineStyle")
    static let semanticTag = Self("noema.semanticTag")
    static let wikiTarget = Self("noema.wikiTarget")
    static let renderedMath = Self("noema.renderedMath")
}

@MainActor enum BlockTextStorage {
    static let semanticHeadingFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
    static var semanticHeadingSpace: CGFloat { ceil(semanticHeadingFont.ascender - semanticHeadingFont.descender) + 8 }
    struct VisibleBlock { var block: EditorBlock; var depth: Int; var number: Int }
    static func visible(_ document: BlockDocument) -> [VisibleBlock] {
        func walk(_ blocks: [EditorBlock], depth: Int) -> [VisibleBlock] {
            var number = 0
            return blocks.flatMap { block in
                number = block.kind == .numbered ? number + 1 : 0
                return [VisibleBlock(block: block, depth: depth, number: number)] + (block.kind == .toggle && block.metadata.collapsed ? [] : walk(block.children, depth: depth + 1))
            }
        }
        return walk(document.blocks, depth: 0)
    }
    static func base(_ block: EditorBlock, depth: Int, theme: NoemaTheme) -> [NSAttributedString.Key: Any] {
        let sizes: [BlockKind: CGFloat] = [.heading1: 30, .heading2: 24, .heading3: 20]
        let size = sizes[block.kind] ?? 16
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 10
        let hasInsideMarker = [.bullet, .numbered, .task, .toggle].contains(block.kind)
        paragraph.headIndent = CGFloat(depth * 24 + (hasInsideMarker ? 24 : (block.kind == .quote ? 18 : 0))); paragraph.firstLineHeadIndent = paragraph.headIndent
        if sizes[block.kind] != nil { paragraph.paragraphSpacingBefore = 12 }
        if block.metadata.semantic != nil || [.quote, .callout, .code, .math].contains(block.kind) {
            paragraph.paragraphSpacingBefore = 12
            paragraph.paragraphSpacing = 18
        }
        let isMonoBlock = block.kind == .code || block.kind == .math
        var attrs: [NSAttributedString.Key: Any] = [
            .font: isMonoBlock ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : NSFont.systemFont(ofSize: size, weight: sizes[block.kind] == nil ? .regular : .semibold),
            .foregroundColor: theme.nativeText(), .paragraphStyle: paragraph,
            .blockID: block.id.uuidString, .blockKind: block.kind.rawValue, .blockDepth: depth
        ]
        attrs[.inlineStyle] = try? JSONEncoder().encode(InlineStyle())
        attrs[.blockMetadata] = try? JSONEncoder().encode(block.metadata)
        if let semantic = block.metadata.semantic { attrs[.semanticTag] = semantic }
        return attrs
    }
    static func attributes(_ style: InlineStyle, block: EditorBlock, depth: Int, theme: NoemaTheme) -> [NSAttributedString.Key: Any] {
        var attrs = base(block, depth: depth, theme: theme)
        var font = attrs[.font] as! NSFont
        if style.code { font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
        else if style.math {
            font = NSFontDescriptor.preferredFontDescriptor(forTextStyle: .body).withDesign(.serif).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        if style.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attrs[.font] = font; attrs[.inlineStyle] = try? JSONEncoder().encode(style)
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.highlight || style.code || style.math { attrs[.backgroundColor] = theme.native(.graphHighlight).withAlphaComponent(theme.dark ? 0.22 : 0.10) }
        if let target = style.wikiTarget {
            attrs[.wikiTarget] = target
            var url = URLComponents(); url.scheme = "noema"; url.host = "wiki"; url.queryItems = [.init(name: "title", value: target)]
            attrs[.link] = url.url
        } else if let link = style.link { attrs[.link] = URL(string: link) }
        return attrs
    }
    static func render(_ document: BlockDocument, theme: NoemaTheme, showSemanticHeadings: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for value in visible(document) {
            let block = value.block
            for run in block.runs {
                var attrs = attributes(run.style, block: block, depth: value.depth, theme: theme)
                let displayString: String
                if run.style.math, let raw = run.style.rawMath {
                    let rendered = TeXMath.render(raw, display: false)
                    displayString = rendered.isEmpty ? run.text : rendered
                    attrs[.renderedMath] = displayString
                } else {
                    displayString = run.text
                }
                result.append(NSAttributedString(string: displayString, attributes: attrs))
            }
            result.append(NSAttributedString(string: "\n", attributes: base(block, depth: value.depth, theme: theme)))
        }
        if showSemanticHeadings { updateSemanticHeadingSpacing(result) }
        return result
    }
    // Reserve display space only above the first paragraph. Labels never enter
    // the editable string, selection offsets, clipboard, or canonical document.
    static func updateSemanticHeadingSpacing(_ storage: NSMutableAttributedString, in affectedRange: NSRange? = nil) {
        for (_, range) in ranges(storage) {
            if let affectedRange, NSIntersectionRange(range, affectedRange).length == 0 { continue }
            let tag = storage.attribute(.semanticTag, at: range.location, effectiveRange: nil) as? String
            guard SemanticPresentation.find(tag) != nil else { continue }
            let first = NSIntersectionRange((storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0)), range)
            var styles: [(NSRange, NSMutableParagraphStyle)] = []
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                guard let original = value as? NSParagraphStyle else { return }
                let leading = NSIntersectionRange(part, first)
                let rest = NSRange(location: max(part.location, NSMaxRange(first)), length: max(0, NSMaxRange(part) - max(part.location, NSMaxRange(first))))
                for (segment, spacing) in [(leading, 12 + semanticHeadingSpace), (rest, CGFloat(12))] {
                    guard segment.length > 0, original.paragraphSpacingBefore != spacing,
                          let style = original.mutableCopy() as? NSMutableParagraphStyle else { continue }
                    style.paragraphSpacingBefore = spacing; styles.append((segment, style))
                }
            }
            for (part, style) in styles { storage.addAttribute(.paragraphStyle, value: style, range: part) }
        }
    }
    static func ranges(_ storage: NSAttributedString) -> [(UUID, NSRange)] {
        var result: [(UUID, NSRange)] = []
        storage.enumerateAttribute(.blockID, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let value = value as? String, let id = UUID(uuidString: value) { result.append((id, range)) }
        }
        return result
    }
    static func style(_ attrs: [NSAttributedString.Key: Any]) -> InlineStyle {
        var style = (attrs[.inlineStyle] as? Data).flatMap { try? JSONDecoder().decode(InlineStyle.self, from: $0) } ?? InlineStyle()
        if let font = attrs[.font] as? NSFont {
            let traits = NSFontManager.shared.traits(of: font)
            // Native pasted fonts supply styles only when our explicit style marker is absent.
            if attrs[.inlineStyle] == nil { style.bold = traits.contains(.boldFontMask); style.italic = traits.contains(.italicFontMask); style.code = traits.contains(.fixedPitchFontMask) }
        }
        style.underline = (attrs[.underlineStyle] as? Int ?? 0) != 0
        style.strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0
        style.highlight = attrs[.backgroundColor] != nil && !style.code && !style.math
        if let link = attrs[.link] { style.link = String(describing: link) }
        style.wikiTarget = attrs[.wikiTarget] as? String ?? style.wikiTarget
        return style
    }
    static func runs(_ storage: NSAttributedString, range: NSRange) -> [RichRun] {
        var result: [RichRun] = []
        storage.enumerateAttributes(in: range) { attrs, range, _ in
            let text = (storage.string as NSString).substring(with: range)
            var value = style(attrs)
            if value.math, let rendered = attrs[.renderedMath] as? String, text != rendered {
                value.rawMath = text
            }
            if result.last?.style == value { result[result.count - 1].text += text }
            else { result.append(RichRun(text, style: value)) }
        }
        return result
    }
    static func capture(_ storage: NSAttributedString, previous: BlockDocument) -> BlockDocument {
        var document = previous
        let visibleIDs = Set(visible(previous).map { $0.block.id })
        let captured = ranges(storage)
        let remainingIDs = Set(captured.map(\.0))
        func prune(_ list: inout [EditorBlock]) {
            list.removeAll { visibleIDs.contains($0.id) && !remainingIDs.contains($0.id) }
            for index in list.indices { prune(&list[index].children) }
        }
        prune(&document.blocks)
        var values: [UUID: ([RichRun], BlockKind?, BlockMetadata?)] = [:]
        for (id, range) in captured {
            var content = range
            if (storage.string as NSString).substring(with: range).hasSuffix("\n") { content.length -= 1 }
            let kind = (storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String).map(BlockKind.init(rawValue:))
            let metadata = (storage.attribute(.blockMetadata, at: range.location, effectiveRange: nil) as? Data).flatMap { try? JSONDecoder().decode(BlockMetadata.self, from: $0) }
            values[id] = (runs(storage, range: content), kind, metadata)
        }
        func refresh(_ list: inout [EditorBlock]) {
            for index in list.indices {
                if let (runs, kind, metadata) = values[list[index].id] {
                    let before = list[index]
                    list[index].runs = runs
                    if let kind { list[index].kind = kind }; if let metadata { list[index].metadata = metadata }
                    if list[index] != before { list[index].modifiedAt = Date() }
                }
                refresh(&list[index].children)
            }
        }
        refresh(&document.blocks)
        if document.blocks.isEmpty { document.blocks = [EditorBlock()] }
        return document
    }
}

// Compatibility entry points for the article renderer used by the previous implementation.
@MainActor enum RichArticleDocument {
    static func render(_ markdown: String, theme: NoemaTheme) -> NSAttributedString { BlockTextStorage.render(BlockDocumentCodec.decode(markdown), theme: theme) }
    static func markdown(_ storage: NSAttributedString) -> String {
        var blocks: [EditorBlock] = []
        for (id, range) in BlockTextStorage.ranges(storage) {
            var content = range; if (storage.string as NSString).substring(with: range).hasSuffix("\n") { content.length -= 1 }
            let kind = BlockKind(rawValue: storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph")
            let metadata = (storage.attribute(.blockMetadata, at: range.location, effectiveRange: nil) as? Data).flatMap { try? JSONDecoder().decode(BlockMetadata.self, from: $0) } ?? .init()
            blocks.append(EditorBlock(id: id, kind: kind, runs: BlockTextStorage.runs(storage, range: content), metadata: metadata))
        }
        return BlockDocumentCodec.encode(BlockDocument(blocks: blocks))
    }
}
