import Foundation
import Testing
@testable import VaultCore

@Test func semanticGroupsIncludeNestedAndUnknownTagsInDocumentOrder() {
    var idea = BlockMetadata(); idea.semantic = "idea"; idea.collapsed = true
    var future = BlockMetadata(); future.semantic = "future-tag"
    let child = EditorBlock(runs: [RichRun("Nested\nidea")], metadata: idea)
    let parent = EditorBlock(runs: [RichRun("First idea")], metadata: idea, children: [child])
    let unknown = EditorBlock(metadata: future)
    var document = BlockDocument(blocks: [parent, EditorBlock(), unknown])
    #expect(document.semanticGroups.map(\.tag) == ["future-tag", "idea"])
    #expect(document.semanticGroups[1].blocks.map(\.id) == [parent.id, child.id])
    #expect(document.semanticGroups[0].blocks.first?.text == "")
    _ = document.apply(.semantic(nil), to: child.id)
    #expect(document.semanticGroups[1].blocks.map(\.id) == [parent.id])
    #expect(BlockDocument().semanticGroups.isEmpty)
    var manualSummary = BlockMetadata(); manualSummary.semantic = "summary"
    let manual = EditorBlock(runs: [RichRun("Manual summary")], metadata: manualSummary)
    document.blocks.append(manual)
    document.setAISummary("Generated summary")
    #expect(document.semanticGroups.first(where: { $0.tag == "summary" })?.blocks.map(\.id) == [manual.id])
    #expect(!document.semanticGroups.flatMap(\.blocks).contains { $0.isAISummary })
}

@Test func blockModelRoundTripsRichTextAndNestedMetadata() throws {
    var style = InlineStyle(); style.bold = true; style.italic = true; style.underline = true; style.strike = true; style.highlight = true; style.link = "https://example.com"
    var metadata = BlockMetadata(); metadata.semantic = "question"; metadata.status = "answered"; metadata.extra["future"] = "kept"
    let child = EditorBlock(kind: .task, runs: [RichRun("child")], metadata: metadata)
    let parent = EditorBlock(kind: .heading2, runs: [RichRun("😀研究", style: style)], metadata: metadata, children: [child])
    let document = BlockDocument(blocks: [parent])
    let source = BlockDocumentCodec.encode(document)
    #expect(source.hasPrefix("## "))
    #expect(BlockDocumentCodec.decode(source) == document)
    #expect(BlockDocumentCodec.valid(document))
    let future = EditorBlock(kind: .init(rawValue: "future-kind"), runs: [RichRun("recoverable")])
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(BlockDocument(blocks: [future]))).blocks.first == future)
}

@Test func blockMarkdownCompatibilityAndExternalChanges() {
    for source in ["", "\n", "# Title\n\nHello **bold** and *italic*. [[Rome|the city]]\n", "- First\n    - Second\n        - Third\n", "```swift\nlet x = 1\n\nprint(x)\n```\n", "| A | B |\n|---|---|\n| 1 | 2 |\n", "<details>unsupported HTML</details>\n", "![original image](photo.png)", "trailing  \n", "~~~\nunclosed"] {
        let document = BlockDocumentCodec.decode(source)
        #expect(BlockDocumentCodec.encode(document) == source)
    }
    var document = BlockDocumentCodec.decode("- Parent\n    - Child\n"); let id = document.blocks[0].id
    _ = document.apply(.semantic("question"), to: id)
    let saved = BlockDocumentCodec.encode(document)
    let changed = saved.replacingOccurrences(of: "Parent", with: "External edit")
    let reload = BlockDocumentCodec.decode(changed)
    #expect(reload.blocks[0].text == "External edit")
    #expect(reload.recoveredMetadata != nil)
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(reload)).recoveredMetadata != nil)
}

@Test func blockCommandsPreserveRunsAndTreeIdentity() {
    var style = InlineStyle(); style.bold = true
    let a = EditorBlock(runs: [RichRun("ab😀cd", style: style)], children: [EditorBlock(runs: [RichRun("nested")])])
    let b = EditorBlock(kind: .bullet, runs: [RichRun("second")])
    var document = BlockDocument(blocks: [a, b])
    _ = document.apply(.semantic("starred"), to: a.id)
    _ = document.apply(.transform(.heading2), to: a.id)
    #expect(document.blocks[0].id == a.id)
    #expect(document.blocks[0].runs == a.runs)
    #expect(document.blocks[0].children == a.children)
    #expect(document.blocks[0].metadata.semantic == "starred")
    let next = document.apply(.split(4), to: a.id)!
    #expect(document.blocks[0].text == "ab😀")
    #expect(document.block(next.id)?.text == "cd")
    #expect(document.block(next.id)?.runs.first?.style.bold == true)
    #expect(document.blocks[0].children == a.children)
    _ = document.apply(.mergeBackward, to: next.id)
    #expect(document.blocks[0].text == a.text)
    #expect(document.blocks[0].children == a.children)
    let duplicate = document.apply(.duplicate, to: a.id)!
    #expect(document.block(duplicate.id)?.children.first?.id != a.children.first?.id)
    #expect(BlockDocumentCodec.valid(document))
    _ = document.apply(.delete, to: duplicate.id)
    _ = document.apply(.indent, to: b.id)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].children.last?.id == b.id)
    _ = document.apply(.outdent, to: b.id)
    #expect(document.blocks.last?.id == b.id)
    _ = document.apply(.reorder(before: a.id), to: b.id)
    #expect(document.blocks.first?.id == b.id)
    #expect(document.apply(.reorder(before: a.children[0].id), to: b.id) == nil)
}

