import Foundation
import Testing
@testable import VaultCore

@Test func knowledgeFixturesRetainDuplicateLabelsAndAliasIdentity() throws {
    let original = KnowledgeFixtures.entities
    let restored = try JSONDecoder().decode([KnowledgeEntity].self, from: JSONEncoder().encode(original))
    #expect(restored == original)
    #expect(Set(restored.map(\.id)).count == 4)
    let people = restored.filter { $0.typeKey == "person" }
    #expect(people.count == 2)
    #expect(people[0].label == people[1].label)
    #expect(people[0].id != people[1].id)
    #expect(people[0].aliases[0].label == people[1].aliases[0].label)
    #expect(people[0].aliases[0].id != people[1].aliases[0].id)
    #expect(Set(restored.map(\.typeKey)) == ["person", "place", "concept"])
}

@Test func knowledgeFixtureUnknownPropertiesSurviveRoundTrip() throws {
    let opaque: JSONValue = .object(["future": .array([.null, .string("preserve")])])
    let original = KnowledgeEntity(id: KnowledgeFixtures.napoleonID, typeKey: "person", label: "Napoleon Bonaparte",
                                   properties: PersistencePayload(properties: ["optionalFuture": opaque]),
                                   createdAt: KnowledgeFixtures.timestamp, modifiedAt: KnowledgeFixtures.timestamp)
    let restored = try JSONDecoder().decode(KnowledgeEntity.self, from: JSONEncoder().encode(original))
    #expect(restored.properties.properties["optionalFuture"] == opaque)
    #expect(restored.id == KnowledgeFixtures.napoleonID)
}
