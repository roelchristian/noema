import SwiftUI
import VaultCore

/// Pure presentation model for page tags in the inspector, separating editable frontmatter tags from derived inline tags
/// while routing mutations through the authoritative `AppModel.tagInput` binding.
struct TagsPanelModel {
    static func editableTags(from tagInput: String) -> [String] {
        normalizeTags(tagInput.components(separatedBy: ","))
    }

    static func inlineTags(for note: NoteRecord, liveBody: String?) -> [String] {
        guard let liveBody else { return note.inlineTags.sorted() }
        return MarkdownService.analyze(liveBody).tags
    }

    static func addingTag(_ rawTag: String, to tagInput: String) -> String {
        let additions = normalizeTags(rawTag.components(separatedBy: ","))
        guard !additions.isEmpty else { return tagInput }
        let merged = normalizeTags(editableTags(from: tagInput) + additions)
        return merged.joined(separator: ", ")
    }

    static func removingTag(_ tagToRemove: String, from tagInput: String) -> String {
        let target = normalized(tagToRemove).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let remaining = editableTags(from: tagInput).filter { $0 != target }
        return remaining.joined(separator: ", ")
    }
}

/// Compact native inspector panel displaying editable page tags separately from derived inline tags.
struct TagsPanel: View {
    @Bindable var model: AppModel
    let note: NoteRecord
    var scrollPosition: Binding<ScrollPosition>? = nil

    @Environment(\.noemaTheme) private var theme
    @State private var newTagText = ""

    private var pageTags: [String] {
        model.currentNote?.id == note.id ? model.editedTags : note.tags.sorted()
    }

    private var derivedInlineTags: [String] {
        TagsPanelModel.inlineTags(
            for: note,
            liveBody: model.currentNote?.id == note.id ? model.body : nil
        )
    }

    private var totalCount: Int {
        Set(pageTags + derivedInlineTags).count
    }

    private var canEdit: Bool {
        !note.isEditingLocked && !model.editingLocked && model.currentNote?.id == note.id
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorPanelHeader(title: "Tags", count: totalCount)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSection(title: "Page tags", count: pageTags.count, showTopDivider: false) {
                        if pageTags.isEmpty {
                            Text("No page tags")
                                .foregroundStyle(.secondary)
                            Text("Page tags are saved in the note’s frontmatter.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(pageTags, id: \.self) { tag in
                                    HStack(spacing: 8) {
                                        Button {
                                            model.changeScope(.tag(tag))
                                        } label: {
                                            Label("#" + tag, systemImage: "tag")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(theme.text(.graphHighlight, on: .background))
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(theme.color(.graphHighlight))
                                        .controlSize(.small)
                                        .help("Filter pages by #\(tag)")
                                        .accessibilityLabel("Filter by tag \(tag)")

                                        Spacer()

                                        if canEdit {
                                            Button {
                                                removePageTag(tag)
                                            } label: {
                                                Label("Remove #\(tag)", systemImage: "xmark.circle.fill")
                                                    .labelStyle(.iconOnly)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.borderless)
                                            .controlSize(.small)
                                            .help("Remove #\(tag) from page tags")
                                            .accessibilityLabel("Remove page tag \(tag)")
                                        }
                                    }
                                }
                            }
                        }

                        if canEdit {
                            HStack(spacing: 6) {
                                TextField("Add tag…", text: $newTagText)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.caption)
                                    .onSubmit {
                                        commitNewTag()
                                    }
                                    .accessibilityLabel("Add page tag")
                                Button("Add") {
                                    commitNewTag()
                                }
                                .controlSize(.small)
                                .font(.caption)
                                .disabled(normalizeTags(newTagText.components(separatedBy: ",")).isEmpty)
                            }
                            .padding(.top, 2)

                            LabeledContent("Frontmatter") {
                                TextField("Comma-separated tags", text: $model.tagInput)
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .font(.caption)
                                    .accessibilityLabel("Page tags frontmatter")
                            }
                            .font(.caption)
                        } else if note.isEditingLocked || model.editingLocked {
                            Label("Unlock editing to add or remove page tags.", systemImage: "lock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    InspectorSection(title: "Inline tags", count: derivedInlineTags.count) {
                        if derivedInlineTags.isEmpty {
                            Text("No inline #tags in the article body.")
                                .foregroundStyle(.secondary)
                            Text("Type #tag in the article text to derive inline tags automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(derivedInlineTags, id: \.self) { tag in
                                    HStack(spacing: 8) {
                                        Button {
                                            model.changeScope(.tag(tag))
                                        } label: {
                                            Label("#" + tag, systemImage: "number")
                                                .font(.caption)
                                                .foregroundStyle(theme.text(.graphHighlight, on: .background))
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(theme.color(.graphHighlight))
                                        .controlSize(.small)
                                        .help("Filter pages by #\(tag)")
                                        .accessibilityLabel("Filter by inline tag \(tag)")

                                        Spacer()

                                        Text("In text")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
        .onChange(of: note.id) {
            newTagText = ""
        }
    }

    private func commitNewTag() {
        guard canEdit else { return }
        let updated = TagsPanelModel.addingTag(newTagText, to: model.tagInput)
        newTagText = ""
        guard updated != model.tagInput else { return }
        model.tagInput = updated
    }

    private func removePageTag(_ tag: String) {
        guard canEdit else { return }
        let updated = TagsPanelModel.removingTag(tag, from: model.tagInput)
        guard updated != model.tagInput else { return }
        model.tagInput = updated
    }
}
