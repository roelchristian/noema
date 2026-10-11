import AppKit
import VaultCore

extension NSAttributedString.Key {
    static let markdownSeparator = Self("noema.markdownSeparator")
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
    static func base(_ block: EditorBlock, depth: Int, theme: NoemaTheme, typography: EditorTypography = .init()) -> [NSAttributedString.Key: Any] {
        let role = EditorTypography.role(for: block.kind)
        let paragraph = typography.paragraphStyle(for: role)
        let hasInsideMarker = [.bullet, .numbered, .task, .toggle].contains(block.kind)
        paragraph.headIndent = CGFloat(depth * 24 + (hasInsideMarker ? 24 : (block.kind == .quote ? 18 : 0))); paragraph.firstLineHeadIndent = paragraph.headIndent
        var attrs: [NSAttributedString.Key: Any] = [
            .font: typography.font(for: role),
            .foregroundColor: theme.nativeText(), .paragraphStyle: paragraph,
            .blockID: block.id.uuidString, .blockKind: block.kind.rawValue, .blockDepth: depth
        ]
        if block.kind == .paragraph, block.metadata.semantic == nil,
           block.originalMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            attrs[.markdownSeparator] = true
        }
        attrs[.inlineStyle] = try? JSONEncoder().encode(InlineStyle())
        attrs[.blockMetadata] = try? JSONEncoder().encode(block.metadata)
        if let semantic = block.metadata.semantic { attrs[.semanticTag] = semantic }
        return attrs
    }
    static func attributes(_ style: InlineStyle, block: EditorBlock, depth: Int, theme: NoemaTheme, typography: EditorTypography = .init()) -> [NSAttributedString.Key: Any] {
        var attrs = base(block, depth: depth, theme: theme, typography: typography)
        attrs[.font] = typography.font(for: EditorTypography.role(for: block.kind), style: style)
        attrs[.inlineStyle] = try? JSONEncoder().encode(style)
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
    static func render(_ document: BlockDocument, theme: NoemaTheme, showSemanticHeadings: Bool = false, typography: EditorTypography = .init()) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for value in visible(document) {
            let block = value.block
            for run in block.runs {
                var attrs = attributes(run.style, block: block, depth: value.depth, theme: theme, typography: typography)
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
            result.append(NSAttributedString(string: "\n", attributes: base(block, depth: value.depth, theme: theme, typography: typography)))
        }
        updateParagraphRhythm(result, typography: typography)
        if showSemanticHeadings { updateSemanticHeadingSpacing(result, typography: typography) }
        return result
    }
    /// Normalize paragraph attributes after rendering and native editing. A
    /// newline inside one block keeps its line rhythm, without another block gap.
    static func updateParagraphRhythm(_ storage: NSMutableAttributedString, typography: EditorTypography = .init()) {
        var previous: EditorTypography.Role?
        let text = storage.string as NSString
        var changes: [(NSRange, NSMutableParagraphStyle)] = []
        for (_, blockRange) in ranges(storage) {
            let kind = BlockKind(rawValue: storage.attribute(.blockKind, at: blockRange.location, effectiveRange: nil) as? String ?? "paragraph")
            let role = EditorTypography.role(for: kind)
            let first = NSIntersectionRange(text.paragraphRange(for: NSRange(location: blockRange.location, length: 0)), blockRange)
            let separator = isEmptySeparator(storage, range: blockRange)
            let rhythm = typography.paragraphStyle(for: role, previous: hasSeparatorBoundary(storage, range: blockRange) ? nil : previous)
            storage.enumerateAttribute(.paragraphStyle, in: blockRange) { value, part, _ in
                guard let original = value as? NSParagraphStyle else { return }
                let leading = NSIntersectionRange(part, first)
                let restStart = max(part.location, NSMaxRange(first))
                let rest = NSRange(location: restStart, length: max(0, NSMaxRange(part) - restStart))
                for (segment, before) in [(leading, rhythm.paragraphSpacingBefore), (rest, CGFloat(0))] {
                    guard segment.length > 0,
                          original.lineSpacing != rhythm.lineSpacing || original.paragraphSpacing != 0 || original.paragraphSpacingBefore != before,
                          let style = original.mutableCopy() as? NSMutableParagraphStyle else { continue }
                    style.lineSpacing = rhythm.lineSpacing
                    style.paragraphSpacing = 0
                    style.paragraphSpacingBefore = before
                    changes.append((segment, style))
                }
            }
            if !separator { previous = role }
        }
        storage.beginEditing()
        for (range, style) in changes { storage.addAttribute(.paragraphStyle, value: style, range: range) }
        storage.endEditing()
    }

    // Reserve display space only above the first paragraph. Labels never enter
    // the editable string, selection offsets, clipboard, or canonical document.
    static func updateSemanticHeadingSpacing(_ storage: NSMutableAttributedString, in affectedRange: NSRange? = nil, typography: EditorTypography = .init()) {
        var previous: EditorTypography.Role?
        for (_, range) in ranges(storage) {
            let kind = BlockKind(rawValue: storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph")
            let role = EditorTypography.role(for: kind)
            let separator = isEmptySeparator(storage, range: range)
            let boundary = hasSeparatorBoundary(storage, range: range) ? 0 : typography.boundarySpacing(before: role, after: previous)
            if !separator { previous = role }
            if let affectedRange, NSIntersectionRange(range, affectedRange).length == 0 { continue }
            let tag = storage.attribute(.semanticTag, at: range.location, effectiveRange: nil) as? String
            guard SemanticPresentation.find(tag) != nil else { continue }
            let first = NSIntersectionRange((storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0)), range)
            var styles: [(NSRange, NSMutableParagraphStyle)] = []
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, part, _ in
                guard let original = value as? NSParagraphStyle else { return }
                let leading = NSIntersectionRange(part, first)
                let rest = NSRange(location: max(part.location, NSMaxRange(first)), length: max(0, NSMaxRange(part) - max(part.location, NSMaxRange(first))))
                for (segment, spacing) in [(leading, boundary + typography.semanticHeadingSpace), (rest, CGFloat(0))] {
                    guard segment.length > 0, original.paragraphSpacingBefore != spacing,
                          let style = original.mutableCopy() as? NSMutableParagraphStyle else { continue }
                    style.paragraphSpacingBefore = spacing; styles.append((segment, style))
                }
            }
            for (part, style) in styles { storage.addAttribute(.paragraphStyle, value: style, range: part) }
        }
    }
    /// Parsed Markdown separators retain their caret line without adding another
    /// boundary gap. The presentation marker survives native typing so filling
    /// that line does not move its caret; new editing blocks keep normal spacing.
    private static func hasSeparatorBoundary(_ storage: NSAttributedString, range: NSRange) -> Bool {
        storage.attribute(.markdownSeparator, at: range.location, effectiveRange: nil) as? Bool == true
            && storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String == BlockKind.paragraph.rawValue
            && (storage.attribute(.semanticTag, at: range.location, effectiveRange: nil) as? String)?.isEmpty != false
    }

    private static func isEmptySeparator(_ storage: NSAttributedString, range: NSRange) -> Bool {
        hasSeparatorBoundary(storage, range: range) && range.length == 1
            && (storage.string as NSString).substring(with: range) == "\n"
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
        style.wikiTarget = attrs[.wikiTarget] as? String ?? style.wikiTarget
        // The rendered wiki URL is navigation metadata, not an external link.
        // Retain explicitly serialized links instead of normalizing their bytes.
        if let link = attrs[.link], style.wikiTarget == nil, style.link == nil {
            style.link = String(describing: link)
        }
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
