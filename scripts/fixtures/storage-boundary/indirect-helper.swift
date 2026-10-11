func loadCanonicalBytes(_ url: URL) throws -> Data {
    try Data(contentsOf: url)
}
let bytes = try loadCanonicalBytes(vaultRoot.appendingPathComponent("Wiki/note.md"))
