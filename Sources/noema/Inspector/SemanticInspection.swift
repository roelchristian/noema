import SwiftUI
import VaultCore

/// Presentation snapshots retain canonical identity and concurrency evidence.
enum SemanticInspectionTarget: Equatable, Sendable {
    case entity(KnowledgeEntitySnapshot)
    case object(SemanticObjectSnapshot)
    case unavailable(EntityIdentity)
    var title: String {
        switch self {
        case .entity(let value): value.entity.label
        case .object(let value): value.object.typeKey == "question" ? Self.questionText(value.object) : (value.object.term ?? "Definition")
        case .unavailable: "Unavailable target"
        }
    }
    var kind: String {
        switch self { case .entity(let v): v.entity.typeKey; case .object(let v): v.object.typeKey; case .unavailable(let v): v.kind }
    }
    var isEditable: Bool {
        switch self { case .entity(let v): v.entity.lifecycle == .live; case .object(let v): v.object.lifecycle == .live; case .unavailable: false }
    }
    static func questionText(_ object: SemanticObject) -> String {
        if case .string(let text) = object.properties.properties["questionText"], !text.isEmpty { return text }
        return "Question text unavailable"
    }
}
struct SemanticInspectionRecord: Identifiable, Equatable, Sendable {
    var annotation: SemanticAnnotation
    var target: SemanticInspectionTarget
    var subject: KnowledgeEntitySnapshot?
    var occurrences: [SemanticAnnotationSnapshot] = []
    var occurrencePreviews: [SemanticOccurrencePreview] = []
    var id: UUID { annotation.id }
}

/// Group only the page's current annotations, including unsaved editor annotations.
/// Global occurrence snapshots must not inflate a document-local mention count.
struct SemanticEntityGroup: Identifiable, Equatable, Sendable {
    let records: [SemanticInspectionRecord]
    var id: UUID { records[0].annotation.referent.identity.id }
    var target: SemanticInspectionTarget { records[0].target }
    var mentionCount: Int { records.count }
    var navigableRecords: [SemanticInspectionRecord] { records.filter { $0.annotation.anchorDisposition == .resolved } }

    static func make(records: [SemanticInspectionRecord], pageID: UUID) -> [Self] {
        var groups: [Self] = []
        for record in records where record.annotation.location.pageID == pageID && record.annotation.anchorDisposition != .deleted {
            guard !["question", "definition"].contains(record.annotation.referent.identity.kind) else { continue }
            if let index = groups.firstIndex(where: { $0.records[0].annotation.referent.identity == record.annotation.referent.identity }) {
                groups[index] = .init(records: groups[index].records + [record])
            } else { groups.append(.init(records: [record])) }
        }
        return groups
    }
}

