import SwiftUI
import VaultCore

/// Reusable in the document inspector and canonical catalogue detail.
struct EntityPropertiesView: View {
    @Bindable var model: AppModel
    let entityID: UUID
    private let previewSnapshot: EntityPropertiesSnapshot?
    @State private var entityChoices: [KnowledgeEntitySnapshot] = []
    @State private var entitySearchRequest = UUID()
    @State private var searchingEntities = false
    @State private var snapshot: EntityPropertiesSnapshot?
    @State private var request = EntityPropertiesRequestToken(entityID: UUID(), sessionID: nil)
    @State private var active = false
    @State private var busy = false
    @State private var error: String?
    @State private var expanded = false
    @State private var editorExpanded = false
    @State private var query = ""
    @State private var selectedDefinition: UUID?
    @State private var kind: EntityPropertyKind = .text
    @State private var many = false
    @State private var text = ""
    @State private var boolean = false
    @State private var otherID: UUID?
    @State private var entityQuery = ""
    @State private var incoming = false
    @State private var draftRequest = UUID()
    @State private var editingAssignment: UUID?
    @State private var inverseLabel = ""
    @State private var sourceTypeKeys: Set<String> = []
    @State private var targetTypeKeys: Set<String> = []
    @State private var definitionLabel = ""
    @State private var pendingRemoval: EntityPropertyEdit?
    @State private var relatedEntityID: UUID?

    init(model: AppModel, entityID: UUID, previewSnapshot: EntityPropertiesSnapshot? = nil) {
        self.model = model; self.entityID = entityID; self.previewSnapshot = previewSnapshot
        _snapshot = State(initialValue: previewSnapshot)
    }

