import SwiftUI
import AppKit
import VaultCore

/// Icon-only contextual tab selector for the right inspector.
struct InspectorTabBar: View {
    let tabs: [InspectorTab]
    let selectedTab: InspectorTab
    let onSelect: (InspectorTab) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noemaTheme) private var theme
    @FocusState private var focusedTab: InspectorTab?

    var body: some View {
        HStack(spacing: NoemaSpacing.xs) {
            ForEach(tabs) { tab in
                let isSelected = tab == selectedTab
                Button {
                    onSelect(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(isSelected ? NoemaTypography.navigationEmphasis : NoemaTypography.navigation)
                        .noemaChromeForeground(.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NoemaChromeButtonStyle(selected: isSelected, surface: .elevated,
                                                    focused: focusedTab == tab))
                .focused($focusedTab, equals: tab)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityValue(isSelected ? "Selected" : "")
            }
        }
        .padding(NoemaMetrics.controlGroupInset)
        .background(
            RoundedRectangle(cornerRadius: NoemaMetrics.radiusStandard, style: .continuous)
                .fill(theme.color(for: .elevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NoemaMetrics.radiusStandard, style: .continuous)
                .strokeBorder(theme.color(for: .separator), lineWidth: NoemaMetrics.borderWidth)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selectedTab)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector tabs")
        .onMoveCommand { direction in
            switch direction {
            case .left:
                if let index = tabs.firstIndex(of: selectedTab) {
                    let prev = (index - 1 + tabs.count) % tabs.count
                    onSelect(tabs[prev])
                }
            case .right:
                if let index = tabs.firstIndex(of: selectedTab) {
                    let next = (index + 1) % tabs.count
                    onSelect(tabs[next])
                }
            default:
                break
            }
        }
    }
}

/// Active panel header displaying the current destination title, optional count badge, and contextual actions.
struct InspectorPanelHeader<Actions: View>: View {
    @Environment(\.noemaTheme) private var theme
    let title: String
    let count: Int?
    let actions: Actions

    init(
        title: String,
        count: Int? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.count = count
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: NoemaSpacing.sm) {
            Text(title)
                .font(NoemaTypography.sectionHeader)
                .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
            if let count {
                Text(count.formatted())
                    .font(NoemaTypography.metadataEmphasis)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(theme.color(for: .elevated))
                    )
            }
            Spacer(minLength: NoemaSpacing.sm)
            actions
                .controlSize(.small)
                .font(NoemaTypography.metadata)
        }
        .padding(.horizontal, NoemaMetrics.inspectorInset)
        .padding(.vertical, NoemaSpacing.md)
    }
}
