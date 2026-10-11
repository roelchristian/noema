import Foundation
import Synchronization

/// Classification of vault mutations coordinated during lock quiescence.
public enum VaultQuiescenceOperationKind: String, Sendable, Equatable, CaseIterable {
    case save
    case autosave
    case pageLCCSave
    case sourceLCCSave
    case sourceImport
    case sourceDownload
}

/// Lifecycle phase of an admitted mutation with respect to its durable commit point.
public enum VaultOperationCommitState: String, Sendable, Equatable, CaseIterable {
    case preCommit
    case committing
    case committed
    case cancelledBeforeCommit
    case failedBeforeCommit
}

/// Outcome of an individual save, autosave, or source import operation during quiescence.
public enum VaultQuiescedOperationOutcome: Sendable, Equatable {
    case completed(operationID: UUID, kind: VaultQuiescenceOperationKind)
    case committed(operationID: UUID, kind: VaultQuiescenceOperationKind)
    case cancelledBeforeCommit(operationID: UUID, kind: VaultQuiescenceOperationKind, draftPreserved: Bool)
    case preservedToRecovery(noteID: UUID, kind: VaultQuiescenceOperationKind)
}

/// Summary report produced when lock quiescence succeeds.
public struct VaultQuiescenceReport: Sendable, Equatable {
    public let sessionID: UUID
    public let vaultID: UUID
    public let root: URL
    public let generation: UInt64
    public let outcomes: [VaultQuiescedOperationOutcome]
    public let preservedDraftIDs: [UUID]
    public let cancelledSourceImportIDs: [UUID]
    public let cleanedStagingPaths: [String]

    public init(
        sessionID: UUID,
        vaultID: UUID,
        root: URL,
        generation: UInt64,
        outcomes: [VaultQuiescedOperationOutcome],
        preservedDraftIDs: [UUID],
        cancelledSourceImportIDs: [UUID],
        cleanedStagingPaths: [String]
    ) {
        self.sessionID = sessionID
        self.vaultID = vaultID
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.generation = generation
        self.outcomes = outcomes
        self.preservedDraftIDs = preservedDraftIDs
        self.cancelledSourceImportIDs = cancelledSourceImportIDs
        self.cleanedStagingPaths = cleanedStagingPaths
    }
}

/// Typed errors emitted when lock quiescence encounters an unrecoverable failure and must abort locking.
public enum VaultQuiescenceError: Error, Sendable, Equatable, LocalizedError {
    case draftPreservationFailed(noteID: UUID, underlyingMessage: String)
    case saveFailedWithoutRecovery(noteID: UUID, saveMessage: String, recoveryMessage: String?)
    case pendingLCCSaveFailed(targetID: UUID, isSource: Bool, message: String)
    case inFlightOperationFailed(operationID: UUID, kind: VaultQuiescenceOperationKind, message: String)
    case stagingCleanupFailed(path: String, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .draftPreservationFailed(let noteID, let underlyingMessage):
            "Could not preserve unsaved draft for page \(noteID.uuidString) before locking: \(underlyingMessage)"
        case .saveFailedWithoutRecovery(let noteID, let saveMessage, let recoveryMessage):
            if let recoveryMessage {
                "Save failed for page \(noteID.uuidString) (\(saveMessage)) and draft recovery also failed (\(recoveryMessage))."
            } else {
                "Save failed for page \(noteID.uuidString) without a recovery store (\(saveMessage))."
            }
        case .pendingLCCSaveFailed(_, let isSource, let message):
            "Could not flush pending \(isSource ? "source" : "page") LCC update before locking: \(message)"
        case .inFlightOperationFailed(_, let kind, let message):
            "In-flight \(kind.rawValue) operation failed during lock quiescence: \(message)"
        case .stagingCleanupFailed(let path, let message):
            "Could not clean up interrupted import staging at '\(path)' before locking: \(message)"
        case .cancelled:
            "Vault lock quiescence was cancelled."
        }
    }
}

/// Cancellation and durable-commit contract for an admitted save, autosave, or source import operation.
/// Distinguishes pre-commit work (which may be cooperatively cancelled when locking starts, provided any
/// unsaved page edits are journaled to `RecoveryStore` and any import staging is cleaned up) from the
/// durable commit window (which must finish uninterrupted once entered so committed writes remain recognized).
public final class VaultQuiescentOperationContext: Sendable {
    public let registration: VaultOperationRegistration
    public let kind: VaultQuiescenceOperationKind
    public let noteSnapshot: DraftRecord?
    public let sourceImportID: UUID?

