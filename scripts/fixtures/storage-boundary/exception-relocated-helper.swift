func newlyIntroducedCanonicalHelper(_ root: URL) throws -> Data {
    let url = root.appendingPathComponent("vault.json")
    return try Data(contentsOf: url)
}