@Test func emptyListExitAndStructuralBackspace() {
    let item = EditorBlock(kind: .task)
    var document = BlockDocument(blocks: [item])
    _ = document.apply(.split(0), to: item.id)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].kind == .paragraph)
    _ = document.apply(.transform(.quote), to: item.id)
    _ = document.apply(.mergeBackward, to: item.id)
    #expect(document.blocks[0].kind == .paragraph)
    _ = document.apply(.delete, to: item.id)
    #expect(document.blocks.count == 1)
    #expect(document.blocks[0].id != item.id)
}

@Test func blockFutureFormatAndMalformedDataRemainRecoverable() throws {
    let newer: [String: Any] = ["version": 2, "document": ["differentSchema": true]]
    let source = "Visible text\n<!--noema:document:" + (try JSONSerialization.data(withJSONObject: newer)).base64EncodedString() + "-->"
    var decoded = BlockDocumentCodec.decode(source)
    #expect(decoded.unsupportedVersion)
    #expect(BlockDocumentCodec.encode(decoded) == source)
    #expect(decoded.apply(.delete, to: decoded.blocks[0].id) == nil)
    let malformed = "Visible\n<!--noema:document:broken-->"
    #expect(BlockDocumentCodec.encode(BlockDocumentCodec.decode(malformed)) == malformed)

    // Pre-math envelopes without "math" in InlineStyle decode cleanly without exposing <!--noema:document:...-->.
    var styledBlock = EditorBlock(runs: [RichRun("Legacy bold", style: { var s = InlineStyle(); s.bold = true; return s }())])
    styledBlock.metadata.semantic = "claim"
    let encodedLegacy = BlockDocumentCodec.encode(BlockDocument(blocks: [styledBlock]))
    let prefix = "<!--noema:document:"
    let envRange = encodedLegacy.range(of: prefix)!
    let rawB64 = String(encodedLegacy[envRange.upperBound...].dropLast(3))
    let legacyJSON = String(data: Data(base64Encoded: rawB64)!, encoding: .utf8)!
        .replacingOccurrences(of: #""math":false,"#, with: "")
    let legacySource = String(encodedLegacy[..<envRange.upperBound]) + Data(legacyJSON.utf8).base64EncodedString() + "-->"
    let decodedLegacy = BlockDocumentCodec.decode(legacySource)
    #expect(decodedLegacy.blocks.count == 1)
    #expect(decodedLegacy.blocks[0].id == styledBlock.id)
    #expect(decodedLegacy.blocks[0].runs.first?.style.bold == true)
    #expect(decodedLegacy.blocks[0].metadata.semantic == "claim")

    // If a version-1 envelope was previously ingested as a trailing paragraph block and re-saved, decode strips it.
    let corruptedBlock = EditorBlock(runs: [RichRun(prefix + rawB64 + "-->")])
    let stackedSource = BlockDocumentCodec.encode(BlockDocument(blocks: [styledBlock, corruptedBlock]))
    let healed = BlockDocumentCodec.decode(stackedSource)
    #expect(healed.blocks.map(\.id) == [styledBlock.id])
    #expect(!BlockDocumentCodec.markdownBody(stackedSource).contains(prefix))

    let first = EditorBlock(runs: [RichRun("First")]), second = EditorBlock(runs: [RichRun("Second")])
    var document = BlockDocument(blocks: [first, second])
    _ = document.apply(.reorderAfter(second.id), to: first.id)
    #expect(document.blocks.last?.id == first.id)
    #expect(document.canReorder(first.id, before: second.id))
}

@Test func markdownIndentationAndRepeatedLegacyIDsStaySafe() {
    for source in ["- Parent\n  - Child\n    - Grandchild\n- Sibling\n", "- Parent\n\t- Child\n\t\t- Grandchild\n- Sibling\n"] {
        var document = BlockDocumentCodec.decode(source)
        #expect(document.blocks.count == 2)
        #expect(document.blocks[0].children[0].children[0].text == "Grandchild")
        #expect(BlockDocumentCodec.encode(document) == source)
        _ = document.apply(.semantic("question"), to: document.blocks[1].id)
        #expect(BlockDocumentCodec.readable(document) == source)
        #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(document)) == document)
    }
    let id = UUID().uuidString
    let repeated = "First <!--noema:block:\(id):question-->\nSecond <!--noema:block:\(id):idea-->"
    let document = BlockDocumentCodec.decode(repeated)
    #expect(BlockDocumentCodec.valid(document))
    #expect(document.blocks[0].metadata.semantic == "question")
    #expect(document.blocks[1].metadata.semantic == "idea")
}


@Test func aiSummaryStaysAboveEditableContentAndRoundTrips() {
    let original = EditorBlock(runs: [RichRun("User content")], children: [EditorBlock(runs: [RichRun("Nested content")])])
    var document = BlockDocument(blocks: [original])
    document.setAISummary("Generated overview")
    let id = document.aiSummary?.id
    #expect(document.blocks.first?.isAISummary == true)
    #expect(document.withoutAISummary.blocks == [original])
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(document)) == document)
    document.setAISummary("Updated overview")
    #expect(document.aiSummary?.id == id)
    #expect(document.blocks.count == 2)
    #expect(document.blocks.last == original)
    document.unsupportedVersion = true
    document.setAISummary("Must not write")
    #expect(document.aiSummary?.text == "Updated overview")
}