    private struct State: Sendable {
        var commitState: VaultOperationCommitState = .preCommit
        var cancelRequested: Bool = false
        var stagedRelativePaths: [String] = []
        var draftPreserved: Bool = false
        var failureError: VaultQuiescenceError?
        var committedNote: NoteRecord?
        var committedSource: SourceRecord?
        var cancellationHandlers: [@Sendable () -> Void] = []
    }

    private let state: Mutex<State>
    private let onFinish: @Sendable (UUID) -> Void

    public var id: UUID { registration.id }
    public var lease: VaultSessionLease { registration.lease }
    public var sessionID: UUID { registration.sessionID }

    init(
        registration: VaultOperationRegistration,
        kind: VaultQuiescenceOperationKind,
        noteSnapshot: DraftRecord? = nil,
        sourceImportID: UUID? = nil,
        onFinish: @escaping @Sendable (UUID) -> Void
    ) {
        self.registration = registration
        self.kind = kind
        self.noteSnapshot = noteSnapshot
        self.sourceImportID = sourceImportID
        self.state = Mutex(State())
        self.onFinish = onFinish
    }

    public var commitState: VaultOperationCommitState {
        state.withLock { $0.commitState }
    }

    public var isCancellationRequested: Bool {
        state.withLock { $0.cancelRequested } || Task.isCancelled
    }

    public var isCommitted: Bool {
        state.withLock { $0.commitState == .committed }
    }

    public var isDraftPreserved: Bool {
        state.withLock { $0.draftPreserved }
    }

    public var stagedRelativePaths: [String] {
        state.withLock { $0.stagedRelativePaths }
    }

    public var committedNote: NoteRecord? {
        state.withLock { $0.committedNote }
    }

    public var committedSource: SourceRecord? {
        state.withLock { $0.committedSource }
    }

    /// Registers a synchronous callback invoked if pre-commit cancellation is requested by quiescence.
    public func onPreCommitCancel(_ handler: @escaping @Sendable () -> Void) {
        let invokeImmediately = state.withLock { s -> Bool in
            if s.cancelRequested && s.commitState == .preCommit {
                return true
            }
            s.cancellationHandlers.append(handler)
            return false
        }
        if invokeImmediately {
            handler()
        }
    }

    /// Records a temporary staging relative path (e.g. `Sources/.import-<UUID>`) created before final publication
    /// so quiescence can deterministically remove it if the import is cancelled before commit.
    public func recordStagingPath(_ relativePath: String) {
        state.withLock { s in
            if !s.stagedRelativePaths.contains(relativePath) {
                s.stagedRelativePaths.append(relativePath)
            }
        }
    }

    /// Marks that the associated page draft has been durably written to `RecoveryStore`.
    public func markDraftPreserved() {
        state.withLock { s in
            s.draftPreserved = true
        }
    }

    /// Requests cooperative cancellation if and only if the operation has not yet entered its durable commit window.
    /// Returns `true` if cancellation was signaled in `.preCommit` or `.cancelledBeforeCommit`, or `false` if the
    /// operation has already reached `.committing` or `.committed`.
    @discardableResult
    public func requestPreCommitCancellation() -> Bool {
        let handlers: [@Sendable () -> Void]? = state.withLock { s in
            switch s.commitState {
            case .preCommit:
                s.cancelRequested = true
                let copied = s.cancellationHandlers
                s.cancellationHandlers.removeAll()
                return copied
            case .cancelledBeforeCommit:
                s.cancelRequested = true
                return []
            case .committing, .committed, .failedBeforeCommit:
                return nil
            }
        }
        guard let handlers else { return false }
        for handler in handlers {
            handler()
        }
        return true
    }

    /// Checks whether the operation was cancelled before entering its durable commit point.
    public func checkPreCommitCancellation() throws {
        let shouldThrow = state.withLock { s -> Bool in
            if s.commitState == .cancelledBeforeCommit {
                return true
            }
            if s.commitState == .preCommit && (s.cancelRequested || Task.isCancelled) {
                s.commitState = .cancelledBeforeCommit
                return true
            }
            return false
        }
        if shouldThrow {
            throw VaultOperationAdmissionError.cancelled(operation: registration.name)
        }
    }

    /// Atomically transitions from `.preCommit` to `.committing`.
    /// Once `.committing` is entered, pre-commit cancellation can no longer abort the operation.
    /// Throws `VaultOperationAdmissionError.cancelled` if pre-commit cancellation was already requested.
    public func beginCommitWindow() throws {
        let cancelled = state.withLock { s -> Bool in
            switch s.commitState {
            case .preCommit:
                if s.cancelRequested || Task.isCancelled {
                    s.commitState = .cancelledBeforeCommit
                    return true
                }
                s.commitState = .committing
                s.cancellationHandlers.removeAll()
                return false
            case .committing, .committed:
                return false
            case .cancelledBeforeCommit, .failedBeforeCommit:
                return true
            }
        }
        if cancelled {
            throw VaultOperationAdmissionError.cancelled(operation: registration.name)
        }
    }

