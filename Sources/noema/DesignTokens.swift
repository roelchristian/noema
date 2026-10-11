import SwiftUI

/// Typography for application chrome. Platform text styles preserve the system's
/// accessibility behavior; document content continues to use `EditorTypography`.
/// Apply these at the text or component level, never as a root font override.
enum NoemaTypography {
    static let documentTitle: Font = .title.weight(.semibold)
    static let libraryTitle: Font = .title2.weight(.bold)
    static let sectionHeader: Font = .headline.weight(.semibold)
    static let navigation: Font = .callout
    static let navigationEmphasis: Font = .callout.weight(.medium)
    static let interface: Font = .callout
    static let interfaceEmphasis: Font = .callout.weight(.medium)
    static let metadata: Font = .caption
    static let metadataEmphasis: Font = .caption.weight(.medium)
    static let caption: Font = .caption2
    static let sidebarSection: Font = .caption.weight(.semibold)
}

/// Shared spacing rhythm for application chrome, expressed in points.
/// Choose spacing by purpose and available room, rather than rounding every
/// existing inset to the nearest token. Native default padding, zero spacing,
/// and small optical corrections remain appropriate where their purpose is clear.
enum NoemaSpacing {
    /// Tight tab and icon grouping.
    static let xs: CGFloat = 4
    /// Navigation gaps and inner row padding.
    static let sm: CGFloat = 8
    /// Header gaps and compact panel rhythm.
    static let md: CGFloat = 12
    /// Inspector and content insets.
    static let lg: CGFloat = 16
    /// Separation between larger grouped containers.
    static let xl: CGFloat = 20
    /// Sheet and group padding reference.
    static let xxl: CGFloat = 24
    /// Outer space around empty and locked states.
    static let xxxl: CGFloat = 32
}

// Density guidance: keep navigation and metadata compact while allowing document
// title chrome and larger panels more breathing room. Native controls retain
// their system sizing; text-bearing custom controls should grow with their
// content instead of clipping to enforce a fixed density. No density preference
// or document/editor typography setting is introduced by these tokens.

/// Geometry reference defaults for custom application chrome, in points.
/// Apply row, search and action heights as minimums so text and accessibility
/// sizing can grow. Text-bearing controls use content-driven widths; pane and
/// window constraints remain component-owned. Native controls keep their
/// platform metrics and focus/accessibility behavior.
///
/// Compact and comfortable describe layout roles, not an appearance setting or
/// a persisted density preference. Reading measure is deliberately deferred:
/// the editor's existing width and gutter alignment remain editorial layout.
enum NoemaMetrics {
    /// Minimum height for compact sidebar navigation rows and custom tabs.
    static let compactRowHeight: CGFloat = 30
    /// Minimum height for vault navigation and roomier custom rows.
    static let comfortableRowHeight: CGFloat = 34
    /// Minimum height for the custom sidebar search container.
    static let searchHeight: CGFloat = 30

    /// Horizontal framing shared by sidebar search, headers and tab groups.
    static let sidebarInset: CGFloat = 12
    /// Horizontal alignment shared by the inspector shell and panel contents.
    static let inspectorInset: CGFloat = 16

    /// Selected tabs and compact custom controls.
    static let radiusSmall: CGFloat = 6
    /// Search and grouped custom control containers.
    static let radiusStandard: CGFloat = 8
    /// Larger custom containers; retain native container shapes where provided.
    static let radiusLarge: CGFloat = 12
    /// Custom group/search hairline; callers may strengthen for Increase Contrast.
    static let borderWidth: CGFloat = 0.5
    /// Visible keyboard focus outline on custom plain chrome.
    static let focusRingWidth: CGFloat = 2
    /// Optical padding around a custom tab group, independent of row padding.
    static let controlGroupInset: CGFloat = 3

    /// Alignment column for chrome icons, never the interactive hit target.
    static let iconWidth: CGFloat = 16
    /// Minimum height for custom compact toolbar/footer actions. Apply to the
    /// whole button label with a content shape; retain visible keyboard focus.
    static let toolbarControlHeight: CGFloat = 28
}
