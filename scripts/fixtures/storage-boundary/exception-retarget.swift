func externalRead(_ selectedURL: URL, root: URL) throws -> Data {
    let url = root.appendingPathComponent("Wiki/note.md")
    return try Data(contentsOf: url)
}
