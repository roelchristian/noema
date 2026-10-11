import SwiftUI
import VaultCore

/// Resolution state for an outgoing wiki link target from a page.
enum OutgoingLinkResolution: Equatable, Sendable {
    case resolved(note: NoteRecord, matchedAlias: String?)
    case ambiguous(target: String, matches: [NoteRecord])
    case unresolved(target: String)
}

/// View-ready representation of an outgoing link in `LinksPanel`.
struct OutgoingLinkItem: Identifiable, Equatable, Sendable {
    let target: String
    let resolution: OutgoingLinkResolution

    var id: String { target }

    var displayTitle: String {
        switch resolution {
        case .resolved(let note, _):
            return note.title
        case .ambiguous(let target, _), .unresolved(let target):
            return target
        }
    }

    var subtitle: String? {
        switch resolution {
        case .resolved(_, let matchedAlias):
            guard let matchedAlias else { return nil }
            return "via \(matchedAlias)"
        case .ambiguous(_, let matches):
            return "Ambiguous · \(matches.count) matching pages"
        case .unresolved:
            return "Unresolved link"
        }
    }
}

/// Pure presentation model for the Links inspector panel (UI.R4).
/// Resolves indexed outgoing link targets and incoming backlinks without synchronous document rescanning.
struct LinksPanelModel: Equatable, Sendable {
    let pageID: UUID
    let backlinks: [NoteRecord]
    let outgoingLinks: [OutgoingLinkItem]

    init(
        pageID: UUID,
        backlinks: [NoteRecord],
        outgoingLinkTargets: [String],
        allNotes: [NoteRecord]
    ) {
        self.pageID = pageID
        self.backlinks = backlinks
        let lookup = OutgoingLinkLookup(notes: allNotes)
        self.outgoingLinks = lookup.resolve(outgoingLinkTargets).map { $0.item(notes: allNotes, positions: lookup.notePositions) }
    }

    init(pageID: UUID, backlinks: [NoteRecord], outgoingLinks: [OutgoingLinkItem]) {
        self.pageID = pageID
        self.backlinks = backlinks
        self.outgoingLinks = outgoingLinks
    }

    var totalCount: Int {
        backlinks.count + outgoingLinks.count
    }
}

/// Inspector panel presenting incoming Backlinks and Outgoing Links for a wiki page (UI.R4).
struct LinksPanel: View {
    @Environment(\.noemaTheme) private var theme
    @Bindable var model: AppModel
    let note: NoteRecord
    let cache: LinksPresentationCache
    var scrollPosition: Binding<ScrollPosition>? = nil

    private var panelModel: LinksPanelModel {
        let isCurrentPage = model.currentNote?.id == note.id
        return cache.model(
            pageID: note.id,
            backlinks: isCurrentPage ? model.backlinks : [],
            outgoingLinkTargets: isCurrentPage ? model.outgoingLinkTargets : [],
            allNotes: model.notes
        )
    }

    var body: some View {
        let state = panelModel
        VStack(spacing: 0) {
            InspectorPanelHeader(
                title: "Links",
                count: state.totalCount
            )
            Divider().overlay(theme.color(for: .separator))
            ScrollView {
                VStack(alignment: .leading, spacing: NoemaSpacing.lg) {
                    InspectorSection(
                        title: "Backlinks",
                        count: state.backlinks.count,
                        showTopDivider: false
                    ) {
                        if state.backlinks.isEmpty {
                            Text("No incoming links")
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                            Text("Pages that link to \(note.title) with [[Wiki Links]] will appear here.")
                                .font(NoemaTypography.metadata)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        } else {
                            ForEach(state.backlinks) { sourceNote in
                                backlinkRow(sourceNote)
                            }
                        }
                    }

                    InspectorSection(
                        title: "Outgoing Links",
                        count: state.outgoingLinks.count,
                        showTopDivider: true
                    ) {
                        if state.outgoingLinks.isEmpty {
                            Text("No outgoing links")
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                            Text("Add [[Wiki Links]] in this page to connect related topics.")
                                .font(NoemaTypography.metadata)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        } else {
                            ForEach(state.outgoingLinks) { item in
                                outgoingLinkRow(item)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, NoemaMetrics.inspectorInset)
                .padding(.vertical, NoemaSpacing.md)
            }
            .modifier(OptionalScrollPositionModifier(position: scrollPosition))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Links panel")
    }

    private func backlinkRow(_ sourceNote: NoteRecord) -> some View {
        Button {
            model.select(sourceNote.id)
        } label: {
            HStack(spacing: NoemaSpacing.sm) {
                Image(systemName: "arrow.backward.circle")
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                    .frame(width: NoemaMetrics.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceNote.title)
                        .font(NoemaTypography.interfaceEmphasis)
                        .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                        .lineLimit(1)
                    if let lcc = sourceNote.lcc, !lcc.isEmpty {
                        Text(lcc)
                            .font(NoemaTypography.caption)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Open \(sourceNote.title)")
        .accessibilityLabel("Backlink from \(sourceNote.title)")
    }

    @ViewBuilder
    private func outgoingLinkRow(_ item: OutgoingLinkItem) -> some View {
        switch item.resolution {
        case .resolved(let targetNote, let matchedAlias):
            Button {
                model.select(targetNote.id)
            } label: {
                HStack(spacing: NoemaSpacing.sm) {
                    Image(systemName: "arrow.up.forward.circle")
                        .font(NoemaTypography.metadata)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        .frame(width: NoemaMetrics.iconWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(targetNote.title)
                            .font(NoemaTypography.interfaceEmphasis)
                            .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                            .lineLimit(1)
                        if let matchedAlias {
                            Text("via \(matchedAlias)")
                                .font(NoemaTypography.caption)
                                .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(NoemaTypography.metadata)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Open \(targetNote.title)")
            .accessibilityLabel(
                matchedAlias.map { "Outgoing link to \(targetNote.title), matched alias \($0)" }
                    ?? "Outgoing link to \(targetNote.title)"
            )

        case .ambiguous(let target, let matches):
            Button {
                model.followWikiLink(target)
            } label: {
                HStack(spacing: NoemaSpacing.sm) {
                    Image(systemName: "questionmark.circle")
                        .font(NoemaTypography.metadata)
                        .foregroundStyle(.orange)
                        .frame(width: NoemaMetrics.iconWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target)
                            .font(NoemaTypography.interfaceEmphasis)
                            .foregroundStyle(theme.text(for: .textPrimary, on: .inspector))
                            .lineLimit(1)
                        Text("Ambiguous · \(matches.count) matching pages")
                            .font(NoemaTypography.caption)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Resolve")
                        .font(NoemaTypography.metadata)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Choose between \(matches.count) matching pages for \(target)")
            .accessibilityLabel("Ambiguous outgoing link \(target), \(matches.count) matching pages")

        case .unresolved(let target):
            HStack(spacing: NoemaSpacing.sm) {
                Image(systemName: "plus.circle.dashed")
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                    .frame(width: NoemaMetrics.iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target)
                        .font(NoemaTypography.interface)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        .lineLimit(1)
                    Text("Unresolved link")
                        .font(NoemaTypography.caption)
                        .foregroundStyle(theme.text(for: .textSecondary, on: .inspector))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Create") {
                    model.followWikiLink(target)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Create or resolve page for \(target)")
                .accessibilityLabel("Create page for unresolved link \(target)")
            }
            .padding(.vertical, 3)
        }
    }
}
