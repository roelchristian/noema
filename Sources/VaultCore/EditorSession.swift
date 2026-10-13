import Foundation

/// The editable document is owned here; Markdown is an asynchronous export format.
@MainActor public final class EditorSession {
    public struct Identity: Equatable, Sendable {
        public var pageID: UUID?
        public var vaultID: UUID?
        public var sessionID: UUID?
        public init(pageID: UUID? = nil, vaultID: UUID? = nil, sessionID: UUID? = nil) { self.pageID = pageID; self.vaultID = vaultID; self.sessionID = sessionID }
    }
    public struct DocumentSnapshot: Sendable {
        public let identity: Identity
        public let generation: UUID
        public let revision: UInt64
        public let document: BlockDocument
        public let selection: NSRange
        public let semanticEdit: SemanticPageEdit?
        public let expectedEntityRevisions: [UUID: BlockStoreRevision]
        public let expectedObjectRevisions: [UUID: BlockStoreRevision]
        public let pageRevision: BlockStoreRevision?
        fileprivate let semanticBaseline: SemanticPageSnapshot?
    }
    public struct Mutation: Sendable {
        public let revision: UInt64
        public let name: String
        public let changedBlockIDs: Set<UUID>
        public let selection: NSRange
    }
    public private(set) var document: BlockDocument
    public private(set) var identity: Identity
    public private(set) var revision: UInt64 = 0
    public private(set) var generation = UUID()
    public var selection = NSRange(location: 0, length: 0)
    public private(set) var changedBlockIDs = Set<UUID>()
    public private(set) var mutationHistory: [Mutation] = []
    public private(set) var publishedRevision: UInt64 = 0
    public private(set) var semanticEdit: SemanticPageEdit?
    public private(set) var pageRevision: BlockStoreRevision?
    public private(set) var expectedEntityRevisions: [UUID: BlockStoreRevision] = [:]
    public private(set) var expectedObjectRevisions: [UUID: BlockStoreRevision] = [:]
    private var semanticBaseline: SemanticPageSnapshot?

