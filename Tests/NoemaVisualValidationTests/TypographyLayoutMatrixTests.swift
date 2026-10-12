import AppKit
import Testing
import VaultCore
import NoemaBrand
@testable import noema

/// Original complete native layout matrices, separate from raster export.
@Suite("Visual validation: Typography full layout matrix", .serialized)
@MainActor struct TypographyLayoutMatrixTests {
    private let prose = "A knowledge vault should make extended reading comfortable. The same native typography follows an article and its readable sources, while preserving every original byte."
    private var markdown: String {
        "# Editorial reading\n\n\(prose)\n\n## A second-level heading\n\nBody **bold** and *italic* and `inline code` and a [reference](https://example.com).\n\n### A third-level heading\n\n> A quotation uses the chosen reading family.\n\n- A list item with enough words to wrap naturally in a narrow reading viewport.\n- Another item\n\n```swift\nlet knowledge = \"Keep the original\"\n```"
    }
    private var document: BlockDocument {
        var value = BlockDocumentCodec.decode(markdown)
        var metadata = BlockMetadata(); metadata.semantic = "idea"
        value.blocks.append(EditorBlock(runs: [RichRun("An idea remains ordinary readable prose.\nContinuation shares its baseline rhythm.")], metadata: metadata))
        return value
    }
    private let families = [("system", ""), ("serif", "Times New Roman"), ("missing", "Unavailable UI.TYP08 Family")]

    @Test func editorNativeLayoutMatrixPreservesContentAndSelection() async throws {
        let original = document
        let serialized = BlockDocumentCodec.encode(original)
        for (_, family) in families {
            for size in [10.0, 16, 32] {
                for width in [CGFloat(420), 1040] {
                    for dark in [false, true] {
                        let typography = EditorTypography(family: family, size: size)
                        let theme = NoemaTheme(dark: dark)
                        let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1100))
                        view.theme = theme; view.typography = typography
                        view.isEditable = false; view.isSelectable = true
                        configure(view, theme: theme)
                        for headings in [false, true] {
                            view.showSemanticHeadings = headings
                            view.textStorage?.setAttributedString(BlockTextStorage.render(original, theme: theme,
                                showSemanticHeadings: headings, typography: typography))
                            view.updateSemanticHeadingTopInset()
                            let selection = NSRange(location: 22, length: 17)
                            view.setSelectedRange(selection)
                            try verifyLayout(view)
                            #expect(view.selectedRange() == selection)
                            let captured = BlockTextStorage.capture(try #require(view.textStorage), previous: original)
                            #expect(captured == original)
                            #expect(BlockDocumentCodec.encode(captured) == serialized)
                        }
                    }
                }
            }
        }
    }

    @Test func sourceNativeLayoutMatrixMatchesEditorAndPreservesOriginals() async throws {
        let bytes = Data(markdown.utf8)
        let blocks = MarkdownService.preview(markdown)
        let htmlBytes = Data("<h1>Editorial reading</h1><p>\(prose)</p><h2>A second-level heading</h2><p>Body <b>bold</b> and <i>italic</i> and <code>inline code</code> and a <a href='https://example.com'>reference</a>.</p><h3>A third-level heading</h3><blockquote>A quotation uses the chosen reading family.</blockquote><ul><li>A list item with enough words to wrap naturally in a narrow reading viewport.</li><li>Another item</li></ul><pre>let knowledge = \"Keep the original\"</pre>".utf8)
        let imported = try NSAttributedString(data: htmlBytes, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        let originalImport = NSAttributedString(attributedString: imported)
        for (_, family) in families {
            for size in [10.0, 16, 32] {
                for width in [CGFloat(420), 1040] {
                    for dark in [false, true] {
                        let typography = EditorTypography(family: family, size: size)
                        let theme = NoemaTheme(dark: dark)
                        let editor = BlockTextStorage.render(document, theme: theme, typography: typography)
                        let sourceMarkdown = SourceTextPresentation.markdown(blocks, typography: typography, theme: theme)
                        // Identical prose roles share native font and rhythm, even
                        // though source/import structure remains consumer-owned.
                        for text in ["Editorial reading", "A second-level heading", "A third-level heading", prose] {
                            let e = (editor.string as NSString).range(of: text)
                            let s = (sourceMarkdown.string as NSString).range(of: text)
                            #expect(e.location != NSNotFound && s.location != NSNotFound)
                            #expect(editor.attribute(.font, at: e.location, effectiveRange: nil) as? NSFont == sourceMarkdown.attribute(.font, at: s.location, effectiveRange: nil) as? NSFont)
                            let ep = try #require(editor.attribute(.paragraphStyle, at: e.location, effectiveRange: nil) as? NSParagraphStyle)
                            let sp = try #require(sourceMarkdown.attribute(.paragraphStyle, at: s.location, effectiveRange: nil) as? NSParagraphStyle)
                            #expect(ep.lineSpacing == sp.lineSpacing)
                            #expect(ep.paragraphSpacingBefore == sp.paragraphSpacingBefore)
                        }
                        for (_, content) in [("markdown", sourceMarkdown),
                                                ("html", SourceTextPresentation.html(imported, typography: typography, theme: theme)),
                                                ("plain", SourceTextPresentation.plainText(prose + "\n\n" + prose, typography: typography, theme: theme))] {
                            let view = ReadingTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1100))
                            view.isEditable = false; view.isSelectable = true
                            configure(view, theme: theme)
                            view.replacePresentation(content, typography: typography)
                            let selected = NSRange(location: 10, length: 19)
                            view.setSelectedRange(selected)
                            view.replacePresentation(content, typography: typography)
                            try verifyLayout(view)
                            #expect(view.selectedRange() == selected)
                            #expect(view.string == content.string)
                        }
                        #expect(imported.isEqual(to: originalImport))
                        #expect(Data(markdown.utf8) == bytes)
                    }
                }
            }
        }
    }

    private func configure(_ view: NSTextView, theme: NoemaTheme) {
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset.height = 24
        view.drawsBackground = false; view.backgroundColor = theme.native(.surfaceElevated)
        view.setFrameSize(view.frame.size)
    }

    private func verifyLayout(_ view: NSTextView) throws {
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        manager.ensureLayout(for: container)
        #expect(container.size.width > 0 && container.size.width <= 680)
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, used, _, _, _ in
            #expect(rect.height > 0 && used.height > 0)
            #expect(used.minX >= -0.01 && used.maxX <= container.size.width + 0.01)
        }
    }

}