    /// Marks the operation's canonical write/publication as durably committed.
    public func markCommitted(note: NoteRecord? = nil, source: SourceRecord? = nil) {
        state.withLock { s in
            s.commitState = .committed
            if let note { s.committedNote = note }
            if let source { s.committedSource = source }
        }
    }

    /// Executes the durable commit closure inside `.committing` and marks the operation `.committed` on success.
    public func performDurableCommit<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        try beginCommitWindow()
        do {
            let result = try await body()
            if let note = result as? NoteRecord {
                markCommitted(note: note)
            } else if let source = result as? SourceRecord {
                markCommitted(source: source)
            } else {
                markCommitted()
            }
            return result
        } catch {
            state.withLock { s in
                if s.commitState != .committed {
                    s.commitState = .failedBeforeCommit
                }
            }
            throw error
        }
    }

    func recordQuiescenceFailure(_ error: VaultQuiescenceError) {
        state.withLock { s in
            s.failureError = error
            if s.commitState == .preCommit || s.commitState == .committing {
                s.commitState = .failedBeforeCommit
            }
        }
    }

    var recordedFailure: VaultQuiescenceError? {
        state.withLock { $0.failureError }
    }

    func finish() {
        let cState = state.withLock { $0.commitState }
        switch cState {
        case .cancelledBeforeCommit:
            registration.cancel()
        default:
            registration.complete(disposition: .completed)
        }
        onFinish(registration.id)
    }
}

/// Pending debounced editor or metadata state that has not yet started an in-flight repository operation
/// when a lock transition is requested.
public struct VaultPendingEditorState: Sendable {
    public struct DirtyNoteState: Sendable {
        public let note: NoteRecord
        public let title: String
        public let body: String
        public let tags: [String]
        public let lcc: String?
        public let preferDirectSave: Bool

        public init(
            note: NoteRecord,
            title: String,
            body: String,
            tags: [String],
            lcc: String? = nil,
            preferDirectSave: Bool = true
        ) {
            self.note = note
            self.title = title
            self.body = body
            self.tags = tags
            self.lcc = lcc
            self.preferDirectSave = preferDirectSave
        }
    }

    public struct PendingPageLCCUpdate: Sendable, Equatable {
        public let note: NoteRecord
        public let lcc: String?

        public init(note: NoteRecord, lcc: String?) {
            self.note = note
            self.lcc = lcc
        }
    }

    public struct PendingSourceLCCUpdate: Sendable, Equatable {
        public let source: SourceRecord
        public let lcc: String?

        public init(source: SourceRecord, lcc: String?) {
            self.source = source
            self.lcc = lcc
        }
    }

    public var dirtyNote: DirtyNoteState?
    public var pendingPageLCC: PendingPageLCCUpdate?
    public var pendingSourceLCCs: [PendingSourceLCCUpdate]
    public var activeDownloadSourceIDs: [UUID]

    public init(
        dirtyNote: DirtyNoteState? = nil,
        pendingPageLCC: PendingPageLCCUpdate? = nil,
        pendingSourceLCCs: [PendingSourceLCCUpdate] = [],
        activeDownloadSourceIDs: [UUID] = []
    ) {
        self.dirtyNote = dirtyNote
        self.pendingPageLCC = pendingPageLCC
        self.pendingSourceLCCs = pendingSourceLCCs
        self.activeDownloadSourceIDs = activeDownloadSourceIDs
    }
}

/// Coordinates safe quiescence of in-flight saves, autosaves, LCC metadata updates, and source imports/downloads
/// using `VaultAccessGate` and `VaultLockAdmissionBarrier` before a vault session reaches `.locked`.
public final class VaultSaveQuiescenceCoordinator: Sendable {
    public let accessGate: VaultAccessGate

    private struct CoordinatorState: Sendable {
        var contexts: [UUID: VaultQuiescentOperationContext] = [:]
        var contextOrder: [UUID] = []
        var completedContexts: [VaultQuiescentOperationContext] = []
        var committedNotesByID: [UUID: NoteRecord] = [:]
        var committedSourcesByID: [UUID: SourceRecord] = [:]
    }

    private let state: Mutex<CoordinatorState>

    public init(accessGate: VaultAccessGate) {
        self.accessGate = accessGate
        self.state = Mutex(CoordinatorState())
    }