    private var definition: EntityPropertyDefinition? {
        snapshot?.definitions.first { $0.definition.id == selectedDefinition }?.definition
    }
    private var editable: Bool { model.canEditSemanticTarget && snapshot?.entity.entity.lifecycle == .live && !busy }
    private var taskIdentity: String { "\(entityID):\(String(describing: model.sessionState.sessionID)):\(model.isLocked)" }

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            HStack {
                Text("Entity Properties").font(NoemaTypography.interfaceEmphasis)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh entity properties").disabled(busy)
            }
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(NoemaTypography.metadata).foregroundStyle(.secondary) }
            if let snapshot {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.entity.entity.label).font(NoemaTypography.interfaceEmphasis)
                    Text("\(KnowledgeTypePresentation.label(for: snapshot.entity.entity.typeKey)) · \(snapshot.entity.entity.id.uuidString.prefix(8))")
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                entries(snapshot)
                if snapshot.values.assignments.isEmpty && snapshot.relationships.isEmpty {
                    Text("No properties set.").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                DisclosureGroup("Add or edit property", isExpanded: $editorExpanded) {
                    editor(snapshot).disabled(!editable)
                }
                if !snapshot.supportsRelationships {
                    Text("Entity relationships require an explicit vault upgrade. Scalar properties remain available.").font(.caption).foregroundStyle(.secondary)
                }
                if snapshot.entity.entity.lifecycle != .live {
                    Text("Deleted entity · properties are preserved and read-only.").font(.caption).foregroundStyle(.secondary)
                }
            } else if !busy && error == nil { Text("Properties unavailable.").font(.caption) }
        }
        .task(id: taskIdentity) { active = true; if previewSnapshot == nil { await reload() } }
        .task(id: entityQuery + taskIdentity) { if previewSnapshot == nil { await searchEntities() } }
        .onDisappear { active = false; request = .init(entityID: entityID, sessionID: model.sessionState.sessionID) }
        .sheet(isPresented: Binding(get: { relatedEntityID != nil }, set: { if !$0 { relatedEntityID = nil } })) {
            if let relatedEntityID { AnyView(EntityPropertiesDetail(model: model, entityID: relatedEntityID)) }
        }
        .onChange(of: entityQuery) { otherID = nil }
        .onChange(of: selectedDefinition) { editingAssignment = nil; text = ""; boolean = false; otherID = nil
            if let definition {
                definitionLabel = definition.label
                inverseLabel = definition.presentation?.inverseLabel ?? ""
                sourceTypeKeys = Set(definition.presentation?.sourceTypeKeys ?? [])
                targetTypeKeys = Set(definition.presentation?.targetTypeKeys ?? [])
            }
        }
        .confirmationDialog("Remove this property value?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove value", role: .destructive) {
                if let edit = pendingRemoval { Task { await perform(edit) } }; pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
    }

    @ViewBuilder private func entries(_ snapshot: EntityPropertiesSnapshot) -> some View {
        let total = snapshot.values.assignments.count + snapshot.relationships.count
        let limit = expanded ? total : EntityPropertiesPresentation.previewLimit
        ForEach(Array(snapshot.values.assignments.prefix(limit))) { assignment in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.definitions.first { $0.definition.id == assignment.definitionID }?.definition.label ?? "Unavailable definition").font(.caption).foregroundStyle(.secondary)
                    Text(EntityPropertiesPresentation.display(assignment.value)).textSelection(.enabled)
                }
                Spacer()
                Button("Edit") {
                    let token = request, draftID = UUID()
                    draftRequest = draftID
                    editorExpanded = true
                    selectedDefinition = assignment.definitionID
                    // Defer draft initialization until the definition change has reset the previous draft.
                    Task { @MainActor in
                        await Task.yield()
                        guard current(token), draftRequest == draftID, selectedDefinition == assignment.definitionID else { return }
                        editingAssignment = assignment.id
                        text = EntityPropertiesPresentation.display(assignment.value)
                        if case .boolean(let value) = assignment.value { boolean = value }
                    }
                }.disabled(!editable)
                Button(role: .destructive) {
                    pendingRemoval = .saveValues(snapshot.values.assignments.filter { $0.id != assignment.id })
                } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove property value").disabled(!editable)
            }
        }
        ForEach(Array(snapshot.relationships.prefix(max(0, limit - snapshot.values.assignments.count))), id: \.relationship.id) { edge in
            relationshipRow(edge, snapshot: snapshot)
        }
        if total > EntityPropertiesPresentation.previewLimit {
            Button(expanded ? "Show fewer" : "Show all \(total) properties") { expanded.toggle() }
        }
    }

    private func relationshipRow(_ edge: EntityPropertyRelationshipSnapshot, snapshot: EntityPropertiesSnapshot) -> some View {
        let incoming = edge.relationship.targetID == entityID && edge.relationship.sourceID != entityID
        let other = incoming ? edge.relationship.sourceID : edge.relationship.targetID
        let definition = snapshot.definitions.first { $0.definition.id == edge.relationship.definitionID }?.definition
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.map { EntityPropertiesPresentation.relationshipLabel($0, incoming: incoming) } ?? "Unavailable definition").font(.caption).foregroundStyle(.secondary)
                if let endpoint = snapshot.entities.first(where: { $0.entity.id == other }) {
                    Button(endpoint.entity.label) { relatedEntityID = other }
                        .buttonStyle(.link)
                        .help("Inspect \(endpoint.entity.label) properties")
                } else { Text("Unavailable entity") }
            }
            Spacer()
            Button(role: .destructive) { pendingRemoval = .removeRelationship(edge) } label: { Image(systemName: "minus.circle") }
                .accessibilityLabel("Remove canonical relationship").disabled(!editable)
        }
    }

    private func editor(_ snapshot: EntityPropertiesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            TextField("Search or name property", text: $query)
            Picker("Reusable property", selection: $selectedDefinition) {
                Text("Choose property").tag(nil as UUID?)
                ForEach(EntityPropertiesPresentation.matchingDefinitions(snapshot.definitions, query: query), id: \.definition.id) { value in
                    Text("\(value.definition.label) · \(value.definition.kind.rawValue)").tag(value.definition.id as UUID?)
                }
            }
            if let definition {
                Text(definition.cardinality == .one ? "One value" : "Multiple values").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Edit reusable definition") {
                    TextField("Property label", text: $definitionLabel)
                    if definition.kind == .entityReference { relationshipMetadata }
                    Button("Save definition") {
                        var edited = definition
                        edited.label = definitionLabel
                        if definition.kind == .entityReference { edited.presentation = relationshipPresentation }
                        Task { await perform(.saveDefinition(edited)) }
                    }
                }
                if definition.isRetired { Text("Retired property · existing values may be removed.").font(.caption) }
                if definition.kind == .entityReference {
                    Toggle("Incoming relationship", isOn: $incoming)
                    if let otherID, let other = snapshot.entities.first(where: { $0.entity.id == otherID }) {
                        let source = incoming ? other.entity.typeKey : snapshot.entity.entity.typeKey
                        let target = incoming ? snapshot.entity.entity.typeKey : other.entity.typeKey
                        let hints = definition.presentation
                        if (hints?.sourceTypeKeys.isEmpty == false && hints?.sourceTypeKeys.contains(source) == false) || (hints?.targetTypeKeys.isEmpty == false && hints?.targetTypeKeys.contains(target) == false) {
                            Text("Outside the suggested entity types. You can still add this relationship.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Search canonical entities", text: $entityQuery)
                    Picker("Canonical entity", selection: $otherID) {
                        Text("Choose entity").tag(nil as UUID?)
                        ForEach(entityChoices.filter { $0.entity.lifecycle == .live }, id: \.entity.id) { value in
                            Text("\(value.entity.label) · \(KnowledgeTypePresentation.label(for: value.entity.typeKey)) · \(value.entity.id.uuidString.prefix(8))").tag(value.entity.id as UUID?)
                        }
                    }
                    if searchingEntities { ProgressView().controlSize(.mini) }
                    Text("Searches canonical entities · up to 100 matches").font(.caption).foregroundStyle(.secondary)
                    Button("Add relationship") {
                        if let otherID { Task { await perform(.addRelationship(definitionID: definition.id, otherID: otherID, incoming: incoming)) } }
                    }.disabled(otherID == nil || definition.isRetired)
                } else {
                    if definition.kind == .boolean { Toggle("Value", isOn: $boolean) }
                    else { TextField(definition.kind == .date ? "YYYY, YYYY-MM, or YYYY-MM-DD" : "Value", text: $text) }
                    Button(editingAssignment == nil ? "Set value" : "Save value") { saveScalar(definition, snapshot: snapshot) }.disabled(definition.isRetired)
                    if editingAssignment != nil { Button("Cancel editing") { editingAssignment = nil; text = "" } }
                }
            }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !snapshot.definitions.contains(where: { $0.definition.normalizedKey == EntityPropertyDefinition.normalize(query) }) {
                Picker("New property kind", selection: $kind) { ForEach(EntityPropertyKind.allCases.filter { snapshot.supportsRelationships || $0 != .entityReference }, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("Allow multiple values", isOn: $many)
                if kind == .entityReference { relationshipMetadata }
                Button("Create reusable property") { Task { await perform(.createDefinition(label: query, kind: kind, cardinality: many ? .many : .one, presentation: kind == .entityReference ? relationshipPresentation : nil)) } }
            }
        }.padding(.top, NoemaSpacing.xs)
    }

    private var relationshipPresentation: EntityPropertyPresentation {
        var presentation = EntityPropertyPresentation(
            inverseLabel: inverseLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : inverseLabel,
            sourceTypeKeys: sourceTypeKeys.sorted(), targetTypeKeys: targetTypeKeys.sorted())
        presentation.unknownFields = definition?.presentation?.unknownFields ?? [:]
        return presentation
    }
    private var relationshipMetadata: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
            TextField("Incoming label (optional)", text: $inverseLabel)
            Text("Suggested types are advisory; other entities remain allowed.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Suggested source types") { typeHints($sourceTypeKeys) }
            DisclosureGroup("Suggested target types") { typeHints($targetTypeKeys) }
        }
    }
    private func typeHints(_ selection: Binding<Set<String>>) -> some View {
        ForEach(KnowledgeEntityType.initial, id: \.key) { type in
            Toggle(KnowledgeTypePresentation.label(for: type.key), isOn: Binding(
                get: { selection.wrappedValue.contains(type.key) },
                set: { if $0 { selection.wrappedValue.insert(type.key) } else { selection.wrappedValue.remove(type.key) } }
            ))
        }
    }
    private func saveScalar(_ definition: EntityPropertyDefinition, snapshot: EntityPropertiesSnapshot) {
        do {
            let value = try EntityPropertyInput.value(kind: definition.kind, text: text, boolean: boolean)
            var assignments = snapshot.values.assignments
            if let id = editingAssignment, let index = assignments.firstIndex(where: { $0.id == id }) {
                assignments[index] = .init(id: id, definitionID: definition.id, value: value)
            } else {
                let existingID = definition.cardinality == .one ? assignments.first(where: { $0.definitionID == definition.id })?.id : nil
                if definition.cardinality == .one { assignments.removeAll { $0.definitionID == definition.id } }
                assignments.append(.init(id: existingID ?? UUID(), definitionID: definition.id, value: value))
            }
            Task { await perform(.saveValues(assignments)) }
        } catch { self.error = error.localizedDescription }
    }
    private func searchEntities() async {
        let queryID = UUID(), token = request
        entitySearchRequest = queryID; searchingEntities = true
        do {
            let choices = try await model.searchEntityPropertyTargets(query: entityQuery)
            guard current(token), entitySearchRequest == queryID else { return }
            entityChoices = choices
            if var loaded = snapshot {
                for choice in choices where !loaded.entities.contains(where: { $0.entity.id == choice.entity.id }) {
                    loaded.entities.append(choice)
                }
                snapshot = loaded
            }
            searchingEntities = false
        } catch { if current(token), entitySearchRequest == queryID { self.error = error.localizedDescription; searchingEntities = false } }
    }
    private func reload() async {
        let token = EntityPropertiesRequestToken(entityID: entityID, sessionID: model.sessionState.sessionID)
        request = token; snapshot = nil; error = nil; busy = true
        editingAssignment = nil; selectedDefinition = nil; expanded = false; pendingRemoval = nil; draftRequest = UUID()
        do {
            let result = try await model.loadEntityProperties(entityID: entityID)
            guard current(token) else { return }
            snapshot = result; busy = false
            if !result.supportsRelationships && kind == .entityReference { kind = .text }
            await searchEntities()
        } catch {
            if current(token) {
                if case KnowledgeStoreError.transitionRequired = error {
                    self.error = "Entity properties require an explicit vault upgrade. Existing vault data has been preserved."
                } else { self.error = error.localizedDescription }
                busy = false
            }
        }
    }
    private func current(_ token: EntityPropertiesRequestToken) -> Bool {
        active && !Task.isCancelled && token.matches(request: request, entityID: entityID, sessionID: model.sessionState.sessionID) && !model.isLocked
    }
    private func perform(_ edit: EntityPropertyEdit) async {
        guard let snapshot, !busy else { return }
        let token = request
        busy = true; error = nil
        do {
            try await model.editEntityProperties(edit, snapshot: snapshot, isCurrent: { current(token) })
            guard current(token) else { return }
            await reload()
        } catch { if current(token) { self.error = error.localizedDescription; busy = false } }
    }
}

struct EntityPropertiesDetail: View {
    @Bindable var model: AppModel
    let entityID: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            ScrollView { EntityPropertiesView(model: model, entityID: entityID).padding() }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
        }.frame(width: 400, height: 500)
    }
}
