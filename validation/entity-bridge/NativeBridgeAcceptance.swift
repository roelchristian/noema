import AppKit
import Foundation
import SwiftUI
import NoemaBrand
@testable import VaultCore
@testable import noema

/// Separate QA executable. Importing noema supplies views; NoemaApp/AppDelegate never run.
@main enum NativeBridgeAcceptance {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = BridgeQADelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor private final class BridgeQADelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var state: BridgeQAState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let identifier = Bundle.main.bundleIdentifier ?? ""
            guard identifier.hasPrefix("com.noema.qa.entitybridge."),
                  let path = Bundle.main.object(forInfoDictionaryKey: "NoemaQARunRoot") as? String else {
                throw VaultError.invalid("Launch only the generated synthetic QA application bundle.")
            }
            let run = URL(fileURLWithPath: path).standardizedFileURL
            guard run.path.contains("/.local/agent-runs/"), run.resolvingSymlinksInPath() == run,
                  FileManager.default.fileExists(atPath: run.appendingPathComponent(".qa-owned").path) else {
                throw VaultError.invalid("The QA run is not an owned managed evidence directory.")
            }
            FileManager.default.createFile(atPath: run.appendingPathComponent(".active").path, contents: Data())
            if FileManager.default.fileExists(atPath: run.appendingPathComponent(".complete").path) {
                try FileManager.default.removeItem(at: run.appendingPathComponent(".complete"))
            }
            let state = try BridgeQAState(run: run, identifier: identifier)
            self.state = state
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Noema ENT\(state.phase) QA — Synthetic Fixtures Only"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BridgeQARoot(state: state).systemNoemaTheme())
            self.window = window
            let menu = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
            appMenu.addItem(withTitle: "Quit Entity Bridge QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.submenu = appMenu; menu.addItem(item); NSApp.mainMenu = menu
            let editItem = NSMenuItem(), editMenu = NSMenu(title: "Edit")
            for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
                editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
            }
            editItem.submenu = editMenu; menu.addItem(editItem)
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            Task { await state.prepare() }
        } catch {
            let alert = NSAlert(); alert.messageText = "QA launch refused"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task {
            let closed = await state.model.closeVault(force: true)
            if closed {
                try? Data("Native QA process finished; keyboard/VoiceOver results require human recording.\n".utf8)
                    .write(to: state.run.appendingPathComponent("native-session-ended.txt"))
            }
            sender.reply(toApplicationShouldTerminate: closed)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor @Observable private final class BridgeQAState {
    let run: URL
    let model: AppModel
    let phase: String
    let primary: URL
    let secondary: URL
    var isSecondary = false
    var busy = true
    var message = "Preparing isolated synthetic fixtures…"
    var entities: [KnowledgeEntitySnapshot] = []
    var selectedEntityID: UUID?
    var selectedSourceID: UUID?
    var mode = "Entity properties"

    init(run: URL, identifier: String) throws {
        self.run = run
        #if ENT05_SOURCE_LINKS
        phase = "05"
        #else
        phase = "04"
        #endif
        primary = run.appendingPathComponent("Primary Vault")
        secondary = run.appendingPathComponent("Secondary Vault")
        guard let defaults = UserDefaults(suiteName: identifier + ".preferences") else { throw VaultError.storage("Cannot isolate QA preferences.") }
        model = AppModel(aiDefaults: defaults, activityRecorder: AIActivityRecorder(store: nil))
        model.localStorageRoot = run.appendingPathComponent("Local State")
        model.persistSecurityScopedBookmark = false
        model.requiresSecurityScopedAccess = false
    }

    func prepare() async {
        do {
            try await seed(root: primary, prefix: "Primary", full: true)
            try await seed(root: secondary, prefix: "Secondary", full: false)
            await open(primary)
        } catch { message = error.localizedDescription; busy = false }
    }

    func open(_ root: URL) async {
        busy = true; selectedEntityID = nil; selectedSourceID = nil; entities = []
        await model.open(root, create: false)
        await refresh()
        busy = false
    }

    func refresh() async {
        await model.refresh()
        await model.refreshKnowledgeCatalogue()
        entities = model.knowledgeCatalogue?.entities ?? []
        if !entities.contains(where: { $0.entity.id == selectedEntityID }) {
            selectedEntityID = entities.first(where: { $0.entity.typeKey == "creativeWork" })?.entity.id
        }
        if !model.sources.contains(where: { $0.id == selectedSourceID }) { selectedSourceID = model.sources.first?.id }
        model.knowledgeFamily = .entities
        message = model.errorMessage ?? "Synthetic \(isSecondary ? "secondary" : "primary") vault · \(model.sessionPhase) · no native acceptance result is inferred"
    }

    func lock() async {
        busy = true
        if await model.lockVault() { entities = []; selectedEntityID = nil; selectedSourceID = nil; message = "Locked · verify old inspectors and sheets clear." }
        else { message = model.errorMessage ?? "Lock failed" }
        busy = false
    }
    func unlock() async {
        busy = true
        if await model.unlockVault(using: isSecondary ? secondary : primary) { await refresh() }
        else { message = model.errorMessage ?? "Unlock failed" }
        busy = false
    }
    func switchVault() async {
        busy = true
        guard await model.closeVault(force: true) else { message = model.errorMessage ?? "Close failed"; busy = false; return }
        isSecondary.toggle()
        await open(isSecondary ? secondary : primary)
    }

    private func seed(root: URL, prefix: String, full: Bool) async throws {
        if FileManager.default.fileExists(atPath: root.path) { return } // QA-owned relaunch retains prior edits.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try await FileVaultRepository.initializeCanonicalStaging(root: root)
        let manifest = try FileVaultRepository.inspectManifest(at: root)
        let session = VaultSession(vaultID: manifest.id, root: root, generation: 1)
        let gate = VaultAccessGate(initialState: .open(session))
        let repository = try FileVaultRepository.open(root: root, sessionLease: session.lease, accessGate: gate)
        let store = repository.sqliteBlockStore
        var byType: [String: KnowledgeEntitySnapshot] = [:]
        for type in KnowledgeEntityType.initial {
            byType[type.key] = try await store.createEntity(.init(typeKey: type.key, label: "\(prefix) \(type.key)"), expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value
        }
        let kinds: [EntityPropertyKind] = [.text, .date, .url, .entityReference, .number, .boolean, .text, .entityReference]
        let labels = ["Working title", "Publication date", "Reference URL", "Created by", "Edition number", "Reviewed", "Language", "Related person"]
        var definitions: [EntityPropertyDefinitionSnapshot] = []
        for index in 0..<17 {
            let definition = try EntityPropertyDefinition(vaultID: manifest.id,
                label: index < labels.count ? labels[index] : "Optional field \(index + 1)",
                kind: index < kinds.count ? kinds[index] : .text,
                presentation: (index == 3 || index == 7) ? .init(inverseLabel: "Works", sourceTypeKeys: ["creativeWork"], targetTypeKeys: ["person"]) : nil)
            definitions.append(try await store.savePropertyDefinition(definition, expected: nil, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID()).value)
        }
        let work = byType["creativeWork"]!, person = byType["person"]!
        _ = try await store.savePropertyValues(entityID: work.entity.id,
            assignments: [.init(definitionID: definitions[16].definition.id, value: .text("Preserved factual value — template changes must leave this intact"))],
            expectedEntity: work.revision, expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        _ = try await store.createPropertyRelationship(definitionID: definitions[7].definition.id,
            entityID: work.entity.id, otherEntityID: person.entity.id, direction: .outgoing,
            expectedEntity: store.loadEntity(id: work.entity.id).revision, expectedOther: person.revision,
            expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        _ = try await store.savePropertyTemplate(typeKey: "creativeWork", definitionIDs: definitions.prefix(4).map(\.definition.id), expected: nil,
            expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        _ = try await store.savePropertyTemplate(typeKey: "person", definitionIDs: definitions.prefix(16).map(\.definition.id), expected: nil,
            expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        let source = try await repository.importSource(data: Data("\(prefix) preserved reading evidence.\n".utf8), filename: "evidence.txt", title: "\(prefix) evidence", originURL: nil)
        _ = try await repository.create(title: "\(prefix) page", body: "Independent Page linked to a Source.", source: source)
        #if ENT05_SOURCE_LINKS
        func associate(_ source: SourceRecord, _ entity: KnowledgeEntitySnapshot, _ role: SourceEntityAssociationRole) async throws {
            _ = try await store.linkSource(source.id, to: entity.entity.id, role: role,
                expectedSource: store.sourceSnapshot(id: source.id).revision, expectedEntity: store.loadEntity(id: entity.entity.id).revision,
                expectedVaultRevision: store.canonicalVaultRevision(), operationID: UUID())
        }
        try await associate(source, work, .representsWork)
        try await associate(source, work, .aboutEntity)
        try await associate(source, person, .aboutEntity)
        if full {
            let trash = try await repository.importSource(data: Data("Preserved trashed QA original".utf8), filename: "trash.txt", title: "QA Source in Trash", originURL: nil)
            try await associate(trash, work, .aboutEntity)
            try await repository.deleteSource(trash)
            let offline = try await repository.importSource(data: Data("Preserved offline QA original".utf8), filename: "offline.txt", title: "QA offline original", originURL: nil)
            try await associate(offline, work, .aboutEntity)
            let content = repository.contentStore
            try content.createDirectory(at: "QA Offline Preservation")
            let path = "Sources/\(offline.id.uuidString.lowercased())/\(offline.metadata.storedFilename)"
            try content.move(from: path, to: "QA Offline Preservation/\(offline.id.uuidString).txt", expected: content.snapshot(at: path))
            for index in 0..<99 {
                let extra = try await repository.importSource(data: Data("QA pagination original \(index)".utf8), filename: "page-\(index).txt", title: "QA pagination \(index + 1)", originURL: nil)
                try await associate(extra, work, .representsWork)
            }
        }
        #endif
        try await store.checkpoint(); try await store.close()
    }
}

@MainActor private struct BridgeQARoot: View {
    @Bindable var state: BridgeQAState
    @State private var query = ""
    @State private var selection: KnowledgeCatalogueSelection?
    private var modes: [String] {
        #if ENT05_SOURCE_LINKS
        ["Entity properties", "Knowledge library", "Source links", "Entity sources"]
        #else
        ["Entity properties", "Knowledge library"]
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ENT\(state.phase) Native QA · Synthetic Fixtures Only").font(.title2)
            Text(state.run.path).font(.caption).textSelection(.enabled)
            HStack {
                Button("Refresh") { Task { await state.refresh() } }.disabled(state.busy || state.model.isLocked)
                Button("Lock") { Task { await state.lock() } }.disabled(state.busy || state.model.isLocked)
                Button("Unlock") { Task { await state.unlock() } }.disabled(state.busy || !state.model.isLocked)
                Button("Switch synthetic vault") { Task { await state.switchVault() } }.disabled(state.busy)
            }
            Text(state.message).font(.caption).foregroundStyle(.secondary)
            if state.busy { ProgressView() }
            if let error = state.model.errorMessage { Text(error).foregroundStyle(.red) }
            Picker("Acceptance view", selection: $state.mode) { ForEach(modes, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            if state.mode != "Knowledge library" {
                Picker("Synthetic entity", selection: $state.selectedEntityID) {
                    Text("Choose entity").tag(nil as UUID?)
                    ForEach(state.entities, id: \.entity.id) { value in Text(value.entity.label).tag(value.entity.id as UUID?) }
                }.disabled(state.model.isLocked)
            }
            Divider()
            if state.mode == "Knowledge library" {
                KnowledgeLibraryView(model: state.model, query: $query, selection: $selection) { Text("Use Knowledge Entities for template acceptance.") }
            } else if state.mode == "Entity properties", let id = state.selectedEntityID, !state.model.isLocked {
                ScrollView { EntityPropertiesView(model: state.model, entityID: id).id(id).padding() }
            }
            #if ENT05_SOURCE_LINKS
            if state.mode == "Source links", !state.model.isLocked {
                Picker("Synthetic Source", selection: $state.selectedSourceID) {
                    Text("Choose Source").tag(nil as UUID?)
                    ForEach(state.model.sources, id: \.id) { source in Text(source.title).tag(source.id as UUID?) }
                }
                if let id = state.selectedSourceID { ScrollView { SourceEntityLinksView(model: state.model, sourceID: id).id(id).padding() } }
            } else if state.mode == "Entity sources", let id = state.selectedEntityID, !state.model.isLocked {
                ScrollView { EntitySourceLinksView(model: state.model, entityID: id).id(id).padding() }
            }
            #endif
            Spacer(minLength: 0)
        }
        .padding(20).frame(minWidth: 760, minHeight: 640)
        .onChange(of: state.model.sessionState.sessionID) { selection = nil; query = "" }
        .onChange(of: state.model.isLocked) { selection = nil; query = "" }
    }
}
