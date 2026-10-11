import Foundation
import Testing
import VaultCore
@testable import noema

private func presentationSource(
    id: UUID = UUID(), title: String = "Reference", capturedAt: String = "2026-10-11T08:30:00Z",
    filename: String = "reference.txt", fileSize: Int? = 512, linked: Bool = false,
    body: String = "Source content"
) throws -> SourceRecord {
    var metadata: [String: Any] = [
        "id": id.uuidString, "title": title, "capturedAt": capturedAt,
        "originalFilename": filename, "sha256": "fixture", "storedFilename": filename
    ]
    if let fileSize { metadata["fileSize"] = fileSize }
    if linked { metadata["linkedBookmark"] = Data([1, 2, 3]).base64EncodedString() }
    let data = try JSONSerialization.data(withJSONObject: ["metadata": metadata, "body": body])
    return try JSONDecoder().decode(SourceRecord.self, from: data)
}

@Test func sourceTableRowsRequireOnlyMetadataAndDoNotBuildContentExcerpts() throws {
    let body = String(repeating: "# Large source **content**\n", count: 10_000)
    var source = try presentationSource(filename: "reference.pdf", fileSize: 4_096, linked: true, body: body)
    // The row initializer accepts metadata, so rendering has no content-decoding dependency.
    let input = SourceTableInput(metadata: source.metadata)
    let row = SourceTableRow(input: input)
    let legacyRow = LibraryRow(source: source)
    #expect(row.id == source.id)
    #expect(row.title == source.title)
    #expect(row.originalFilename == "reference.pdf")
    #expect(row.sourceLocation == "Linked")
    #expect(!row.fileKind.isEmpty)
    #expect(row.fileSize == 4_096)
    #expect(row.updatedAt != nil)
    #expect(!row.formattedFileSize.isEmpty)
    #expect(!row.captureHelp.isEmpty)
    #expect(legacyRow.excerpt.isEmpty)
    source.body = "Completely different content"
    #expect(SourceTableInput(source: source) == input)
    #expect(LibraryRow(source: source) == legacyRow)
}

@Test func legacySourcesKeepByteCountFallbackWithoutParsingContent() throws {
    let source = try presentationSource(capturedAt: "not a date", fileSize: nil, body: "😀 **café**")
    let row = SourceTableRow(input: SourceTableInput(source: source))
    #expect(row.fileSize == source.body.utf8.count)
    #expect(LibraryRow(source: source).fileSize == row.fileSize)
    #expect(row.updatedAt == nil)
    #expect(row.captureSortDate == .distantPast)
    #expect(row.captureHelp.isEmpty)
    var changed = source
    changed.body += " extra bytes"
    #expect(SourceTableInput(source: changed).fileSize > row.fileSize)
}

@Test @MainActor func sourcePresentationReusesUnchangedRowsAndIgnoresContentAndStatusChanges() throws {
    var first = try presentationSource(title: "Zulu")
    let second = try presentationSource(title: "Alpha")
    var constructed: [UUID] = []
    let presentation = SourcesTablePresentation { input in
        constructed.append(input.id)
        return SourceTableRow(input: input)
    }
    #expect(presentation.synchronize([first, second]))
    #expect(presentation.rows.map(\.id) == [second.id, first.id])
    #expect(constructed.count == 2)
    let rows = presentation.rows
    #expect(!presentation.synchronize([first, second]))
    first.body = String(repeating: "Changed body", count: 10_000)
    first.availabilityIssue = "Original unavailable"
    first.metadata.aiSummary = "Updated AI summary"
    first.metadata.sha256 = "different-content-hash"
    #expect(!presentation.synchronize([first, second]))
    #expect(constructed.count == 2)
    #expect(presentation.rows == rows)

    first.metadata.title = "Aardvark"
    #expect(presentation.synchronize([first, second]))
    #expect(constructed == [first.id, second.id, first.id])
    #expect(presentation.rows.map(\.id) == [first.id, second.id])
    #expect(presentation.rows.first?.title == "Aardvark")
    #expect(presentation.rows.last == rows.first)
}

