import Darwin
import Foundation
import Testing
@testable import VaultCore

struct SourcePreviewDirectoryTests {
    private func fixture() throws -> (URL, SourcePreviewDirectory) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("noema-preview-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, SourcePreviewDirectory(baseDirectory: base))
    }

    /// Copy a snapshot to model persisted bytes after the owning process and its lease have exited.
    private func orphan(from snapshot: SourcePreviewSnapshot, in directory: SourcePreviewDirectory) throws -> URL {
        let url = directory.root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.copyItem(at: snapshot.url.deletingLastPathComponent(), to: url)
        return url
    }

    @Test func launchCleanupRemovesOrphansAndProtectsActiveReaders() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("only copied preview".utf8)
        let active = try directory.makeSnapshot(data: bytes, filename: "source.pdf")
        defer { active.remove() }
        let orphan1 = try orphan(from: active, in: directory)
        let orphan2 = try orphan(from: active, in: directory)
        // A new manager models the next launch; leases are kernel-owned, not manager-local state.
        let reopened = SourcePreviewDirectory(baseDirectory: base)
        #expect(try reopened.cleanupOrphans() == 2)
        #expect(!FileManager.default.fileExists(atPath: orphan1.path))
        #expect(!FileManager.default.fileExists(atPath: orphan2.path))
        #expect(try Data(contentsOf: active.url) == bytes)
        active.remove()
        active.remove()
        #expect(!FileManager.default.fileExists(atPath: active.url.deletingLastPathComponent().path))
    }

    @Test func repeatedSnapshotsShareAnExistingRoot() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try directory.makeSnapshot(data: Data([1]), filename: "source.pdf")
        defer { first.remove() }
        let second = try directory.makeSnapshot(data: Data([2]), filename: "source.pdf")
        defer { second.remove() }
        let third = try SourcePreviewDirectory(baseDirectory: base).makeSnapshot(data: Data([3]), filename: "source.pdf")
        defer { third.remove() }
        #expect(try Data(contentsOf: first.url) == Data([1]))
        #expect(try Data(contentsOf: second.url) == Data([2]))
        #expect(try Data(contentsOf: third.url) == Data([3]))
        #expect(Set([first.url, second.url, third.url]).count == 3)
        #expect(try directory.cleanupOrphans() == 0)
    }

    @Test func concurrentSnapshotsCreateTheRootOnce() async throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let snapshots = try await withThrowingTaskGroup(of: SourcePreviewSnapshot.self) { group in
            for index in 0..<12 {
                group.addTask { try directory.makeSnapshot(data: Data([UInt8(index)]), filename: "source.pdf") }
            }
            var snapshots: [SourcePreviewSnapshot] = []
            for try await snapshot in group { snapshots.append(snapshot) }
            return snapshots
        }
        defer { for snapshot in snapshots { snapshot.remove() } }
        #expect(snapshots.count == 12)
        #expect(Set(snapshots.map(\.url)).count == 12)
        let recoveredBytes = Set(try snapshots.map { try Data(contentsOf: $0.url) })
        #expect(recoveredBytes == Set((0..<12).map { Data([UInt8($0)]) }))
        #expect(try directory.cleanupOrphans() == 0)
    }

    @Test func cleanupNeverDeletesUnrelatedTemporaryFilesOrAmbiguousSnapshots() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let active = try directory.makeSnapshot(data: Data("preview".utf8), filename: "source.pdf")
        defer { active.remove() }
        let outside = base.appendingPathComponent("unrelated.tmp")
        let legacy = base.appendingPathComponent("noema-preview-" + UUID().uuidString)
        try Data("unrelated".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let unmarked = directory.root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        let foreign = unmarked.appendingPathComponent("keep.txt")
        try Data("foreign".utf8).write(to: foreign)
        let extra = try orphan(from: active, in: directory)
        try Data("foreign".utf8).write(to: extra.appendingPathComponent("keep.txt"))
        let malformed = try orphan(from: active, in: directory)
        try Data("not a Noema marker".utf8).write(to: malformed.appendingPathComponent(".noema-preview-lease"))
        let traversal = try orphan(from: active, in: directory)
        try Data("noema-source-preview-v1\n../../unrelated.tmp".utf8).write(to: traversal.appendingPathComponent(".noema-preview-lease"))
        #expect(try directory.cleanupOrphans() == 0)
        #expect(try Data(contentsOf: outside) == Data("unrelated".utf8))
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        for url in [legacy, extra, malformed, traversal] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func symlinkedDirectoriesMarkersAndPayloadsArePreserved() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let active = try directory.makeSnapshot(data: Data("preview".utf8), filename: "source.pdf")
        defer { active.remove() }
        let external = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let externalFile = external.appendingPathComponent("keep.pdf")
        try Data("outside".utf8).write(to: externalFile)
        let directoryLink = directory.root.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: external)
        let markerLink = try orphan(from: active, in: directory)
        let marker = markerLink.appendingPathComponent(".noema-preview-lease")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: active.url.deletingLastPathComponent().appendingPathComponent(".noema-preview-lease"))
        let payloadLink = try orphan(from: active, in: directory)
        let payload = payloadLink.appendingPathComponent("source.pdf")
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: externalFile)
        #expect(try directory.cleanupOrphans() == 0)
        #expect(try Data(contentsOf: externalFile) == Data("outside".utf8))
        for url in [directoryLink, markerLink, payloadLink] { #expect(FileManager.default.fileExists(atPath: url.path)) }
    }

    @Test func cleanupIsBoundedAndLaterLaunchesContinueCleanup() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let template = try directory.makeSnapshot(data: Data([1, 2, 3]), filename: "source.pdf")
        for _ in 0..<5 { _ = try orphan(from: template, in: directory) }
        template.remove()
        #expect(try directory.cleanupOrphans(maximumEntries: 0) == 0)
        #expect(try directory.cleanupOrphans(maximumEntries: 2) == 2)
        #expect(try directory.cleanupOrphans(maximumEntries: 2) == 2)
        #expect(try directory.cleanupOrphans(maximumEntries: 2) == 1)
        #expect(try directory.cleanupOrphans() == 0)
    }

    @Test func failedNormalRemovalAndInterruptedTeardownCanBeRetried() throws {
        let (base, directory) = try fixture()
        let snapshot = try directory.makeSnapshot(data: Data([1, 2, 3]), filename: "source.pdf")
        let snapshotDirectory = snapshot.url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotDirectory.path)
            try? FileManager.default.removeItem(at: base)
        }
        let partial = try orphan(from: snapshot, in: directory)
        try FileManager.default.removeItem(at: partial.appendingPathComponent("source.pdf"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: snapshotDirectory.path)
        snapshot.remove()
        #expect(FileManager.default.fileExists(atPath: snapshot.url.path))
        #expect(FileManager.default.fileExists(atPath: snapshotDirectory.appendingPathComponent(".noema-preview-lease").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: snapshotDirectory.path)
        #expect(try directory.cleanupOrphans() == 2)
        #expect(!FileManager.default.fileExists(atPath: snapshotDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func processTerminationReleasesLeaseForNextLaunch() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let template = try directory.makeSnapshot(data: Data([1, 2, 3]), filename: "source.pdf")
        defer { template.remove() }
        let leased = try orphan(from: template, in: directory)
        let child = Process()
        let output = Pipe()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl, sys; lease = open(sys.argv[1], 'r+b'); fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB); print('ready', flush=True); sys.stdin.read()",
                           leased.appendingPathComponent(".noema-preview-lease").path]
        child.standardOutput = output
        child.standardInput = input
        try child.run()
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
        }
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        try #require(ready == Data("ready\n".utf8))
        #expect(try directory.cleanupOrphans() == 0)
        #expect(FileManager.default.fileExists(atPath: leased.path))
        #expect(Darwin.kill(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()
        #expect(try SourcePreviewDirectory(baseDirectory: base).cleanupOrphans() == 1)
        #expect(!FileManager.default.fileExists(atPath: leased.path))
    }

    @Test func privatePermissionsInvalidFilenamesAndSymlinkedRoot() throws {
        let (base, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let snapshot = try directory.makeSnapshot(data: Data([1]), filename: "source.pdf")
        defer { snapshot.remove() }
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: directory.root.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: snapshot.url.deletingLastPathComponent().path)
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.url.path)
        #expect((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for filename in ["", ".", "..", "../source.pdf", ".hidden", "bad\nname", "bad\0name", String(repeating: "a", count: 256)] {
            #expect(throws: (any Error).self) { try directory.makeSnapshot(data: Data(), filename: filename) }
        }
        let linkedBase = base.appendingPathComponent("linked-base")
        try FileManager.default.createDirectory(at: linkedBase, withIntermediateDirectories: false)
        let linked = SourcePreviewDirectory(baseDirectory: linkedBase)
        try FileManager.default.createSymbolicLink(at: linked.root, withDestinationURL: directory.root)
        #expect(throws: (any Error).self) { try linked.cleanupOrphans() }
        #expect(throws: (any Error).self) { try linked.makeSnapshot(data: Data(), filename: "source.pdf") }
        #expect(try Data(contentsOf: snapshot.url) == Data([1]))
    }
}
