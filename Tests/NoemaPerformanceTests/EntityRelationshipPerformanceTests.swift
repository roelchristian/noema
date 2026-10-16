import Foundation
import SQLite3
import Testing
@testable import VaultCore

@Suite("Entity relationship reverse-query benchmark")
struct EntityRelationshipPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOEMA_PERFORMANCE_TESTS"] == "1"))
    func reverseQueryWithTwoThousandEntitiesUsesCanonicalEdgesAndTargetIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("entity-reverse-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("blocks.sqlite"), vaultID = UUID()
        let store = try VaultStorageProvider.plaintext.makeRelationshipStagingStore(url: url, vaultID: vaultID)
        let target = try await store.createEntity(.init(typeKey: "person", label: "Creator"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        let definition = try EntityPropertyDefinition(vaultID: vaultID, label: "Created by", kind: .entityReference, cardinality: .many)
        _ = try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        var expectedIDs: Set<UUID> = []
        for index in 0..<1_999 {
            let source = try await store.createEntity(.init(typeKey: "creativeWork", label: "Work \(index)"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
            // Sparse fan-in verifies that unrelated entities do not leak into the result.
            if index.isMultiple(of: 10) {
                let edge = try await store.createPropertyRelationship(definitionID: definition.id, entityID: source.entity.id, otherEntityID: target.entity.id, direction: .outgoing, expectedEntity: source.revision, expectedOther: target.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
                expectedIDs.insert(edge.relationship.id)
            }
        }
        let clock = ContinuousClock(), start = clock.now
        var result: [EntityPropertyRelationshipSnapshot] = []
        for _ in 0..<100 {
            result = try await store.queryPropertyRelationships(entityID: target.entity.id, direction: .incoming)
            #expect(Set(result.map(\.relationship.id)) == expectedIDs)
            #expect(result.allSatisfy { $0.relationship.targetID == target.entity.id })
        }
        let elapsed = start.duration(to: clock.now)
        #expect(expectedIDs.count == 200)
        #expect(try await store.queryPropertyRelationships(entityID: target.entity.id, direction: .outgoing).isEmpty)
        try await store.close()

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw VaultError.storage("Cannot inspect benchmark query plan")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "EXPLAIN QUERY PLAN SELECT id FROM entity_property_relationships WHERE target_id=? ORDER BY created_at,id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw VaultError.storage("Cannot prepare benchmark query plan")
        }
        defer { sqlite3_finalize(statement) }
        var plan: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 3) { plan.append(String(cString: value)) }
        }
        #expect(plan.contains { $0.contains("entity_property_relationships_target") })
        #expect(!plan.contains { $0.contains("TEMP B-TREE") })
        print("ENTITY_REVERSE_BENCHMARK ENT.03: 2000 entities, 200 incoming edges, 100 queries=\(elapsed); plan=\(plan.joined(separator: "; "))")
    }
}
