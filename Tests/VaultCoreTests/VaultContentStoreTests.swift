import Foundation
import Testing
@testable import VaultCore

struct VaultContentStoreTests {
    private func fixture(_ test: (PlaintextVaultContentStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noema-content-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(PlaintextVaultContentStore(root: root), root)
    }

    private func fails(_ operation: () throws -> Void, matching: (VaultContentStoreError) -> Bool) {
        do { try operation(); Issue.record("Expected a typed storage failure") }
        catch let error as VaultContentStoreError { #expect(matching(error)) }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func byteRoundTripAndReplacement() throws {
        try fixture { store, _ in
            let bytes = Data([0, 255, 128, 10, 0])
            try store.write(bytes, at: "page.md", condition: .createOnly)
            #expect(try store.read(at: "page.md") == bytes)
            try store.write(Data(), at: "page.md", condition: .replace(expected: bytes))
            #expect(try store.read(at: "page.md").isEmpty)
        }
    }

    @Test func createOnlyAndStaleReplacementPreserveBytes() throws {
        try fixture { store, _ in
            let bytes = Data("original".utf8)
            try store.write(bytes, at: "page.md", condition: .createOnly)
            fails({ try store.write(Data(), at: "page.md", condition: .createOnly) }) {
                if case .alreadyExists = $0 { true } else { false }
            }
            fails({ try store.write(Data(), at: "page.md", condition: .replace(expected: Data())) }) {
                if case .stale = $0 { true } else { false }
            }
            #expect(try store.read(at: "page.md") == bytes)
        }
    }

    @Test(arguments: ["", "/escape", "../escape", "Wiki/../../escape", "Wiki/./page", "Wiki//page", "page/", "bad\0path"])
    func rejectsUnsafePaths(path: String) throws {
        try fixture { store, _ in
            fails({ _ = try store.read(at: path) }) { if case .unsafePath = $0 { true } else { false } }
            fails({ try store.write(Data(), at: path, condition: .createOnly) }) { if case .unsafePath = $0 { true } else { false } }
            fails({ try store.move(from: path, to: "safe", expected: .file(Data())) }) { if case .unsafePath = $0 { true } else { false } }
            fails({ try store.delete(at: path, expected: .file(Data())) }) { if case .unsafePath = $0 { true } else { false } }
        }
    }

    @Test func rejectsSymlinkAncestryAndDestination() throws {
        try fixture { store, root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "real")
            fails({ try store.write(Data(), at: "alias/page", condition: .createOnly) }) { if case .unsafePath = $0 { true } else { false } }
            try store.write(Data(), at: "page", condition: .createOnly)
            fails({ try store.move(from: "page", to: "alias/page", expected: .file(Data())) }) { if case .unsafePath = $0 { true } else { false } }
            #expect(try store.read(at: "page").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("real/page").path))
        }
    }

    @Test func movesAndDeletesRequireCurrentSnapshots() throws {
        try fixture { store, root in
            let bytes = Data("original".utf8)
            try store.write(bytes, at: "page", condition: .createOnly)
            try store.write(Data(), at: "occupied", condition: .createOnly)
            fails({ try store.move(from: "page", to: "occupied", expected: .file(bytes)) }) { if case .alreadyExists = $0 { true } else { false } }
            fails({ try store.move(from: "page", to: "moved", expected: .file(Data())) }) { if case .stale = $0 { true } else { false } }
            try store.move(from: "page", to: "moved", expected: .file(bytes))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("page").path))
            fails({ try store.delete(at: "moved", expected: .file(Data())) }) { if case .stale = $0 { true } else { false } }
            #expect(try store.read(at: "moved") == bytes)
            try store.delete(at: "moved", expected: .file(bytes))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("moved").path))
        }
    }

    @Test func flatDirectorySnapshotProtectsOriginalAndMetadata() throws {
        try fixture { store, root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: false)
            try store.write(Data([255]), at: "staging/original.bin", condition: .createOnly)
            try store.write(Data("{}".utf8), at: "staging/metadata.json", condition: .createOnly)
            let expected = try store.snapshot(at: "staging")
            #expect(expected == .directory(["original.bin": Data([255]), "metadata.json": Data("{}".utf8)]))
            try store.move(from: "staging", to: "published", expected: expected)
            try store.write(Data(), at: "published/extra", condition: .createOnly)
            fails({ try store.delete(at: "published", expected: expected) }) { if case .stale = $0 { true } else { false } }
            #expect(try store.read(at: "published/original.bin") == Data([255]))
            try store.delete(at: "published", expected: store.snapshot(at: "published"))
        }
    }

    @Test func missingItemsAreNeverRecreatedByReplacement() throws {
        try fixture { store, root in
            fails({ _ = try store.read(at: "missing") }) { if case .missing = $0 { true } else { false } }
            fails({ try store.write(Data(), at: "missing", condition: .replace(expected: Data())) }) { if case .missing = $0 { true } else { false } }
            fails({ try store.delete(at: "missing", expected: .file(Data())) }) { if case .missing = $0 { true } else { false } }
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
        }
    }
}