    public var activeContexts: [VaultQuiescentOperationContext] {
        state.withLock { s in
            s.contextOrder.compactMap { s.contexts[$0] }
        }
    }

    public var committedNotes: [UUID: NoteRecord] {
        state.withLock { $0.committedNotesByID }
    }

    public var committedSources: [UUID: SourceRecord] {
        state.withLock { $0.committedSourcesByID }
    }

    /// Admits and executes a tracked quiescent operation (`save`, `autosave`, `sourceImport`, etc.).
    public func runOperation<T: Sendable>(
        kind: VaultQuiescenceOperationKind,
        name: String? = nil,
        lease: VaultSessionLease? = nil,
        noteSnapshot: DraftRecord? = nil,
        sourceImportID: UUID? = nil,
        id: UUID = UUID(),
        body: @Sendable (VaultQuiescentOperationContext) async throws -> T
    ) async throws -> T {
        let opName = name ?? kind.rawValue
        let registration = try accessGate.admitOperation(
            operation: opName,
            lease: lease,
            id: id
        )
        let context = VaultQuiescentOperationContext(
            registration: registration,
            kind: kind,
            noteSnapshot: noteSnapshot,
            sourceImportID: sourceImportID
        ) { [weak self] finishedID in
            self?.completeContext(id: finishedID)
        }

        state.withLock { s in
            s.contexts[registration.id] = context
            s.contextOrder.append(registration.id)
        }

        do {
            let value = try await VaultLockAdmissionBarrier.$currentOperationID.withValue(registration.id) {
                try await body(context)
            }
            if let note = value as? NoteRecord, !context.isCommitted {
                context.markCommitted(note: note)
            } else if let source = value as? SourceRecord, !context.isCommitted {
                context.markCommitted(source: source)
            }
            recordCommittedArtifacts(from: context)
            context.finish()
            return value
        } catch {
            recordCommittedArtifacts(from: context)
            context.finish()
            throw error
        }
    }

    /// Runs a page save or autosave with recovery integration and durable-commit tracking.
    /// 1. Journals `draft` to `recovery` before attempting the repository save if `journalBeforeSave` is true.
    /// 2. Checks pre-commit cancellation before entering the commit window.
    /// 3. Executes `repository.save` inside the durable commit window so committed writes are always recognized.
    /// 4. If cancelled or if `repository.save` fails with a recoverable conflict/stale error, ensures `draft`
    ///    is durably preserved in `recovery`; if `recovery` also fails, records an unrecoverable quiescence error.
    public func performPageSave(
        kind: VaultQuiescenceOperationKind = .save,
        note: NoteRecord,
        title: String,
        body: String,
        tags: [String],
        lcc: String? = nil,
        repository: FileVaultRepository,
        recovery: RecoveryStore?,
        lease: VaultSessionLease? = nil,
        willEnterCommitWindow: (@Sendable (VaultQuiescentOperationContext) async throws -> Void)? = nil
    ) async throws -> NoteRecord {
        let noteToSave: NoteRecord = {
            var copy = note
            if let lcc {
                let trimmed = lcc.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.lcc = trimmed.isEmpty ? nil : trimmed
            }
            return copy
        }()
        let draft = DraftRecord(note: noteToSave, title: title, body: body, tags: normalizeTags(tags))

        return try await runOperation(
            kind: kind,
            name: kind.rawValue,
            lease: lease ?? repository.sessionLease,
            noteSnapshot: draft
        ) { context in
            if let recovery {
                do {
                    try await recovery.store(draft)
                    context.markDraftPreserved()
                } catch {
                    let qError = VaultQuiescenceError.draftPreservationFailed(
                        noteID: draft.id,
                        underlyingMessage: error.localizedDescription
                    )
                    context.recordQuiescenceFailure(qError)
                    throw qError
                }
            }

            do {
                try await willEnterCommitWindow?(context)
                try context.checkPreCommitCancellation()
                let saved = try await context.performDurableCommit {
                    try await repository.save(
                        note: noteToSave,
                        title: draft.title,
                        body: draft.body,
                        tags: draft.tags
                    )
                }
                if let recovery {
                    try? await recovery.remove(saved.id)
                }
                return saved
            } catch {
                // If cancelled or failed before commit, guarantee the draft is preserved in RecoveryStore.
                if !context.isCommitted {
                    if let recovery {
                        if !context.isDraftPreserved {
                            do {
                                try await recovery.store(draft)
                                context.markDraftPreserved()
                            } catch let recoveryError {
                                let qError = VaultQuiescenceError.saveFailedWithoutRecovery(
                                    noteID: draft.id,
                                    saveMessage: error.localizedDescription,
                                    recoveryMessage: recoveryError.localizedDescription
                                )
                                context.recordQuiescenceFailure(qError)
                                throw qError
                            }
                        }
                    } else {
                        let qError = VaultQuiescenceError.saveFailedWithoutRecovery(
                            noteID: draft.id,
                            saveMessage: error.localizedDescription,
                            recoveryMessage: nil
                        )
                        context.recordQuiescenceFailure(qError)
                        throw qError
                    }
                }
                throw error
            }
        }
    }

