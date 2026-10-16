import Foundation
import NaturalLanguage
import Yams

public enum EmbeddingInputPreparationError: Error, Sendable, Equatable {
    case staleRevision, unsupportedDocument, unsupportedSourceType, unavailableOriginal, unsupportedLanguage
}

/// A committed, transient input snapshot. Neither text nor original-byte evidence is ledger data.
/// Capturing this value grants no inference or publication authority.
public struct EmbeddingPreparedInputSnapshot: AIWorkSnapshot, Sendable {
    public let identity: EmbeddingEntityIdentity
    public let canonicalRevision: BlockStoreRevision
    public let model: EmbeddingModelDescriptor
    public let inputs: [EmbeddingChunkInput]
    public var revision: String { workRevision ?? identity.revision }
    public var inputFingerprint: String {
        // Include structural identity and ordered fingerprints, including the empty document case.
        digest(Data(inputs.map { $0.chunk.chunkID + ":" + $0.chunk.contentFingerprint }.joined(separator: "\n").utf8))
    }
    let sourceEvidence: SourceSummarySnapshot?
    var workRevision: String? = nil
}

/// Pure provider admission. Model selection, batches and prepared inputs are never cloud permission.
public enum EmbeddingInputPreparation {
    static func nativeLanguage(_ model: EmbeddingModelDescriptor) -> String? {
        guard model.providerID == "apple-natural-language", model.modelID.hasPrefix("sentence-"),
              model.modelID.hasSuffix("-input-v1") else { return nil }
        return String(model.modelID.dropFirst("sentence-".count).dropLast("-input-v1".count))
    }

    public static func page(_ document: BlockDocument, identity: EmbeddingEntityIdentity,
                            model: EmbeddingModelDescriptor) throws -> [EmbeddingChunkInput] {
        guard !document.unsupportedVersion else { throw EmbeddingInputPreparationError.unsupportedDocument }
        return try admit(EmbeddingChunker.page(document, identity: identity, model: model), model: model)
    }

    /// Complete extracted original text is required. Source paragraph IDs remain positional.
    public static func source(extractedOriginalText: String, identity: EmbeddingEntityIdentity,
                              model: EmbeddingModelDescriptor) throws -> [EmbeddingChunkInput] {
        // Frontmatter belongs to local source metadata, not the submitted original body.
        var originalBody = extractedOriginalText.replacingOccurrences(of: "\r\n", with: "\n")
        if originalBody.hasPrefix("---\n") {
            let lines = originalBody.components(separatedBy: "\n")
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                let header = lines[1..<end].joined(separator: "\n")
                // Delimiter-like prose is original content. Only a valid YAML mapping is metadata.
                if let node = try? Yams.compose(yaml: header), node.mapping != nil {
                    originalBody = lines.dropFirst(end + 1).joined(separator: "\n")
                }
            }
        }
        var document = BlockDocumentCodec.decode(originalBody)
        guard !document.unsupportedVersion else { throw EmbeddingInputPreparationError.unsupportedDocument }
        let hasGenerated = document.flattened.contains { $0.metadata.extra["aiGenerated"] == "true" }
        func excludingGenerated(_ blocks: [EditorBlock]) -> [EditorBlock] {
            blocks.compactMap { block in
                guard block.metadata.extra["aiGenerated"] != "true" else { return nil }
                var copy = block; copy.children = excludingGenerated(block.children); return copy
            }
        }
        document.blocks = excludingGenerated(document.blocks)
        // Preserve original paragraph boundaries unless structural filtering is actually needed.
        let text = hasGenerated ? BlockDocumentCodec.readable(document) : BlockDocumentCodec.markdownBody(originalBody)
        return try admit(EmbeddingChunker.source(originalText: text, identity: identity, model: model), model: model)
    }

    private static func admit(_ inputs: [EmbeddingChunkInput], model: EmbeddingModelDescriptor) throws -> [EmbeddingChunkInput] {
        for input in inputs {
            guard input.text.utf8.count <= model.maximumInputUTF8Bytes else { throw EmbeddingContractError.invalidInput }
            if let language = nativeLanguage(model) {
                guard NLLanguageRecognizer.dominantLanguage(for: input.text)?.rawValue == language else {
                    throw EmbeddingInputPreparationError.unsupportedLanguage
                }
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.setLanguage(NLLanguage(rawValue: language)); tokenizer.string = input.text
                var count = 0
                tokenizer.enumerateTokens(in: input.text.startIndex..<input.text.endIndex) { _, _ in count += 1; return count <= 128 }
                guard count > 0, count <= 128 else { throw EmbeddingContractError.invalidInput }
            }
        }
        return inputs
    }

    /// Every returned batch needs independently minted exact-request authority for cloud dispatch.
    public static func requestBatches(_ inputs: [EmbeddingChunkInput], model: EmbeddingModelDescriptor) -> [[EmbeddingChunkInput]] {
        stride(from: 0, to: inputs.count, by: model.maximumBatchSize).map {
            Array(inputs[$0..<min($0 + model.maximumBatchSize, inputs.count)])
        }
    }

    /// Retain only exact compatible structural chunks, rebinding metadata to the new document revision.
    /// The caller still needs the canonical-owned permit spanning the eventual derived commit.
    public static func reusableRecords(_ existing: [EmbeddingRecord], for snapshot: EmbeddingPreparedInputSnapshot,
                                       generation: EmbeddingIndexGeneration) throws -> [EmbeddingRecord] {
        guard generation.model == snapshot.model, generation.vaultID == snapshot.identity.vaultID,
              generation.chunkingVersion == EmbeddingChunker.version else { throw EmbeddingContractError.incompatibleGeneration }
        let candidates = Dictionary(existing.filter {
            $0.generation == generation && $0.chunk.identity.entityKind == snapshot.identity.entityKind &&
            $0.chunk.identity.entityID == snapshot.identity.entityID
        }.map { ($0.chunk.chunkID, $0) }, uniquingKeysWith: { first, _ in first })
        return try snapshot.inputs.compactMap { input in
            guard let previous = candidates[input.chunk.chunkID],
                  previous.chunk.contentFingerprint == input.chunk.contentFingerprint,
                  previous.chunk.chunkingVersion == input.chunk.chunkingVersion else { return nil }
            return try EmbeddingRecord(generation: generation, chunk: input.chunk, vector: previous.vector)
        }
    }
}

