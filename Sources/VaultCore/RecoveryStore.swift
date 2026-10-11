import Foundation

public actor RecoveryStore {
    public nonisolated let sessionLease: VaultSessionLease?
    public nonisolated let accessGate: VaultAccessGate?
    private let directory: URL
    public init(
        directory: URL,
        sessionLease: VaultSessionLease? = nil,
        accessGate: VaultAccessGate? = nil
    ) throws {
        if let accessGate, let sessionLease {
            try accessGate.validate(
                lease: sessionLease,
                targetRoot: sessionLease.root,
                targetVaultID: sessionLease.vaultID,
                operation: "recoveryStore.open"
            )
        }
        self.directory = directory
        self.sessionLease = sessionLease
        self.accessGate = accessGate
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func validateAccess(_ operation: String) throws {
        guard let accessGate else { return }
        guard let sessionLease else {
            throw VaultAccessError.missingLease(operation: operation)
        }
        try accessGate.validate(
            lease: sessionLease,
            targetRoot: sessionLease.root,
            targetVaultID: sessionLease.vaultID,
            operation: operation
        )
    }
    public func store(_ draft: DraftRecord) throws {
        try validateAccess("recoveryStore.store")
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent(draft.id.uuidString + ".json"), options: .atomic)
    }
    public func remove(_ id: UUID) throws {
        try validateAccess("recoveryStore.remove")
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func drafts() throws -> [DraftRecord] {
        try validateAccess("recoveryStore.drafts")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(DraftRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}
