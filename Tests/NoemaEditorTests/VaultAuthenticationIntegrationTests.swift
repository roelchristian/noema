import Foundation
import NativeAuthentication
import Synchronization
import Testing
@testable import VaultCore
@testable import noema

extension VaultUIIntegrationTests {
@Suite(.serialized, .timeLimit(.minutes(1)))
struct VaultAuthenticationIntegrationTests {
    @Test @MainActor
    func initialOpenCancellationLoadsNoResourcesAndPreservesRecoveryForFreshRetry() async throws {
        let f = try await IntegrationFixture()
        defer { f.finish() }
        let note = try await f.repository.create(title: "Protected Page", body: "Canonical body")
        let drafts = f.local.appendingPathComponent("KnowledgeVault/\(f.vaultID)/Drafts")
        let journal = try RecoveryStore(unguardedTestingDirectory: drafts)
        let draft = DraftRecord(note: note, title: note.title, body: "Unsaved recovery body", tags: [])
        try await journal.store(draft)
        let damaged = drafts.appendingPathComponent("damaged.json")
        let damagedBytes = Data("{\"body\":\"Preserve incomplete recovery".utf8)
        try damagedBytes.write(to: damaged)
        let recoveryBytes = try Data(contentsOf: drafts.appendingPathComponent("\(draft.id).json"))
        f.policy.setRequired(true, for: f.vaultID)
        let indices = IntegrationCounter()
        f.model.searchIndexFactory = { url, lease, gate in
            indices.increment()
            return try SQLiteSearchIndex(url: url, sessionLease: lease, accessGate: gate)
        }
        let opening = Task { @MainActor in await f.model.open(f.root, create: false) }
        await f.auth.waitForCalls(1)
        #expect(f.manager.accessGate.currentState == .closed)
        #expect(f.manager.currentLease == nil)
        #expect(f.model.root == nil && f.model.index == nil)
        #expect(f.model.notes.isEmpty && f.model.sources.isEmpty && f.model.rows.isEmpty)
        #expect(f.model.body.isEmpty && f.model.preview.isEmpty && !f.model.hasRecoveryEntries)
        #expect(indices.value == 0)
        // A second ordinary Open request must not create a second native attempt.
        await f.model.open(f.root, create: false)
        #expect(await f.auth.purposes == [.openVault])
        #expect(await f.model.closeVault())
        await opening.value
        #expect(!f.model.isVaultAvailable && f.model.sessionPhase == .closed)
        #expect(indices.value == 0)
        #expect(try Data(contentsOf: damaged) == damagedBytes)
        #expect(try Data(contentsOf: drafts.appendingPathComponent("\(draft.id).json")) == recoveryBytes)
        let retry = Task { @MainActor in await f.model.open(f.root, create: false) }
        await f.auth.waitForCalls(2)
        await f.auth.resolve(0)
        #expect(indices.value == 0)
        #expect(!f.model.isVaultAvailable && f.model.notes.isEmpty)
        await f.auth.resolve(1)
        await retry.value
        #expect(f.model.isVaultAvailable && f.model.errorMessage == nil)
        #expect(indices.value == 1)
        #expect(f.model.notes.contains { $0.id == note.id && $0.body == "Canonical body" })
        #expect(f.model.recoveredDrafts.contains { $0.id == draft.id && $0.body == "Unsaved recovery body" })
        #expect(f.model.damagedRecoveryEntries.count == 1)
        #expect(try Data(contentsOf: damaged) == damagedBytes)
        #expect(await f.model.closeVault())
    }