    /// Runs a source import or URL source import with pre-commit cancellation and staging cleanup.
    /// Pre-commit preparation (e.g. network fetch or cloud download) can be cooperatively cancelled when locking
    /// begins; once entering the publication commit window, the staged source is published atomically.
    public func performSourceImport(
        kind: VaultQuiescenceOperationKind = .sourceImport,
        sourceID: UUID = UUID(),
        repository: FileVaultRepository,
        lease: VaultSessionLease? = nil,
        prepare: @Sendable (VaultQuiescentOperationContext) async throws -> (data: Data, filename: String, title: String, originURL: String?, isURLSource: Bool),
        willEnterCommitWindow: (@Sendable (VaultQuiescentOperationContext) async throws -> Void)? = nil
    ) async throws -> SourceRecord {
        try await runOperation(
            kind: kind,
            name: kind.rawValue,
            lease: lease ?? repository.sessionLease,
            sourceImportID: sourceID
        ) { context in
            let stagingPath = "Sources/.import-\(sourceID.uuidString)"
            context.recordStagingPath(stagingPath)
            do {
                try context.checkPreCommitCancellation()
                let prepared = try await prepare(context)
                try await willEnterCommitWindow?(context)
                try context.checkPreCommitCancellation()
                return try await context.performDurableCommit {
                    try await repository.importPreparedSource(
                        id: sourceID,
                        data: prepared.data,
                        filename: prepared.filename,
                        title: prepared.title,
                        originURL: prepared.originURL,
                        isURLSource: prepared.isURLSource
                    )
                }
            } catch {
                if !context.isCommitted {
                    await repository.cancelSourceDownload(id: sourceID)
                    _ = try? await repository.cleanupInterruptedImportStaging(id: sourceID)
                }
                throw error
            }
        }
    }

    private func recordCommittedArtifacts(from context: VaultQuiescentOperationContext) {
        let note = context.committedNote
        let source = context.committedSource
        guard note != nil || source != nil else { return }
        state.withLock { s in
            if let note {
                s.committedNotesByID[note.id] = note
            }
            if let source {
                s.committedSourcesByID[source.id] = source
            }
        }
    }

    private func completeContext(id: UUID) {
        state.withLock { s in
            if let removed = s.contexts.removeValue(forKey: id) {
                s.contextOrder.removeAll { $0 == id }
                s.completedContexts.append(removed)
            }
        }
    }

