import SwiftUI
import AppKit
import VaultCore

/// Native macOS tabbed contextual inspector shell (UI.R1, UI.R2, UI.R7).
struct InspectorContainer: View {
    @Bindable var model: AppModel
    @Bindable var state: InspectorState
    let context: InspectorContext
    var onCloseSourceSelection: () -> Void = {}

    @Environment(\.noemaTheme) private var theme
    @State private var scrollPositions: [InspectorTab: ScrollPosition] = [:]

    var body: some View {
        Group {
            if context.isInspectable {
                let activeTab = state.activeTab(for: context)
                VStack(spacing: 0) {
                    InspectorTabBar(
                        tabs: context.applicableTabs,
                        selectedTab: activeTab,
                        onSelect: { state.selectTab($0, for: context) }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 10)
                    Divider()
                    activePanelView(for: activeTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
                .background(theme.color(.background))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel)
            } else {
                EmptyView()
            }
        }
        .frame(
            minWidth: InspectorState.minWidth,
            idealWidth: InspectorState.idealWidth,
            maxWidth: InspectorState.maxWidth,
            maxHeight: .infinity
        )
        .onChange(of: context.targetID) {
            scrollPositions.removeAll()
        }
    }

    private var accessibilityLabel: String {
        switch context {
        case .none:
            return "Inspector"
        case .page:
            return "Page inspector"
        case .source:
            return "Source inspector"
        }
    }

    private func scrollPositionBinding(for tab: InspectorTab) -> Binding<ScrollPosition> {
        Binding(
            get: { scrollPositions[tab] ?? ScrollPosition(edge: .top) },
            set: { scrollPositions[tab] = $0 }
        )
    }

    @ViewBuilder
    private func activePanelView(for tab: InspectorTab) -> some View {
        let position = scrollPositionBinding(for: tab)
        switch tab {
        case .links:
            if case .page(let note) = context {
                LinksPanel(model: model, note: note, cache: state.linksCache, scrollPosition: position)
            } else {
                PropertiesPanel(model: model, context: context, scrollPosition: position)
            }
        case .references:
            ReferencesPanel(model: model, context: context, scrollPosition: position)
        case .tags:
            if case .page(let note) = context {
                TagsPanel(model: model, note: note, scrollPosition: position)
            } else {
                PropertiesPanel(model: model, context: context, scrollPosition: position)
            }
        case .properties:
            PropertiesPanel(model: model, context: context, scrollPosition: position)
        case .insights:
            InsightsPanel(
                model: model,
                context: context,
                cache: state.insightsCache,
                scrollPosition: position
            )
        }
    }
}

struct OptionalScrollPositionModifier: ViewModifier {
    let position: Binding<ScrollPosition>?

    func body(content: Content) -> some View {
        if let position {
            content.scrollPosition(position)
        } else {
            content
        }
    }
}

enum InspectorFormatting {
    static func metadataDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: value)
        if date == nil {
            formatter.formatOptions.insert(.withFractionalSeconds)
            date = formatter.date(from: value)
        }
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

struct InspectorProperty: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        LabeledContent {
            Text(value.isEmpty ? "None" : value).foregroundStyle(.primary)
        } label: {
            Text(title).foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

struct InspectorSection<Content: View, Actions: View>: View {
    let title: String
    let count: Int?
    let showTopDivider: Bool
    let content: Content
    let actions: Actions
    @State private var expanded: Bool = true

    init(
        title: String,
        count: Int? = nil,
        showTopDivider: Bool = true,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.count = count
        self.showTopDivider = showTopDivider
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showTopDivider {
                Divider()
            }
            HStack(alignment: .center, spacing: 8) {
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let count {
                            Text(count.formatted())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                actions
                    .controlSize(.small)
                    .font(.caption)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout)
            }
        }
    }
}

struct SidebarAISummary: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.callout)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel(expanded ? "Collapse AI-generated summary" : "Expand AI-generated summary")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
        .onChange(of: text) { expanded = false }
    }
}

struct SourceAssociationRow: View {
    let title: String
    let openLabel: String
    let canOpen: Bool
    let canRemove: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(action: open) {
                    Label(openLabel, systemImage: "arrow.up.forward.square").labelStyle(.iconOnly)
                }
                .disabled(!canOpen)
                .help(openLabel)
                Button { confirmingRemoval = true } label: {
                    Label("Remove link", systemImage: "trash").labelStyle(.iconOnly)
                }
                .disabled(!canRemove || confirmingRemoval)
                .help("Remove link")
            }
            if confirmingRemoval {
                Text("Remove this link? The page and source will be kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Remove", role: .destructive) {
                        confirmingRemoval = false
                        remove()
                    }
                    .disabled(!canRemove)
                    Button("Cancel") { confirmingRemoval = false }
                }
            }
        }
        .onChange(of: canRemove) { if !canRemove { confirmingRemoval = false } }
    }
}

struct SemanticBlockSidebarRow: View {
    let block: EditorBlock
    let navigate: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let presentation = SemanticPresentation.find(block.metadata.semantic)
        let preview = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        Button(action: navigate) {
            HStack(spacing: 8) {
                Image(systemName: presentation?.symbol ?? "tag")
                    .foregroundStyle(Color(nsColor: presentation?.accent ?? .secondaryLabelColor))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation?.title ?? block.metadata.semantic ?? "Block")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(preview.isEmpty ? "Empty block" : preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.body)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focused($focused)
        .help(block.text)
        .accessibilityLabel("Go to \(presentation?.title ?? block.metadata.semantic ?? "tagged") block: \(preview.isEmpty ? "Empty block" : preview)")
    }
}
