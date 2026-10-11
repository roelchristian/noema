func externalRead(_ url: URL) throws -> Data {
    return try Data(contentsOf: url)
}