    /// Quiesces all pending and in-flight saves, autosaves, LCC updates, and source imports/downloads
    /// during the `.locking` phase before `.locked` is published.
    ///
    /// - Parameters:
    ///   - session: The session currently transitioning from `.open` to `.locked`.
    ///   - repository: The session's gated `FileVaultRepository`.
    ///   - recovery: The session's `RecoveryStore` for preserving unsaved edits.
    ///   - pendingState: Optional snapshot of debounced/unsaved editor state (`dirtyNote`, `pendingPageLCC`, `pendingSourceLCCs`, `activeDownloadSourceIDs`).
    ///   - cancelPreCommitSaves: If `true`, in-flight saves/autosaves still in `.preCommit` are signalled to cancel and preserve their drafts in `RecoveryStore`; if `false` (default), in-flight saves finish committing if possible and fall back to `RecoveryStore` on conflict/cancelled/error. Pre-commit source imports/downloads are always signalled to cancel cleanly.
    @discardableResult
    public func quiesceForLock(
        session: VaultSession,
        repository: FileVaultRepository,
        recovery: RecoveryStore?,
        pendingState: VaultPendingEditorState = VaultPendingEditorState(),
        cancelPreCommitSaves: Bool = false
    ) async throws -> VaultQuiescenceReport {
        if Task.isCancelled {
            throw VaultQuiescenceError.cancelled
        }

        // Snapshot all currently active operation contexts for this session.
        let initialActive: [VaultQuiescentOperationContext] = state.withLock { s in
            s.contextOrder.compactMap { id in
                guard let ctx = s.contexts[id], ctx.sessionID == session.id else { return nil }
                return ctx
            }
        }

        // 1. Signal pre-commit cancellation to in-flight source imports/downloads (and optionally pre-commit saves).
        for ctx in initialActive {
            switch ctx.kind {
            case .sourceImport, .sourceDownload:
                _ = ctx.requestPreCommitCancellation()
            case .save, .autosave:
                if cancelPreCommitSaves {
                    _ = ctx.requestPreCommitCancellation()
                }
            case .pageLCCSave, .sourceLCCSave:
                break
            }
        }

        // 2. Wait for all admitted in-flight operations on the session's admission barrier to drain.
        try await accessGate.awaitInFlightOperations(forSessionID: session.id)
        if Task.isCancelled {
            throw VaultQuiescenceError.cancelled
        }

        // 3. Inspect drained operation contexts for unrecoverable errors, recovery needs, or interrupted import staging.
        let drainedContexts: [VaultQuiescentOperationContext] = state.withLock { s in
            let matching = s.completedContexts.filter { $0.sessionID == session.id }
            s.completedContexts.removeAll { $0.sessionID == session.id }
            return matching
        }

        var outcomes: [VaultQuiescedOperationOutcome] = []
        var preservedDraftIDs: [UUID] = []
        var cancelledSourceImportIDs: [UUID] = []
        var cleanedStagingPaths: [String] = []
        var notesHandledByInFlight: Set<UUID> = []

        // Register the privileged quiescence scope for this locking session so recovery draft journaling
        // and staging cleanup are authorized while the admission barrier is closed.
        let quiescenceOpID = UUID()
        accessGate.registerQuiescenceScope(id: quiescenceOpID, session: session)
        defer {
            accessGate.unregisterQuiescenceScope(id: quiescenceOpID, sessionID: session.id)
        }

        try await VaultLockAdmissionBarrier.$currentOperationID.withValue(quiescenceOpID) {
            for ctx in drainedContexts {
                if let recordedFailure = ctx.recordedFailure {
                    throw recordedFailure
                }

                switch ctx.commitState {
                case .committed:
                    if let note = ctx.committedNote {
                        notesHandledByInFlight.insert(note.id)
                    } else if let draft = ctx.noteSnapshot {
                        notesHandledByInFlight.insert(draft.id)
                    }
                    outcomes.append(.committed(operationID: ctx.id, kind: ctx.kind))

                case .cancelledBeforeCommit:
                    if let draft = ctx.noteSnapshot {
                        notesHandledByInFlight.insert(draft.id)
                        if !ctx.isDraftPreserved {
                            guard let recovery else {
                                throw VaultQuiescenceError.saveFailedWithoutRecovery(
                                    noteID: draft.id,
                                    saveMessage: "Operation cancelled before commit",
                                    recoveryMessage: nil
                                )
                            }
                            do {
                                try await recovery.store(draft)
                                ctx.markDraftPreserved()
                            } catch {
                                throw VaultQuiescenceError.draftPreservationFailed(
                                    noteID: draft.id,
                                    underlyingMessage: error.localizedDescription
                                )
                            }
                        }
                        if !preservedDraftIDs.contains(draft.id) {
                            preservedDraftIDs.append(draft.id)
                        }
                    }
                    if let importID = ctx.sourceImportID {
                        await repository.cancelSourceDownload(id: importID)
                        do {
                            let cleaned = try await collectStagingCleanup(repository: repository, importID: importID)
                            for path in cleaned where !cleanedStagingPaths.contains(path) {
                                cleanedStagingPaths.append(path)
                            }
                        } catch {
                            throw VaultQuiescenceError.stagingCleanupFailed(
                                path: "Sources/.import-\(importID.uuidString)",
                                message: error.localizedDescription
                            )
                        }
                        if !cancelledSourceImportIDs.contains(importID) {
                            cancelledSourceImportIDs.append(importID)
                        }
                    }
                    outcomes.append(.cancelledBeforeCommit(
                        operationID: ctx.id,
                        kind: ctx.kind,
                        draftPreserved: ctx.isDraftPreserved
                    ))

                case .failedBeforeCommit:
                    if let draft = ctx.noteSnapshot {
                        notesHandledByInFlight.insert(draft.id)
                        if !ctx.isDraftPreserved {
                            guard let recovery else {
                                throw VaultQuiescenceError.saveFailedWithoutRecovery(
                                    noteID: draft.id,
                                    saveMessage: "In-flight save failed before commit",
                                    recoveryMessage: nil
                                )
                            }
                            do {
                                try await recovery.store(draft)
                                ctx.markDraftPreserved()
                            } catch {
                                throw VaultQuiescenceError.draftPreservationFailed(
                                    noteID: draft.id,
                                    underlyingMessage: error.localizedDescription
                                )
                            }
                        }
                        if !preservedDraftIDs.contains(draft.id) {
                            preservedDraftIDs.append(draft.id)
                        }
                        outcomes.append(.preservedToRecovery(noteID: draft.id, kind: ctx.kind))
                    } else if let importID = ctx.sourceImportID {
                        await repository.cancelSourceDownload(id: importID)
                        do {
                            let cleaned = try await collectStagingCleanup(repository: repository, importID: importID)
                            for path in cleaned where !cleanedStagingPaths.contains(path) {
                                cleanedStagingPaths.append(path)
                            }
                        } catch {
                            throw VaultQuiescenceError.stagingCleanupFailed(
                                path: "Sources/.import-\(importID.uuidString)",
                                message: error.localizedDescription
                            )
                        }
                        if !cancelledSourceImportIDs.contains(importID) {
                            cancelledSourceImportIDs.append(importID)
                        }
                        outcomes.append(.cancelledBeforeCommit(operationID: ctx.id, kind: ctx.kind, draftPreserved: false))
                    } else {
                        throw VaultQuiescenceError.inFlightOperationFailed(
                            operationID: ctx.id,
                            kind: ctx.kind,
                            message: "Operation failed before commit without recovery handler."
                        )
                    }

                case .preCommit, .committing:
                    outcomes.append(.completed(operationID: ctx.id, kind: ctx.kind))
                }
            }
            // 4a. Clean up any remaining active source downloads and leftover `.import-*` staging directories.
            for downloadID in pendingState.activeDownloadSourceIDs {
                await repository.cancelSourceDownload(id: downloadID)
                if !cancelledSourceImportIDs.contains(downloadID) {
                    cancelledSourceImportIDs.append(downloadID)
                }
            }
            let cancelledAllDownloads = await repository.cancelAllSourceDownloads()
            for downloadID in cancelledAllDownloads where !cancelledSourceImportIDs.contains(downloadID) {
                cancelledSourceImportIDs.append(downloadID)
            }
            do {
                let sweptPaths = try await repository.cleanupAllInterruptedImportStaging()
                for path in sweptPaths where !cleanedStagingPaths.contains(path) {
                    cleanedStagingPaths.append(path)
                }
            } catch {
                throw VaultQuiescenceError.stagingCleanupFailed(
                    path: "Sources/.import-*",
                    message: error.localizedDescription
                )
            }

            // 4b. Handle pending dirty note edits if not already committed or preserved by an in-flight save.
            if let dirty = pendingState.dirtyNote {
                var baseNote = state.withLock { $0.committedNotesByID[dirty.note.id] } ?? dirty.note
                if let lcc = dirty.lcc {
                    let trimmed = lcc.trimmingCharacters(in: .whitespacesAndNewlines)
                    baseNote.lcc = trimmed.isEmpty ? nil : trimmed
                }
                let normalizedTags = normalizeTags(dirty.tags)
                let stillDirty = dirty.title != baseNote.title
                    || dirty.body != baseNote.body
                    || normalizedTags != baseNote.tags
                    || baseNote.lcc != (state.withLock { $0.committedNotesByID[dirty.note.id]?.lcc } ?? dirty.note.lcc)

                if stillDirty {
                    let draft = DraftRecord(
                        note: baseNote,
                        title: dirty.title,
                        body: dirty.body,
                        tags: normalizedTags
                    )
                    if let recovery {
                        do {
                            try await recovery.store(draft)
                        } catch {
                            throw VaultQuiescenceError.draftPreservationFailed(
                                noteID: draft.id,
                                underlyingMessage: error.localizedDescription
                            )
                        }
                    }

                    if dirty.preferDirectSave {
                        do {
                            let saved = try await repository.save(
                                note: baseNote,
                                title: draft.title,
                                body: draft.body,
                                tags: draft.tags
                            )
                            state.withLock { $0.committedNotesByID[saved.id] = saved }
                            if let recovery {
                                try? await recovery.remove(saved.id)
                            }
                            preservedDraftIDs.removeAll { $0 == saved.id }
                            outcomes.append(.committed(operationID: quiescenceOpID, kind: .save))
                        } catch {
                            // Direct save failed (e.g. conflict/stale/empty title): preserve via RecoveryStore if available.
                            guard recovery != nil else {
                                throw VaultQuiescenceError.saveFailedWithoutRecovery(
                                    noteID: draft.id,
                                    saveMessage: error.localizedDescription,
                                    recoveryMessage: nil
                                )
                            }
                            if !preservedDraftIDs.contains(draft.id) {
                                preservedDraftIDs.append(draft.id)
                            }
                            outcomes.append(.preservedToRecovery(noteID: draft.id, kind: .save))
                        }
                    } else {
                        guard recovery != nil else {
                            throw VaultQuiescenceError.saveFailedWithoutRecovery(
                                noteID: draft.id,
                                saveMessage: "Direct save disabled during quiescence",
                                recoveryMessage: nil
                            )
                        }
                        if !preservedDraftIDs.contains(draft.id) {
                            preservedDraftIDs.append(draft.id)
                        }
                        outcomes.append(.preservedToRecovery(noteID: draft.id, kind: .autosave))
                    }
                }
            }

            // 4c. Flush any pending debounced page LCC update (when note body/title wasn't dirty).
            if let pendingPageLCC = pendingState.pendingPageLCC,
               !preservedDraftIDs.contains(pendingPageLCC.note.id) {
                var targetNote = state.withLock { $0.committedNotesByID[pendingPageLCC.note.id] } ?? pendingPageLCC.note
                let trimmed = pendingPageLCC.lcc?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedLCC = (trimmed?.isEmpty == false) ? trimmed : nil
                if targetNote.lcc != normalizedLCC {
                    targetNote.lcc = normalizedLCC
                    do {
                        let saved = try await repository.save(
                            note: targetNote,
                            title: targetNote.title,
                            body: targetNote.body,
                            tags: targetNote.tags
                        )
                        state.withLock { $0.committedNotesByID[saved.id] = saved }
                        outcomes.append(.committed(operationID: UUID(), kind: .pageLCCSave))
                    } catch {
                        // Fall back to preserving a recovery draft if possible; otherwise fail quiescence.
                        if let recovery {
                            let draft = DraftRecord(
                                note: targetNote,
                                title: targetNote.title,
                                body: targetNote.body,
                                tags: targetNote.tags
                            )
                            do {
                                try await recovery.store(draft)
                                if !preservedDraftIDs.contains(draft.id) {
                                    preservedDraftIDs.append(draft.id)
                                }
                                outcomes.append(.preservedToRecovery(noteID: draft.id, kind: .pageLCCSave))
                            } catch let recoveryError {
                                throw VaultQuiescenceError.pendingLCCSaveFailed(
                                    targetID: targetNote.id,
                                    isSource: false,
                                    message: "\(error.localizedDescription) (recovery failed: \(recoveryError.localizedDescription))"
                                )
                            }
                        } else {
                            throw VaultQuiescenceError.pendingLCCSaveFailed(
                                targetID: targetNote.id,
                                isSource: false,
                                message: error.localizedDescription
                            )
                        }
                    }
                }
            }

            // 4d. Flush any pending debounced source LCC updates.
            for sourceLCC in pendingState.pendingSourceLCCs {
                guard !cancelledSourceImportIDs.contains(sourceLCC.source.id) else { continue }
                let targetSource = state.withLock { $0.committedSourcesByID[sourceLCC.source.id] } ?? sourceLCC.source
                do {
                    let updated = try await repository.updateSourceLCC(targetSource, lcc: sourceLCC.lcc)
                    state.withLock { $0.committedSourcesByID[updated.id] = updated }
                    outcomes.append(.committed(operationID: UUID(), kind: .sourceLCCSave))
                } catch {
                    throw VaultQuiescenceError.pendingLCCSaveFailed(
                        targetID: sourceLCC.source.id,
                        isSource: true,
                        message: error.localizedDescription
                    )
                }
            }
        }

        return VaultQuiescenceReport(
            sessionID: session.id,
            vaultID: session.vaultID,
            root: session.root,
            generation: session.generation,
            outcomes: outcomes,
            preservedDraftIDs: preservedDraftIDs,
            cancelledSourceImportIDs: cancelledSourceImportIDs,
            cleanedStagingPaths: cleanedStagingPaths
        )
    }

    private func collectStagingCleanup(
        repository: FileVaultRepository,
        importID: UUID
    ) async throws -> [String] {
        let cleanupOpID = UUID()
        if case .locking(let session) = accessGate.currentState {
            accessGate.registerQuiescenceScope(id: cleanupOpID, session: session)
        }
        defer {
            if let sessionID = accessGate.currentState.sessionID {
                accessGate.unregisterQuiescenceScope(id: cleanupOpID, sessionID: sessionID)
            }
        }
        return try await VaultLockAdmissionBarrier.$currentOperationID.withValue(cleanupOpID) {
            if try await repository.cleanupInterruptedImportStaging(id: importID) {
                return ["Sources/.import-\(importID.uuidString)"]
            }
            return []
        }
    }
}
