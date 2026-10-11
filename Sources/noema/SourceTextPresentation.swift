import AppKit
import VaultCore

/// Source presentation translates semantic content into the shared editorial system.
/// It only creates display attributes; the original source data remains untouched.
@MainActor enum SourceTextPresentation {
    static func role(for style: PreviewBlock.Style) -> EditorTypography.Role {
        switch style {
        case .heading(let level):
            switch level { case 1: .heading1; case 2: .heading2; case 3: .heading3; default: .body }
        case .quote: .quote
        case .code: .code
        case .math: .math
        case .paragraph, .rule: .body
        }
    }

    static func markdown(_ blocks: [PreviewBlock], typography: EditorTypography, theme: NoemaTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, block) in blocks.enumerated() {
            let blockStart = result.length
            let role = role(for: block.style)
            let previous = index > 0 ? self.role(for: blocks[index - 1].style) : nil
            let paragraph = paragraphStyle(for: role, previous: previous, typography: typography)
            if case .heading(let level) = block.style { paragraph.headerLevel = level }
            if block.style == .quote {
                paragraph.headIndent = typography.pointSize(for: .body)
                paragraph.firstLineHeadIndent = paragraph.headIndent
            }
            if block.style == .math { paragraph.alignment = .center }
            let color = block.style == .quote ? theme.nativeText(.textMuted) : (block.style == .rule ? theme.native(.border) : theme.nativeText())
            let base: [NSAttributedString.Key: Any] = [.font: typography.font(for: role), .foregroundColor: color, .paragraphStyle: paragraph]
            for span in block.spans {
                var style = InlineStyle()
                style.bold = span.bold; style.italic = span.italic; style.code = span.code; style.math = span.math
                // H4–H6 retain hierarchy without inventing another document type scale.
                if case .heading(let level) = block.style, level >= 4 { style.bold = true }
                var attributes = base
                attributes[.font] = typography.font(for: role, style: style)
                if span.code || span.math { attributes[.backgroundColor] = theme.native(.accentPrimary).withAlphaComponent(theme.dark ? 0.18 : 0.08) }
                if let target = span.wikiTarget {
                    var components = URLComponents(); components.scheme = "noema"; components.host = "wiki"
                    components.queryItems = [URLQueryItem(name: "title", value: target)]
                    attributes[.link] = components.url
                } else if let address = span.url, let url = URL(string: address), ["http", "https", "mailto"].contains(url.scheme ?? "") { attributes[.link] = url }
                let text = span.math ? (span.rawMath.map { TeXMath.render($0, display: block.style == .math) } ?? span.text) : span.text
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: base))
            // Embedded hard breaks and code lines continue the same block: the
            // incoming block gap belongs only to its first paragraph.
            let blockRange = NSRange(location: blockStart, length: result.length - blockStart)
            let firstBreak = (result.string as NSString).range(of: "\n", options: [], range: blockRange)
            let continuationStart = NSMaxRange(firstBreak)
            if continuationStart < result.length {
                let continuation = paragraph.mutableCopy() as! NSMutableParagraphStyle
                continuation.paragraphSpacingBefore = 0
                result.addAttribute(.paragraphStyle, value: continuation, range: NSRange(location: continuationStart, length: result.length - continuationStart))
            }
        }
        return result
    }

    static func plainText(_ text: String, typography: EditorTypography, theme: NoemaTheme) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: typography.font(for: .body), .foregroundColor: theme.nativeText(),
            .paragraphStyle: paragraphStyle(for: .body, previous: .body, typography: typography)])
    }

    /// AppKit's HTML importer preserves headings, lists, indentation and inline traits.
    /// Preserve those semantics while replacing only editorial fonts and rhythm.
    static func html(_ imported: NSAttributedString, typography: EditorTypography, theme: NoemaTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: imported)
        let fullRange = NSRange(location: 0, length: imported.length)
        var previous: EditorTypography.Role?
        (imported.string as NSString).enumerateSubstrings(in: fullRange, options: .byParagraphs) { _, range, enclosingRange, _ in
            guard range.location < imported.length else { return }
            let attributes = imported.attributes(at: range.location, effectiveRange: nil)
            let original = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
            var allMonospaced = true
            imported.enumerateAttribute(.font, in: range) { value, _, _ in
                if let font = value as? NSFont { allMonospaced = allMonospaced && NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) }
                else { allMonospaced = false }
            }
            let role: EditorTypography.Role
            switch original.headerLevel {
            case 1: role = .heading1
            case 2: role = .heading2
            case 3: role = .heading3
            case 4, 5, 6: role = .body
            default:
                if allMonospaced { role = .code }
                else if original.headIndent > 0 && original.textLists.isEmpty && original.textBlocks.isEmpty { role = .quote }
                else { role = original.textLists.isEmpty ? .body : .list }
            }
            let paragraph = original.mutableCopy() as! NSMutableParagraphStyle
            let metrics = paragraphStyle(for: role, previous: previous, typography: typography)
            paragraph.lineSpacing = metrics.lineSpacing
            paragraph.paragraphSpacing = metrics.paragraphSpacing
            paragraph.paragraphSpacingBefore = role == .code && previous == .code ? 0 : metrics.paragraphSpacingBefore
            paragraph.minimumLineHeight = 0; paragraph.maximumLineHeight = 0; paragraph.lineHeightMultiple = 0
            result.addAttributes([.paragraphStyle: paragraph, .foregroundColor: role == .quote ? theme.nativeText(.textMuted) : theme.nativeText()], range: enclosingRange)
            imported.enumerateAttribute(.font, in: enclosingRange) { value, run, _ in
                var style = InlineStyle()
                if let font = value as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    style.bold = traits.contains(.boldFontMask)
                    style.italic = traits.contains(.italicFontMask)
                    style.code = traits.contains(.fixedPitchFontMask)
                }
                if original.headerLevel >= 4 { style.bold = true }
                result.addAttribute(.font, value: typography.font(for: role, style: style), range: run)
            }
            previous = role
        }
        return result
    }

    private static func paragraphStyle(for role: EditorTypography.Role, previous: EditorTypography.Role?, typography: EditorTypography) -> NSMutableParagraphStyle {
        // Shared role metrics are supplied by EditorTypography (UI.TYP03).
        typography.paragraphStyle(for: role, previous: previous)
    }
}

/// Read-only prose geometry has no editor decorations or reserved semantic gutters.
@MainActor final class ReadingTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let geometry = ReadingGeometry(availableWidth: bounds.width)
        textContainerInset = NSSize(width: geometry.horizontalInset, height: textContainerInset.height)
        textContainer?.lineFragmentPadding = 0
    }

    func replacePresentation(_ content: NSAttributedString) {
        let selections = selectedRanges
        let origin = enclosingScrollView?.contentView.bounds.origin
        textStorage?.setAttributedString(content)
        selectedRanges = selections.map { value in
            let range = value.rangeValue
            let location = min(range.location, content.length)
            return NSValue(range: NSRange(location: location, length: min(range.length, content.length - location)))
        }
        if let textContainer { layoutManager?.ensureLayout(for: textContainer) }
        if let origin, let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