struct SemanticInspectionSection: View {
    @Bindable var model: AppModel
    let pageID: UUID
    @State private var selectedType: String = "all"
    private var records: [SemanticInspectionRecord] {
        model.semanticInspectionPageID == pageID ? model.semanticInspectionRecords : []
    }
    private var groups: [SemanticEntityGroup] { SemanticEntityGroup.make(records: records, pageID: pageID) }
    private var visibleGroups: [SemanticEntityGroup] {
        groups.filter { selectedType == "all" || $0.target.kind == selectedType }
    }
    private var otherRecords: [SemanticInspectionRecord] {
        records.filter { ["question", "definition"].contains($0.annotation.referent.identity.kind) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            InspectorSection(title: "Entities", count: groups.count) {
                Text("People, places, concepts and events linked to this document.")
                    .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                InspectionAuthorityCaption(authority: .canonicalKnowledge)
                ScrollView(.horizontal) {
                    HStack(spacing: NoemaSpacing.xs) {
                        typeFilter("All", key: "all")
                        ForEach(KnowledgeEntityType.initial, id: \.key) { type in
                            typeFilter(KnowledgeTypePresentation.label(for: type.key), key: type.key)
                        }
                    }
                }.scrollIndicators(.hidden)
                if let error = model.semanticInspectionError {
                    Text(error).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                if visibleGroups.isEmpty {
                    Text(model.semanticInspectionLoading ? "Loading entities…" : (groups.isEmpty ? "No entities linked to this document." : "No entities of this type."))
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                ForEach(visibleGroups) { group in
                    SemanticEntityRow(model: model, group: group)
                }
                Button {
                    model.semanticCoordinator?.annotateSelection(nil)
                } label: {
                    Label("Link entity to selection…", systemImage: "plus")
                }.disabled(!model.canAnnotateSelection || !model.canEditSemanticAssociation)
                    .help("Select text in the editor to link a canonical target.")
            } actions: {
                Button { model.semanticCoordinator?.annotateSelection(nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Link entity to selected text")
                    .disabled(!model.canAnnotateSelection || !model.canEditSemanticAssociation)
                Button { Task { await model.refreshSemanticInspection(pageID: pageID) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh canonical targets").disabled(model.semanticInspectionLoading)
            }
            if !otherRecords.isEmpty {
                InspectorSection(title: "Semantic objects", count: otherRecords.count) {
                    ForEach(otherRecords) { record in SemanticInspectionRow(model: model, record: record) }
                }
            }
        }
        .task(id: pageID) { await model.refreshSemanticInspection(pageID: pageID) }
        .onChange(of: pageID) { selectedType = "all" }
        .onChange(of: model.semanticInspectionFocusID) {
            if let record = records.first(where: { $0.id == model.semanticInspectionFocusID }),
               selectedType != "all", selectedType != record.target.kind { selectedType = "all" }
        }
        .onChange(of: model.body) { Task { await model.refreshSemanticInspection(pageID: pageID) } }
        .onChange(of: model.semanticSavedRevision) { Task { await model.refreshSemanticInspection(pageID: pageID) } }
    }
    private func typeFilter(_ title: String, key: String) -> some View {
        Button { selectedType = key } label: {
            Text(title).font(NoemaTypography.metadata).padding(.horizontal, NoemaSpacing.sm).padding(.vertical, NoemaSpacing.xs)
                .background(selectedType == key ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(selectedType == key ? .isSelected : [])
    }
}

struct SemanticEntityRow: View {
    @Bindable var model: AppModel
    let group: SemanticEntityGroup
    @State private var editingTarget = false
    @State private var inspectingProperties = false
    @State private var changingAnnotation: SemanticInspectionRecord?
    @State private var removingAnnotation: SemanticInspectionRecord?
    private var focused: Bool { group.records.contains { $0.id == model.semanticInspectionFocusID } }
    private var tint: Color {
        switch group.target.kind {
        case "person": .blue
        case "place": .green
        case "concept": .orange
        case "event": .purple
        default: .secondary
        }
    }
    var body: some View {
        HStack(spacing: NoemaSpacing.sm) {
            Button {
                if let record = group.navigableRecords.first { model.navigateSemanticAssociation(record.annotation) }
            } label: {
                HStack(spacing: NoemaSpacing.sm) {
                    Image(systemName: KnowledgeTypePresentation.symbol(for: group.target.kind))
                        .font(.system(size: 17)).foregroundStyle(tint).frame(width: 32, height: 32)
                        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.target.title).font(NoemaTypography.interfaceEmphasis).lineLimit(2)
                        Text(KnowledgeTypePresentation.label(for: group.target.kind)).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Text("\(group.mentionCount) \(group.mentionCount == 1 ? "mention" : "mentions")")
                        .font(NoemaTypography.metadata).foregroundStyle(.secondary).fixedSize()
                    Image(systemName: "chevron.right").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(group.navigableRecords.isEmpty)
                .help("Find this entity in the document")
            Menu {
                Button("Entity properties…") { inspectingProperties = true }
                Button("Edit shared target…") { editingTarget = true }
                    .disabled(!group.target.isEditable || !model.canEditSemanticTarget)
                ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                    Menu("Mention \(index + 1)") {
                        Button("Find in document") { model.navigateSemanticAssociation(record.annotation) }
                            .disabled(record.annotation.anchorDisposition != .resolved)
                        Button("Change association…") { changingAnnotation = record }
                            .disabled(!model.canEditSemanticAssociation)
                        Button("Remove association…", role: .destructive) { removingAnnotation = record }
                            .disabled(!model.canEditSemanticAssociation)
                    }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Manage \(group.target.title) associations")
        }
        .padding(NoemaSpacing.sm)
        .background(focused ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .sheet(isPresented: $editingTarget) { SemanticTargetEditor(model: model, target: group.target) }
        .sheet(isPresented: $inspectingProperties) {
            if case .entity(let value) = group.target {
                EntityPropertiesDetail(model: model, entityID: value.entity.id)
            }
        }
        .sheet(item: $changingAnnotation) { record in SemanticAssociationPicker(model: model, annotationID: record.id) }
        .confirmationDialog("Remove this association? The shared entity will be kept.", isPresented: Binding(
            get: { removingAnnotation != nil }, set: { if !$0 { removingAnnotation = nil } }
        ), titleVisibility: .visible) {
            if let record = removingAnnotation {
                Button("Remove association", role: .destructive) { Task { _ = await model.removeInspectedAssociation(record.id) } }
            }
            Button("Cancel", role: .cancel) { removingAnnotation = nil }
        }
    }
}

struct SemanticInspectionRow: View {
    @Bindable var model: AppModel
    let record: SemanticInspectionRecord
    @State private var expanded = false
    @State private var editingTarget = false
    @State private var changingAssociation = false
    @State private var confirmingRemoval = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                details
                if record.annotation.anchorDisposition != .resolved {
                    Text("Anchor needs review").font(NoemaTypography.metadata).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Go to text") { model.navigateSemanticAssociation(record.annotation) }
                        .disabled(record.annotation.anchorDisposition != .resolved)
                    Button("Edit target…") { editingTarget = true }
                        .disabled(!record.target.isEditable || !model.canEditSemanticTarget)
                }
                HStack {
                    Button("Change association…") { changingAssociation = true }
                        .disabled(!model.canEditSemanticAssociation)
                    Button("Remove", role: .destructive) { confirmingRemoval = true }
                        .disabled(!model.canEditSemanticAssociation)
                }
                if confirmingRemoval {
                    Text("Remove this association? The shared target will be kept.").font(NoemaTypography.metadata)
                    HStack {
                        Button("Remove association", role: .destructive) {
                            Task { if await model.removeInspectedAssociation(record.id) { confirmingRemoval = false } }
                        }
                        Button("Cancel") { confirmingRemoval = false }
                    }
                }
                if !record.occurrencePreviews.isEmpty {
                    DisclosureGroup("Occurrences (\(record.occurrencePreviews.count))") {
                        ForEach(record.occurrencePreviews) { occurrence in
                            VStack(alignment: .leading, spacing: 3) {
                                Button(occurrence.pageTitle) { model.navigateSemanticAssociation(occurrence.annotation) }
                                    .disabled(!occurrence.canNavigate)
                                    .help(occurrence.canNavigate ? "Go to this annotated block" : occurrence.state.rawValue)
                                Text(occurrence.context).lineLimit(3).font(NoemaTypography.metadata)
                                Text(occurrence.stateLabel).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }.padding(.top, NoemaSpacing.sm)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.target.title).font(NoemaTypography.interfaceEmphasis).lineLimit(2)
                Label(KnowledgeTypePresentation.label(for: record.target.kind), systemImage: KnowledgeTypePresentation.symbol(for: record.target.kind)).font(NoemaTypography.metadata).foregroundStyle(.secondary)
            }
        }
        .onAppear { expanded = model.semanticInspectionFocusID == record.id }
        .onChange(of: model.semanticInspectionFocusID) { if model.semanticInspectionFocusID == record.id { expanded = true } }
        .sheet(isPresented: $editingTarget) { SemanticTargetEditor(model: model, target: record.target) }
        .sheet(isPresented: $changingAssociation) { SemanticAssociationPicker(model: model, annotationID: record.id) }
    }
    @ViewBuilder private var details: some View {
        switch record.target {
        case .entity(let snapshot):
            if let description = snapshot.entity.description, !description.isEmpty { Text(description) }
            if !snapshot.entity.aliases.isEmpty {
                InspectorProperty("Aliases", snapshot.entity.aliases.map(\.label).joined(separator: ", "))
            }
            if snapshot.entity.lifecycle != .live { Text("Target unavailable").foregroundStyle(.secondary) }
        case .object(let snapshot):
            if snapshot.object.typeKey == "question" {
                InspectorProperty("Status", snapshot.object.questionStatus.rawValue.capitalized)
                if let answer = snapshot.object.answerText, !answer.isEmpty { Text(answer) }
            } else {
                Text(snapshot.object.definitionText ?? "Definition text unavailable")
                if let subject = record.subject { InspectorProperty("Subject", subject.entity.label) }
            }
            if snapshot.object.lifecycle != .live { Text("Target unavailable").foregroundStyle(.secondary) }
        case .unavailable: Text("The canonical target could not be loaded.").foregroundStyle(.secondary)
        }
    }
}

struct SemanticTargetEditor: View {
    @Bindable var model: AppModel
    let target: SemanticInspectionTarget
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var detail: String
    @State private var answer: String
    @State private var answered: Bool
    @State private var saving = false
    init(model: AppModel, target: SemanticInspectionTarget) {
        self.model = model; self.target = target
        switch target {
        case .entity(let v):
            _name = State(initialValue: v.entity.label); _detail = State(initialValue: v.entity.description ?? "")
            _answer = State(initialValue: ""); _answered = State(initialValue: false)
        case .object(let v):
            let question: String
            if case .string(let text) = v.object.properties.properties["questionText"] { question = text } else { question = "" }
            _name = State(initialValue: v.object.typeKey == "question" ? question : (v.object.term ?? ""))
            _detail = State(initialValue: v.object.definitionText ?? ""); _answer = State(initialValue: v.object.answerText ?? "")
            _answered = State(initialValue: v.object.questionStatus == .answered)
        case .unavailable:
            _name = State(initialValue: ""); _detail = State(initialValue: ""); _answer = State(initialValue: ""); _answered = State(initialValue: false)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            Text("Edit \(KnowledgeTypePresentation.label(for: target.kind))").font(.headline)
            Text("Changes apply to this shared target wherever it appears.").font(.caption).foregroundStyle(.secondary)
            TextField(target.kind == "question" ? "Question text" : (target.kind == "definition" ? "Defined term" : "Canonical name"), text: $name)
            if target.kind == "question" {
                Toggle("Answered", isOn: $answered)
                TextField("Answer", text: $answer, axis: .vertical).lineLimit(3...6)
            } else {
                TextField(target.kind == "definition" ? "Definition" : "Description", text: $detail, axis: .vertical).lineLimit(3...6)
            }
            if let error = model.semanticInspectionError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save target") {
                    saving = true
                    Task {
                        if await model.saveInspectedTarget(target, name: name, detail: detail, answered: answered, answer: answer) { dismiss() }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || !model.canEditSemanticTarget || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding().frame(width: 360)
    }
}

struct SemanticAssociationPicker: View {
    @Bindable var model: AppModel
    let annotationID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [EditorAnnotationChoice] = []
    @State private var selected: Int = 0
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            Text("Change association").font(.headline)
            Text("Choose a target for this occurrence. Canonical targets remain unchanged.").font(.caption).foregroundStyle(.secondary)
            Picker("Target", selection: $selected) {
                ForEach(choices.indices, id: \.self) { index in Label(choices[index].title, systemImage: choices[index].symbol).tag(index) }
            }
            if let error = model.semanticInspectionError { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change association") {
                    guard choices.indices.contains(selected) else { return }
                    saving = true
                    Task {
                        if await model.replaceInspectedAssociation(annotationID, choice: choices[selected]) { dismiss() }
                        saving = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(saving || choices.isEmpty || !model.canEditSemanticAssociation)
            }
        }.padding().frame(width: 360)
        .task {
            do { choices = try await model.annotationChoices() }
            catch { model.semanticInspectionError = error.localizedDescription }
        }
    }
}