    public init(document: BlockDocument = .init(), identity: Identity = .init()) {
        self.document = document; self.identity = identity
    }
    public func load(_ document: BlockDocument, identity: Identity, selection: NSRange) {
        self.document = document; self.identity = identity; self.selection = selection
        generation = UUID(); revision = 0; publishedRevision = 0
        changedBlockIDs.removeAll(); mutationHistory.removeAll()
        semanticEdit = nil; pageRevision = nil; semanticBaseline = nil
        expectedEntityRevisions = [:]; expectedObjectRevisions = [:]
    }
    public func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(identity: identity, generation: generation, revision: revision, document: document, selection: selection, semanticEdit: semanticEdit, expectedEntityRevisions: expectedEntityRevisions, expectedObjectRevisions: expectedObjectRevisions, pageRevision: pageRevision, semanticBaseline: semanticBaseline)
    }
    /// Resume an immutable in-memory draft when returning to a page before its save completes.
    public func restorePendingSnapshot(_ snapshot: DocumentSnapshot, identity: Identity) {
        guard snapshot.identity == identity else { return }
        load(snapshot.document, identity: identity, selection: snapshot.selection)
        revision = snapshot.revision
        semanticEdit = snapshot.semanticEdit; pageRevision = snapshot.pageRevision
        semanticBaseline = snapshot.semanticBaseline
        expectedEntityRevisions = snapshot.expectedEntityRevisions
        expectedObjectRevisions = snapshot.expectedObjectRevisions
    }

    /// Advance only evidence from an acknowledged predecessor save; retain newer local edits.
    public func rebaseSemanticEvidence(_ saved: SemanticPageSnapshot) {
        guard saved.snapshot.pageID == identity.pageID else { return }
        pageRevision = saved.snapshot.revision; semanticBaseline = saved
        expectedObjectRevisions.merge(Dictionary(uniqueKeysWithValues: saved.objects.map { ($0.object.id, $0.revision) })) { _, saved in saved }
        if var edit = semanticEdit {
            edit.expectedAnnotationRevisions = saved.edit.expectedAnnotationRevisions
            for index in edit.annotations.indices where edit.annotations[index].anchorDisposition == .resolved {
                edit.annotations[index].expectedRevision = saved.snapshot.revision.token
                if case .inline(let page, let block, var target) = edit.annotations[index].location {
                    target.digest = InlineAnnotationTarget.evidence(quote: target.quote, revision: saved.snapshot.revision.token)
                    edit.annotations[index].location = .inline(pageID: page, blockID: block, target: target)
                }
            }
            edit.recordSemanticMutation(from: saved.edit); semanticEdit = edit
        }
    }

    public func accepts(_ snapshot: DocumentSnapshot) -> Bool {
        snapshot.identity == identity && snapshot.generation == generation && snapshot.revision == revision && snapshot.revision > publishedRevision
    }
    @discardableResult public func markPublished(_ snapshot: DocumentSnapshot) -> Bool {
        guard accepts(snapshot) else { return false }
        publishedRevision = snapshot.revision; changedBlockIDs.removeAll(); return true
    }
    /// Used for native typing. Only the active block is inspected and mutated.
    public func updateRuns(_ id: UUID, runs: [RichRun], selection: NSRange, name: String = "Typing") {
        guard !document.unsupportedVersion, let block = document.block(id), block.runs != runs else { self.selection = selection; return }
        var value = document
        value.update(id) { $0.runs = runs }
        replaceDocument(value, selection: selection, name: name)
    }
    public func replaceDocument(_ value: BlockDocument, selection: NSRange? = nil, name: String = "Edit blocks") {
        guard value != document else { return }
        let old = Dictionary(uniqueKeysWithValues: document.flattened.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: value.flattened.map { ($0.id, $0) })
        let oldOrder = Dictionary(uniqueKeysWithValues: document.flattened.enumerated().map { ($0.element.id, $0.offset) })
        let newOrder = Dictionary(uniqueKeysWithValues: value.flattened.enumerated().map { ($0.element.id, $0.offset) })
        func parents(_ blocks: [EditorBlock], parent: UUID? = nil) -> [UUID: UUID] {
            var result: [UUID: UUID] = [:]
            for block in blocks {
                if let parent { result[block.id] = parent }
                result.merge(parents(block.children, parent: block.id)) { _, new in new }
            }
            return result
        }
        let oldParents = parents(document.blocks), newParents = parents(value.blocks)
        let ids = Set(old.keys).union(new.keys).filter {
            old[$0] != new[$0] || oldOrder[$0] != newOrder[$0] || oldParents[$0] != newParents[$0]
        }
        if var edit = semanticEdit, let baseline = semanticBaseline {
            edit.document = value
            semanticEdit = edit.preparingAnnotationsForPersistence(comparedTo: baseline)
        }
        document = value; record(name, ids: Set(ids), selection: selection ?? self.selection)
    }
    @discardableResult public func apply(_ mutation: BlockMutation, to id: UUID, name: String = "Edit block") -> BlockCursor? {
        guard !document.unsupportedVersion else { return nil }
        if var edit = semanticEdit, let pageRevision {
            guard let cursor = try? edit.apply(mutation, to: id, expectedRevision: pageRevision) else { return nil }
            commitSemantic(edit, name: name, selection: selection)
            return cursor
        }
        var value = document
        let cursor = value.apply(mutation, to: id)
        replaceDocument(value, name: name)
        return cursor
    }
    public func replaceText(_ id: UUID, range: NSRange, runs: [RichRun], selection: NSRange) {
        let revisions: Set<Data>
        if case .array(let values) = document.extensions?.properties["annotations"] {
            revisions = Set(values.compactMap { value in
                guard let bytes = try? JSONEncoder().encode(value), let annotation = try? JSONDecoder().decode(InlineAnnotation.self, from: bytes), annotation.disposition == .resolved else { return nil }
                return annotation.expectedRevision
            })
        } else { revisions = [] }
        guard revisions.count <= 1 else { return }
        try? replaceText(id, range: range, runs: runs, selection: selection, expectedRevision: .init(token: revisions.first ?? Data()))
    }
    /// Exact editor input carries store-issued revision evidence independently of
    /// the local session counter. Work on a value so failures cannot publish text.
    public func replaceText(_ id: UUID, range: NSRange, runs: [RichRun], selection: NSRange, expectedRevision: BlockStoreRevision) throws {
        if var edit = semanticEdit, let pageRevision {
            try edit.replaceText(in: id, range: range, with: runs, expectedRevision: pageRevision)
            commitSemantic(edit, name: "Replace text", selection: selection)
            return
        }
        var value = document
        try value.replaceText(in: id, range: range, with: runs, expectedRevision: expectedRevision)
        replaceDocument(value, selection: selection, name: "Replace text")
    }
    public func restore(_ snapshot: DocumentSnapshot, name: String) {
        guard snapshot.identity == identity, snapshot.generation == generation else { return }
        if let old = snapshot.semanticEdit, let current = semanticEdit, let pageRevision {
            let saved = SemanticPageSnapshot(snapshot: .init(pageID: current.pageID, document: old.document, revision: pageRevision), annotations: old.annotations.map { .init(annotation: $0, revision: current.expectedAnnotationRevisions[$0.id] ?? .init(token: Data())) })
            guard var restored = try? current.restoring(saved, expectedRevision: pageRevision) else { return }
            restored.objects = old.objects.filter { expectedObjectRevisions[$0.id] == nil }
            expectedEntityRevisions.merge(snapshot.expectedEntityRevisions) { current, _ in current }
            expectedObjectRevisions.merge(snapshot.expectedObjectRevisions) { current, _ in current }
            commitSemantic(restored, name: name, selection: snapshot.selection)
            return
        }
        var restored = snapshot.document
        restored.annotationMutationEvidence = .init(before: document.annotationEvidenceDigest(), after: restored.annotationEvidenceDigest())
        replaceDocument(restored, selection: snapshot.selection, name: name)
        selection = snapshot.selection
    }
    /// Undo after a canonical save rebases resolved evidence to the current page
    /// token; the next store save still allocates a fresh canonical revision.
    public func restore(_ snapshot: DocumentSnapshot, name: String, expectedRevision: BlockStoreRevision) throws {
        guard snapshot.identity == identity, snapshot.generation == generation else { return }
        var restored = snapshot.document.advancingAnnotationRevision(to: expectedRevision)
        try restored.validateWritablePayloads()
        restored.annotationMutationEvidence = .init(before: document.annotationEvidenceDigest(), after: restored.annotationEvidenceDigest())
        replaceDocument(restored, selection: snapshot.selection, name: name)
        selection = snapshot.selection
    }
    public func load(_ snapshot: SemanticPageSnapshot, identity: Identity, selection: NSRange,
                     expectedEntityRevisions: [UUID: BlockStoreRevision] = [:], expectedObjectRevisions: [UUID: BlockStoreRevision] = [:]) {
        load(snapshot.snapshot.document, identity: identity, selection: selection)
        semanticBaseline = snapshot; semanticEdit = snapshot.edit; pageRevision = snapshot.snapshot.revision
        self.expectedEntityRevisions = expectedEntityRevisions; self.expectedObjectRevisions = expectedObjectRevisions
        self.expectedObjectRevisions.merge(Dictionary(uniqueKeysWithValues: snapshot.objects.map { ($0.object.id, $0.revision) })) { _, snapshot in snapshot }
    }
    /// Publication advances store evidence without incrementing the local mutation counter.
    @discardableResult public func acceptSemanticPublication(_ saved: SemanticPageSnapshot, for snapshot: DocumentSnapshot) -> Bool {
        guard snapshot.identity == identity, snapshot.generation == generation, saved.snapshot.pageID == identity.pageID else { return false }
        pageRevision = saved.snapshot.revision; semanticBaseline = saved
        expectedObjectRevisions.merge(Dictionary(uniqueKeysWithValues: saved.objects.map { ($0.object.id, $0.revision) })) { _, saved in saved }
        if revision == snapshot.revision { document = saved.snapshot.document; semanticEdit = saved.edit }
        else if var edit = semanticEdit {
            edit.expectedAnnotationRevisions = saved.edit.expectedAnnotationRevisions
            for index in edit.annotations.indices where edit.annotations[index].anchorDisposition == .resolved {
                edit.annotations[index].expectedRevision = saved.snapshot.revision.token
                if case .inline(let page, let block, var target) = edit.annotations[index].location {
                    target.digest = InlineAnnotationTarget.evidence(quote: target.quote, revision: saved.snapshot.revision.token)
                    edit.annotations[index].location = .inline(pageID: page, blockID: block, target: target)
                }
            }
            edit.recordSemanticMutation(from: saved.edit); semanticEdit = edit
        }
        return true
    }
    /// A successful canonical target edit refreshes its evidence for subsequent page saves.
    public func acceptReferentRevision(_ identity: EntityIdentity, revision: BlockStoreRevision) {
        if ["question", "definition"].contains(identity.kind) { expectedObjectRevisions[identity.id] = revision }
        else { expectedEntityRevisions[identity.id] = revision }
    }
    public func annotationSelection(blockID: UUID, range: NSRange) throws -> InlineAnnotationTarget {
        guard !document.unsupportedVersion, let pageRevision, semanticEdit != nil,
              let block = document.block(blockID), range.length > 0 else { throw PersistencePayloadError.invalidAnnotation }
        return try InlineAnnotationTarget(text: block.text, range: range, revision: pageRevision.token)
    }
    @discardableResult public func applyAnnotation(_ command: EditorAnnotationCommand, expectedLocalRevision: UInt64,
                                                 expectedReferentRevision: BlockStoreRevision? = nil) throws -> UUID {
        guard expectedLocalRevision == revision else { throw KnowledgeStoreError.staleRevision }
        guard var edit = semanticEdit, let pageRevision, !document.unsupportedVersion else { throw PersistencePayloadError.invalidAnnotation }
        let original = edit
        let id: UUID
        switch command {
        case .create(let blockID, let range, let referent, let designation, let startAffinity, let endAffinity):
            var target = try annotationSelection(blockID: blockID, range: range)
            target.startAffinity = startAffinity; target.endAffinity = endAffinity
            let annotation = SemanticAnnotation(location: .inline(pageID: edit.pageID, blockID: blockID, target: target), referent: referent,
                                                designation: designation, expectedRevision: pageRevision.token)
            id = annotation.id; edit.annotations.append(annotation)
        case .replace(let annotationID, let referent, let designation):
            guard let index = edit.annotations.firstIndex(where: { $0.id == annotationID }) else { throw KnowledgeStoreError.notFound(annotationID) }
            id = annotationID; edit.annotations[index].referent = referent; edit.annotations[index].designation = designation; edit.annotations[index].modifiedAt = Date()
        case .remove(let annotationID):
            guard let index = edit.annotations.firstIndex(where: { $0.id == annotationID }) else { throw KnowledgeStoreError.notFound(annotationID) }
            id = annotationID; edit.annotations[index].anchorDisposition = .deleted; edit.annotations[index].modifiedAt = Date()
        }
        if let annotation = edit.annotations.first(where: { $0.id == id }), annotation.anchorDisposition != .deleted, annotation.referent.disposition != .unresolved {
            let identity = annotation.referent.identity
            if let expectedReferentRevision {
                if ["question", "definition"].contains(identity.kind) { expectedObjectRevisions[identity.id] = expectedReferentRevision }
                else { expectedEntityRevisions[identity.id] = expectedReferentRevision }
            } else if !edit.objects.contains(where: { $0.id == identity.id && $0.typeKey == identity.kind }) {
                throw KnowledgeStoreError.staleRevision
            }
        }
        edit.recordSemanticMutation(from: original)
        commitSemantic(edit, name: "Annotate selection", selection: selection)
        return id
    }
    public func stageAnnotationObject(_ object: SemanticObject) throws {
        try object.validateWritable()
        guard var edit = semanticEdit, !edit.objects.contains(where: { $0.id == object.id }),
              object.relatedEntityIDs.isEmpty, object.subjectEntityID == nil else { throw PersistencePayloadError.invalidAnnotation }
        edit.objects.append(object)
        edit.recordSemanticMutation(from: semanticEdit!)
        commitSemantic(edit, name: "Create semantic object", selection: selection)
    }
    private func commitSemantic(_ edit: SemanticPageEdit, name: String, selection: NSRange) {
        let previous = semanticEdit
        semanticEdit = nil
        if document != edit.document { replaceDocument(edit.document, selection: selection, name: name) }
        else if previous != edit { record(name, ids: Set(edit.annotations.compactMap { $0.location.blockID }), selection: selection) }
        semanticEdit = edit
    }
    private func record(_ name: String, ids: Set<UUID>, selection: NSRange) {
        revision &+= 1; self.selection = selection; changedBlockIDs.formUnion(ids)
        mutationHistory.append(Mutation(revision: revision, name: name, changedBlockIDs: ids, selection: selection))
        // Native NSUndoManager owns undo payloads; this bounded journal describes revisions.
        if mutationHistory.count > 256 { mutationHistory.removeFirst(mutationHistory.count - 256) }
    }
}

public enum EditorAnnotationCommand: Sendable {
    case create(blockID: UUID, range: NSRange, referent: SemanticReferent, designation: String,
                startAffinity: AnnotationAffinity = .after, endAffinity: AnnotationAffinity = .before)
    case replace(annotationID: UUID, referent: SemanticReferent, designation: String)
    case remove(annotationID: UUID)
}
