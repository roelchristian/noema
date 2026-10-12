import SwiftUI
import AppKit
import Testing
import VaultCore
@testable import noema

// Opt-in service comparisons use the same fixture and host for both paths.
// Native event delivery, layout, scrolling and persistence require separate profiling.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"), arguments: [100, 1_000, 5_000])
@MainActor func benchmarkBlockDocumentScaling(_ count: Int) {
    let blocks = (0..<count).map { EditorBlock(runs: [RichRun("Paragraph \($0) with sufficient content for wrapping and editing.")]) }
    let document = BlockDocument(blocks: blocks)
    let theme = NoemaTheme(), clock = ContinuousClock()
    var rich = NSMutableAttributedString(string: "")
    let opening = clock.measure { rich = NSMutableAttributedString(attributedString: BlockTextStorage.render(document, theme: theme)) }
    var index: BlockTextStorage.RangeIndex!
    let indexing = clock.measure { index = BlockTextStorage.RangeIndex(rich) }
    let middle = count / 2, target = blocks[middle].id
    var edited = document
    edited.blocks[middle].runs = [RichRun(blocks[middle].text + " Typed😀")]
    var full = NSAttributedString(string: "")
    let fullRender = clock.measure { full = BlockTextStorage.render(edited, theme: theme) }
    let incremental = clock.measure {
        BlockTextStorage.apply(document: edited, previous: document, to: rich, index: index, theme: theme)
    }
    #expect(rich.isEqual(to: full))
    #expect(index.count == count)
    var resolved = 0
    let selection = clock.measure {
        for iteration in 0..<1_000 {
            let id = blocks[iteration % count].id
            if let range = index.range(for: id), index.block(at: range.location)?.0 == id { resolved += 1 }
        }
    }
    #expect(resolved == 1_000)
    var reordered = edited
    let reorder = clock.measure { reordered.apply(.reorderAfter(blocks.last!.id), to: target) }
    let reorderStorage = clock.measure {
        BlockTextStorage.apply(document: reordered, previous: edited, to: rich, index: index, theme: theme)
    }
    #expect(reordered.blocks.last?.id == target)
    #expect(Set(reordered.blocks.map(\.id)) == Set(blocks.map(\.id)))
    var captured = document
    let capture = clock.measure { captured = BlockTextStorage.capture(rich, previous: reordered) }
    #expect(captured.blocks == reordered.blocks)
    var serialized = ""
    let encode = clock.measure { serialized = BlockDocumentCodec.encode(captured) }
    var decoded = document
    let decode = clock.measure { decoded = BlockDocumentCodec.decode(serialized) }
    #expect(decoded.blocks == reordered.blocks)
    print("BLOCK_SCALING blocks=\(count) utf16=\(rich.length) bytes=\(serialized.utf8.count) open_render=\(opening) index_build=\(indexing) full_edit_render=\(fullRender) incremental_edit_apply=\(incremental) selection_1000=\(selection) reorder_model=\(reorder) reorder_apply=\(reorderStorage) capture=\(capture) encode=\(encode) decode=\(decode)")
}

