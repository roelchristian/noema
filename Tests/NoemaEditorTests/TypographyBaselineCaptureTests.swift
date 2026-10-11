import AppKit
import SwiftUI
import Testing
import VaultCore
@testable import noema

/// Opt-in native fixture capture. For the UI.TYP01 baseline run this file against
/// b6cd5c7, before any production typography changes. Later runs are comparisons.
@Suite("Editorial typography native captures (UI.TYP01)", .serialized)
struct TypographyBaselineCaptureTests {
    private let markdown = """
    # Editorial reading

    A knowledge vault should make extended reading comfortable. This paragraph intentionally wraps across several lines so native baseline spacing and reading measure can be inspected alongside the document hierarchy.

    ## A second-level heading

    Body text includes **bold**, *italic*, `inline code`, and a [reference](https://example.com).

    ### A third-level heading

    > A quotation uses the document's reading family and a reserved gutter.

    - A first list item that wraps to show continuation alignment beside its marker.
    - A second list item

    ```swift
    let knowledge = "Keep the original"
    ```
    """

    @Test @MainActor func captureOnlyWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOEMA_TYPOGRAPHY_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            let theme = NoemaTheme(dark: dark)
            for size in [10.0, 15.0, 32.0] {
                var document = BlockDocumentCodec.decode(markdown)
                var metadata = BlockMetadata(); metadata.semantic = "idea"
                document.blocks.append(EditorBlock(runs: [RichRun("A semantic idea remains ordinary readable prose.")], metadata: metadata))
                let article = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 940))
                article.theme = theme
                article.isEditable = false
                article.drawsBackground = false
                article.backgroundColor = theme.native(.surfaceElevated)
                article.textContainerInset = NSSize(width: 80, height: 24)
                article.textContainer?.widthTracksTextView = true
                article.textStorage?.setAttributedString(BlockTextStorage.render(document, theme: theme,
                    typography: EditorTypography(family: "", size: size)))
                try await capture(article, name: "article-system-\(Int(size))-\(dark ? "dark" : "light")",
                    appearance: appearance, directory: directory)
            }
            // This is the real MarkdownPreview representable, not a re-created style sheet.
            let preview = NSHostingView(rootView: MarkdownPreview(blocks: MarkdownService.preview(markdown), onWikiLink: { _ in })
                .environment(\.noemaTheme, theme).environment(\.colorScheme, dark ? .dark : .light)
                .background(theme.color(.surfaceElevated)))
            preview.frame = NSRect(x: 0, y: 0, width: 840, height: 940)
            try await capture(preview, name: "source-preview-\(dark ? "dark" : "light")",
                appearance: appearance, directory: directory)
        }
        print("UI.TYP01 captured 8 native fixture PNGs in \(directory.path); no live interaction was exercised.")
    }

    @MainActor private func capture(_ view: NSView, name: String, appearance: NSAppearance, directory: URL) async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        view.appearance = appearance
        let surface: NSView
        if let text = view as? NSTextView {
            let scroll = NSScrollView(frame: view.frame)
            scroll.drawsBackground = true; scroll.backgroundColor = text.backgroundColor
            scroll.documentView = text
            surface = scroll
        } else { surface = view }
        window.contentView = surface
        defer { window.contentView = nil; window.close() }
        surface.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        surface.layoutSubtreeIfNeeded()
        surface.displayIfNeeded()
        let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 840 && bitmap.pixelsHigh >= 940)
        var colors: Set<String> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 11) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 11) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        #expect(colors.count > 8, "Capture must contain native text, not a blank raster")
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
