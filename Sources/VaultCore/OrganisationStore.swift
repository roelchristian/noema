import Foundation
import SQLite3

extension SQLiteBlockStore {
    public func organisationSnapshot(includingHidden: Bool) throws -> OrganisationSnapshot {
        try requireVaultOrganisation()
        return try readTransaction {
            let containers = try loadOrganisationContainers()
            var memberships = try loadOrganisationMemberships()
            var favourites = try loadOrganisationFavourites()
            if includingHidden {
                memberships = try memberships.filter { try organisationReferenceExists($0.reference) }
                favourites = try favourites.filter { try organisationReferenceExists($0.reference) }
            } else {
                memberships = try memberships.filter { try organisationReferenceIsListed($0.reference) }
                favourites = try favourites.filter { try organisationReferenceIsListed($0.reference) }
            }
            return OrganisationSnapshot(containers: containers, memberships: memberships, favourites: favourites, vaultRevision: try vaultRevision())
        }
    }

    public func createContainer(kind: OrganisationContainerKind, name: String, parentID: UUID?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<OrganisationContainer> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            let containers = try loadOrganisationContainers()
            try validateContainerParent(kind: kind, parentID: parentID, containers: containers, moving: nil)
            let now = Date()
            let container = OrganisationContainer(id: UUID(), kind: kind, name: try organisationName(name), parentID: parentID, sortOrder: try nextOrganisationOrder(parentID: parentID), revision: newOrganisationRevision(), createdAt: now, modifiedAt: now)
            try insertContainer(container)
            let vault = try finishOrganisationWrite(operationID, record: container.revision)
            return KnowledgeMutationResult(value: container, vaultRevision: vault, operationID: operationID)
        }
    }

    public func renameContainer(id: UUID, name: String, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<OrganisationContainer> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            var container = try requireContainer(id, expected: expected)
            container.name = try organisationName(name)
            container.revision = newOrganisationRevision()
            container.modifiedAt = Date()
            try run("UPDATE organisation_containers SET name=?, revision=?, modified_at=? WHERE id=?", [.text(container.name), .blob(container.revision.token), .real(container.modifiedAt.timeIntervalSince1970), .text(id.uuidString)])
            let vault = try finishOrganisationWrite(operationID, record: container.revision)
            return KnowledgeMutationResult(value: container, vaultRevision: vault, operationID: operationID)
        }
    }

    public func moveContainer(id: UUID, parentID: UUID?, index: Int, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<OrganisationContainer> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            var container = try requireContainer(id, expected: expected)
            let containers = try loadOrganisationContainers()
            try validateContainerParent(kind: container.kind, parentID: parentID, containers: containers, moving: id)
            var siblings = containers.filter { $0.parentID == parentID && $0.id != id }.sorted(by: organisationContainerOrder)
            let bounded = min(max(index, 0), siblings.count)
            siblings.insert(container, at: bounded)
            for (offset, sibling) in siblings.enumerated() where sibling.id != id {
                try run("UPDATE organisation_containers SET sort_order=? WHERE id=?", [.integer(Int64(offset)), .text(sibling.id.uuidString)])
            }
            container.parentID = parentID
            container.sortOrder = bounded
            container.revision = newOrganisationRevision()
            container.modifiedAt = Date()
            try run("UPDATE organisation_containers SET parent_id=?, sort_order=?, revision=?, modified_at=? WHERE id=?", [parentID.map { .text($0.uuidString) } ?? .null, .integer(Int64(bounded)), .blob(container.revision.token), .real(container.modifiedAt.timeIntervalSince1970), .text(id.uuidString)])
            let vault = try finishOrganisationWrite(operationID, record: container.revision)
            return KnowledgeMutationResult(value: container, vaultRevision: vault, operationID: operationID)
        }
    }

    public func deleteContainer(id: UUID, expected: BlockStoreRevision, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<UUID> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            _ = try requireContainer(id, expected: expected)
            let containers = try loadOrganisationContainers()
            for child in organisationDeletionOrder(root: id, containers: containers) {
                try run("DELETE FROM organisation_containers WHERE id=?", [.text(child.uuidString)])
            }
            let vault = try finishOrganisationWrite(operationID, record: expected)
            return KnowledgeMutationResult(value: id, vaultRevision: vault, operationID: operationID)
        }
    }

    public func addMembership(containerID: UUID, reference: OrganisationItemReference, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<OrganisationMembership> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            let membership = try insertMembership(containerID: containerID, reference: reference)
            let vault = try finishOrganisationWrite(operationID, record: newOrganisationRevision())
            return KnowledgeMutationResult(value: membership, vaultRevision: vault, operationID: operationID)
        }
    }

    public func removeMembership(containerID: UUID, reference: OrganisationItemReference, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<UUID> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            try reference.validate()
            guard let membership = try loadOrganisationMemberships().first(where: { $0.containerID == containerID && $0.reference == reference }) else {
                throw VaultError.invalid("That item is not in this container.")
            }
            try run("DELETE FROM organisation_memberships WHERE id=?", [.text(membership.id.uuidString)])
            let vault = try finishOrganisationWrite(operationID, record: newOrganisationRevision())
            return KnowledgeMutationResult(value: membership.id, vaultRevision: vault, operationID: operationID)
        }
    }

    public func moveMembership(containerID: UUID, reference: OrganisationItemReference, direction: Int, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<OrganisationMembership> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            var memberships = try loadOrganisationMemberships().filter { $0.containerID == containerID }.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
            guard let current = memberships.firstIndex(where: { $0.reference == reference }) else { throw VaultError.invalid("That item is not in this container.") }
            let destination = current + direction
            guard memberships.indices.contains(destination) else { throw VaultError.invalid("The item is already at the end of the order.") }
            memberships.swapAt(current, destination)
            for (offset, membership) in memberships.enumerated() {
                try run("UPDATE organisation_memberships SET sort_order=? WHERE id=?", [.integer(Int64(offset)), .text(membership.id.uuidString)])
            }
            var moved = memberships[destination]
            moved.sortOrder = destination
            let vault = try finishOrganisationWrite(operationID, record: newOrganisationRevision())
            return KnowledgeMutationResult(value: moved, vaultRevision: vault, operationID: operationID)
        }
    }

    public func placeMembership(reference: OrganisationItemReference, containerID: UUID, removingFrom: UUID?, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<OrganisationMembership> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            if let removingFrom, removingFrom != containerID {
                try run("DELETE FROM organisation_memberships WHERE container_id=? AND placement_key=?", [.text(removingFrom.uuidString), .text(reference.placementKey)])
            }
            if let existing = try loadOrganisationMemberships().first(where: { $0.containerID == containerID && $0.reference == reference }) {
                let vault = try finishOrganisationWrite(operationID, record: newOrganisationRevision())
                return KnowledgeMutationResult(value: existing, vaultRevision: vault, operationID: operationID)
            }
            let membership = try insertMembership(containerID: containerID, reference: reference)
            let vault = try finishOrganisationWrite(operationID, record: newOrganisationRevision())
            return KnowledgeMutationResult(value: membership, vaultRevision: vault, operationID: operationID)
        }
    }

    public func setFavourite(_ reference: OrganisationItemReference, favourite: Bool, expectedVaultRevision: BlockStoreRevision, operationID: UUID) throws -> KnowledgeMutationResult<Bool> {
        try requireVaultOrganisation()
        return try transaction {
            try prepareOrganisationWrite(expectedVaultRevision, operationID)
            try reference.validate()
            let existing = try loadOrganisationFavourites().contains { $0.reference == reference }
            if existing == favourite {
                let vault = try vaultRevision()
                try recordOrganisationOperation(operationID, record: vault)
                return KnowledgeMutationResult(value: favourite, vaultRevision: vault, operationID: operationID)
            }
            if favourite {
                try requireListedOrganisationTarget(reference)
                let order = (try loadOrganisationFavourites().map(\.sortOrder).max() ?? -1) + 1
                try run("INSERT INTO organisation_favourites(placement_key, item_kind, item_id, page_id, sort_order, created_at) VALUES(?,?,?,?,?,?)", [.text(reference.placementKey), .text(reference.kind.rawValue), .text(reference.itemID.uuidString), reference.pageID.map { .text($0.uuidString) } ?? .null, .integer(Int64(order)), .real(Date().timeIntervalSince1970)])
            } else {
                try run("DELETE FROM organisation_favourites WHERE placement_key=?", [.text(reference.placementKey)])
            }
            let vault = try finishOrganisationWrite(operationID, record: newOrganisationRevision())
            return KnowledgeMutationResult(value: favourite, vaultRevision: vault, operationID: operationID)
        }
    }

    func deleteOrganisationReferences(pageID: UUID) throws {
        guard try organisationTablesPresent() else { return }
        try run("DELETE FROM organisation_memberships WHERE (item_kind='page' AND item_id=?) OR (item_kind='semanticBlock' AND page_id=?)", [.text(pageID.uuidString), .text(pageID.uuidString)])
        try run("DELETE FROM organisation_favourites WHERE (item_kind='page' AND item_id=?) OR (item_kind='semanticBlock' AND page_id=?)", [.text(pageID.uuidString), .text(pageID.uuidString)])
    }

    func deleteOrganisationSourceReferences(_ id: UUID) throws {
        guard try organisationTablesPresent() else { return }
        try run("DELETE FROM organisation_memberships WHERE item_kind='source' AND item_id=?", [.text(id.uuidString)])
        try run("DELETE FROM organisation_favourites WHERE item_kind='source' AND item_id=?", [.text(id.uuidString)])
    }

    func deleteOrganisationBlockReference(pageID: UUID, blockID: UUID) throws {
        guard try organisationTablesPresent() else { return }
        try run("DELETE FROM organisation_memberships WHERE item_kind='semanticBlock' AND page_id=? AND item_id=?", [.text(pageID.uuidString), .text(blockID.uuidString)])
        try run("DELETE FROM organisation_favourites WHERE item_kind='semanticBlock' AND page_id=? AND item_id=?", [.text(pageID.uuidString), .text(blockID.uuidString)])
    }

    func validateOrganisationRecords() throws {
        guard try organisationTablesPresent() else { throw VaultError.invalid("Vault organisation tables are missing.") }
        let containers = try loadOrganisationContainers()
        let byID = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        for container in containers {
            guard !container.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultError.invalid("Organisation container name is empty.") }
            try validateContainerParent(kind: container.kind, parentID: container.parentID, containers: containers, moving: container.kind == .folder ? container.id : nil)
            if container.kind == .folder, container.parentID != nil, byID[container.parentID!] == nil {
                throw VaultError.invalid("Organisation folder parent is missing.")
            }
        }
        for membership in try loadOrganisationMemberships() {
            guard byID[membership.containerID] != nil else { throw VaultError.invalid("Organisation membership container is missing.") }
            guard try organisationReferenceExists(membership.reference) else { throw VaultError.invalid("Organisation reference is unresolved.") }
        }
        for favourite in try loadOrganisationFavourites() {
            guard try organisationReferenceExists(favourite.reference) else { throw VaultError.invalid("Organisation reference is unresolved.") }
        }
    }

    private func requireVaultOrganisation() throws {
        try validate("organisation.access")
        try requireCanonical()
        guard try isOrganisationSchema() else { throw VaultError.invalid("Organisation is owned by a schema-6 vault.") }
    }

    private func prepareOrganisationWrite(_ expected: BlockStoreRevision, _ operationID: UUID) throws {
        guard try vaultRevision() == expected else { throw VaultError.conflict("Organisation revision changed.") }
        let query = try statement("SELECT 1 FROM knowledge_operations WHERE operation_id=?", [.text(operationID.uuidString)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw VaultError.conflict("Operation already committed; inspect its outcome.") }
    }

    private func finishOrganisationWrite(_ operationID: UUID, record: BlockStoreRevision) throws -> BlockStoreRevision {
        let vault = try advanceVaultRevision()
        try recordOrganisationOperation(operationID, record: record, vault: vault)
        return vault
    }

    private func recordOrganisationOperation(_ operationID: UUID, record: BlockStoreRevision, vault suppliedVault: BlockStoreRevision? = nil) throws {
        let committedVault = try suppliedVault ?? vaultRevision()
        try run("INSERT INTO knowledge_operations(operation_id, result_kind, result_payload, record_revision, vault_revision) VALUES(?,?,?,?,?)", [.text(operationID.uuidString), .text("organisation"), .blob(Data("{}".utf8)), .blob(record.token), .blob(committedVault.token)])
    }

    private func organisationName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 240, !trimmed.contains("\0") else { throw VaultError.invalid("Enter a container name.") }
        return trimmed
    }

    private func newOrganisationRevision() -> BlockStoreRevision { BlockStoreRevision(token: Data(UUID().uuidString.utf8)) }

    private func validateContainerParent(kind: OrganisationContainerKind, parentID: UUID?, containers: [OrganisationContainer], moving: UUID?) throws {
        if kind == .collection {
            guard parentID == nil else { throw VaultError.invalid("Collections cannot be nested.") }
            return
        }
        guard let parentID else { return }
        guard let parent = containers.first(where: { $0.id == parentID }) else { throw VaultError.invalid("The destination folder is unavailable.") }
        guard parent.kind == .collection || parent.kind == .folder else { throw VaultError.invalid("A folder can only be placed in the vault, a collection, or a folder.") }
        if let moving {
            var cursor: UUID? = parentID
            var seen: Set<UUID> = [moving]
            while let id = cursor {
                if !seen.insert(id).inserted { throw VaultError.invalid("Folder cycles are not allowed.") }
                cursor = containers.first(where: { $0.id == id })?.parentID
            }
        }
    }

    private func nextOrganisationOrder(parentID: UUID?) throws -> Int {
        let sql = parentID == nil
            ? "SELECT COALESCE(MAX(sort_order), -1) FROM organisation_containers WHERE parent_id IS NULL"
            : "SELECT COALESCE(MAX(sort_order), -1) FROM organisation_containers WHERE parent_id=?"
        let query = try statement(sql, parentID.map { [.text($0.uuidString)] } ?? [])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(query, 0)) + 1
    }

    private func insertContainer(_ container: OrganisationContainer) throws {
        try run("INSERT INTO organisation_containers(id, kind, name, parent_id, sort_order, revision, created_at, modified_at) VALUES(?,?,?,?,?,?,?,?)", [.text(container.id.uuidString), .text(container.kind.rawValue), .text(container.name), container.parentID.map { .text($0.uuidString) } ?? .null, .integer(Int64(container.sortOrder)), .blob(container.revision.token), .real(container.createdAt.timeIntervalSince1970), .real(container.modifiedAt.timeIntervalSince1970)])
    }

    private func requireContainer(_ id: UUID, expected: BlockStoreRevision) throws -> OrganisationContainer {
        guard let container = try loadOrganisationContainers().first(where: { $0.id == id }) else { throw VaultError.invalid("The container is no longer in this vault.") }
        guard container.revision == expected else { throw VaultError.conflict("Organisation container changed.") }
        return container
    }

    private func insertMembership(containerID: UUID, reference: OrganisationItemReference) throws -> OrganisationMembership {
        try reference.validate()
        guard try loadOrganisationContainers().contains(where: { $0.id == containerID }) else { throw VaultError.invalid("The container is no longer in this vault.") }
        try requireListedOrganisationTarget(reference)
        let order = (try loadOrganisationMemberships().filter { $0.containerID == containerID }.map(\.sortOrder).max() ?? -1) + 1
        let membership = OrganisationMembership(id: UUID(), containerID: containerID, reference: reference, sortOrder: order)
        do {
            try run("INSERT INTO organisation_memberships(id, container_id, item_kind, item_id, page_id, placement_key, sort_order) VALUES(?,?,?,?,?,?,?)", [.text(membership.id.uuidString), .text(containerID.uuidString), .text(reference.kind.rawValue), .text(reference.itemID.uuidString), reference.pageID.map { .text($0.uuidString) } ?? .null, .text(reference.placementKey), .integer(Int64(order))])
        } catch {
            let message = String(describing: error)
            if message.localizedCaseInsensitiveContains("UNIQUE") { throw VaultError.conflict("That item is already in this container.") }
            throw error
        }
        return membership
    }

    private func requireListedOrganisationTarget(_ reference: OrganisationItemReference) throws {
        guard try organisationReferenceIsListed(reference) else { throw VaultError.invalid("That item is not available in this vault.") }
    }

    func organisationTablesPresent() throws -> Bool {
        let query = try statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='organisation_containers'")
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW
    }

    func isOrganisationSchema() throws -> Bool {
        let query = try statement("PRAGMA user_version")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
        return [Int32(Self.organisationSchemaVersion), Int32(Self.propertySchemaVersion), Int32(Self.relationshipSchemaVersion), Int32(Self.templateSchemaVersion), Int32(Self.associationSchemaVersion)].contains(sqlite3_column_int(query, 0))
    }

    private func loadOrganisationContainers() throws -> [OrganisationContainer] {
        let query = try statement("SELECT id, kind, name, parent_id, sort_order, revision, created_at, modified_at FROM organisation_containers ORDER BY sort_order, id")
        defer { sqlite3_finalize(query) }
        var result: [OrganisationContainer] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let id = UUID(uuidString: text(query, 0)), let kind = OrganisationContainerKind(rawValue: text(query, 1)) else { throw VaultError.invalid("Invalid organisation container.") }
            let parent = sqlite3_column_type(query, 3) == SQLITE_NULL ? nil : UUID(uuidString: text(query, 3))
            if sqlite3_column_type(query, 3) != SQLITE_NULL, parent == nil { throw VaultError.invalid("Invalid organisation container.") }
            result.append(OrganisationContainer(id: id, kind: kind, name: text(query, 2), parentID: parent, sortOrder: Int(sqlite3_column_int(query, 4)), revision: BlockStoreRevision(token: blob(query, 5)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 6)), modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 7))))
        }
        return result
    }

    private func loadOrganisationMemberships() throws -> [OrganisationMembership] {
        let query = try statement("SELECT id, container_id, item_kind, item_id, page_id, placement_key, sort_order FROM organisation_memberships ORDER BY sort_order, id")
        defer { sqlite3_finalize(query) }
        var result: [OrganisationMembership] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            let reference = try organisationReference(kind: text(query, 2), item: text(query, 3), page: sqlite3_column_type(query, 4) == SQLITE_NULL ? nil : text(query, 4), placementKey: text(query, 5))
            guard let id = UUID(uuidString: text(query, 0)), let containerID = UUID(uuidString: text(query, 1)) else { throw VaultError.invalid("Invalid organisation membership.") }
            result.append(OrganisationMembership(id: id, containerID: containerID, reference: reference, sortOrder: Int(sqlite3_column_int(query, 6))))
        }
        return result
    }

    private func loadOrganisationFavourites() throws -> [OrganisationFavourite] {
        let query = try statement("SELECT item_kind, item_id, page_id, placement_key, sort_order, created_at FROM organisation_favourites ORDER BY sort_order, placement_key")
        defer { sqlite3_finalize(query) }
        var result: [OrganisationFavourite] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure() }
            let reference = try organisationReference(kind: text(query, 0), item: text(query, 1), page: sqlite3_column_type(query, 2) == SQLITE_NULL ? nil : text(query, 2), placementKey: text(query, 3))
            result.append(OrganisationFavourite(reference: reference, sortOrder: Int(sqlite3_column_int(query, 4)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 5))))
        }
        return result
    }

    private func organisationReference(kind: String, item: String, page: String?, placementKey: String) throws -> OrganisationItemReference {
        guard let itemKind = OrganisationItemKind(rawValue: kind), let itemID = UUID(uuidString: item) else { throw VaultError.invalid("Invalid organisation reference.") }
        let pageID = page.flatMap(UUID.init(uuidString:))
        if page != nil, pageID == nil { throw VaultError.invalid("Invalid organisation reference.") }
        let reference = OrganisationItemReference(kind: itemKind, itemID: itemID, pageID: pageID)
        try reference.validate()
        guard reference.placementKey == placementKey else { throw VaultError.invalid("Organisation reference does not match its identity.") }
        return reference
    }

    private func organisationReferenceIsListed(_ reference: OrganisationItemReference) throws -> Bool {
        switch reference.kind {
        case .page:
            return try pageIsListed(reference.itemID)
        case .source:
            return try sourceIsListed(reference.itemID)
        case .semanticBlock:
            guard let pageID = reference.pageID, try pageIsListed(pageID) else { return false }
            let query = try statement("SELECT 1 FROM blocks WHERE page_id=? AND id=?", [.text(pageID.uuidString), .text(reference.itemID.uuidString)])
            defer { sqlite3_finalize(query) }
            return sqlite3_step(query) == SQLITE_ROW
        case .knowledgeEntity:
            return try lifecycleIsLive("knowledge_entities", reference.itemID)
        case .semanticObject:
            return try lifecycleIsLive("semantic_objects", reference.itemID)
        }
    }

    private func organisationReferenceExists(_ reference: OrganisationItemReference) throws -> Bool {
        switch reference.kind {
        case .page:
            return try rowExists("SELECT 1 FROM pages WHERE id=?", [reference.itemID.uuidString])
        case .source:
            return try rowExists("SELECT 1 FROM sources WHERE id=?", [reference.itemID.uuidString])
        case .semanticBlock:
            guard let pageID = reference.pageID else { return false }
            return try rowExists("SELECT 1 FROM blocks WHERE page_id=? AND id=?", [pageID.uuidString, reference.itemID.uuidString])
        case .knowledgeEntity:
            return try rowExists("SELECT 1 FROM knowledge_entities WHERE id=?", [reference.itemID.uuidString])
        case .semanticObject:
            return try rowExists("SELECT 1 FROM semantic_objects WHERE id=?", [reference.itemID.uuidString])
        }
    }

    private func pageIsListed(_ id: UUID) throws -> Bool {
        let query = try statement("SELECT trashed FROM pages WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return false }
        return sqlite3_column_int(query, 0) == 0
    }

    private func sourceIsListed(_ id: UUID) throws -> Bool {
        let query = try statement("SELECT trashed FROM sources WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return false }
        return sqlite3_column_int(query, 0) == 0
    }

    private func lifecycleIsLive(_ table: String, _ id: UUID) throws -> Bool {
        let query = try statement("SELECT lifecycle FROM \(table) WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return false }
        return text(query, 0) == "live"
    }

    private func rowExists(_ sql: String, _ values: [String]) throws -> Bool {
        let query = try statement(sql, values.map { .text($0) })
        defer { sqlite3_finalize(query) }
        return sqlite3_step(query) == SQLITE_ROW
    }

    private func organisationContainerOrder(_ lhs: OrganisationContainer, _ rhs: OrganisationContainer) -> Bool {
        (lhs.sortOrder, lhs.id.uuidString) < (rhs.sortOrder, rhs.id.uuidString)
    }

    private func organisationDeletionOrder(root: UUID, containers: [OrganisationContainer]) -> [UUID] {
        var children: [UUID: [UUID]] = [:]
        for container in containers { if let parentID = container.parentID { children[parentID, default: []].append(container.id) } }
        var order: [UUID] = []
        func walk(_ id: UUID) {
            for child in children[id] ?? [] { walk(child) }
            order.append(id)
        }
        walk(root)
        return order
    }
}