@Test @MainActor func sourcePresentationSortsOnlyWhenOrderOrMetadataChanges() throws {
    let first = try presentationSource(title: "Zulu", capturedAt: "2026-10-11T08:30:00.123Z", filename: "a.txt", fileSize: 128)
    var second = try presentationSource(title: "Alpha", capturedAt: "2026-10-10T08:30:00Z", filename: "z.txt", fileSize: 512)
    var constructionCount = 0
    let presentation = SourcesTablePresentation { input in
        constructionCount += 1
        return SourceTableRow(input: input)
    }
    presentation.synchronize([first, second])
    let bySize = [KeyPathComparator(\SourceTableRow.fileSize, order: .reverse)]
    #expect(presentation.setSortOrder(bySize))
    #expect(presentation.rows.map(\.id) == [second.id, first.id])
    #expect(!presentation.setSortOrder(bySize))
    #expect(constructionCount == 2)
    second.metadata.fileSize = 64
    #expect(presentation.synchronize([first, second]))
    #expect(presentation.rows.map(\.id) == [first.id, second.id])
    #expect(constructionCount == 3)
    presentation.setSortOrder([KeyPathComparator(\SourceTableRow.captureSortDate)])
    #expect(presentation.rows.map(\.id) == [second.id, first.id])
    presentation.setSortOrder([KeyPathComparator(\SourceTableRow.originalFilename)])
    #expect(presentation.rows.map(\.id) == [first.id, second.id])
    #expect(constructionCount == 3)
}

@Test @MainActor func sourcePresentationRefreshesAllDisplayMetadataAndDropsRemovedSources() throws {
    var source = try presentationSource()
    let removed = try presentationSource(title: "Removed")
    let presentation = SourcesTablePresentation()
    presentation.synchronize([source, removed])
    let identity = source.id
    source.metadata.originalFilename = "new.pdf"
    source.metadata.capturedAt = "2026-10-12T00:00:00Z"
    source.metadata.fileSize = 8_192
    source.metadata.linkedBookmark = Data([5, 6])
    #expect(presentation.synchronize([source]))
    #expect(presentation.rows.count == 1)
    let row = try #require(presentation.rows.first)
    #expect(row.id == identity)
    #expect(row.originalFilename == "new.pdf")
    #expect(row.sourceLocation == "Linked")
    #expect(row.fileSize == 8_192)
    #expect(row.updatedAt == LibraryRow.date(source.metadata.capturedAt))
    #expect(row.fileKind == SourceTableRow(input: SourceTableInput(source: source)).fileKind)
    #expect(!presentation.rows.contains(where: { $0.id == removed.id }))
}

@Test @MainActor func sourcePresentationClearsSensitiveMetadataAndRestoresFreshRows() throws {
    let first = try presentationSource(title: "Private source")
    let second = try presentationSource(title: "Replacement vault source")
    var constructionCount = 0
    let presentation = SourcesTablePresentation { input in
        constructionCount += 1
        return SourceTableRow(input: input)
    }
    let sortOrder = [KeyPathComparator(\SourceTableRow.fileSize)]
    presentation.setSortOrder(sortOrder)
    presentation.synchronize([first])
    let columnCustomization = presentation.columnCustomization
    presentation.clear()
    #expect(presentation.rows.isEmpty)
    #expect(presentation.sortOrder == sortOrder)
    #expect(presentation.columnCustomization == columnCustomization)
    #expect(!presentation.synchronize(inputs: []))
    #expect(presentation.synchronize([first]))
    #expect(constructionCount == 2) // Clear also discarded the metadata used to retain old rows.
    presentation.clear()
    presentation.synchronize([second])
    #expect(presentation.rows.map(\.id) == [second.id])
    #expect(!presentation.rows.contains(where: { $0.id == first.id }))
}
