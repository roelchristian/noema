import XCTest
@testable import VaultCore

final class KnowledgeDomainTests: XCTestCase {
    func testPatchPreservesIdentityAliasesAndOpaqueFields() throws {
        var entity = KnowledgeEntity(typeKey: "person", label: "Napoleon", aliases: [.init(label: "Emperor")],
                                     properties: .init(properties: ["future": .array([.number(7), .null])]))
        entity.unknownFields["futureRecord"] = .object(["value": .bool(true)])
        entity.properties.unknownFields["futurePayload"] = .string("retain")
        let revised = try KnowledgeEntityPatch(label: "Napoleon Bonaparte", properties: ["known": .string("new")]).applying(to: entity)
        XCTAssertEqual(revised.id, entity.id)
        XCTAssertEqual(revised.aliases, entity.aliases)
        XCTAssertEqual(revised.unknownFields, entity.unknownFields)
        XCTAssertEqual(revised.properties.unknownFields, entity.properties.unknownFields)
        XCTAssertEqual(revised.properties.properties["future"], entity.properties.properties["future"])
        XCTAssertEqual(try JSONDecoder().decode(KnowledgeEntity.self, from: JSONEncoder().encode(revised)), revised)
    }

    func testWritableValidationRejectsUnknownRequiredSemanticsAndIdentityProperties() throws {
        XCTAssertThrowsError(try KnowledgeEntity(typeKey: "future", label: "Known label").validateWritable()) {
            XCTAssertEqual($0 as? KnowledgeStoreError, .unknownType("future"))
        }
        XCTAssertThrowsError(try KnowledgeEntity(typeKey: "person", label: " \n ").validateWritable())
        XCTAssertThrowsError(try KnowledgeEntity(typeKey: "person", label: "A", properties: .init(version: 2)).validateWritable())
        XCTAssertThrowsError(try KnowledgeEntity(typeKey: "person", label: "A", properties: .init(requiredFeatures: ["future"])).validateWritable())
        XCTAssertThrowsError(try KnowledgeEntity(typeKey: "person", label: "A", properties: .init(properties: ["id": .string("forged")])).validateWritable())
        XCTAssertThrowsError(try KnowledgeRelation(predicate: "future", sourceID: UUID(), targetID: UUID()).validateWritable()) {
            XCTAssertEqual($0 as? KnowledgeStoreError, .unknownPredicate("future"))
        }
    }

    func testDirectOpaqueFieldsSurviveAllNestedRecords() throws {
        var alias = KnowledgeAlias(label: "A")
        alias.unknownFields["futureAlias"] = .array([.null, .bool(false)])
        var entity = KnowledgeEntity(typeKey: "concept", label: "A", aliases: [alias])
        entity.unknownFields["futureEntity"] = .number(3)
        var relation = KnowledgeRelation(sourceID: entity.id, targetID: UUID())
        relation.unknownFields["futureRelation"] = .object(["nested": .string("retained")])
        XCTAssertEqual(try JSONDecoder().decode(KnowledgeEntity.self, from: JSONEncoder().encode(entity)), entity)
        XCTAssertEqual(try JSONDecoder().decode(KnowledgeRelation.self, from: JSONEncoder().encode(relation)), relation)
        entity.unknownFields["label"] = .string("collision")
        XCTAssertThrowsError(try entity.validateWritable())
        XCTAssertThrowsError(try JSONEncoder().encode(entity))
    }

    func testDuplicateAliasNamesAllowedButDuplicateAliasIdentityRejected() throws {
        let first = KnowledgeAlias(label: "same")
        let second = KnowledgeAlias(label: "same")
        try KnowledgeEntity(typeKey: "place", label: "same", aliases: [first, second]).validateWritable()
        XCTAssertThrowsError(try KnowledgeEntity(typeKey: "place", label: "same", aliases: [first, first]).validateWritable())
    }
}
