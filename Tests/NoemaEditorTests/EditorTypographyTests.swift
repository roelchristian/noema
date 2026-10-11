import AppKit
import Testing
import VaultCore
@testable import noema

@Test @MainActor func editorTypographyDefaultsPersistenceAndFallback() throws {
    let suite = "NoemaTypographyTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(EditorTypography.load(defaults: defaults).size == 15)
    #expect(EditorTypography.load(defaults: defaults).family.isEmpty)
    defaults.set("Helvetica", forKey: EditorPreferences.fontFamilyKey)
    defaults.set(19.0, forKey: EditorPreferences.fontSizeKey)
    let saved = EditorTypography.load(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(saved.size == 19)
    #expect(saved.font().familyName == "Helvetica")
    #expect(EditorTypography(size: .nan).size == 15)
    #expect(EditorTypography(size: 100).size == 32)
    #expect(EditorTypography(size: 0).size == 10)
    #expect(EditorTypography(family: "Unavailable Noema Test Font").font() == NSFont.systemFont(ofSize: 15))
}

@Test @MainActor func editorTypographyScalesHeadingsAndPreservesRichContent() throws {
    var bold = InlineStyle(); bold.bold = true
    var italic = InlineStyle(); italic.italic = true
    let document = BlockDocument(blocks: [
        EditorBlock(runs: [RichRun("Body"), RichRun("Bold", style: bold), RichRun("Italic", style: italic)]),
        EditorBlock(kind: .heading1, runs: [RichRun("Heading")]),
        EditorBlock(kind: .code, runs: [RichRun("Code")])
    ])
    let theme = NoemaTheme(dark: false)
    let baseline = BlockTextStorage.render(document, theme: theme)
    let changed = BlockTextStorage.render(document, theme: theme, typography: EditorTypography(family: "Helvetica", size: 19))
    let ranges = BlockTextStorage.ranges(baseline)
    for (index, expected) in [CGFloat(15), 29, 13].enumerated() {
        let location = ranges[index].1.location
        let before = try #require(baseline.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        let after = try #require(changed.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(before.pointSize == expected)
        #expect(after.pointSize == expected + 4)
        #expect(index == 2 ? NSFontManager.shared.traits(of: after).contains(.fixedPitchFontMask) : after.familyName == "Helvetica")
    }
    let boldFont = try #require(changed.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
    let italicFont = try #require(changed.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
    #expect(baseline.string == changed.string)
    #expect(BlockTextStorage.capture(changed, previous: document) == document)
}
