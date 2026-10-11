import Foundation
import VaultCore

/// Metadata-only link resolution index (UI.R.REM02). Never stores a page body.
struct OutgoingLinkLookup {
    private struct Metadata {
        let title: String
        let aliases: [String]
    }

    private struct Match {
        let id: UUID
        let title: String
        let matchedAlias: String?
    }

    private var metadata: [UUID: Metadata] = [:]
    private var matches: [String: [Match]] = [:]
    private(set) var notePositions: [UUID: Int] = [:]

    init(notes: [NoteRecord]) {
        for (position, note) in notes.enumerated() {
            metadata[note.id] = Metadata(title: note.title, aliases: note.aliases)
            notePositions[note.id] = position
            var seen: Set<String> = []
            let titleKey = normalized(note.title)
            seen.insert(titleKey)
            matches[titleKey, default: []].append(Match(id: note.id, title: note.title, matchedAlias: nil))
            for alias in note.aliases {
                let key = normalized(alias)
                guard seen.insert(key).inserted else { continue }
                matches[key, default: []].append(Match(id: note.id, title: note.title, matchedAlias: alias))
            }
        }
        for key in matches.keys {
            guard (matches[key]?.count ?? 0) > 1 else { continue }
            matches[key]?.sort {
                let comparison = $0.title.localizedStandardCompare($1.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    /// Checks the actual resolution inputs, ignoring body/tag edits and page ordering.
    /// Refreshing positions lets cached IDs hydrate the latest records without retaining them.
    mutating func matchesMetadata(of notes: [NoteRecord]) -> Bool {
        guard metadata.count == notes.count else { return false }
        for (position, note) in notes.enumerated() {
            guard let existing = metadata[note.id],
                  existing.title == note.title, existing.aliases == note.aliases else { return false }
            if notePositions[note.id] != position {
                notePositions[note.id] = position
            }
        }
        return true
    }

    func resolve(_ targets: [String]) -> [CachedOutgoingLink] {
        var seen: Set<String> = []
        return targets.compactMap { target in
            let key = normalized(target)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            let candidates = matches[key] ?? []
            let resolution: CachedOutgoingLink.Resolution
            if candidates.count == 1, let match = candidates.first {
                resolution = .resolved(id: match.id, matchedAlias: match.matchedAlias)
            } else if candidates.isEmpty {
                resolution = .unresolved
            } else {
                resolution = .ambiguous(ids: candidates.map(\.id))
            }
            return CachedOutgoingLink(target: target, resolution: resolution)
        }
    }
}

/// Only IDs, display targets, and aliases are retained between evaluations.
struct CachedOutgoingLink {
    enum Resolution {
        case resolved(id: UUID, matchedAlias: String?)
        case ambiguous(ids: [UUID])
        case unresolved
    }

    let target: String
    let resolution: Resolution

    func item(notes: [NoteRecord], positions: [UUID: Int]) -> OutgoingLinkItem {
        let value: OutgoingLinkResolution
        switch resolution {
        case .resolved(let id, let alias):
            // The metadata check guarantees cached IDs exist in the current page collection.
            value = .resolved(note: notes[positions[id]!], matchedAlias: alias)
        case .ambiguous(let ids):
            value = .ambiguous(target: target, matches: ids.map { notes[positions[$0]!] })
        case .unresolved:
            value = .unresolved(target: target)
        }
        return OutgoingLinkItem(target: target, resolution: value)
    }
}

/// Inspector-owned, selection/session-aware cache for outgoing links (UI.R.REM02).
/// Normalization and target resolution run only when their inputs change. The cache is
/// deliberately not observable: warming it during rendering must not trigger another render.
@MainActor
final class LinksPresentationCache {
    private var lookup: OutgoingLinkLookup?
    private var cachedTargets: [String] = []
    private var cachedLinks: [CachedOutgoingLink] = []
    private(set) var currentCachedPageID: UUID?
    private(set) var lookupBuildCount = 0
    private(set) var resolutionCount = 0

    func model(
        pageID: UUID,
        backlinks: [NoteRecord],
        outgoingLinkTargets: [String],
        allNotes: [NoteRecord]
    ) -> LinksPanelModel {
        if lookup?.matchesMetadata(of: allNotes) != true {
            lookup = OutgoingLinkLookup(notes: allNotes)
            lookupBuildCount += 1
            currentCachedPageID = nil
        }
        if currentCachedPageID != pageID || cachedTargets != outgoingLinkTargets {
            cachedTargets = outgoingLinkTargets
            cachedLinks = lookup!.resolve(outgoingLinkTargets)
            resolutionCount += 1
            currentCachedPageID = pageID
        }
        return LinksPanelModel(
            pageID: pageID,
            backlinks: backlinks,
            outgoingLinks: cachedLinks.map { $0.item(notes: allNotes, positions: lookup!.notePositions) }
        )
    }

    func reconcileTarget(id: UUID?) {
        guard currentCachedPageID != id else { return }
        currentCachedPageID = nil
        cachedTargets = []
        cachedLinks = []
    }

    /// Purges all cached page metadata on lock, close, source selection, or vault switch.
    func invalidate() {
        lookup = nil
        reconcileTarget(id: nil)
        cachedTargets = []
        cachedLinks = []
    }

    var hasCachedLookup: Bool { lookup != nil }
}
