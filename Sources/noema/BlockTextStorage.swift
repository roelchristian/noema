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
    static let originalRichRun = Self("noema.originalRichRun")
}

@MainActor enum BlockTextStorage {
    /// Stable ID lookup and UTF-16 prefix sums. Typing updates one length in
    /// O(log n), without rescanning attributed-string block markers.
    @MainActor final class RangeIndex {
        private var ids: [UUID] = []
        private var positions: [UUID: Int] = [:]
        private var lengths: [Int] = []
        private var sums: [Int] = [0]
        private var numbers: [Int] = []
        init(_ storage: NSAttributedString) { rebuild(storage) }
        var count: Int { ids.count }
        func rebuild(_ storage: NSAttributedString) {
            let values = BlockTextStorage.ranges(storage)
            ids = values.map(\.0); lengths = values.map { $0.1.length }
            positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
            sums = Array(repeating: 0, count: ids.count + 1)
            var numberByDepth: [Int: Int] = [:]
            numbers = values.map { _, range in
                let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
                let kind = storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String
                numberByDepth[depth] = kind == BlockKind.numbered.rawValue ? (numberByDepth[depth] ?? 0) + 1 : 0
                for nested in numberByDepth.keys where nested > depth { numberByDepth[nested] = nil }
                return numberByDepth[depth] ?? 0
            }
            for (offset, length) in lengths.enumerated() { add(length, at: offset) }
        }
        private func add(_ delta: Int, at index: Int) {
            var cursor = index + 1
            while cursor < sums.count { sums[cursor] += delta; cursor += cursor & -cursor }
        }
        private func prefix(_ count: Int) -> Int {
            var cursor = count, result = 0
            while cursor > 0 { result += sums[cursor]; cursor -= cursor & -cursor }
            return result
        }
        func number(for id: UUID) -> Int {
            positions[id].map { numbers[$0] } ?? 0
        }
        func range(for id: UUID) -> NSRange? {
            guard let index = positions[id] else { return nil }
            return NSRange(location: prefix(index), length: lengths[index])
        }
        func block(at location: Int) -> (UUID, NSRange)? {
            guard location >= 0, location < prefix(ids.count) else { return nil }
            // Fenwick binary lifting finds the containing prefix in O(log n).
            var offset = 0, consumed = 0, step = 1
            while step < sums.count { step <<= 1 }
            while step > 0 {
                let candidate = offset + step
                if candidate < sums.count, consumed + sums[candidate] <= location {
                    offset = candidate; consumed += sums[candidate]
                }
                step >>= 1
            }
            return (ids[offset], NSRange(location: consumed, length: lengths[offset]))
        }
        func applyLocalEdit(blockID: UUID, delta: Int) {
            guard let index = positions[blockID], lengths[index] + delta > 0 else { return }
            lengths[index] += delta; add(delta, at: index)
        }
        var ordered: [(UUID, NSRange)] {
            var location = 0
            return ids.enumerated().map { index, id in
                defer { location += lengths[index] }
                return (id, NSRange(location: location, length: lengths[index]))
            }
        }
        func intersecting(_ range: NSRange) -> [(UUID, NSRange)] {
            guard let (first, _) = block(at: range.location), let start = positions[first] else { return [] }
            var result: [(UUID, NSRange)] = [], location = prefix(start)
            for index in start..<ids.count {
                if location >= NSMaxRange(range), !result.isEmpty { break }
                result.append((ids[index], NSRange(location: location, length: lengths[index])))
                location += lengths[index]
            }
            return result
        }
        /// Include the next content block: its boundary spacing depends on the
        /// edited predecessor even when empty Markdown separators intervene.
        func rhythmAffectedRange(for id: UUID, storage: NSAttributedString) -> NSRange? {
            guard let position = positions[id], let start = range(for: id) else { return nil }
            var end = NSMaxRange(start)
            for offset in (position + 1)..<ids.count {
                let next = NSRange(location: end, length: lengths[offset])
                end = NSMaxRange(next)
                if !BlockTextStorage.isEmptySeparator(storage, range: next) { break }
            }
            return NSRange(location: start.location, length: end - start.location)
        }
        func previousRole(before id: UUID, storage: NSAttributedString) -> EditorTypography.Role? {
            guard let index = positions[id], index > 0 else { return nil }
            for offset in stride(from: index - 1, through: 0, by: -1) {
                let range = NSRange(location: prefix(offset), length: lengths[offset])
                if BlockTextStorage.isEmptySeparator(storage, range: range) { continue }
                let kind = BlockKind(rawValue: storage.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph")
                return EditorTypography.role(for: kind)
            }
            return nil
        }
    }
    private static var metadataCache: [(BlockMetadata, Data)] = []
    private static var mathCache: [String: String] = [:]
    private static func encodedStyle(_ style: InlineStyle) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(style)
    }
    private static var cachedMacroSource = ""
    private static var cachedMacros: [TeXMacro] = []
    static func renderedMath(_ raw: String, display: Bool, defaults: UserDefaults = .standard) -> String {
        // Reading one preferences string is cheap; decode macros only when it
        // changes. Its bytes also version every mathematical presentation.
        let source = defaults.string(forKey: TeXMacroStore.defaultsKey) ?? ""
        if source != cachedMacroSource {
            cachedMacroSource = source
            cachedMacros = TeXMacroStore.load(from: defaults)
            mathCache.removeAll(keepingCapacity: true)
        }
        let key = String(display) + raw + "\u{0}" + source
        if let rendered = mathCache[key] { return rendered }
        let rendered = TeXMath.render(raw, display: display, macros: cachedMacros)
        if mathCache.count >= 256 { mathCache.removeAll(keepingCapacity: true) }
        mathCache[key] = rendered
        return rendered
    }
    private static func encodedMetadata(_ metadata: BlockMetadata) -> Data? {
        if let cached = metadataCache.first(where: { $0.0 == metadata }) { return cached.1 }
        guard let encoded = try? JSONEncoder().encode(metadata) else { return nil }
        if metadataCache.count >= 32 { metadataCache.removeFirst() }
        metadataCache.append((metadata, encoded)); return encoded
    }
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
        attrs[.inlineStyle] = encodedStyle(InlineStyle())
        attrs[.blockMetadata] = encodedMetadata(block.metadata)
        if let semantic = block.metadata.semantic { attrs[.semanticTag] = semantic }
        return attrs
    }
    static func attributes(_ style: InlineStyle, block: EditorBlock, depth: Int, theme: NoemaTheme, typography: EditorTypography = .init()) -> [NSAttributedString.Key: Any] {
        var attrs = base(block, depth: depth, theme: theme, typography: typography)
        attrs[.font] = typography.font(for: EditorTypography.role(for: block.kind), style: style)
        attrs[.inlineStyle] = encodedStyle(style)
        if style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if style.highlight || style.code { attrs[.backgroundColor] = theme.native(.graphHighlight).withAlphaComponent(theme.dark ? 0.22 : 0.10) }
        if let target = style.wikiTarget {
            attrs[.wikiTarget] = target
            var url = URLComponents(); url.scheme = "noema"; url.host = "wiki"; url.queryItems = [.init(name: "title", value: target)]
            attrs[.link] = url.url
        } else if let link = style.link { attrs[.link] = URL(string: link) }
        return attrs
    }
    static func render(_ document: BlockDocument, theme: NoemaTheme, showSemanticHeadings: Bool = false, typography: EditorTypography = .init()) -> NSAttributedString {
        let result = renderVisible(visible(document), theme: theme, typography: typography)
        updateParagraphRhythm(result, typography: typography)
        if showSemanticHeadings { updateSemanticHeadingSpacing(result, typography: typography) }
        return result
    }
    static func renderBlock(_ block: EditorBlock, depth: Int, theme: NoemaTheme, typography: EditorTypography) -> NSAttributedString {
        renderVisible([VisibleBlock(block: block, depth: depth, number: 0)], theme: theme, typography: typography)
    }
    private static func renderVisible(_ values: [VisibleBlock], theme: NoemaTheme, typography: EditorTypography) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for value in values {
            let block = value.block
            for run in block.runs {
                var attrs = attributes(run.style, block: block, depth: value.depth, theme: theme, typography: typography)
                // Keep model characters stable. Mathematical images only affect
                // TextKit glyph layout, never selection or block offsets.
                let displayString = run.text
                if run.style.math {
                    attrs[.renderedMath] = displayString
                    if let data = try? JSONEncoder().encode(run) {
                        attrs[.originalRichRun] = ["data": data, "id": UUID().uuidString] as [String: Any]
                    }
                }
                result.append(NSAttributedString(string: displayString, attributes: attrs))
            }
            result.append(NSAttributedString(string: "\n", attributes: base(block, depth: value.depth, theme: theme, typography: typography)))
        }
        return result
    }
    /// Replace only the changed visible span. Structural changes invalidate the
    /// index; unchanged prefix/suffix attributed runs retain native storage.
    @discardableResult static func apply(document: BlockDocument, previous: BlockDocument,
        to storage: NSMutableAttributedString, index: RangeIndex, theme: NoemaTheme,
        showSemanticHeadings: Bool = false, typography: EditorTypography = .init()) -> NSRange {
        let before = visible(previous), after = visible(document)
        func same(_ lhs: VisibleBlock, _ rhs: VisibleBlock) -> Bool {
            lhs.block.id == rhs.block.id && lhs.block.kind == rhs.block.kind && lhs.block.runs == rhs.block.runs
                && lhs.block.metadata == rhs.block.metadata && lhs.depth == rhs.depth && lhs.number == rhs.number
        }
        var prefix = 0
        while prefix < min(before.count, after.count), same(before[prefix], after[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              same(before[before.count - suffix - 1], after[after.count - suffix - 1]) { suffix += 1 }
        guard prefix < before.count || prefix < after.count else { return NSRange(location: 0, length: 0) }
        let start = prefix < before.count ? index.range(for: before[prefix].block.id)?.location ?? storage.length : storage.length
        let end = suffix > 0 ? index.range(for: before[before.count - suffix].block.id)?.location ?? storage.length : storage.length
        let replacement = renderVisible(Array(after[prefix..<(after.count - suffix)]), theme: theme, typography: typography)
        storage.replaceCharacters(in: NSRange(location: start, length: max(0, end - start)), with: replacement)
        // Local block-content and metadata changes keep the prefix index. A
        // structural change (including numbering/depth) rebuilds it once.
        let sameStructure = before.count == after.count && zip(before, after).allSatisfy { lhs, rhs in
            lhs.block.id == rhs.block.id && lhs.block.kind == rhs.block.kind && lhs.depth == rhs.depth && lhs.number == rhs.number
        }
        if sameStructure {
            let oldLengths = before[prefix..<(before.count - suffix)].map { index.range(for: $0.block.id)?.length ?? 0 }
            let newLengths = ranges(replacement).map { $0.1.length }
            for (offset, value) in after[prefix..<(after.count - suffix)].enumerated() {
                index.applyLocalEdit(blockID: value.block.id, delta: newLengths[offset] - oldLengths[offset])
            }
        } else { index.rebuild(storage) }
        // A following separator has no role of its own; include the next
        // content block so changing a heading cannot leave stale body spacing.
        let tail = index.block(at: min(start + max(0, replacement.length - 1), max(0, storage.length - 1)))
        let tailRange = tail.flatMap { id, range in
            replacement.length > 0 || isEmptySeparator(storage, range: range)
                ? index.rhythmAffectedRange(for: id, storage: storage) : range
        }
        let affected = NSRange(location: start, length: max(replacement.length, (tailRange.map(NSMaxRange) ?? start) - start))
        updateParagraphRhythm(storage, in: affected, index: index, typography: typography)
        if showSemanticHeadings { updateSemanticHeadingSpacing(storage, in: affected, index: index, typography: typography) }
        return affected
    }
    /// Normalize paragraph attributes after rendering and native editing. A
    /// newline inside one block keeps its line rhythm, without another block gap.
    static func updateParagraphRhythm(_ storage: NSMutableAttributedString, in affectedRange: NSRange? = nil, index: RangeIndex? = nil, typography: EditorTypography = .init()) {
        var previous: EditorTypography.Role?
        let text = storage.string as NSString
        var changes: [(NSRange, NSMutableParagraphStyle)] = []
        let blocks = affectedRange.flatMap { range in index.map { $0.intersecting(range) } } ?? ranges(storage)
        if let id = blocks.first?.0, let index, affectedRange != nil {
            previous = index.previousRole(before: id, storage: storage)
        }
        for (_, blockRange) in blocks {
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
    static func updateSemanticHeadingSpacing(_ storage: NSMutableAttributedString, in affectedRange: NSRange? = nil, index: RangeIndex? = nil, typography: EditorTypography = .init()) {
        var previous: EditorTypography.Role?
        let blocks = affectedRange.flatMap { range in index.map { $0.intersecting(range) } } ?? ranges(storage)
        if let id = blocks.first?.0, let index, affectedRange != nil {
            previous = index.previousRole(before: id, storage: storage)
        }
        for (_, range) in blocks {
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
        if !style.math { style.highlight = attrs[.backgroundColor] != nil && !style.code }
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
        storage.enumerateAttribute(.originalRichRun, in: range) { original, part, _ in
            let text = (storage.string as NSString).substring(with: part)
            if let marker = original as? [String: Any], let data = marker["data"] as? Data,
               let run = try? JSONDecoder().decode(RichRun.self, from: data),
               run.text == text,
               style(storage.attributes(at: part.location, effectiveRange: nil)) == run.style {
                result.append(run)
                return
            }
            storage.enumerateAttributes(in: part) { attrs, segment, _ in
                let text = (storage.string as NSString).substring(with: segment)
                var value = style(attrs)
                if value.math, let rendered = attrs[.renderedMath] as? String, text != rendered {
                    value.rawMath = text
                }
                if result.last?.style == value { result[result.count - 1].text += text }
                else { result.append(RichRun(text, style: value)) }
            }
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
