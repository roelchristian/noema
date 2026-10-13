import SwiftUI
import VaultCore

enum KnowledgeLibraryFamily: String, CaseIterable, Identifiable {
    case blocks = "Semantic Blocks", entities = "Knowledge Entities", objects = "Semantic Objects", annotations = "Annotations"
    var id: Self { self }
    var explanation: String {
        switch self {
        case .blocks: "Blocks designated as semantically meaningful. Filter by designation and status."
        case .entities: "Independently identified people, places, concepts, and events. Occurrences are optional."
        case .objects: "Independently stored questions and definitions. These are not blocks or pages."
        case .annotations: "Explicit associations between content locations and canonical referents."
        }
    }
}
enum KnowledgeCatalogueSelection: Identifiable {
    case entity(KnowledgeEntitySnapshot), object(SemanticObjectSnapshot), annotation(SemanticAnnotation)
    var id: String {
        switch self { case .entity(let v): "entity:\(v.entity.id)"; case .object(let v): "object:\(v.object.id)"; case .annotation(let v): "annotation:\(v.id)" }
    }
}
struct KnowledgeLibraryView<Blocks: View>: View {
    @Bindable var model: AppModel
    @Binding var query: String
    @Binding var selection: KnowledgeCatalogueSelection?
    let blocks: Blocks
    init(model: AppModel, query: Binding<String>, selection: Binding<KnowledgeCatalogueSelection?>, @ViewBuilder blocks: () -> Blocks) {
        self.model = model
        self._query = query
        self._selection = selection
        self.blocks = blocks()
    }
    private func matches(_ text: String) -> Bool { query.split(whereSeparator: \.isWhitespace).allSatisfy { text.localizedCaseInsensitiveContains(String($0)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                Picker("Knowledge record family", selection: $model.knowledgeFamily) {
                    ForEach(KnowledgeLibraryFamily.allCases) { family in Text(family.rawValue).tag(family) }
                }.pickerStyle(.menu)
                Text(model.knowledgeFamily.explanation).font(NoemaTypography.metadata).foregroundStyle(.secondary)
                if model.knowledgeFamily != .blocks { TextField("Search \(model.knowledgeFamily.rawValue.lowercased())", text: $query) }
                if let error = model.knowledgeCatalogueError { Text(error).font(.caption).foregroundStyle(.secondary) }
                if model.knowledgeCatalogueLoading { ProgressView().controlSize(.small) }
            }.padding(NoemaSpacing.md)
            if model.knowledgeFamily == .blocks { blocks } else {
                List {
                    switch model.knowledgeFamily {
                    case .entities:
                        ForEach((model.knowledgeCatalogue?.entities ?? []).filter { matches($0.entity.label + " " + ($0.entity.description ?? "") + " " + $0.entity.aliases.map(\.label).joined(separator: " ")) }, id: \.entity.id) { value in
                            Button { selection = .entity(value) } label: {
                                row(value.entity.label, symbol: KnowledgeTypePresentation.symbol(for: value.entity.typeKey), subtitle: value.entity.typeKey.capitalized + " · " + value.entity.id.uuidString.prefix(8))
                            }.buttonStyle(.plain)
                        }
                    case .objects:
                        ForEach((model.knowledgeCatalogue?.objects ?? []).filter { matches(SemanticInspectionTarget.object($0).title + " " + ($0.object.definitionText ?? "") + " " + ($0.object.answerText ?? "")) }, id: \.object.id) { value in
                            Button { selection = .object(value) } label: {
                                row(SemanticInspectionTarget.object(value).title, subtitle: value.object.typeKey.capitalized + " · " + value.object.id.uuidString.prefix(8))
                            }.buttonStyle(.plain)
                        }
                    case .annotations:
                        ForEach((model.knowledgeCatalogue?.annotations ?? []).filter { matches($0.annotation.designation + " " + $0.annotation.anchorDisposition.rawValue + " " + $0.annotation.id.uuidString) }, id: \.annotation.id) { value in
                            Button { selection = .annotation(value.annotation) } label: {
                                row(value.annotation.designation.capitalized + " association", subtitle: value.annotation.anchorDisposition.rawValue.capitalized + " · " + value.annotation.id.uuidString.prefix(8))
                            }.buttonStyle(.plain)
                        }
                    case .blocks: EmptyView()
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
                Text("Canonical catalogue · up to 1,000 records per family").font(.caption).foregroundStyle(.secondary).padding(NoemaSpacing.md)
            }
        }
        .task { await model.refreshKnowledgeCatalogue() }
        .onChange(of: model.knowledgeFamily) { query = ""; Task { await model.refreshKnowledgeCatalogue() } }
        .sheet(item: $selection) { selected in KnowledgeCatalogueDetail(model: model, selection: selected) }
    }
    private func row(_ title: String, symbol: String? = nil, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).font(NoemaTypography.interfaceEmphasis).lineLimit(2)
            }
            Text(subtitle).font(NoemaTypography.metadata).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }
}
struct KnowledgeCatalogueDetail: View {
    @Bindable var model: AppModel
    let selection: KnowledgeCatalogueSelection
    @Environment(\.dismiss) private var dismiss
    @State private var occurrences: [SemanticOccurrencePreview] = []
    @State private var editing = false
    @State private var error: String?
    private var target: SemanticInspectionTarget? {
        switch selection {
        case .entity(let value): .entity(model.knowledgeCatalogue?.entities.first { $0.entity.id == value.entity.id } ?? value)
        case .object(let value): .object(model.knowledgeCatalogue?.objects.first { $0.object.id == value.object.id } ?? value)
        case .annotation: nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            if let target {
                Text(target.title).font(.headline)
                Label(target.kind.capitalized, systemImage: KnowledgeTypePresentation.symbol(for: target.kind)).font(.caption).foregroundStyle(.secondary)
                switch target {
                case .entity(let value):
                    Text(value.entity.lifecycle.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    if let description = value.entity.description { Text(description) }
                    if !value.entity.aliases.isEmpty { Text("Aliases: " + value.entity.aliases.map(\.label).joined(separator: ", ")) }
                case .object(let value):
                    if value.object.typeKey == "question" {
                        Text(value.object.questionStatus.rawValue.capitalized)
                        if let answer = value.object.answerText { Text(answer) }
                    } else {
                        Text(value.object.definitionText ?? "")
                        if let id = value.object.subjectEntityID, let subject = model.knowledgeCatalogue?.entities.first(where: { $0.entity.id == id }) {
                            Text("Subject: " + subject.entity.label).font(.caption)
                        }
                    }
                case .unavailable: Text("Target unavailable")
                }
                Button("Edit canonical target…") { editing = true }.disabled(!target.isEditable || !model.canEditSemanticTarget)
                if occurrences.isEmpty { Text("No content occurrences.").foregroundStyle(.secondary) }
            } else { Text("Annotation association").font(.headline) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                    ForEach(occurrences) { occurrence in
                        Button(occurrence.pageTitle) { model.navigateSemanticAssociation(occurrence.annotation); dismiss() }.disabled(!occurrence.canNavigate)
                        Text(occurrence.context).font(.caption).lineLimit(3)
                        Text(occurrence.stateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 200)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding().frame(width: 380)
        .task(id: selection.id) {
            do {
                if let target { occurrences = try await model.catalogueOccurrencePreviews(target: target) }
                else if case .annotation(let annotation) = selection { occurrences = try await model.catalogueAnnotationPreview(annotation) }
            } catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $editing) { if let target { SemanticTargetEditor(model: model, target: target) } }
    }
}
