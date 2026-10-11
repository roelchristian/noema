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
                    .padding(.horizontal, NoemaMetrics.inspectorInset)
                    .padding(.top, NoemaSpacing.md)
                    .padding(.bottom, NoemaSpacing.md)
                    Divider().overlay(theme.color(for: .separator))
                    activePanelView(for: activeTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
                .background(theme.color(for: .inspector))
                .ignoresSafeArea(.container, edges: .top)
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
    @Environment(\.noemaTheme) private var theme
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        LabeledContent {
            Text(value.isEmpty ? "None" : value).foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
        } label: {
            Text(title).foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
        }
        .font(NoemaTypography.metadata)
    }
}

struct InspectorSection<Content: View, Actions: View>: View {
    @Environment(\.noemaTheme) private var theme
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
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            if showTopDivider {
                Divider().overlay(theme.color(for: .separator))
            }
            HStack(alignment: .center, spacing: NoemaSpacing.sm) {
                DisclosureGroup(isExpanded: $expanded) { EmptyView() } label: {
                    HStack(spacing: NoemaSpacing.sm) {
                        Text(title)
                            .font(NoemaTypography.sectionHeader)
                            .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                        if let count {
                            Text(count.formatted())
                                .font(NoemaTypography.metadata)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        }
                    }
                }
                actions
                    .controlSize(.small)
                    .font(NoemaTypography.metadata)
            }
            if expanded {
                VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(NoemaTypography.interface)
            }
        }
    }
}

struct SidebarAISummary: View {
    @Environment(\.noemaTheme) private var theme
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            Text(text)
                .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                .font(NoemaTypography.interface)
                .lineLimit(expanded ? nil : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                .buttonStyle(.link)
                .font(NoemaTypography.metadata)
                .accessibilityLabel(expanded ? "Collapse AI-generated summary" : "Expand AI-generated summary")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
        .onChange(of: text) { expanded = false }
    }
}

struct SourceAssociationRow: View {
    @Environment(\.noemaTheme) private var theme
    let title: String
    let openLabel: String
    let canOpen: Bool
    let canRemove: Bool
    let open: () -> Void
    let remove: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
            HStack {
                Text(title).font(NoemaTypography.interfaceEmphasis)
                    .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
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
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
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
    @Environment(\.noemaTheme) private var theme
    let block: EditorBlock
    let navigate: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let presentation = SemanticPresentation.find(block.metadata.semantic)
        let preview = block.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        Button(action: navigate) {
            HStack(spacing: NoemaSpacing.sm) {
                Image(systemName: presentation?.symbol ?? "tag")
                    .foregroundStyle(Color(nsColor: presentation?.accent ?? .secondaryLabelColor))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation?.title ?? block.metadata.semantic ?? "Block")
                        .font(NoemaTypography.interfaceEmphasis)
                        .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                    Text(preview.isEmpty ? "Empty block" : preview)
                        .font(NoemaTypography.metadata)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
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