    @Test @MainActor
    func cancelledUnlockRemainsLockedAndSameFolderReselectionAuthenticatesFresh() async throws {
        let f = try await IntegrationFixture()
        defer { f.finish() }
        let note = try await f.repository.create(title: "Page", body: "Protected content")
        f.policy.setRequired(true, for: f.vaultID)
        let open = Task { @MainActor in await f.model.open(f.root, create: false) }
        await f.auth.waitForCalls(1); await f.auth.resolve(0); await open.value
        #expect(f.model.isVaultAvailable)
        #expect(await f.model.lockVault())
        let locked = f.manager.accessGate.currentState
        let unlock = Task { @MainActor in await f.model.unlockVault() }
        await f.auth.waitForCalls(2)
        #expect(f.model.isLocked && f.model.notes.isEmpty && f.model.index == nil)
        #expect(f.manager.accessGate.currentState == locked)
        await f.model.cancelVaultAuthentication()
        #expect(!(await unlock.value))
        #expect(f.model.isLocked && !f.model.isVaultAvailable)
        let reselected = Task { @MainActor in await f.model.open(f.root, create: false) }
        await f.auth.waitForCalls(3)
        await f.auth.resolve(1)
        #expect(f.manager.accessGate.currentState == locked)
        #expect(f.model.notes.isEmpty)
        await f.auth.resolve(2); await reselected.value
        #expect(f.model.isVaultAvailable && !f.model.isLocked)
        #expect(f.model.notes.contains { $0.id == note.id })
        #expect(await f.model.closeVault())
        let reopen = Task { @MainActor in await f.model.open(f.root, create: false) }
        await f.auth.waitForCalls(4)
        #expect(!f.model.isVaultAvailable && f.model.notes.isEmpty)
        await f.auth.resolve(3); await reopen.value
        #expect(await f.auth.purposes == [.openVault, .unlockVault, .unlockVault, .openVault])
        #expect(f.model.isVaultAvailable && f.model.vaultAccessAuthenticationRequired)
        #expect(await f.model.closeVault())
    }

    @Test @MainActor
    func preferenceInteractionsAuthenticateAndUnprotectedCompatibilityStaysPromptFree() async throws {
        let f = try await IntegrationFixture()
        defer { f.finish() }
        await f.model.open(f.root, create: false)
        #expect(f.model.isVaultAvailable && !f.model.vaultAccessAuthenticationRequired)
        #expect(await f.auth.purposes.isEmpty)
        let enable = Task { @MainActor in await f.model.setVaultAccessAuthenticationRequired(true) }
        await f.auth.waitForCalls(1)
        #expect(!f.model.vaultAccessAuthenticationRequired)
        await f.auth.resolve(0)
        #expect(await enable.value)
        #expect(f.model.vaultAccessAuthenticationRequired)
        let cancelledDisable = Task { @MainActor in await f.model.setVaultAccessAuthenticationRequired(false) }
        await f.auth.waitForCalls(2)
        await f.model.cancelVaultAuthentication()
        #expect(!(await cancelledDisable.value))
        #expect(f.model.isVaultAvailable && f.model.vaultAccessAuthenticationRequired)
        await f.auth.resolve(1)
        let disable = Task { @MainActor in await f.model.setVaultAccessAuthenticationRequired(false) }
        await f.auth.waitForCalls(3); await f.auth.resolve(2)
        #expect(await disable.value)
        #expect(!f.model.vaultAccessAuthenticationRequired)
        #expect(await f.model.lockVault())
        #expect(await f.model.unlockVault())
        #expect(await f.model.closeVault())
        await f.model.open(f.root, create: false)
        #expect(f.model.isVaultAvailable)
        #expect(await f.auth.purposes == [.changeVaultAccessPolicy, .changeVaultAccessPolicy, .changeVaultAccessPolicy])
        #expect(await f.model.closeVault())
    }

