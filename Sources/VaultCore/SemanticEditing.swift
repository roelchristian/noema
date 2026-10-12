import Foundation

extension SemanticPageSnapshot {
    public func replacingText(in blockID: UUID, range: NSRange, with runs: [RichRun]) throws -> SemanticPageEdit {
        var edit = SemanticPageEdit(pageID: snapshot.pageID, document: snapshot.document,
            annotations: annotations.map(\.annotation),
            expectedAnnotationRevisions: Dictionary(uniqueKeysWithValues: annotations.map { ($0.annotation.id, $0.revision) }))
        try edit.replaceText(in: blockID, range: range, with: runs, expectedRevision: snapshot.revision)
        return edit
    }
    public var edit: SemanticPageEdit {
        .init(pageID: snapshot.pageID, document: snapshot.document, annotations: annotations.map(\.annotation),
              expectedAnnotationRevisions: Dictionary(uniqueKeysWithValues: annotations.map { ($0.annotation.id, $0.revision) }))
    }
}

extension SemanticPageEdit {
    func semanticEvidenceDigest() -> String {
        struct Evidence: Encodable { var document: BlockDocument; var annotations: [SemanticAnnotation] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(Evidence(document: document, annotations: annotations))).map(digest) ?? "invalid"
    }
    mutating func recordSemanticMutation(from previous: Self) {
        let baseline = previous.semanticMutationEvidence.flatMap { $0.after == previous.semanticEvidenceDigest() ? $0.before : nil }
        semanticMutationEvidence = .init(before: baseline ?? previous.semanticEvidenceDigest(), after: semanticEvidenceDigest())
    }
    /// A process-local proof covers both canonical content and independent records.
    /// Reusing it after changing either value cannot authorize a resolved anchor.
    public func preparingAnnotationsForPersistence(comparedTo previous: SemanticPageSnapshot) -> Self {
        let before = previous.edit
        if let proof = semanticMutationEvidence, proof.before == before.semanticEvidenceDigest(), proof.after == semanticEvidenceDigest() { return self }
        var value = self
        let originals = Dictionary(uniqueKeysWithValues: before.annotations.map { ($0.id, $0) })
        for index in value.annotations.indices {
            let annotation = value.annotations[index]
            guard annotation.anchorDisposition == .resolved, let blockID = annotation.location.blockID else { continue }
            if document.block(blockID) == nil { value.annotations[index].anchorDisposition = .deleted }
            else if case .inline = annotation.location, let original = originals[annotation.id],
                    original.location.blockID != blockID || previous.snapshot.document.block(blockID)?.text != document.block(blockID)?.text {
                value.annotations[index].location = original.location
                value.annotations[index].expectedRevision = original.expectedRevision
                value.annotations[index].anchorDisposition = .stale
            }
        }
        value.semanticMutationEvidence = nil
        return value
    }
    private func projectedDocument(expectedRevision: BlockStoreRevision) throws -> BlockDocument {
        var value = document
        var projection: [JSONValue] = []
        var ids = Set<UUID>()
        for annotation in annotations {
            guard ids.insert(annotation.id).inserted else { throw PersistencePayloadError.invalidAnnotation }
            guard annotation.location.pageID == nil || annotation.location.pageID == pageID else { throw PersistencePayloadError.invalidAnnotation }
            if annotation.anchorDisposition == .resolved, annotation.location.pageID != nil,
               annotation.expectedRevision != expectedRevision.token { throw PersistencePayloadError.invalidAnnotation }
            guard case .inline(let pageID, let blockID, let target) = annotation.location else { continue }
            var inline = InlineAnnotation(id: annotation.id, pageID: pageID, blockID: blockID,
                designation: annotation.designation, expectedRevision: annotation.expectedRevision,
                target: target, disposition: annotation.anchorDisposition)
            inline.targetEntity = annotation.referent.identity; inline.payload = annotation.payload
            inline.createdAt = annotation.createdAt; inline.modifiedAt = annotation.modifiedAt
            projection.append(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(inline)))
        }
        var payload = value.extensions ?? .init()
        if !payload.requiredFeatures.contains("annotationsV1") { payload.requiredFeatures.append("annotationsV1") }
        payload.properties["annotations"] = .array(projection); value.extensions = payload
        return value
    }
    private mutating func acceptProjection(_ projected: BlockDocument, original: Self) throws {
        guard case .array(let values) = projected.extensions?.properties["annotations"] else { throw PersistencePayloadError.invalidAnnotation }
        let transformed = try Dictionary(uniqueKeysWithValues: values.map { value in
            let inline = try JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value))
            return (inline.id, inline)
        })
        document = projected
        document.extensions = original.document.extensions
        // Export-only legacy projection, when present, follows the independent set.
        if case .array(let legacy) = original.document.extensions?.properties["annotations"] {
            document.extensions?.properties["annotations"] = .array(try legacy.map { value in
                guard let old = try? JSONDecoder().decode(InlineAnnotation.self, from: JSONEncoder().encode(value)), let updated = transformed[old.id],
                      case .object(var fields) = value, case .object(let updates) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(updated)) else { return value }
                fields.merge(updates) { _, replacement in replacement }; return .object(fields)
            })
        }
        for index in annotations.indices {
            if let inline = transformed[annotations[index].id] {
                annotations[index].location = .inline(pageID: inline.pageID, blockID: inline.blockID, target: inline.target)
                annotations[index].anchorDisposition = inline.disposition; annotations[index].modifiedAt = inline.modifiedAt
            } else if annotations[index].anchorDisposition == .resolved, let blockID = annotations[index].location.blockID, document.block(blockID) == nil {
                annotations[index].anchorDisposition = .deleted
            }
        }
        document.recordAnnotationMutation(from: original.document)
        recordSemanticMutation(from: original)
    }
    public mutating func replaceText(in blockID: UUID, range: NSRange, with runs: [RichRun], expectedRevision: BlockStoreRevision) throws {
        let original = self
        var projected = try projectedDocument(expectedRevision: expectedRevision)
        try projected.replaceText(in: blockID, range: range, with: runs, expectedRevision: expectedRevision)
        var staged = self; try staged.acceptProjection(projected, original: original); self = staged
    }
    /// Structural mutations reuse the same grapheme-safe editor transformations.
    /// Duplication has a separate API because anchored objects need explicit input.
    @discardableResult public mutating func apply(_ mutation: BlockMutation, to blockID: UUID, expectedRevision: BlockStoreRevision) throws -> BlockCursor? {
        if case .duplicate = mutation { return try duplicateBlock(blockID, objects: [], expectedRevision: expectedRevision) }
        let original = self
        var projected = try projectedDocument(expectedRevision: expectedRevision)
        guard let cursor = projected.apply(mutation, to: blockID) else { return nil }
        var staged = self; try staged.acceptProjection(projected, original: original); self = staged
        return cursor
    }
    /// Restore a coherent semantic snapshot while comparing the current annotation
    /// revisions. The store allocates fresh canonical revisions after publication.
    public func restoring(_ snapshot: SemanticPageSnapshot, expectedRevision: BlockStoreRevision) throws -> Self {
        guard snapshot.snapshot.pageID == pageID else { throw PersistencePayloadError.invalidAnnotation }
        var value = self
        value.document = snapshot.snapshot.document.advancingAnnotationRevision(to: expectedRevision)
        value.annotations = snapshot.annotations.map(\.annotation)
        for index in value.annotations.indices where value.annotations[index].anchorDisposition == .resolved {
            value.annotations[index].expectedRevision = expectedRevision.token
            if case .inline(let pageID, let blockID, var target) = value.annotations[index].location {
                target.digest = InlineAnnotationTarget.evidence(quote: target.quote, revision: expectedRevision.token)
                value.annotations[index].location = .inline(pageID: pageID, blockID: blockID, target: target)
            }
        }
        try value.document.validateWritablePayloads()
        value.document.recordAnnotationMutation(from: document)
        value.recordSemanticMutation(from: self)
        return value
    }
    public func duplicatedPage(to newPageID: UUID = UUID(), objects: [SemanticObjectSnapshot]) throws -> Self {
        guard newPageID != pageID else { throw PersistencePayloadError.invalidAnnotation }
        var result = self, blockIDs: [UUID: UUID] = [:]
        func fresh(_ block: EditorBlock) -> EditorBlock {
            var copy = block; copy.id = UUID(); blockIDs[block.id] = copy.id
            copy.createdAt = Date(); copy.modifiedAt = copy.createdAt; copy.children = block.children.map(fresh); return copy
        }
        result.document.blocks = document.blocks.map(fresh)
        result.document.originalSource = nil
        result.document.extensions?.properties.removeValue(forKey: "annotations")
        result.pageID = newPageID; result.expectedAnnotationRevisions = [:]; result.objects = []
        result.annotations = try copiedAnnotations(blockIDs: blockIDs, pageID: newPageID, objects: objects, copiedObjects: &result.objects)
        result.semanticMutationEvidence = nil
        return result
    }
    @discardableResult public mutating func duplicateBlock(_ blockID: UUID, objects: [SemanticObjectSnapshot], expectedRevision: BlockStoreRevision) throws -> BlockCursor? {
        let original = self
        _ = try projectedDocument(expectedRevision: expectedRevision)
        guard let source = document.block(blockID) else { throw PersistencePayloadError.invalidAnnotation }
        var staged = self
        guard let cursor = staged.document.apply(.duplicate, to: blockID), let copied = staged.document.block(cursor.id) else { return nil }
        var blockIDs: [UUID: UUID] = [:]
        func pair(_ source: EditorBlock, _ copy: EditorBlock) {
            blockIDs[source.id] = copy.id
            for (a, b) in zip(source.children, copy.children) { pair(a, b) }
        }
        pair(source, copied)
        staged.annotations += try copiedAnnotations(blockIDs: blockIDs, pageID: pageID, objects: objects, copiedObjects: &staged.objects)
        staged.document.extensions?.properties.removeValue(forKey: "annotations")
        staged.document.recordAnnotationMutation(from: original.document)
        staged.recordSemanticMutation(from: original); self = staged
        return cursor
    }
    private func copiedAnnotations(blockIDs: [UUID: UUID], pageID: UUID, objects: [SemanticObjectSnapshot], copiedObjects: inout [SemanticObject]) throws -> [SemanticAnnotation] {
        guard Set(objects.map { $0.object.id }).count == objects.count else { throw PersistencePayloadError.invalidAnnotation }
        let available = Dictionary(uniqueKeysWithValues: objects.map { ($0.object.id, $0.object) })
        var objectIDs: [UUID: UUID] = [:], copies: [SemanticAnnotation] = []
        for original in annotations {
            guard let oldBlock = original.location.blockID, let newBlock = blockIDs[oldBlock] else { continue }
            var copy = original; copy.id = UUID(); copy.createdAt = Date(); copy.modifiedAt = copy.createdAt
            copy.expectedRevision = pageID == self.pageID || copy.anchorDisposition != .resolved ? original.expectedRevision : Data()
            switch original.location {
            case .wholeBlock: copy.location = .wholeBlock(pageID: pageID, blockID: newBlock)
            case .inline(_, _, var target):
                if copy.anchorDisposition == .resolved { target.digest = InlineAnnotationTarget.evidence(quote: target.quote, revision: copy.expectedRevision) }
                copy.location = .inline(pageID: pageID, blockID: newBlock, target: target)
            default: continue
            }
            var provenance = copy.payload ?? .init()
            provenance.properties["copiedFromAnnotationID"] = .string(original.id.uuidString)
            provenance.properties["copiedFromPageID"] = .string(self.pageID.uuidString)
            provenance.properties["copiedFromBlockID"] = .string(oldBlock.uuidString); copy.payload = provenance
            let identity = original.referent.identity
            if ["question", "definition"].contains(identity.kind), ["question", "definition"].contains(original.designation), original.referent.disposition != .unresolved {
                if objectIDs[identity.id] == nil {
                    guard var object = available[identity.id] else { throw KnowledgeStoreError.notFound(identity.id) }
                    let newID = UUID(); objectIDs[identity.id] = newID; object.id = newID
                    object.createdAt = Date(); object.modifiedAt = object.createdAt
                    object.properties.properties["copiedFromObjectID"] = .string(identity.id.uuidString)
                    copiedObjects.append(object)
                }
                copy.referent.identity.id = objectIDs[identity.id]!
            }
            if ["question", "definition"].contains(identity.kind), !["question", "definition", "reference"].contains(original.designation) {
                copy.referent.disposition = .unresolved
                var payload = copy.referent.payload ?? .init()
                payload.properties["copiedTargetKind"] = .string(identity.kind)
                payload.properties["copiedTargetID"] = .string(identity.id.uuidString)
                copy.referent.payload = payload
            }
            copies.append(copy)
        }
        return copies
    }
}
