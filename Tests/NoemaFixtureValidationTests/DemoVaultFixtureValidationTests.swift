import Foundation
import Testing
import VaultCore

// Fixture quality is invoked separately from behavioral regression tests.
struct DemoVaultFixtureValidationTests {
    @Test func demoVaultPagesAndSourcesHaveLCCMetadata() throws {
        let demoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/Demo Vault")
        let demoWikiFiles = try FileManager.default.contentsOfDirectory(at: demoRoot.appendingPathComponent("Wiki"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        #expect(!demoWikiFiles.isEmpty)
        for fileURL in demoWikiFiles {
            let note = try NoteCodec.decode(Data(contentsOf: fileURL), path: "Wiki/" + fileURL.lastPathComponent, vaultID: UUID())
            #expect(note.lcc?.isEmpty == false, "Expected non-empty lcc for \(fileURL.lastPathComponent)")
        }
        let demoSourceDirs = try FileManager.default.contentsOfDirectory(at: demoRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        #expect(!demoSourceDirs.isEmpty)
        for dirURL in demoSourceDirs {
            let metadataURL = dirURL.appendingPathComponent("metadata.json")
            let metadata = try JSONDecoder().decode(SourceMetadata.self, from: Data(contentsOf: metadataURL))
            #expect(metadata.lcc?.isEmpty == false, "Expected non-empty lcc for source \(metadata.title)")
        }
    }
}
