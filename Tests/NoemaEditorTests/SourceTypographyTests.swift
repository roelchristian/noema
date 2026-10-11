import AppKit
import Testing
import VaultCore
@testable import noema

@Test @MainActor func sourceMarkdownUsesReadingRolesAndPreservesLinksAndContent() throws {
    let source = "# Title\n\n## Section\n\n### Detail\n\n#### Small heading\n\n##### Emphasized heading\n\nBody **bold** and *italic* and `inline code` and [link](https://example.com) and [[Wiki page]].\n\n> A quotation\n\n```swift\nlet value = 1\n```"
    let bytes = Data(source.utf8)
    let blocks = MarkdownService.preview(source)
    let theme = NoemaTheme(dark: false)
    let baseline = SourceTextPresentation.markdown(blocks, typography: EditorTypography(), theme: theme)
    for size in [10.0, 16, 32] {
        let typography = EditorTypography(family: "Helvetica", size: size)
        let rendered = SourceTextPresentation.markdown(blocks, typography: typography, theme: theme)
        #expect(rendered.string == baseline.string)
        for (text, role) in [("Title", EditorTypography.Role.heading1), ("Section", .heading2), ("Detail", .heading3), ("Small heading", .body), ("Emphasized heading", .body), ("Body", .body), ("A quotation", .quote), ("let value", .code)] {
            let range = (rendered.string as NSString).range(of: text)
            let font = try #require(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            #expect(abs(font.pointSize - typography.pointSize(for: role)) < 0.001)
            if role != .code { #expect(font.familyName == "Helvetica") }
        }
        let codeRange = (rendered.string as NSString).range(of: "inline code")
        let codeFont = try #require(rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: codeFont).contains(.fixedPitchFontMask))
        #expect(abs(codeFont.pointSize - typography.pointSize(for: .code)) < 0.001)
        let urlRange = (rendered.string as NSString).range(of: "link")
        #expect((rendered.attribute(.link, at: urlRange.location, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com")
        let wikiRange = (rendered.string as NSString).range(of: "Wiki page")
        let wikiURL = try #require(rendered.attribute(.link, at: wikiRange.location, effectiveRange: nil) as? URL)
        #expect(wikiURL.scheme == "noema")
        #expect(URLComponents(url: wikiURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Wiki page")
    }
    #expect(Data(source.utf8) == bytes)
    #expect(MarkdownService.preview(source) == blocks)
}

@Test @MainActor func sourceHTMLRetainsImportSemanticsWithEditorialTypography() throws {
    let bytes = Data("<h1>Title</h1><h2>Section</h2><p>Body <b>bold</b> <i>italic</i> <code>code</code> <a href='https://example.com'>link</a></p><p><code>first code</code> regular prose</p><blockquote>Quoted text</blockquote><pre>let value = 1\nlet next = 2</pre>".utf8)
    let imported = try NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
    let originalCopy = NSAttributedString(attributedString: imported)
    let typography = EditorTypography(family: "Helvetica", size: 20)
    let rendered = SourceTextPresentation.html(imported, typography: typography, theme: NoemaTheme(dark: true))
    #expect(rendered.string == imported.string)
    #expect(imported.isEqual(to: originalCopy))
    for (text, role) in [("Title", EditorTypography.Role.heading1), ("Section", .heading2), ("Body", .body), ("Quoted text", .quote), ("regular prose", .body), ("let value", .code)] {
        let range = (rendered.string as NSString).range(of: text)
        let font = try #require(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - typography.pointSize(for: role)) < 0.001)
    }
    for (text, trait) in [("bold", NSFontTraitMask.boldFontMask), ("italic", .italicFontMask), ("code", .fixedPitchFontMask)] {
        let range = (rendered.string as NSString).range(of: text)
        let font = try #require(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(trait))
    }
    let nextLine = (rendered.string as NSString).range(of: "let next")
    let nextParagraph = try #require(rendered.attribute(.paragraphStyle, at: nextLine.location, effectiveRange: nil) as? NSParagraphStyle)
    #expect(nextParagraph.paragraphSpacingBefore == 0)
    let link = (rendered.string as NSString).range(of: "link")
    #expect(rendered.attribute(.link, at: link.location, effectiveRange: nil) != nil)
}

@Test @MainActor func sourcePlainTextAndNativeRefreshPreserveSelectionAndMeasure() throws {
    let source = String(repeating: "Readable prose with a second sentence.\n", count: 150)
    let view = ReadingTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    view.isEditable = false; view.isSelectable = true; view.isVerticallyResizable = true
    view.textContainer?.widthTracksTextView = true
    let scroll = NSScrollView(frame: view.frame)
    scroll.documentView = view
    let first = SourceTextPresentation.plainText(source, typography: EditorTypography(size: 16), theme: NoemaTheme(dark: false))
    view.replacePresentation(first)
    let selected = NSRange(location: 60, length: 24)
    view.setSelectedRange(selected)
    let second = SourceTextPresentation.plainText(source, typography: EditorTypography(family: "Helvetica", size: 24), theme: NoemaTheme(dark: true))
    view.replacePresentation(second, typography: EditorTypography(family: "Helvetica", size: 24))
    #expect(view.string == source)
    #expect(view.selectedRange() == selected)
    let font = try #require(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(font.familyName == "Helvetica")
    #expect(font.pointSize == 24)
    view.setFrameSize(NSSize(width: 900, height: 600))
    #expect(abs(view.bounds.width - 2 * view.textContainerInset.width - 680) < 0.001)
    view.setFrameSize(NSSize(width: 300, height: 600))
    #expect(view.textContainerInset.width == 24)
    #expect(view.bounds.width - 2 * view.textContainerInset.width == 252)
}

@Test @MainActor func plainSourceEmptyParagraphsHaveSingleBoundaryAndRetainBytes() throws {
    let source = "First paragraph\n\n\nNext paragraph\n"
    let bytes = Data(source.utf8)
    let typography = EditorTypography()
    let rendered = SourceTextPresentation.plainText(source, typography: typography, theme: NoemaTheme())
    let text = source as NSString
    text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, _ in
        let paragraph = rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as! NSParagraphStyle
        let expected: CGFloat = range.length == 0 || range.location == 0 ? 0 : typography.boundarySpacing(before: .body, after: .body)
        #expect(abs(paragraph.paragraphSpacingBefore - expected) < 0.001)
        #expect(paragraph.paragraphSpacing == 0)
    }
    #expect(rendered.string == source)
    #expect(Data(rendered.string.utf8) == bytes)
}
