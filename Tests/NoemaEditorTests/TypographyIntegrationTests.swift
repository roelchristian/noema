import AppKit
import SwiftUI
import Testing
import VaultCore
import NoemaBrand
@testable import noema

/// Native layout and raster validation runs normally. PNG export is opt-in and
/// never uses a personal vault or changes the application's saved preferences.
@Suite("UI.TYP08 editorial integration", .serialized)
@MainActor struct TypographyIntegrationTests {
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
        for (familyName, family) in families {
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
                        try await capture(view, name: "editor-\(familyName)-\(Int(size))-\(Int(width))-\(dark ? "dark" : "light")", dark: dark)
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
        for (familyName, family) in families {
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
                        for (kind, content) in [("markdown", sourceMarkdown),
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
                            if size == 16 {
                                try await capture(view, name: "source-\(kind)-\(familyName)-16-\(Int(width))-\(dark ? "dark" : "light")", dark: dark)
                            }
                        }
                        #expect(imported.isEqual(to: originalImport))
                        #expect(Data(markdown.utf8) == bytes)
                    }
                }
            }
        }
    }

    @Test func preferencesAndIncreasedContrastFixturesUseIsolatedDefaults() async throws {
        let suite = "NoemaTypographyCapture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for dark in [false, true] {
            defaults.set(dark ? "Unavailable UI.TYP08 Family" : "Times New Roman", forKey: EditorPreferences.fontFamilyKey)
            defaults.set(16.0, forKey: EditorPreferences.fontSizeKey)
            let theme = NoemaTheme(dark: dark, increasedContrast: true)
            let service = ExternalAIService(accessGate: VaultAccessGate(), defaults: defaults)
            let settings = NSHostingView(rootView: NoemaSettings(externalAIService: service).defaultAppStorage(defaults)
                .environment(\.noemaTheme, theme).environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.disablesAnimations = true })
            settings.frame = NSRect(x: 0, y: 0, width: 760, height: 1000)
            try await capture(settings, name: "preferences-increased-contrast-static-\(dark ? "dark" : "light")", dark: dark, increased: true)
            let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 1100))
            view.theme = theme; view.typography = EditorTypography(size: 16)
            view.showSemanticHeadings = true
            configure(view, theme: theme)
            view.textStorage?.setAttributedString(BlockTextStorage.render(document, theme: theme, showSemanticHeadings: true))
            view.updateSemanticHeadingTopInset()
            try await capture(view, name: "editor-increased-contrast-\(dark ? "dark" : "light")", dark: dark, increased: true)
            let backing = try #require(theme.native(.surfaceElevated).usingColorSpace(.sRGB))
            for role in [ThemeRole.textPrimary, .textMuted] {
                let foreground = try #require(theme.nativeText(role).usingColorSpace(.sRGB))
                #expect(rgb(foreground).contrastRatio(against: rgb(backing)) >= 7)
            }
        }
        print("UI.TYP08 fixtures: 72 editor layouts, 108 source layouts, 2 static preference fixtures, 2 increased-contrast editor fixtures. Export: 76 PNGs when requested. OS Reduce Motion: \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion).")
    }

    @Test func customFamilyWeightsSelectNearestRealUprightFace() throws {
        for family in ["Avenir Next", "Times New Roman", "Helvetica"] {
            let fonts = try #require(NSFontManager.shared.availableMembers(ofFontFamily: family)).compactMap { member -> NSFont? in
                guard let name = member.first as? String, let font = NSFont(name: name, size: 16),
                      !NSFontManager.shared.traits(of: font).contains(.italicFontMask) else { return nil }
                return font
            }
            #expect(!fonts.isEmpty)
            for weight in [NSFont.Weight.regular, .medium, .semibold, .bold] {
                let resolved = EditorTypography(family: family).font(weight: weight)
                func distance(_ font: NSFont) -> CGFloat {
                    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
                    return abs(CGFloat((traits?[.weight] as? NSNumber)?.doubleValue ?? 0) - weight.rawValue)
                }
                #expect(resolved.familyName == family)
                #expect(!NSFontManager.shared.traits(of: resolved).contains(.italicFontMask))
                #expect(abs(distance(resolved) - (fonts.map(distance).min() ?? .infinity)) < 0.001)
            }
        }
    }

    @Test func defaultReadingMeasureRecordsActualNativeCharactersPerLine() throws {
        let text = String(repeating: prose + " ", count: 20)
        for family in ["", "Times New Roman"] {
            let typography = EditorTypography(family: family)
            let view = ReadingTextView(frame: NSRect(x: 0, y: 0, width: 1040, height: 5000))
            configure(view, theme: NoemaTheme())
            view.replacePresentation(SourceTextPresentation.plainText(text, typography: typography, theme: NoemaTheme()), typography: typography)
            try verifyLayout(view)
            let manager = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            var counts: [Int] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                counts.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).length)
            }
            let fullLines = counts.dropLast()
            let mean = Double(fullLines.reduce(0, +)) / Double(max(1, fullLines.count))
            print("UI.TYP08 default native prose measure (\(family.isEmpty ? "system" : family)): \(container.size.width) pt; \(String(format: "%.1f", mean)) UTF-16 characters per complete line in this English fixture; \(counts.count) lines.")
            #expect(mean >= 65 && mean <= 80)
            #expect(counts.count > 20)
            let editor = ArticleTextView(frame: view.frame)
            editor.typography = typography; editor.updateReadingGeometry()
            #expect(abs((editor.textContainer?.size.width ?? 0) - container.size.width) < 0.001)
        }
    }

    @Test func typographyNeverWritesCanonicalSourceBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaTypographyBytes-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try PlaintextVaultContentStore(root: root)
        let repository = try FileVaultRepository.open(root: root, create: true, contentStore: store)
        let bytes = Data(markdown.utf8)
        let source = try await repository.importSource(data: bytes, filename: "reading.md", title: "Reading fixture", originURL: nil)
        let path = "Sources/" + source.id.uuidString.lowercased() + "/" + source.metadata.storedFilename
        let before = try store.snapshot(at: path)
        for family in families.map(\.1) {
            for size in [10.0, 16, 32] {
                _ = SourceTextPresentation.markdown(MarkdownService.preview(String(decoding: try store.read(at: path), as: UTF8.self)), typography: EditorTypography(family: family, size: size), theme: NoemaTheme(dark: true))
            }
        }
        #expect(try store.read(at: path) == bytes)
        #expect(try store.snapshot(at: path) == before)
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

    private func capture(_ view: NSView, name: String, dark: Bool, increased: Bool = false) async throws {
        _ = NSApplication.shared
        let appearanceName: NSAppearance.Name = increased ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua)
        // Native layout may grow the document before export. Preserve the actual
        // requested scroll viewport instead of turning enlarged text into a taller image.
        let viewport = NSRect(x: 0, y: 0, width: view.frame.width,
                              height: view is NSTextView ? 1100 : view.frame.height)
        let window = NSWindow(contentRect: viewport, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearanceName)
        let surface: NSView
        if let text = view as? NSTextView {
            text.setSelectedRange(NSRange(location: 0, length: 0))
            let scroll = NSScrollView(frame: viewport)
            scroll.drawsBackground = true; scroll.backgroundColor = text.backgroundColor
            scroll.hasVerticalScroller = false
            scroll.documentView = text
            surface = scroll
        } else { surface = view }
        view.appearance = window.appearance; window.contentView = surface
        defer { window.contentView = nil; window.close() }
        surface.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        surface.layoutSubtreeIfNeeded(); surface.displayIfNeeded()
        let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(surface.bounds.width) && bitmap.pixelsHigh >= Int(surface.bounds.height))
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 11) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 11) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        #expect(colors.count > 8, "\(name) should contain native text, not a blank raster")
        if let path = ProcessInfo.processInfo.environment["NOEMA_TYPOGRAPHY_AFTER_CAPTURE_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private func rgb(_ color: NSColor) -> ThemeRGB {
        var value = ThemeRGB(hex: 0)
        value.red = Double(color.redComponent); value.green = Double(color.greenComponent); value.blue = Double(color.blueComponent)
        return value
    }
}
