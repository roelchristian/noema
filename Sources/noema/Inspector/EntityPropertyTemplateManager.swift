import SwiftUI
import VaultCore

/// Edits suggestion membership only. Facts remain in the existing property editor.
struct EntityPropertyTemplateManager: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var typeKey: String
    @State private var configuration: EntityPropertyTemplateConfiguration?
    @State private var definitionIDs: [UUID] = []
    @State private var selectedDefinitionID: UUID?
    @State private var request = UUID()
    @State private var active = false
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    init(model: AppModel, initialTypeKey: String) {
        self.model = model
        _typeKey = State(initialValue: initialTypeKey)
    }

    private var identity: String { "\(typeKey):\(String(describing: model.sessionState.sessionID)):\(model.isLocked)" }
    private var editable: Bool { configuration != nil && model.canEditSemanticTarget && !model.isLocked && !busy }
    private var hasChanges: Bool {
        guard let configuration else { return false }
        return definitionIDs != configuration.template.definitionIDs || configuration.template.revision == nil
    }
    private var availableDefinitions: [EntityPropertyDefinitionSnapshot] {
        configuration?.definitions.filter { !$0.definition.isRetired && !definitionIDs.contains($0.definition.id) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            Text("Property templates").font(NoemaTypography.interfaceEmphasis)
            Text("Choose optional suggestions for each entity type. Saving a template leaves entity values unchanged.")
                .font(NoemaTypography.metadata).foregroundStyle(.secondary)
            Picker("Entity type", selection: $typeKey) {
                ForEach(KnowledgeEntityType.initial, id: \.key) { type in
                    Text(KnowledgeTypePresentation.label(for: type.key)).tag(type.key)
                }
            }.disabled(busy)
            Text("Switching type discards unsaved template changes.").font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Loading or saving property template") }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).accessibilityLabel("Template error: \(error)") }
            if configuration != nil && !model.isLocked {
                Text("\(definitionIDs.count) of \(EntityPropertyTemplateSnapshot.maximumEntries) suggestions")
                    .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                        if definitionIDs.isEmpty { Text("No suggestions configured.").foregroundStyle(.secondary) }
                        ForEach(Array(definitionIDs.enumerated()), id: \.element) { index, id in
                            templateRow(id: id, index: index)
                        }
                    }
                }.frame(minHeight: 100, maxHeight: 250)
                Picker("Existing property", selection: $selectedDefinitionID) {
                    Text("Choose a property").tag(nil as UUID?)
                    ForEach(availableDefinitions, id: \.definition.id) { value in
                        Text("\(value.definition.label) · \(value.definition.kind.rawValue)").tag(value.definition.id as UUID?)
                    }
                }.disabled(!editable || definitionIDs.count >= EntityPropertyTemplateSnapshot.maximumEntries)
                Button("Add suggestion") {
                    guard editable, let id = selectedDefinitionID,
                          availableDefinitions.contains(where: { $0.definition.id == id }),
                          definitionIDs.count < EntityPropertyTemplateSnapshot.maximumEntries else { return }
                    definitionIDs.append(id); selectedDefinitionID = nil; saved = false
                }.disabled(!editable || selectedDefinitionID == nil || definitionIDs.count >= EntityPropertyTemplateSnapshot.maximumEntries)
                if availableDefinitions.isEmpty {
                    Text("Create additional reusable properties in the entity property editor.").font(.caption).foregroundStyle(.secondary)
                }
                if saved { Text("Template saved.").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Reload") { Task { await reload() } }.disabled(busy || model.isLocked)
                Button("Save template") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(!editable || !hasChanges)
            }
        }
        .padding()
        .frame(width: 480)
        .task { active = true; await reload() }
        .onChange(of: identity) { invalidate(); Task { await reload() } }
        .onDisappear { active = false; invalidate() }
    }

    private func templateRow(id: UUID, index: Int) -> some View {
        let definition = configuration?.definitions.first { $0.definition.id == id }?.definition
        let label = definition?.label ?? "Unavailable property"
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if definition?.isRetired == true {
                    Text("Retired · retained until removed").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { move(index, offset: -1) } label: { Image(systemName: "arrow.up") }
                .accessibilityLabel("Move \(label) earlier").disabled(!editable || index == 0)
            Button { move(index, offset: 1) } label: { Image(systemName: "arrow.down") }
                .accessibilityLabel("Move \(label) later").disabled(!editable || index == definitionIDs.count - 1)
            Button(role: .destructive) {
                guard editable else { return }
                definitionIDs.removeAll { $0 == id }; saved = false
            } label: { Image(systemName: "minus.circle") }
                .accessibilityLabel("Remove \(label) suggestion").disabled(!editable)
        }
    }

    private func move(_ index: Int, offset: Int) {
        guard editable, definitionIDs.indices.contains(index), definitionIDs.indices.contains(index + offset) else { return }
        definitionIDs.swapAt(index, index + offset); saved = false
    }

    private func invalidate() {
        request = UUID(); configuration = nil; definitionIDs = []; selectedDefinitionID = nil
        error = nil; saved = false; busy = false
    }

    private func current(_ token: UUID, type: String, sessionID: UUID?) -> Bool {
        active && !Task.isCancelled && request == token && typeKey == type &&
            model.sessionState.sessionID == sessionID && !model.isLocked
    }

    @discardableResult private func reload() async -> Bool {
        invalidate()
        guard active, !model.isLocked else { return false }
        let token = request, type = typeKey, sessionID = model.sessionState.sessionID
        busy = true
        do {
            let loaded = try await model.loadPropertyTemplateConfiguration(typeKey: type)
            guard current(token, type: type, sessionID: sessionID) else { return false }
            configuration = loaded; definitionIDs = loaded.template.definitionIDs; busy = false
            return true
        } catch {
            guard current(token, type: type, sessionID: sessionID) else { return false }
            if case KnowledgeStoreError.transitionRequired = error {
                self.error = "Property templates require an explicit vault upgrade. Existing properties remain available."
            } else { self.error = error.localizedDescription }
            busy = false
            return false
        }
    }

    private func save() async {
        guard editable, let configuration else { return }
        let token = request, type = typeKey, sessionID = model.sessionState.sessionID
        let ids = definitionIDs
        busy = true; error = nil; saved = false
        do {
            try await model.savePropertyTemplateConfiguration(ids, snapshot: configuration,
                isCurrent: { current(token, type: type, sessionID: sessionID) })
            guard current(token, type: type, sessionID: sessionID) else { return }
            if await reload() { saved = true }
        } catch {
            guard current(token, type: type, sessionID: sessionID) else { return }
            self.error = error.localizedDescription; busy = false
        }
    }
}
