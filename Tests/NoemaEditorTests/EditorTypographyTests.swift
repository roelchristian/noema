import AppKit
import Testing
import VaultCore
@testable import noema

@Test @MainActor func editorTypographyDefaultsPersistenceAndFallback() throws {
    let suite = "NoemaTypographyTests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(EditorTypography.load(defaults: defaults).size == 16)
    #expect(EditorTypography.load(defaults: defaults).family.isEmpty)
    defaults.set(15.0, forKey: EditorPreferences.fontSizeKey)
    #expect(EditorTypography.load(defaults: defaults).size == 15)
    defaults.set("Helvetica", forKey: EditorPreferences.fontFamilyKey)
    defaults.set(19.0, forKey: EditorPreferences.fontSizeKey)
    let saved = EditorTypography.load(defaults: try #require(UserDefaults(suiteName: suite)))
    #expect(saved.size == 19)
    #expect(saved.font().familyName == "Helvetica")
    #expect(EditorTypography(size: .nan).size == 16)
    #expect(EditorTypography(size: 100).size == 32)
    #expect(EditorTypography(size: 0).size == 10)
    #expect(EditorTypography(family: "Unavailable Noema Test Font").font() == NSFont.systemFont(ofSize: 16))
}

@Test @MainActor func editorTypographyScalesAllDocumentRoles() {
    for size in [10.0, 16, 32] {
        let typography = EditorTypography(size: size)
        for (role, scale) in [(EditorTypography.Role.heading1, 1.93), (.heading2, 1.53), (.heading3, 1.27), (.body, 1), (.quote, 1), (.list, 1), (.code, 0.88), (.mathSource, 0.88), (.supporting, 0.88), (.math, 1)] {
            #expect(abs(typography.font(for: role).pointSize - size * scale) < 0.001)
        }
        #expect(typography.font(for: .heading1).pointSize > typography.font(for: .heading2).pointSize)
        #expect(typography.font(for: .heading2).pointSize > typography.font(for: .heading3).pointSize)
        #expect(typography.font(for: .heading3).pointSize > typography.font(for: .body).pointSize)
    }
}

@Test @MainActor func editorTypographyCustomFamilyUsesDistinctNativeWeights() throws {
    // Avenir Next ships on macOS and offers actual Medium and Demi Bold faces.
    let typography = EditorTypography(family: "Avenir Next")
    let regular = typography.font(weight: .regular)
    let medium = typography.font(weight: .medium)
    let semibold = typography.font(weight: .semibold)
    let bold = typography.font(weight: .bold)
    #expect(regular.familyName == "Avenir Next")
    #expect(medium.familyName == regular.familyName)
    #expect(semibold.familyName == regular.familyName)
    #expect(Set([regular.fontName, medium.fontName, semibold.fontName, bold.fontName]).count == 4)
    #expect(typography.font(for: .heading1).fontName == semibold.fontName)
}

@Test @MainActor func editorTypographyScalesHeadingsAndPreservesRichContent() throws {
    var bold = InlineStyle(); bold.bold = true
    var italic = InlineStyle(); italic.italic = true
    var code = InlineStyle(); code.code = true
    var math = InlineStyle(); math.math = true; math.rawMath = "x^2"
    var link = InlineStyle(); link.link = "https://example.com/Some%20Page"
    var wiki = InlineStyle(); wiki.wikiTarget = "Linked article"
    let document = BlockDocument(blocks: [
        EditorBlock(runs: [RichRun("Body"), RichRun("Bold", style: bold), RichRun("Italic", style: italic), RichRun("code", style: code), RichRun("x²", style: math), RichRun("Link", style: link), RichRun("Wiki", style: wiki)]),
        EditorBlock(kind: .heading1, runs: [RichRun("Heading")]),
        EditorBlock(kind: .code, runs: [RichRun("Code")]),
        EditorBlock(kind: .math, runs: [RichRun("Equation")])
    ])
    let theme = NoemaTheme(dark: false)
    let baseline = BlockTextStorage.render(document, theme: theme)
    let typography = EditorTypography(family: "Helvetica", size: 19)
    let changed = BlockTextStorage.render(document, theme: theme, typography: typography)
    let ranges = BlockTextStorage.ranges(baseline)
    for (index, role) in [EditorTypography.Role.body, .heading1, .code, .mathSource].enumerated() {
        let location = ranges[index].1.location
        let before = try #require(baseline.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        let after = try #require(changed.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
        #expect(abs(before.pointSize - EditorTypography().pointSize(for: role)) < 0.001)
        #expect(abs(after.pointSize - typography.pointSize(for: role)) < 0.001)
        if role == .code || role == .mathSource { #expect(NSFontManager.shared.traits(of: after).contains(.fixedPitchFontMask)) }
        if role == .body || role == .heading1 { #expect(after.familyName == "Helvetica") }
    }
    let boldFont = try #require(changed.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
    let italicFont = try #require(changed.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)
    let codeFont = try #require(changed.attribute(.font, at: 14, effectiveRange: nil) as? NSFont)
    let mathFont = try #require(changed.attribute(.font, at: 18, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
    #expect(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
    #expect(abs(codeFont.pointSize - 19 * 0.88) < 0.001)
    #expect(mathFont.fontName == typography.font(for: .math).fontName)
    #expect(baseline.string == changed.string)
    #expect(BlockTextStorage.capture(changed, previous: document) == document)
    #expect(BlockDocumentCodec.encode(BlockTextStorage.capture(changed, previous: document)) == BlockDocumentCodec.encode(document))
}
