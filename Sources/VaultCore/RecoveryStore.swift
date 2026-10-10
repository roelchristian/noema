import Foundation

public actor RecoveryStore {
    private let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func store(_ draft: DraftRecord) throws {
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent(draft.id.uuidString + ".json"), options: .atomic)
    }
    public func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func drafts() throws -> [DraftRecord] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(DraftRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}
