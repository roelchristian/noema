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
        var seen: Set<String> = []
        var items: [OutgoingLinkItem] = []
        for rawTarget in outgoingLinkTargets {
            let key = normalized(rawTarget)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let matches = allNotes
                .filter { note in
                    normalized(note.title) == key || note.aliases.contains(where: { normalized($0) == key })
                }
                .sorted {
                    let cmp = $0.title.localizedStandardCompare($1.title)
                    if cmp != .orderedSame { return cmp == .orderedAscending }
                    return $0.id.uuidString < $1.id.uuidString
                }
            let resolution: OutgoingLinkResolution
            if matches.count == 1 {
                let note = matches[0]
                let matchedAlias: String?
                if normalized(note.title) == key {
                    matchedAlias = nil
                } else {
                    matchedAlias = note.aliases.first(where: { normalized($0) == key }) ?? rawTarget
                }
                resolution = .resolved(note: note, matchedAlias: matchedAlias)
            } else if matches.isEmpty {
                resolution = .unresolved(target: rawTarget)
            } else {
                resolution = .ambiguous(target: rawTarget, matches: matches)
            }
            items.append(OutgoingLinkItem(target: rawTarget, resolution: resolution))
        }
        self.outgoingLinks = items
    }

    var totalCount: Int {
        backlinks.count + outgoingLinks.count
    }
}

/// Inspector panel presenting incoming Backlinks and Outgoing Links for a wiki page (UI.R4).
struct LinksPanel: View {
    @Bindable var model: AppModel
    let note: NoteRecord
    var scrollPosition: Binding<ScrollPosition>? = nil

    private var panelModel: LinksPanelModel {
        let isCurrentPage = model.currentNote?.id == note.id
        return LinksPanelModel(
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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSection(
                        title: "Backlinks",
                        count: state.backlinks.count,
                        showTopDivider: false
                    ) {
                        if state.backlinks.isEmpty {
                            Text("No incoming links")
                                .foregroundStyle(.secondary)
                            Text("Pages that link to \(note.title) with [[Wiki Links]] will appear here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                            Text("Add [[Wiki Links]] in this page to connect related topics.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(state.outgoingLinks) { item in
                                outgoingLinkRow(item)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
            HStack(spacing: 8) {
                Image(systemName: "arrow.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sourceNote.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let lcc = sourceNote.lcc, !lcc.isEmpty {
                        Text(lcc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.forward.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(targetNote.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let matchedAlias {
                            Text("via \(matchedAlias)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Ambiguous · \(matches.count) matching pages")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Resolve")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Choose between \(matches.count) matching pages for \(target)")
            .accessibilityLabel("Ambiguous outgoing link \(target), \(matches.count) matching pages")

        case .unresolved(let target):
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Unresolved link")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
