import Foundation
import VaultCore

/// Application fixtures exercise the admitted SQLite-only repository path.
func openCanonicalAppFixture(
    root: URL,
    create: Bool = false,
    contentStore: (any VaultContentStore)? = nil
) async throws -> FileVaultRepository {
    if create { _ = try await FileVaultRepository.initializeCanonicalStaging(root: root) }
    let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    let manifest = try FileVaultRepository.inspectManifest(at: canonicalRoot)
    let session = VaultSession(vaultID: manifest.id, root: canonicalRoot, generation: 1)
    let gate = VaultAccessGate(initialState: .open(session))
    return try FileVaultRepository.open(root: canonicalRoot, contentStore: contentStore,
        sessionLease: session.lease, accessGate: gate)
}

/// Compare the canonical page payload rather than a retired Wiki Markdown path.
func canonicalAppPageSnapshot(_ repository: FileVaultRepository, id: UUID) async throws -> Data {
    guard let page = try await repository.scan().notes.first(where: { $0.id == id }) else {
        throw VaultError.invalid("Missing canonical fixture page")
    }
    return try NoteCodec.encode(page)
}
