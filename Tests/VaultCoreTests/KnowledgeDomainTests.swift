import Foundation
import Testing
@testable import VaultCore

struct KnowledgeDomainTests {
    @Test func testPatchPreservesIdentityAliasesAndOpaqueFields() throws {
        var entity = KnowledgeEntity(typeKey: "person", label: "Napoleon", aliases: [.init(label: "Emperor")],
                                     properties: .init(properties: ["future": .array([.number(7), .null])]))
        entity.unknownFields["futureRecord"] = .object(["value": .bool(true)])
        entity.properties.unknownFields["futurePayload"] = .string("retain")
        let revised = try KnowledgeEntityPatch(label: "Napoleon Bonaparte", properties: ["known": .string("new")]).applying(to: entity)
        #expect(revised.id == entity.id)
        #expect(revised.aliases == entity.aliases)
        #expect(revised.unknownFields == entity.unknownFields)
        #expect(revised.properties.unknownFields == entity.properties.unknownFields)
        #expect(revised.properties.properties["future"] == entity.properties.properties["future"])
        #expect(try JSONDecoder().decode(KnowledgeEntity.self, from: JSONEncoder().encode(revised)) == revised)
    }

    @Test func testWritableValidationRejectsUnknownRequiredSemanticsAndIdentityProperties() throws {
        expectThrows { try KnowledgeEntity(typeKey: "future", label: "Known label").validateWritable() } verify: {
            #expect($0 as? KnowledgeStoreError == .unknownType("future"))
        }
        expectThrows { try KnowledgeEntity(typeKey: "person", label: " \n ").validateWritable() }
        expectThrows { try KnowledgeEntity(typeKey: "person", label: "A", properties: .init(version: 2)).validateWritable() }
        expectThrows { try KnowledgeEntity(typeKey: "person", label: "A", properties: .init(requiredFeatures: ["future"])).validateWritable() }
        expectThrows { try KnowledgeEntity(typeKey: "person", label: "A", properties: .init(properties: ["id": .string("forged")])).validateWritable() }
        expectThrows { try KnowledgeRelation(predicate: "future", sourceID: UUID(), targetID: UUID()).validateWritable() } verify: {
            #expect($0 as? KnowledgeStoreError == .unknownPredicate("future"))
        }
    }

    @Test func testDirectOpaqueFieldsSurviveAllNestedRecords() throws {
        var alias = KnowledgeAlias(label: "A")
        alias.unknownFields["futureAlias"] = .array([.null, .bool(false)])
        var entity = KnowledgeEntity(typeKey: "concept", label: "A", aliases: [alias])
        entity.unknownFields["futureEntity"] = .number(3)
        var relation = KnowledgeRelation(sourceID: entity.id, targetID: UUID())
        relation.unknownFields["futureRelation"] = .object(["nested": .string("retained")])
        #expect(try JSONDecoder().decode(KnowledgeEntity.self, from: JSONEncoder().encode(entity)) == entity)
        #expect(try JSONDecoder().decode(KnowledgeRelation.self, from: JSONEncoder().encode(relation)) == relation)
        entity.unknownFields["label"] = .string("collision")
        expectThrows { try entity.validateWritable() }
        expectThrows { try JSONEncoder().encode(entity) }
    }

    @Test func testDuplicateAliasNamesAllowedButDuplicateAliasIdentityRejected() throws {
        let first = KnowledgeAlias(label: "same")
        let second = KnowledgeAlias(label: "same")
        try KnowledgeEntity(typeKey: "place", label: "same", aliases: [first, second]).validateWritable()
        expectThrows { try KnowledgeEntity(typeKey: "place", label: "same", aliases: [first, first]).validateWritable() }
    }
}

private func expectThrows<T>(_ operation: () throws -> T, verify: (Error) -> Void = { _ in }) {
    do { _ = try operation(); Issue.record("Expected operation to throw") }
    catch { verify(error) }
}
