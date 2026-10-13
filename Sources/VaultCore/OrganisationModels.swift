import Foundation

/// Placement inside a vault. A collection or folder describes where an item is
/// shown. It is not a page, source, knowledge entity, tag or directory.
public enum OrganisationContainerKind: String, Codable, Sendable, Equatable {
    case collection, folder
}

public enum OrganisationItemKind: String, Codable, Sendable, Equatable {
    case page, source, semanticBlock, knowledgeEntity, semanticObject
}

/// A typed reference to one canonical vault item. Semantic blocks keep both identities.
public struct OrganisationItemReference: Hashable, Sendable, Equatable {
    public var kind: OrganisationItemKind
    public var itemID: UUID
    public var pageID: UUID?

    public init(kind: OrganisationItemKind, itemID: UUID, pageID: UUID? = nil) {
        self.kind = kind
        self.itemID = itemID
        self.pageID = pageID
    }

    public var placementKey: String {
        switch kind {
        case .semanticBlock:
            return "semanticBlock:\(pageID?.uuidString ?? ""):\(itemID.uuidString)"
        default:
            return "\(kind.rawValue):\(itemID.uuidString)"
        }
    }

    public func validate() throws {
        switch kind {
        case .semanticBlock:
            guard pageID != nil else { throw VaultError.invalid("A semantic block reference needs its page.") }
        default:
            guard pageID == nil else { throw VaultError.invalid("Only a semantic block reference includes a page.") }
        }
    }

    public static func parse(placementKey key: String) -> OrganisationItemReference? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, parts[0] == OrganisationItemKind.semanticBlock.rawValue,
           let pageID = UUID(uuidString: parts[1]), let itemID = UUID(uuidString: parts[2]) {
            return OrganisationItemReference(kind: .semanticBlock, itemID: itemID, pageID: pageID)
        }
        if parts.count == 2, let kind = OrganisationItemKind(rawValue: parts[0]), kind != .semanticBlock,
           let itemID = UUID(uuidString: parts[1]) {
            return OrganisationItemReference(kind: kind, itemID: itemID)
        }
        return nil
    }
}

public struct OrganisationContainer: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: OrganisationContainerKind
    public var name: String
    public var parentID: UUID?
    public var sortOrder: Int
    public var revision: BlockStoreRevision
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID, kind: OrganisationContainerKind, name: String, parentID: UUID?, sortOrder: Int, revision: BlockStoreRevision, createdAt: Date, modifiedAt: Date) {
        self.id = id
        self.kind = kind
        self.name = name
        self.parentID = parentID
        self.sortOrder = sortOrder
        self.revision = revision
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public struct OrganisationMembership: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var containerID: UUID
    public var reference: OrganisationItemReference
    public var sortOrder: Int

    public init(id: UUID, containerID: UUID, reference: OrganisationItemReference, sortOrder: Int) {
        self.id = id
        self.containerID = containerID
        self.reference = reference
        self.sortOrder = sortOrder
    }
}

public struct OrganisationFavourite: Identifiable, Equatable, Sendable {
    public var reference: OrganisationItemReference
    public var sortOrder: Int
    public var createdAt: Date
    public var id: String { reference.placementKey }

    public init(reference: OrganisationItemReference, sortOrder: Int, createdAt: Date) {
        self.reference = reference
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public struct OrganisationSnapshot: Equatable, Sendable {
    public var containers: [OrganisationContainer]
    public var memberships: [OrganisationMembership]
    public var favourites: [OrganisationFavourite]
    public var vaultRevision: BlockStoreRevision

    public init(containers: [OrganisationContainer], memberships: [OrganisationMembership], favourites: [OrganisationFavourite], vaultRevision: BlockStoreRevision) {
        self.containers = containers
        self.memberships = memberships
        self.favourites = favourites
        self.vaultRevision = vaultRevision
    }
}

public enum OrganisationDrag {
    public static func item(_ reference: OrganisationItemReference) -> String {
        "noema-organisation-item:\(reference.placementKey)"
    }
    public static func movingItem(_ reference: OrganisationItemReference, from containerID: UUID) -> String {
        "noema-organisation-move:\(containerID.uuidString):\(reference.placementKey)"
    }
    public static func container(_ id: UUID) -> String {
        "noema-organisation-container:\(id.uuidString)"
    }

    public enum Payload: Equatable, Sendable {
        case item(OrganisationItemReference, removingFrom: UUID?)
        case container(UUID)
    }

    public static func parse(_ value: String) -> Payload? {
        let containerPrefix = "noema-organisation-container:"
        if value.hasPrefix(containerPrefix), let id = UUID(uuidString: String(value.dropFirst(containerPrefix.count))) {
            return .container(id)
        }
        let movePrefix = "noema-organisation-move:"
        if value.hasPrefix(movePrefix) {
            let rest = value.dropFirst(movePrefix.count)
            guard rest.count > 37, let source = UUID(uuidString: String(rest.prefix(36))), rest.dropFirst(36).first == ":" else { return nil }
            guard let reference = OrganisationItemReference.parse(placementKey: String(rest.dropFirst(37))) else { return nil }
            return .item(reference, removingFrom: source)
        }
        let itemPrefix = "noema-organisation-item:"
        if value.hasPrefix(itemPrefix), let reference = OrganisationItemReference.parse(placementKey: String(value.dropFirst(itemPrefix.count))) {
            return .item(reference, removingFrom: nil)
        }
        return nil
    }
}

/// Mutations compare the vault revision and do not change page, source or knowledge revisions.
public protocol OrganisationStore: Sendable {
    func organisationSnapshot(includingHidden: Bool) async throws -> OrganisationSnapshot
    func createContainer(kind: OrganisationContainerKind, name: String, parentID: UUID?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<OrganisationContainer>
    func renameContainer(id: UUID, name: String, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<OrganisationContainer>
    func moveContainer(id: UUID, parentID: UUID?, index: Int, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<OrganisationContainer>
    func deleteContainer(id: UUID, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<UUID>
    func addMembership(containerID: UUID, reference: OrganisationItemReference, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<OrganisationMembership>
    func removeMembership(containerID: UUID, reference: OrganisationItemReference, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<UUID>
    func moveMembership(containerID: UUID, reference: OrganisationItemReference, direction: Int, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<OrganisationMembership>
    func placeMembership(reference: OrganisationItemReference, containerID: UUID, removingFrom: UUID?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<OrganisationMembership>
    func setFavourite(_ reference: OrganisationItemReference, favourite: Bool, expectedVaultRevision: BlockStoreRevision, operationID: UUID) async throws -> KnowledgeMutationResult<Bool>
}
