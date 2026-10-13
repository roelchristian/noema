import AppKit
import SwiftUI
import Testing
@testable import VaultCore
@testable import noema

@Suite("Document entity presentation")
struct SemanticEntityPresentationTests {
    private func record(pageID: UUID, entity: KnowledgeEntity, disposition: AnnotationDisposition = .resolved) -> SemanticInspectionRecord {
        .init(annotation: .init(location: .wholeBlock(pageID: pageID, blockID: UUID()),
            referent: .init(identity: .init(kind: entity.typeKey, id: entity.id)), designation: entity.typeKey,
            anchorDisposition: disposition), target: .entity(.init(entity: entity, revision: .init(token: Data("fixture".utf8)))))
    }

    @Test func groupsCanonicalIdentitiesAndCountsOnlyCurrentDocumentMentions() throws {
        let pageID = UUID(), otherPageID = UUID()
        let entity = KnowledgeEntity(typeKey: "person", label: "Shared name")
        let second = KnowledgeEntity(typeKey: "person", label: "Shared name")
        let event = KnowledgeEntity(typeKey: "event", label: "Conference")
        var first = record(pageID: pageID, entity: entity)
        let external = record(pageID: otherPageID, entity: entity)
        first.occurrences = [.init(annotation: external.annotation, revision: .init(token: Data()))]
        let records = [first, record(pageID: pageID, entity: entity, disposition: .stale), external,
            record(pageID: pageID, entity: entity, disposition: .deleted),
            record(pageID: pageID, entity: second), record(pageID: pageID, entity: event)]
        let groups = SemanticEntityGroup.make(records: records, pageID: pageID)
        #expect(groups.count == 3)
        #expect(groups[0].mentionCount == 2)
        #expect(groups[0].navigableRecords.map(\.id) == [first.id])
        #expect(groups[1].id == second.id)
        #expect(groups[2].target.kind == "event")
        #expect(SemanticEntityGroup.make(records: records, pageID: UUID()).isEmpty)
    }

    @Test func retainsUnavailableEntitiesAndKeepsSemanticObjectsSeparate() {
        let pageID = UUID()
        let identity = EntityIdentity(kind: "person", id: UUID())
        let unavailable = SemanticInspectionRecord(annotation: .init(location: .wholeBlock(pageID: pageID, blockID: UUID()),
            referent: .init(identity: identity, disposition: .unresolved), designation: "person"), target: .unavailable(identity))
        let objectID = EntityIdentity(kind: "question", id: UUID())
        let question = SemanticInspectionRecord(annotation: .init(location: .wholeBlock(pageID: pageID, blockID: UUID()),
            referent: .init(identity: objectID), designation: "question"), target: .unavailable(objectID))
        let groups = SemanticEntityGroup.make(records: [unavailable, question], pageID: pageID)
        #expect(groups.count == 1)
        #expect(groups[0].target == .unavailable(identity))
    }

    /// Opt-in native pixels, captured alongside the focused presentation regressions.
    @Test @MainActor func nativeEntityInspectorCaptureWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOEMA_ENTITY_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pageID = UUID(), model = AppModel()
        model.semanticInspectionPageID = pageID
        let fixtures = [("person", "Ariel Calcita", 3), ("concept", "Toastmasters feedback", 5),
            ("place", "Westerville", 2), ("event", "Conference", 1)]
        model.semanticInspectionRecords = fixtures.flatMap { kind, label, count in
            let entity = KnowledgeEntity(typeKey: kind, label: label)
            return (0..<count).map { _ in record(pageID: pageID, entity: entity) }
        }
        _ = NSApplication.shared
        for width in [280, 340] {
            let root = SemanticInspectionSection(model: model, pageID: pageID)
                .padding(12).frame(width: CGFloat(width), height: 520, alignment: .top)
                .environment(\.colorScheme, .dark)
                .environment(\.noemaTheme, NoemaTheme(dark: true, increasedContrast: false))
                .environment(\.appearsActive, true)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            defer { window.contentView = nil; window.close() }
            hosting.frame = window.contentView!.bounds
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("entities-native-\(width).png"))
        }
    }
}
