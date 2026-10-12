import Foundation
import Testing
import VaultCore
@testable import noema

@Suite struct AIActivityExportTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaActivityExport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func canonicalAndRecoveryTargetsRemainUntouched() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let vault = base.appendingPathComponent("Vault")
        let recovery = base.appendingPathComponent("Local/Drafts")
        let targets = [vault.appendingPathComponent("vault.json"),
                       vault.appendingPathComponent("Sources/Fixture/metadata.json"),
                       recovery.appendingPathComponent("draft.json")]
        let original = Data("preserved canonical or recovery bytes".utf8)
        for target in targets {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: target)
            #expect(throws: AIActivityExportDestination.Failure.protectedLocation) {
                try AIActivityExportDestination.write(Data("[]".utf8), to: target, protectedRoots: [vault, recovery])
            }
            #expect(try Data(contentsOf: target) == original)
        }
        #expect(throws: AIActivityExportDestination.Failure.protectedLocation) {
            try AIActivityExportDestination.write(Data("[]".utf8), to: vault.appendingPathComponent("new-export.json"), protectedRoots: [vault])
        }
    }

    @Test func symlinkRoutesIntoVaultAreRejectedAndSiblingPrefixIsAllowed() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let vault = base.appendingPathComponent("Vault")
        let sibling = base.appendingPathComponent("Vault-backup")
        for root in [vault, sibling] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        let manifest = vault.appendingPathComponent("vault.json")
        try Data("canonical".utf8).write(to: manifest)
        let alias = base.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: vault)
        let fileAlias = base.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: fileAlias, withDestinationURL: manifest)
        for destination in [alias.appendingPathComponent("new.json"), fileAlias] {
            #expect(throws: AIActivityExportDestination.Failure.protectedLocation) {
                try AIActivityExportDestination.write(Data("[]".utf8), to: destination, protectedRoots: [vault])
            }
        }
        let destination = sibling.appendingPathComponent("history.json")
        try AIActivityExportDestination.write(Data("[]".utf8), to: destination, protectedRoots: [vault])
        #expect(try Data(contentsOf: destination) == Data("[]".utf8))
        #expect(try Data(contentsOf: manifest) == Data("canonical".utf8))
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("new.json").path))
    }

    @Test func directoryCaseAliasesAreProtectedWithoutRejectingDistinctCaseSensitiveSiblings() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let vault = base.appendingPathComponent("Vault")
        let variant = base.appendingPathComponent("vAuLt")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        let destination = variant.appendingPathComponent("new.json")
        if FileManager.default.fileExists(atPath: variant.path) {
            #expect(throws: AIActivityExportDestination.Failure.protectedLocation) {
                try AIActivityExportDestination.write(Data("[]".utf8), to: destination, protectedRoots: [vault])
            }
            #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent("new.json").path))
        } else {
            try FileManager.default.createDirectory(at: variant, withIntermediateDirectories: true)
            try AIActivityExportDestination.write(Data("[]".utf8), to: destination, protectedRoots: [vault])
            #expect(try Data(contentsOf: destination) == Data("[]".utf8))
        }
    }

    @Test @MainActor func lockedAndSwitchedVaultRootsStayProtectedBeforeWrite() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let model = AppModel()
        let first = base.appendingPathComponent("First")
        let second = base.appendingPathComponent("Second")
        model.sessionManager.accessGate.updateState(.locked(vaultID: UUID(), root: first, vaultName: "First", generation: 1))
        let captured = AIActivityExportDestination.protectedRoots(model: model)
        #expect(captured.contains(first))
        model.sessionManager.accessGate.updateState(.locked(vaultID: UUID(), root: second, vaultName: "Second", generation: 2))
        let protected = captured + AIActivityExportDestination.protectedRoots(model: model)
        for root in [first, second] {
            #expect(throws: AIActivityExportDestination.Failure.protectedLocation) {
                try AIActivityExportDestination.validate(root.appendingPathComponent("vault.json"), protectedRoots: protected)
            }
        }
    }

    @Test func existingExternalFileIsNeverReplaced() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("history.json")
        let original = Data("original external file".utf8)
        try original.write(to: destination)
        #expect(throws: AIActivityExportDestination.Failure.alreadyExists) {
            try AIActivityExportDestination.write(Data("[]".utf8), to: destination, protectedRoots: [])
        }
        #expect(try Data(contentsOf: destination) == original)
    }

    @Test func concurrentExportsCannotReplaceTheFirstCompletedFile() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("history.json")
        let successful = await withTaskGroup(of: Int?.self) { group in
            for value in 0..<16 {
                group.addTask {
                    do {
                        try AIActivityExportDestination.write(Data("[\(value)]".utf8), to: destination, protectedRoots: [])
                        return value
                    } catch { return nil }
                }
            }
            var values = [Int]()
            for await value in group { if let value { values.append(value) } }
            return values
        }
        #expect(successful.count == 1)
        let value = try #require(successful.first)
        #expect(try Data(contentsOf: destination) == Data("[\(value)]".utf8))
    }
}
