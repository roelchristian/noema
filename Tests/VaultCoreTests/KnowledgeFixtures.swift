import Foundation
@testable import VaultCore

/// Stable identities shared by knowledge and later semantic acceptance tests.
enum KnowledgeFixtures {
    static let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    static let napoleonID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let russiaID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let invasionID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let otherNapoleonID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    static let emperorAliasID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    static let otherAliasID = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!

    static var entities: [KnowledgeEntity] {
        [
            KnowledgeEntity(id: napoleonID, typeKey: "person", label: "Napoleon Bonaparte",
                            description: "French emperor", aliases: [.init(id: emperorAliasID, label: "Napoleon")],
                            createdAt: timestamp, modifiedAt: timestamp),
            KnowledgeEntity(id: russiaID, typeKey: "place", label: "Russia",
                            createdAt: timestamp, modifiedAt: timestamp),
            KnowledgeEntity(id: invasionID, typeKey: "concept", label: "invasion",
                            createdAt: timestamp, modifiedAt: timestamp),
            KnowledgeEntity(id: otherNapoleonID, typeKey: "person", label: "Napoleon Bonaparte",
                            description: "A different person sharing the name",
                            aliases: [.init(id: otherAliasID, label: "Napoleon")],
                            createdAt: timestamp, modifiedAt: timestamp)
        ]
    }
}
