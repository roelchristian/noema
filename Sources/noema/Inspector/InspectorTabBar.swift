import SwiftUI
import AppKit
import VaultCore

/// Icon-only contextual tab selector for the right inspector.
struct InspectorTabBar: View {
    let tabs: [InspectorTab]
    let selectedTab: InspectorTab
    let onSelect: (InspectorTab) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let isSelected = tab == selectedTab
                Button {
                    onSelect(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                        .contentShape(Rectangle())
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(colorSchemeContrast == .increased ? 0.16 : 0.09))
                                    .matchedGeometryEffect(id: "inspectorActiveTab", in: tabNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityValue(isSelected ? "Selected" : "")
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorSchemeContrast == .increased ? 0.25 : 0.07), lineWidth: 0.5)
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
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            if let count {
                Text(count.formatted())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.07))
                    )
            }
            Spacer(minLength: 8)
            actions
                .controlSize(.small)
                .font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
