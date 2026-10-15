import SwiftUI
import VaultCore

/// Presentation only: every row retains its canonical typed identity for selection and drag routing.
struct OrganisationContentsRowPresentation: Equatable {
    let kind: OrganisationItemKind
    let parentTitle: String?

    var kindTitle: String {
        switch kind {
        case .page: "Page"
        case .source: "Source"
        case .semanticBlock: "Knowledge block"
        case .knowledgeEntity: "Knowledge entity"
        case .semanticObject: "Semantic object"
        }
    }

    var subtitle: String {
        guard kind == .semanticBlock, let parentTitle, !parentTitle.isEmpty else { return kindTitle }
        return "\(kindTitle) · \(parentTitle)"
    }

    static func reference(for id: RecentItemID) -> OrganisationItemReference {
        switch id {
        case .page(let id): .init(kind: .page, itemID: id)
        case .source(let id): .init(kind: .source, itemID: id)
        case .semanticBlock(let pageID, let blockID): .init(kind: .semanticBlock, itemID: blockID, pageID: pageID)
        }
    }
}

struct OrganisationContentsSummary: Equatable {
    let itemCount: Int
    let folderCount: Int

    var isEmpty: Bool { itemCount == 0 && folderCount == 0 }
    var label: String {
        let items = "\(itemCount) \(itemCount == 1 ? "item" : "items")"
        guard folderCount > 0 else { return items }
        return "\(folderCount) \(folderCount == 1 ? "folder" : "folders") · \(items)"
    }
}

/// A modified click changes the drag selection without opening any of its members.
enum OrganisationContentsSelection {
    static func itemToOpen(in references: Set<OrganisationItemReference>, extendingSelection: Bool) -> OrganisationItemReference? {
        guard !extendingSelection, references.count == 1 else { return nil }
        return references.first
    }
}

/// Shared native list label for page, source, block and catalogue memberships.
struct OrganisationContentsRowLabel: View {
    let title: String
    let symbol: String
    let subtitle: String
    var isLocked = false
    var isUnavailable = false

    var body: some View {
        HStack(spacing: NoemaSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: NoemaMetrics.sidebarIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(NoemaTypography.interfaceEmphasis)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Page locked against editing")
            }
            if isUnavailable {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Details unavailable")
            }
        }
        .padding(.horizontal, NoemaSpacing.sm)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
