import Foundation

public struct DamagedRecoveryEntry: Identifiable, Sendable {
    public enum Failure: Equatable, Sendable {
        case unreadable, decoding, identityMismatch
    }

    public let fileURL: URL
    public let failure: Failure
    public let message: String
    public var id: String { fileURL.lastPathComponent }
    public var fileName: String { fileURL.lastPathComponent }
}

public struct RecoveryListing: Sendable {
    public var drafts: [DraftRecord]
    public var damagedEntries: [DamagedRecoveryEntry]

    public init(drafts: [DraftRecord] = [], damagedEntries: [DamagedRecoveryEntry] = []) {
        self.drafts = drafts
        self.damagedEntries = damagedEntries
    }
}

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
        let bytes = try JSONEncoder().encode(draft)
        let url = directory.appendingPathComponent(draft.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path), !isValidDraft(at: url, id: draft.id) {
            // A new save for the same page must not overwrite its damaged, potentially unique copy.
            // Renaming retains the original bytes; the listing continues to expose this entry.
            let preserved = directory.appendingPathComponent(draft.id.uuidString + ".damaged-" + UUID().uuidString + ".json")
            try FileManager.default.moveItem(at: url, to: preserved)
        }
        try bytes.write(to: url, options: .atomic)
    }
    public func remove(_ id: UUID) throws {
        try validateAccess("recoveryStore.remove")
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard isValidDraft(at: url, id: id) else {
                throw VaultError.invalid("The damaged recovery entry is preserved and cannot be discarded as a decoded draft.")
            }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func isValidDraft(at url: URL, id: UUID) -> Bool {
        guard let bytes = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(DraftRecord.self, from: bytes) else { return false }
        return draft.id == id
    }

    /// Compatibility view for callers that only need usable drafts. Directory and access errors
    /// still throw; damaged individual entries are exposed by `listing()` without blocking peers.
    public func drafts() throws -> [DraftRecord] {
        try validateAccess("recoveryStore.drafts")
        return try readListing().drafts
    }

    public func listing() throws -> RecoveryListing {
        try validateAccess("recoveryStore.listing")
        return try readListing()
    }

    private func readListing() throws -> RecoveryListing {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result = RecoveryListing()
        for file in files {
            let bytes: Data
            do { bytes = try Data(contentsOf: file) }
            catch {
                result.damagedEntries.append(DamagedRecoveryEntry(fileURL: file, failure: .unreadable, message: error.localizedDescription))
                continue
            }
            let draft: DraftRecord
            do { draft = try JSONDecoder().decode(DraftRecord.self, from: bytes) }
            catch {
                result.damagedEntries.append(DamagedRecoveryEntry(fileURL: file, failure: .decoding, message: error.localizedDescription))
                continue
            }
            guard file.deletingPathExtension().lastPathComponent == draft.id.uuidString else {
                result.damagedEntries.append(DamagedRecoveryEntry(fileURL: file, failure: .identityMismatch, message: "The recovery filename must match the draft identity exactly (\(draft.id.uuidString).json)."))
                continue
            }
            result.drafts.append(draft)
        }
        result.drafts.sort { $0.capturedAt > $1.capturedAt }
        return result
    }
}
