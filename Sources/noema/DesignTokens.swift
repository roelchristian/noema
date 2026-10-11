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
