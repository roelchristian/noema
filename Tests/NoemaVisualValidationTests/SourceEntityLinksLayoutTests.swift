import AppKit
import Foundation
import SwiftUI
import Testing
import NoemaBrand
@testable import VaultCore
@testable import noema

@Suite("Visual validation: Source entity links", .serialized)
struct SourceEntityLinksLayoutTests {
    /// Static synthetic content; does not certify presented sheets, keyboard or VoiceOver.
    @Test @MainActor func nativeSourceEntityLinksAtInspectorWidths() throws {
        guard let path = ProcessInfo.processInfo.environment["NOEMA_ENTITY_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/agent-runs").standardizedFileURL.path + "/"
        #expect(directory.path.hasPrefix(evidence))
        guard directory.path.hasPrefix(evidence) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let revision = BlockStoreRevision(token: Data("fixture".utf8))
        let metadata = SourceMetadata(id: UUID(), title: "A collected work — preserved edition", capturedAt: "2026-10-16", originalFilename: "edition.txt", originURL: nil,
            sha256: String(repeating: "a", count: 64), storedFilename: "original.txt")
        let source = CanonicalSourceSnapshot(source: try .init(metadata: metadata), revision: revision, trashed: false, trashedAt: nil)
        var alternate = metadata; alternate.id = UUID(); alternate.title = "Another edition in Source Trash"
        let trash = CanonicalSourceSnapshot(source: try .init(metadata: alternate), revision: revision, trashed: true, trashedAt: Date())
        let work = KnowledgeEntitySnapshot(entity: .init(typeKey: "creativeWork", label: "A collected work"), revision: revision)
        let person = KnowledgeEntitySnapshot(entity: .init(typeKey: "person", label: "Ariel Calcita", lifecycle: .tombstoned), revision: revision)
        let represents = SourceEntityAssociationSnapshot(association: .init(sourceID: source.source.id, entityID: work.entity.id, role: .representsWork), revision: revision)
        let about = SourceEntityAssociationSnapshot(association: .init(sourceID: source.source.id, entityID: person.entity.id, role: .aboutEntity), revision: revision)
        let alternateLink = SourceEntityAssociationSnapshot(association: .init(sourceID: trash.source.id, entityID: work.entity.id, role: .representsWork), revision: revision)
        let sourceSnapshot = SourceEntityLinksSnapshot(associations: [represents, about], sources: [source], entities: [work, person], vaultRevision: revision, sessionID: nil, offset: 0)
        let entitySnapshot = SourceEntityLinksSnapshot(associations: [represents, alternateLink], sources: [source, trash], entities: [work], vaultRevision: revision, sessionID: nil, offset: 0)
        _ = NSApplication.shared
        for width in [280, 340] {
            for side in ["source", "entity"] {
                let model = AppModel()
                let content: AnyView
                if side == "source" {
                    content = AnyView(VStack(alignment: .leading, spacing: 12) {
                        Text("Linked entities").font(.headline)
                        SourceEntityLinksView(model: model, sourceID: source.source.id, previewSnapshot: sourceSnapshot)
                    })
                } else {
                    content = AnyView(EntitySourceLinksView(model: model, entityID: work.entity.id, previewSnapshot: entitySnapshot))
                }
                let root = content.padding(12).frame(width: CGFloat(width), height: 560, alignment: .top)
                    .environment(\.colorScheme, .dark)
                    .environment(\.noemaTheme, NoemaTheme(dark: true, increasedContrast: false))
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua); window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = window.contentView!.bounds; host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("source-entity-links-\(side)-\(width).png"))
                #expect(host.fittingSize.width <= CGFloat(width))
            }
        }
    }
}