extension FileVaultRepository {
    public func embeddingPageSnapshot(id: UUID, expectedRevision: String,
                                      model: EmbeddingModelDescriptor) async throws -> EmbeddingPreparedInputSnapshot {
        try validateAccess(operation: "embedding.page.prepare")
        try Task.checkCancellation()
        let current = try await sqliteBlockStore.loadPage(pageID: id)
        guard current.snapshot.revision.token.base64EncodedString() == expectedRevision,
              !current.record.relativePath.hasPrefix("sqlite/trash-"),
              !current.record.relativePath.hasPrefix("sqlite/undated-trash-") else { throw EmbeddingInputPreparationError.staleRevision }
        let identity = try EmbeddingEntityIdentity(vaultID: manifest.id, entityKind: .page, entityID: id, revision: expectedRevision)
        let inputs = try EmbeddingInputPreparation.page(current.snapshot.document, identity: identity, model: model)
        try validateAccess(operation: "embedding.page.prepared")
        return .init(identity: identity, canonicalRevision: current.snapshot.revision, model: model, inputs: inputs, sourceEvidence: nil)
    }

    /// Extraction is injected so PDF/HTML original consumers can retain their existing adapters.
    /// It must extract all original content, never a cached excerpt or generated source summary.
    public func embeddingSourceSnapshot(id: UUID, expectedRevision: String, model: EmbeddingModelDescriptor,
        extractOriginal: @Sendable (SourceSummarySnapshot) throws -> String
    ) async throws -> EmbeddingPreparedInputSnapshot {
        let evidence = try await sourceSummarySnapshot(id: id)
        guard let revision = evidence.canonicalRevision else { throw EmbeddingInputPreparationError.staleRevision }
        let canonicalRevision = revision.token.base64EncodedString()
        // External-original events bind both canonical metadata and the newly verified bytes.
        guard expectedRevision == canonicalRevision || expectedRevision == canonicalRevision + ":" + digest(evidence.original) else {
            throw EmbeddingInputPreparationError.staleRevision
        }
        let identity = try EmbeddingEntityIdentity(vaultID: manifest.id, entityKind: .source, entityID: id, revision: canonicalRevision)
        let inputs = try EmbeddingInputPreparation.source(extractedOriginalText: extractOriginal(evidence), identity: identity, model: model)
        try await validateSourceSnapshot(evidence)
        return .init(identity: identity, canonicalRevision: revision, model: model, inputs: inputs, sourceEvidence: evidence, workRevision: expectedRevision)
    }

    /// Revalidates linked bytes and canonical metadata. An external writer can still change a linked
    /// file after this read: no transaction spans externally owned bytes and the semantic database.
    /// This check is preparation evidence, never a replacement for final canonical commit protection.
    public func validateEmbeddingSnapshot(_ snapshot: EmbeddingPreparedInputSnapshot) async throws {
        try validateAccess(operation: "embedding.snapshot.validate")
        guard snapshot.identity.vaultID == manifest.id else { throw EmbeddingContractError.authorityDenied }
        if let evidence = snapshot.sourceEvidence { try await validateSourceSnapshot(evidence) }
        else {
            let current = try await sqliteBlockStore.loadPage(pageID: snapshot.identity.entityID)
            guard current.snapshot.revision == snapshot.canonicalRevision else { throw EmbeddingInputPreparationError.staleRevision }
        }
        try validateAccess(operation: "embedding.snapshot.validated")
    }
}