@Test func deletingAISummaryPreservesUserBlocksAndFutureFormats() {
    let user = EditorBlock(runs: [RichRun("User writing")], children: [EditorBlock(runs: [RichRun("Nested writing")])])
    var document = BlockDocument(blocks: [user])
    document.setAISummary("AI overview")
    document.unsupportedVersion = true
    let rejected = document.removeAISummary()
    #expect(!rejected)
    #expect(document.aiSummary != nil)
    document.unsupportedVersion = false
    let removed = document.removeAISummary()
    #expect(removed)
    #expect(document.blocks == [user])
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(document)).blocks == [user])
    let absent = document.removeAISummary()
    #expect(!absent)
    var summaryOnly = BlockDocument(blocks: [])
    summaryOnly.setAISummary("Summary only")
    let removedOnly = summaryOnly.removeAISummary()
    #expect(removedOnly)
    #expect(summaryOnly.blocks.count == 1)
    #expect(summaryOnly.blocks[0].text.isEmpty)
}

@Test func inlineAndDisplayMathAndCustomNewcommandMacros() throws {
    let suite = UserDefaults(suiteName: "noema.math.tests.\(UUID().uuidString)")!
    #expect(TeXMacro(name: "\\R", argCount: 0, body: "\\mathbb{R}")?.newcommandString == #"\newcommand{\R}{\mathbb{R}}"#)
    #expect(TeXMacro(name: "norm", argCount: 1, body: "\\|#1\\|")?.newcommandString == #"\newcommand{\norm}[1]{\|#1\|}"#)
    #expect(TeXMacro(name: "inner", argCount: 2, body: "\\langle #1, #2 \\rangle")?.newcommandString == #"\newcommand{\inner}[2]{\langle #1, #2 \rangle}"#)
    #expect(TeXMacro(name: "tri", argCount: 3, body: "#1 + #2 + #3")?.newcommandString == #"\newcommand{\tri}[3]{#1 + #2 + #3}"#)
    #expect(TeXMacro(name: "tooMany", argCount: 4, body: "#1") == nil)
    #expect(TeXMacro(name: "badRef", argCount: 1, body: "#1 + #2") == nil)
    #expect(TeXMacro.parseNewcommand(#"\newcommand{\tooMany}[4]{#1}"#) == nil)

    let added = TeXMacroStore.addFromNewcommand("""
    \\newcommand{\\R}{\\mathbb{R}}
    \\newcommand{\\inv}[1]{\\frac{1}{#1}}
    \\newcommand{\\pair}[2]{\\langle #1, #2 \\rangle}
    \\newcommand{\\lincomb}[3]{#1 x + #2 y + #3 z}
    """, in: suite)
    #expect(added?.count == 4)

    var macros = TeXMacroStore.load(from: suite)
    #expect(TeXMath.render(#"x \in \R"#, macros: macros) == "x ∈ ℝ")
    #expect(TeXMath.render(#"\inv{\alpha}"#, macros: macros) == "1/α")
    #expect(TeXMath.render(#"\pair{u}{v}"#, macros: macros) == "⟨ u, v ⟩")
    #expect(TeXMath.render(#"\lincomb{\alpha}{\beta}{\gamma}"#, macros: macros) == "α x + β y + γ z")
    #expect(TeXMath.render(#"\newcommand{\cube}[1]{#1^3}\cube{x} = y_1"#, macros: macros) == "x³ = y₁")

    // Verify editing in-place, renaming via builder/newcommand, and deleting custom macros.
    let editedInv = TeXMacro(name: "\\recip", argCount: 1, body: "\\frac{1}{#1}")!
    macros = TeXMacroStore.update(originalName: "inv", with: editedInv, in: suite)
    #expect(macros.map(\.name) == ["R", "recip", "pair", "lincomb"])
    #expect(TeXMath.render(#"\recip{\beta}"#, macros: macros) == "1/β")

    let updatedPair = TeXMacroStore.updateFromNewcommand(originalName: "\\pair", #"\newcommand{\ip}[2]{\langle #1 | #2 \rangle}"#, in: suite)
    #expect(updatedPair?.map(\.name) == ["R", "recip", "ip", "lincomb"])
    #expect(TeXMath.render(#"\ip{a}{b}"#, macros: updatedPair ?? []) == "⟨ a | b ⟩")

    macros = TeXMacroStore.remove(name: "\\lincomb", in: suite)
    #expect(macros.map(\.name) == ["R", "recip", "ip"])

    let markdown = """
    Inline $E = mc^2$ and $\\frac{\\alpha}{\\beta}$ with #tag.

    $$
    \\int_0^\\infty e^{-x^2} dx
    $$
    """
    let analysis = MarkdownService.analyze(markdown)
    #expect(analysis.tags == ["tag"])
    let preview = MarkdownService.preview(markdown)
    #expect(preview.count == 2)
    #expect(preview[0].spans.contains(where: { $0.math && $0.text == "E = mc²" && $0.rawMath == "E = mc^2" }))
    #expect(preview[0].spans.contains(where: { $0.math && $0.text == "α/β" && $0.rawMath == #"\frac{\alpha}{\beta}"# }))
    #expect(preview[1].style == .math)
    #expect(preview[1].spans.first?.text == "∫₀^∞ e^(-x²) dx")

    var doc = BlockDocumentCodec.decode(markdown)
    #expect(doc.blocks.count == 3)
    #expect(doc.blocks[0].runs.contains(where: { $0.style.math && $0.style.rawMath == "E = mc^2" }))
    #expect(doc.blocks[2].kind == .math)
    #expect(doc.blocks[2].text == #"\int_0^\infty e^{-x^2} dx"#)
    #expect(BlockDocumentCodec.encode(doc) == markdown)
    _ = doc.apply(.semantic("important"), to: doc.blocks[2].id)
    #expect(BlockDocumentCodec.readable(doc).contains("$$\n\\int_0^\\infty e^{-x^2} dx\n$$"))
    #expect(BlockDocumentCodec.decode(BlockDocumentCodec.encode(doc)) == doc)
}


@Test func linksAndTagsExcludeCode() {
    let text = "# Heading\n\n[[Pertinax|my reading]] #history #rome/empire\n\n`[[Ignore]] #ignored`\n\n```swift\n[[Also ignore]] #code\n```\n"
    let analysis = MarkdownService.analyze(text)
    #expect(analysis.links == [WikiLink(target: "Pertinax", label: "my reading")])
    #expect(analysis.tags == ["history", "rome/empire"])
    let blocks = MarkdownService.preview(text)
    #expect(blocks.contains { $0.style == .heading(1) })
    #expect(blocks.flatMap(\.spans).contains { $0.wikiTarget == "Pertinax" })
    #expect(blocks.contains { $0.style == .code })
}

@Test func blockNoOpCommandsPreserveOriginalMarkdownAndIdentity() {
    let source = "First  \nSecond\n    - Child\n"
    let original = BlockDocumentCodec.decode(source)
    let first = original.blocks[0].id, second = original.blocks[1].id
    let child = original.blocks[1].children[0].id
    let commands: [(BlockMutation, UUID)] = [
        (.transform(.paragraph), first), (.semantic(nil), first), (.status(nil), first),
        (.language(nil), first), (.mergeBackward, first), (.move(0), first),
        (.move(-1), first), (.move(1), second), (.indent, first), (.outdent, first),
        (.reorder(before: second), first), (.reorderAfter(first), second),
        (.reorder(before: first), first), (.reorder(before: child), first),
        (.reorder(before: UUID()), first), (.delete, UUID())
    ]
    for (command, id) in commands {
        var document = original
        #expect(document.apply(command, to: id) == nil)
        #expect(document == original)
        #expect(document.originalSource == source)
        #expect(BlockDocumentCodec.encode(document) == source)
    }
}
