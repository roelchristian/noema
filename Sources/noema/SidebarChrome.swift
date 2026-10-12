import AppKit
import SwiftUI

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
                .font(isSelected ? NoemaTypography.sidebarNavigationEmphasis : NoemaTypography.sidebarNavigation)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: NoemaMetrics.compactRowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Shared section header for sidebar groups.
struct NoemaSidebarSectionHeader: View {
    let title: String
    @Environment(\.noemaTheme) private var theme

    var body: some View {
        Text(title)
            .font(NoemaTypography.sidebarHeading)
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
                .font(NoemaTypography.sidebarNavigationEmphasis)
                .foregroundStyle(theme.text(for: .textPrimary, on: .sidebar))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: NoemaSpacing.xs)
            Image(systemName: "chevron.down")
                .font(NoemaTypography.caption)
                .foregroundStyle(theme.text(for: .textSecondary, on: .sidebar))
                .accessibilityHidden(true)
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
