import AppKit
import Testing
import VaultCore
@testable import noema

@Test @MainActor func semanticLabelsUseExplicitNativeMetricsAndPreserveBoundaryRhythm() throws {
    var metadata = BlockMetadata(); metadata.semantic = "idea"
    let nested = EditorBlock(kind: .bullet, runs: [RichRun("Nested\ncontinuation")], metadata: metadata)
    let document = BlockDocument(blocks: [
        EditorBlock(kind: .heading2, runs: [RichRun("Heading")], metadata: metadata),
        EditorBlock(kind: .bullet, runs: [RichRun("List\ncontinuation")], metadata: metadata, children: [nested]),
        EditorBlock(kind: .quote, runs: [RichRun("Quoted")], metadata: metadata),
        EditorBlock(metadata: metadata)
    ])
    for family in ["", "Times New Roman", "Unavailable Semantic Font"] {
        for size in [10.0, 16, 32] {
            let typography = EditorTypography(family: family, size: size)
            let label = typography.font(for: .semanticLabel)
            #expect(label == NSFont.systemFont(ofSize: size * 0.88, weight: .semibold))
            #expect(typography.semanticHeadingSpace == ceil(label.ascender - label.descender) + typography.semanticLabelGap)
            let storage = NSMutableAttributedString(attributedString: BlockTextStorage.render(document, theme: NoemaTheme(), showSemanticHeadings: true, typography: typography))
            let rendered = NSAttributedString(attributedString: storage)
            // Repeated native edits, including a narrowed affected range, must not accumulate label space.
            for _ in 0..<3 {
                BlockTextStorage.updateParagraphRhythm(storage, typography: typography)
                BlockTextStorage.updateSemanticHeadingSpacing(storage, typography: typography)
                BlockTextStorage.updateSemanticHeadingSpacing(storage, in: NSRange(location: 0, length: 1), typography: typography)
                #expect(storage == rendered)
            }
            var previous: EditorTypography.Role?
            for (id, range) in BlockTextStorage.ranges(storage) {
                let block = try #require(document.block(id))
                let role = EditorTypography.role(for: block.kind)
                let first = try #require(storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
                #expect(first.paragraphSpacingBefore == typography.boundarySpacing(before: role, after: previous) + typography.semanticHeadingSpace)
                #expect(first.paragraphSpacing == 0)
                let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
                if NSMaxRange(paragraph) < NSMaxRange(range) {
                    let continuation = try #require(storage.attribute(.paragraphStyle, at: NSMaxRange(paragraph), effectiveRange: nil) as? NSParagraphStyle)
                    #expect(continuation.paragraphSpacingBefore == 0)
                }
                previous = role
            }
            #expect(BlockTextStorage.capture(storage, previous: document) == document)
            BlockTextStorage.updateParagraphRhythm(storage, typography: typography)
            let withoutLabels = BlockTextStorage.render(document, theme: NoemaTheme(), typography: typography)
            #expect(storage.string == withoutLabels.string)
            // Fresh renders may encode metadata JSON keys in a different order.
            // Compare the resolved typography and captured semantic content.
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                #expect(attributes[.font] as? NSFont == withoutLabels.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
                #expect(attributes[.paragraphStyle] as? NSParagraphStyle == withoutLabels.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            }
            #expect(BlockTextStorage.capture(storage, previous: document) == document)
        }
    }
}

@Test @MainActor func semanticAndListGeometryTracksNativeBaselineAtEveryReadingSize() throws {
    _ = NSApplication.shared
    var metadata = BlockMetadata(); metadata.semantic = "question"
    let child = EditorBlock(kind: .task, runs: [RichRun("Nested task")], metadata: metadata)
    let document = BlockDocument(blocks: [EditorBlock(runs: [RichRun("Parent")], children: [child])])
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 1000))
    view.textContainerInset.height = 24
    view.updateReadingGeometry()
    for size in [10.0, 16, 32] {
        view.typography = EditorTypography(family: "Times New Roman", size: size)
        for labels in [true, false, true] {
            view.showSemanticHeadings = labels
            view.textStorage!.setAttributedString(BlockTextStorage.render(document, theme: NoemaTheme(), showSemanticHeadings: labels, typography: view.typography))
            view.updateSemanticHeadingTopInset()
            view.layoutManager!.ensureLayout(for: view.textContainer!)
            let range = try #require(BlockTextStorage.ranges(view.textStorage!).last?.1)
            let heading = view.semanticHeadingRect(for: range)
            #expect((heading != nil) == labels)
            let glyph = view.layoutManager!.glyphIndexForCharacter(at: range.location)
            let nativeBaseline = view.textContainerOrigin.y + view.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.layoutManager!.location(forGlyphAt: glyph).y
            #expect(abs(view.firstBaseline(for: range) - nativeBaseline) < 0.001)
            let marker = view.markerRect(for: range, depth: 1)
            #expect(marker.maxX < view.rect(for: range).minX)
            #expect(abs(marker.minY + marker.height * 0.8 - nativeBaseline) < 0.001)
            let icon = try #require(view.semanticSymbolRect(for: range, depth: 1, heading: heading))
            #expect(icon.maxX < marker.minX)
            let expected = heading.map { $0.minY + view.typography.font(for: .semanticLabel).ascender } ?? nativeBaseline
            #expect(abs(icon.minY + icon.height * 0.8 - expected) < 0.001)
            #expect(BlockTextStorage.capture(view.textStorage!, previous: document) == document)
        }
    }
    view.setFrameSize(NSSize(width: 128, height: 1000))
    let range = try #require(BlockTextStorage.ranges(view.textStorage!).last?.1)
    #expect(view.semanticSymbolRect(for: range, depth: 1, heading: nil) == nil)
}

@Test @MainActor func mathPreviewUsesOnlyAvailableSpaceBesideUnwrappedSource() throws {
    let view = ArticleTextView(frame: NSRect(x: 0, y: 0, width: 840, height: 1000))
    view.updateReadingGeometry()
    view.textStorage!.setAttributedString(BlockTextStorage.render(BlockDocument(blocks: [EditorBlock(kind: .math, runs: [RichRun("x^2")])]), theme: NoemaTheme()))
    view.layoutManager!.ensureLayout(for: view.textContainer!)
    let range = try #require(BlockTextStorage.ranges(view.textStorage!).first?.1)
    let preview = try #require(view.mathPreviewRect(for: range))
    #expect(preview.minX > view.rect(for: range).maxX)
    #expect(preview.maxX <= view.bounds.width - view.textContainerOrigin.x)
    view.setFrameSize(NSSize(width: 180, height: 1000))
    view.layoutManager!.ensureLayout(for: view.textContainer!)
    #expect(view.mathPreviewRect(for: range) == nil)
    view.setFrameSize(NSSize(width: 840, height: 1000))
    view.textStorage!.setAttributedString(BlockTextStorage.render(BlockDocument(blocks: [EditorBlock(kind: .math, runs: [RichRun(String(repeating: "long TeX expression ", count: 20))])]), theme: NoemaTheme()))
    view.layoutManager!.ensureLayout(for: view.textContainer!)
    let wrapped = try #require(BlockTextStorage.ranges(view.textStorage!).first?.1)
    #expect(view.mathPreviewRect(for: wrapped) == nil)
}
