import Foundation

public actor RecoveryStore {
    public nonisolated let sessionLease: VaultSessionLease?
    public nonisolated let accessGate: VaultAccessGate?
    private let directory: URL
    private let unguardedForTesting: Bool

    /// Production construction always requires a gate and an explicit lease. A missing lease
    /// is rejected before creating the directory or accessing any recovery content.
    public init(
        directory: URL,
        sessionLease: VaultSessionLease?,
        accessGate: VaultAccessGate
    ) throws {
        guard let sessionLease else {
            throw VaultAccessError.missingLease(operation: "recoveryStore.open")
        }
        try accessGate.validate(
            lease: sessionLease,
            targetRoot: sessionLease.root,
            targetVaultID: sessionLease.vaultID,
            operation: "recoveryStore.open"
        )
        self.directory = directory
        self.sessionLease = sessionLease
        self.accessGate = accessGate
        self.unguardedForTesting = false
        try Self.prepareDirectory(directory)
    }

    /// Internal fixture-only construction, available to tests via `@testable import`.
    /// Deliberately has a different argument label and is absent from the public API.
    init(unguardedTestingDirectory directory: URL) throws {
        self.directory = directory
        self.sessionLease = nil
        self.accessGate = nil
        self.unguardedForTesting = true
        try Self.prepareDirectory(directory)
    }

    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func validateAccess(_ operation: String) throws {
        if unguardedForTesting { return }
        guard let accessGate, let sessionLease else {
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
