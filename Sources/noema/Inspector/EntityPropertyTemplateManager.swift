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
    @State private var focusRequest = UUID()
    @FocusState private var focusedControl: EntityPropertyTemplateFocus?
    @AccessibilityFocusState(for: .voiceOver) private var accessibleControl: EntityPropertyTemplateFocus?

    init(model: AppModel, initialTypeKey: String) {
        self.model = model
        _typeKey = State(initialValue: initialTypeKey)
    }

    private var identity: String { "\(typeKey):\(String(describing: model.sessionState.sessionID)):\(model.isLocked)" }
    private var displayed: EntityPropertyTemplateConfiguration? {
        guard let configuration, EntityPropertyTemplatePresentation.canDisplay(configuration, typeKey: typeKey,
            sessionID: model.sessionState.sessionID, isLocked: model.isLocked) else { return nil }
        return configuration
    }
    private var editable: Bool { displayed != nil && model.canEditSemanticTarget && !busy }
    private var hasChanges: Bool {
        guard let configuration = displayed else { return false }
        return definitionIDs != configuration.template.definitionIDs || configuration.template.revision == nil
    }
    private var availableDefinitions: [EntityPropertyDefinitionSnapshot] {
        displayed?.definitions.filter { !$0.definition.isRetired && !definitionIDs.contains($0.definition.id) } ?? []
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
            }.disabled(busy).focused($focusedControl, equals: .typePicker)
                .accessibilityFocused($accessibleControl, equals: .typePicker)
            Text("Switching type discards unsaved template changes.").font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.small).accessibilityLabel("Loading or saving property template") }
            if !model.isLocked, let error { status("Template error: \(error)") }
            if displayed != nil {
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
                    .focused($focusedControl, equals: .definitionPicker)
                    .accessibilityFocused($accessibleControl, equals: .definitionPicker)
                Button("Add suggestion") {
                    guard editable, let id = selectedDefinitionID,
                          availableDefinitions.contains(where: { $0.definition.id == id }),
                          definitionIDs.count < EntityPropertyTemplateSnapshot.maximumEntries else { return }
                    definitionIDs.append(id); selectedDefinitionID = nil; saved = false
                    restoreFocus(definitionIDs.count < EntityPropertyTemplateSnapshot.maximumEntries ? .definitionPicker : .typePicker)
                }.disabled(!editable || selectedDefinitionID == nil || definitionIDs.count >= EntityPropertyTemplateSnapshot.maximumEntries)
                if availableDefinitions.isEmpty {
                    Text("Create additional reusable properties in the entity property editor.").font(.caption).foregroundStyle(.secondary)
                }
                if saved { status("Template saved.") }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Reload") { Task { await reload() } }.disabled(busy || model.isLocked)
                Button("Save template") { scheduleSave() }
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
        let definition = displayed?.definitions.first { $0.definition.id == id }?.definition
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
                .focused($focusedControl, equals: .earlier(id))
                .accessibilityFocused($accessibleControl, equals: .earlier(id))
            Button { move(index, offset: 1) } label: { Image(systemName: "arrow.down") }
                .accessibilityLabel("Move \(label) later").disabled(!editable || index == definitionIDs.count - 1)
                .focused($focusedControl, equals: .later(id))
                .accessibilityFocused($accessibleControl, equals: .later(id))
            Button(role: .destructive) {
                guard editable else { return }
                let destination = EntityPropertyTemplateFocus.afterRemoving(id, from: definitionIDs)
                definitionIDs.removeAll { $0 == id }; saved = false
                restoreFocus(destination)
            } label: { Image(systemName: "minus.circle") }
                .accessibilityLabel("Remove \(label) suggestion").disabled(!editable)
                .focused($focusedControl, equals: .remove(id))
                .accessibilityFocused($accessibleControl, equals: .remove(id))
        }
    }

    private func move(_ index: Int, offset: Int) {
        guard editable, definitionIDs.indices.contains(index), definitionIDs.indices.contains(index + offset) else { return }
        let id = definitionIDs[index]
        definitionIDs.swapAt(index, index + offset); saved = false
        let newIndex = index + offset
        // Keep the same action until it reaches its disabled boundary; never move
        // keyboard focus from a reorder action onto the destructive Remove action.
        if offset < 0, newIndex > 0 { restoreFocus(.earlier(id)) }
        else if offset > 0, newIndex < definitionIDs.count - 1 { restoreFocus(.later(id)) }
        else { restoreFocus(.typePicker) }
    }

    private func status(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(message)
            .focusable().focused($focusedControl, equals: .status)
                .accessibilityFocused($accessibleControl, equals: .status)
    }

    /// Restore a surviving native control only while its original selection is current.
    private func restoreFocus(_ destination: EntityPropertyTemplateFocus) {
        let token = request, type = typeKey, sessionID = model.sessionState.sessionID
        let focusID = UUID()
        focusRequest = focusID
        focusedControl = nil; accessibleControl = nil
        Task { @MainActor in
            await Task.yield()
            guard current(token, type: type, sessionID: sessionID), focusRequest == focusID else { return }
            focusedControl = destination; accessibleControl = destination
        }
    }

    private func invalidate() {
        request = UUID(); configuration = nil; definitionIDs = []; selectedDefinitionID = nil
        error = nil; saved = false; busy = false; focusedControl = nil; accessibleControl = nil; focusRequest = UUID()
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
            restoreFocus(.typePicker)
            return true
        } catch {
            guard current(token, type: type, sessionID: sessionID) else { return false }
            if case KnowledgeStoreError.transitionRequired = error {
                self.error = "Property templates require an explicit vault upgrade. Existing properties remain available."
            } else { self.error = error.localizedDescription }
            busy = false
            restoreFocus(.status)
            return false
        }
    }

    private func scheduleSave() {
        guard editable, let configuration = displayed else { return }
        let token = EntityPropertyTemplateRequestToken(typeKey: typeKey,
            sessionID: model.sessionState.sessionID, requestID: request)
        let ids = definitionIDs
        busy = true; error = nil; saved = false
        Task { await save(ids, configuration: configuration, token: token) }
    }

    private func save(_ ids: [UUID], configuration: EntityPropertyTemplateConfiguration,
                      token: EntityPropertyTemplateRequestToken) async {
        guard active, !Task.isCancelled, !model.isLocked,
              token.matches(request: request, typeKey: typeKey, sessionID: model.sessionState.sessionID) else { return }
        guard model.canEditSemanticTarget else { busy = false; return }
        do {
            try await model.savePropertyTemplateConfiguration(ids, snapshot: configuration,
                isCurrent: { current(token.requestID, type: token.typeKey, sessionID: token.sessionID) })
            guard current(token.requestID, type: token.typeKey, sessionID: token.sessionID) else { return }
            if await reload() { saved = true; restoreFocus(.status) }
        } catch {
            guard current(token.requestID, type: token.typeKey, sessionID: token.sessionID) else { return }
            self.error = error.localizedDescription; busy = false; restoreFocus(.status)
        }
    }
}