    @Test @MainActor
    func optedInCreatePersistsRequirementBeforePromptAndCancellationKeepsCreatedBytes() async throws {
        let f = try await IntegrationFixture()
        defer { f.finish() }
        let createdRoot = f.base.appendingPathComponent("Created Protected Vault")
        let create = Task { @MainActor in
            try await f.model.createVault(parent: f.base, name: "Created Protected Vault",
                encryptionRequested: false, accessAuthenticationRequested: true)
        }
        await f.auth.waitForCalls(1)
        let manifest = try FileVaultRepository.inspectManifest(at: createdRoot)
        let original = try Data(contentsOf: createdRoot.appendingPathComponent("vault.json"))
        #expect(manifest.formatVersion == 1)
        #expect(f.manager.accessAuthenticationRequired(for: manifest.id))
        #expect(!f.model.isVaultAvailable && f.model.index == nil)
        await f.model.cancelVaultAuthentication()
        do { try await create.value; Issue.record("Cancelled creation reported opened vault") } catch {}
        #expect(f.model.sessionPhase == .closed && f.model.root == nil)
        #expect(try Data(contentsOf: createdRoot.appendingPathComponent("vault.json")) == original)
        #expect(f.manager.accessAuthenticationRequired(for: manifest.id))
        let retry = Task { @MainActor in await f.model.open(createdRoot, create: false) }
        await f.auth.waitForCalls(2)
        await f.auth.resolve(0)
        #expect(!f.model.isVaultAvailable)
        await f.auth.resolve(1); await retry.value
        #expect(f.model.isVaultAvailable && f.model.vaultAccessAuthenticationRequired)
        #expect(await f.auth.purposes == [.openVault, .openVault])
        #expect(await f.model.closeVault())
    }

    @Test @MainActor
    func authenticationFailurePublishesNoContentAndReleasesTemporarySecurityScope() async throws {
        let f = try await IntegrationFixture()
        defer { f.finish() }
        f.policy.setRequired(true, for: f.vaultID)
        let acquired = IntegrationCounter(), released = IntegrationCounter()
        f.model.requiresSecurityScopedAccess = true
        f.model.securityScopeAcquirer = { _ in acquired.increment(); return true }
        f.model.securityScopeReleaser = { _ in released.increment() }
        let opening = Task { @MainActor in await f.model.open(f.root, create: false) }
        await f.auth.waitForCalls(1)
        #expect(acquired.value == 1 && released.value == 0)
        await f.auth.resolve(0, failure: .unavailable)
        await opening.value
        #expect(f.model.sessionPhase == .closed && !f.model.isVaultAvailable)
        #expect(f.model.root == nil && f.model.index == nil)
        #expect(f.model.notes.isEmpty && f.model.sources.isEmpty && f.model.body.isEmpty)
        #expect(released.value == 1)
        #expect(f.model.errorMessage == NativeAuthenticationError.unavailable.localizedDescription)
    }
}
}

private struct IntegrationFixture: Sendable {
    let base: URL
    let root: URL
    let local: URL
    let repository: FileVaultRepository
    let vaultID: UUID
    let suite: String
    let policy: VaultAccessPolicyStore
    let auth: IntegrationAuthenticator
    let manager: VaultSessionManager
    let model: AppModel

    @MainActor init() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        base = repositoryRoot.appendingPathComponent(".local/agent-runs/d03b-integration-fixture-\(UUID())")
        root = base.appendingPathComponent("Vault")
        local = base.appendingPathComponent("Local")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent(".active"))
        repository = try await openCanonicalAppFixture(root: root, create: true)
        vaultID = repository.manifest.id
        suite = "noema.d03b.integration.\(UUID())"
        policy = VaultAccessPolicyStore(defaults: UserDefaults(suiteName: suite)!)
        auth = IntegrationAuthenticator()
        manager = VaultSessionManager(authenticator: auth, accessPolicy: policy)
        model = AppModel(sessionManager: manager)
        model.localStorageRoot = local
        model.persistSecurityScopedBookmark = false
    }

    func finish() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? Data().write(to: base.appendingPathComponent(".complete"))
        try? FileManager.default.removeItem(at: base.appendingPathComponent(".active"))
    }
}

private final class IntegrationCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

private actor IntegrationAuthenticator: NativeAuthenticating {
    private(set) var purposes: [NativeAuthenticationPurpose] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func authenticate(for purpose: NativeAuthenticationPurpose) async throws {
        let index = purposes.count
        purposes.append(purpose)
        try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { purposes.count >= $0.0 }
            observers.removeAll { purposes.count >= $0.0 }
            for observer in ready { observer.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if purposes.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func resolve(_ index: Int, failure: NativeAuthenticationError? = nil) {
        guard let continuation = pending.removeValue(forKey: index) else { return }
        if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
    }
}
