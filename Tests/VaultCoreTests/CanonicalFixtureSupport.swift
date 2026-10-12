import Foundation
@testable import VaultCore

/// Explicit test-only schema-5 creation and session authority. Production admission
/// never accepts an absent lease or silently initializes an existing vault.
func canonicalSchema5TestRepository(root: URL, create: Bool = false,
                                   contentStore: (any VaultContentStore)? = nil) async throws -> FileVaultRepository {
    if create { try await FileVaultRepository.initializeSchema5(root: root, storageProvider: .plaintext) }
    let manifest = try FileVaultRepository.inspectManifest(at: root)
    let session = VaultSession(vaultID: manifest.id, root: root, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    return try FileVaultRepository.open(root: root, contentStore: contentStore,
                                        sessionLease: session.lease, accessGate: gate)
}

func canonicalTestNoteBytes(root: URL, id: UUID) async throws -> Data {
    let repo = try await canonicalSchema5TestRepository(root: root)
    let notes = try await repo.scan().notes
    guard let note = notes.first(where: { $0.id == id }) else { throw VaultError.invalid("Missing test note") }
    let bytes = try NoteCodec.encode(note)
    try await repo.sqliteBlockStore.close()
    return bytes
}
