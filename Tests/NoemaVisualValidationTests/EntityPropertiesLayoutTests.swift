import AppKit
import Foundation
import SwiftUI
import Testing
import NoemaBrand
@testable import VaultCore
@testable import noema

@Suite("Visual validation: Entity properties", .serialized)
struct EntityPropertiesLayoutTests {
    /// Narrow raster acceptance only; this does not exercise live focus or VoiceOver.
    @Test @MainActor func nativeEntityPropertiesAtInspectorWidths() throws {
        guard let path = ProcessInfo.processInfo.environment["NOEMA_ENTITY_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/agent-runs").standardizedFileURL.path + "/"
        #expect(directory.path.hasPrefix(evidence))
        guard directory.path.hasPrefix(evidence) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vault = UUID(), entity = KnowledgeEntity(typeKey: "creativeWork", label: "A collected work")
        let person = KnowledgeEntity(typeKey: "person", label: "Ariel Calcita")
        let revision = BlockStoreRevision(token: Data("fixture".utf8))
        let title = try EntityPropertyDefinition(vaultID: vault, label: "Working title", kind: .text)
        let date = try EntityPropertyDefinition(vaultID: vault, label: "Publication date", kind: .date)
        let relation = try EntityPropertyDefinition(vaultID: vault, label: "Created by", kind: .entityReference,
            presentation: .init(inverseLabel: "Creator of"))
        let count = try EntityPropertyDefinition(vaultID: vault, label: "Edition", kind: .number)
        let definitions = [title, date, relation, count].map { EntityPropertyDefinitionSnapshot(definition: $0, revision: revision) }
        let assignments: [EntityPropertyAssignment] = [
            .init(definitionID: title.id, value: .text("A long descriptive working title that wraps in the narrow inspector")),
            .init(definitionID: date.id, value: .date(try .init(year: 2024, month: 2))),
            .init(definitionID: count.id, value: .number(0))
        ]
        let edge = EntityPropertyRelationshipSnapshot(relationship: .init(definitionID: relation.id, sourceID: entity.id, targetID: person.id), revision: revision)
        let incomingEdge = EntityPropertyRelationshipSnapshot(relationship: .init(definitionID: relation.id, sourceID: person.id, targetID: entity.id), revision: revision)
        let snapshot = EntityPropertiesSnapshot(entity: .init(entity: entity, revision: revision), definitions: definitions,
            values: .init(entityID: entity.id, assignments: assignments, entityRevision: revision), relationships: [edge, incomingEdge],
            entities: [entity, person].map { .init(entity: $0, revision: revision) }, vaultRevision: revision, sessionID: nil)
        _ = NSApplication.shared
        for width in [280, 340] {
            let model = AppModel()
            let root = EntityPropertiesView(model: model, entityID: entity.id, previewSnapshot: snapshot)
                .padding(12).frame(width: CGFloat(width), height: 560, alignment: .top)
                .environment(\.colorScheme, .dark)
                .environment(\.noemaTheme, NoemaTheme(dark: true, increasedContrast: false))
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame = window.contentView!.bounds
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("entity-properties-\(width).png"))
            #expect(host.fittingSize.width <= CGFloat(width))
        }
    }
}
