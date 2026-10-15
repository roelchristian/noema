import AppKit
import SwiftUI
import VaultCore

struct NoemaOrganisationSidebarEntry: Identifiable {
    let container: OrganisationContainer
    let depth: Int
    var id: UUID { container.id }
}

/// Presentation-only traversal. The organisation store owns hierarchy validation.
enum NoemaOrganisationSidebarTree {
    static func rows(_ containers: [OrganisationContainer], collapsed: Set<UUID>) -> [NoemaOrganisationSidebarEntry] {
        var visited: Set<UUID> = []
        func children(_ parent: UUID?, depth: Int) -> [NoemaOrganisationSidebarEntry] {
            containers.filter { $0.parentID == parent }.flatMap { container -> [NoemaOrganisationSidebarEntry] in
                guard visited.insert(container.id).inserted else { return [] }
                return [NoemaOrganisationSidebarEntry(container: container, depth: depth)]
                    + (collapsed.contains(container.id) ? [] : children(container.id, depth: depth + 1))
            }
        }
        return children(nil, depth: 0)
    }

    static func destinations(for container: OrganisationContainer, in containers: [OrganisationContainer]) -> [OrganisationContainer] {
        guard container.kind == .folder else { return [] }
        return containers.filter { destination in
            guard destination.id != container.parentID else { return false }
            var cursor: UUID? = destination.id
            var visited: Set<UUID> = [container.id]
            while let id = cursor {
                guard visited.insert(id).inserted else { return false }
                cursor = containers.first { $0.id == id }?.parentID
            }
            return true
        }
    }
}

private struct NoemaOrganisationSidebarRowSurface: ViewModifier {
    let selected: Bool
    let targeted: Bool
    @State private var hovered = false
    @Environment(\.noemaTheme) private var theme

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0 }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected || targeted ? theme.color(for: .selection) : hovered ? theme.color(for: .hover) : Color.clear)
            )
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(theme.color(for: .focusRing), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func noemaOrganisationSidebarRowSurface(selected: Bool, targeted: Bool = false) -> some View {
        modifier(NoemaOrganisationSidebarRowSurface(selected: selected, targeted: targeted))
    }
}

/// Shared layout geometry for sidebar rows, section headers, and footer chrome.
enum NoemaSidebarLayout {
    static let rowInsets = EdgeInsets(
        top: 1,
        leading: NoemaMetrics.sidebarRowHorizontalInset,
        bottom: 1,
        trailing: NoemaMetrics.sidebarRowHorizontalInset
    )
    static let sectionHeaderInsets = EdgeInsets(
        top: 6,
        leading: NoemaMetrics.sidebarRowHorizontalInset,
        bottom: 2,
        trailing: NoemaMetrics.sidebarRowHorizontalInset
    )
    static let organisationIndent: CGFloat = 12
    static let footerHorizontalPadding: CGFloat = NoemaMetrics.sidebarInset
    static let footerRowHorizontalPadding: CGFloat = NoemaMetrics.sidebarRowHorizontalInset + 3
}

/// Shared row label for sidebar navigation destinations and recent items.
struct NoemaSidebarRowLabel: View {
    let title: String
    let symbol: String
    var isSelected: Bool = false
    var iconColor: Color? = nil

    var body: some View {
        HStack(spacing: NoemaMetrics.sidebarIconSpacing) {
            Image(systemName: symbol)
                .font(NoemaTypography.sidebarIcon)
                .foregroundStyle(iconColor ?? .secondary)
                .frame(width: NoemaMetrics.iconWidth, alignment: .center)
                .accessibilityHidden(true)
            Text(title)
                .font(isSelected ? NoemaTypography.navigationEmphasis : NoemaTypography.navigation)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A stable icon slot discloses children independently of container selection.
struct NoemaOrganisationSidebarRow: View {
    let title: String
    let symbol: String
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let onExpansionChange: (Bool) -> Void
    let onSelect: () -> Void
    @State private var isHovered = false
    @FocusState private var disclosureFocused: Bool

    var body: some View {
        HStack(spacing: NoemaMetrics.sidebarIconSpacing) {
            Button {
                onExpansionChange(!isExpanded)
            } label: {
                Image(systemName: isHovered || disclosureFocused
                    ? (isExpanded ? "chevron.down" : "chevron.right") : symbol)
                    .font(NoemaTypography.sidebarIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: NoemaMetrics.iconWidth, height: NoemaMetrics.compactRowHeight)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .focused($disclosureFocused)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(title)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help("\(isExpanded ? "Collapse" : "Expand") \(title)")

            Button(action: onSelect) {
                HStack(spacing: 0) {
                    Text(title)
                        .font(isSelected ? NoemaTypography.navigationEmphasis : NoemaTypography.navigation)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
        }
        .padding(.leading, CGFloat(depth) * NoemaSidebarLayout.organisationIndent)
        .onHover { isHovered = $0 }
        .onMoveCommand { direction in
            switch direction {
            case .right: onExpansionChange(true)
            case .left: onExpansionChange(false)
            default: break
            }
        }
    }
}

/// Shared section header for sidebar groups.
struct NoemaSidebarSectionHeader: View {
    let title: String
    @Environment(\.noemaTheme) private var theme

    var body: some View {
        Text(title)
            .font(NoemaTypography.sidebarSection)
            .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

/// Shared vault switcher label at the bottom of the workspace sidebar,
/// aligned to the same icon column, spacing, and row height as navigation rows.
struct NoemaSidebarVaultSelectorLabel: View {
    let vaultName: String
    @Environment(\.noemaTheme) private var theme

    var body: some View {
        HStack(spacing: NoemaMetrics.sidebarIconSpacing) {
            Image(systemName: "folder")
                .font(NoemaTypography.sidebarIcon)
                .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                .frame(width: NoemaMetrics.iconWidth, alignment: .center)
                .accessibilityHidden(true)
            Text(vaultName)
                .font(NoemaTypography.navigationEmphasis)
                .foregroundStyle(theme.text(for: .textPrimary, on: .sidebar))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: NoemaSpacing.xs)
        }
        .padding(.horizontal, NoemaSidebarLayout.footerRowHorizontalPadding)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Native sidebar material backing when using the system appearance.
struct NoemaSidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

extension View {
    /// Applies full-palette sidebar surface color or native `.sidebar` vibrancy material.
    func noemaSidebarBackground(theme: NoemaTheme) -> some View {
        background {
            if theme.usesFullPalette {
                theme.color(for: .sidebar).ignoresSafeArea()
            } else {
                NoemaSidebarMaterialView().ignoresSafeArea()
            }
        }
    }
}
