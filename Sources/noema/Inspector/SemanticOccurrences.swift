import Foundation
import VaultCore

enum SemanticOccurrenceState: String, Equatable, Sendable {
    case verified = "Verified"
    case trashed = "Page in Trash"
    case stale = "Stale anchor"
    case deleted = "Deleted association"
    case unavailablePage = "Page unavailable"
    case unavailableBlock = "Block unavailable"
    case unsupportedLocation = "No page location"
}
struct SemanticOccurrencePreview: Identifiable, Equatable, Sendable {
    let annotation: SemanticAnnotation
    let pageTitle: String
    let context: String
    let state: SemanticOccurrenceState
    var id: UUID { annotation.id }
    var canNavigate: Bool { state == .verified }
    var stateLabel: String { state.rawValue + " · " + annotation.anchorDisposition.rawValue.capitalized }
    static func make(annotation: SemanticAnnotation, record: NoteRecord?, snapshot: BlockStoreSnapshot?, trashed: Bool) -> Self {
        let captured: String
        if case .inline(_, _, let target) = annotation.location { captured = target.prefix + target.quote + target.suffix }
        else { captured = "No text context was captured." }
        let title = record?.title ?? "Unavailable page"
        func result(_ state: SemanticOccurrenceState, _ text: String = "") -> Self {
            .init(annotation: annotation, pageTitle: title, context: String((text.isEmpty ? captured : text).prefix(220)), state: state)
        }
        if annotation.anchorDisposition == .deleted { return result(.deleted) }
        guard annotation.location.pageID != nil, let blockID = annotation.location.blockID else { return result(.unsupportedLocation) }
        guard let snapshot, let record, snapshot.pageID == annotation.location.pageID,
            record.id == annotation.location.pageID else { return result(.unavailablePage) }
        if trashed { return result(.trashed) }
        guard let block = snapshot.document.block(blockID) else { return result(.unavailableBlock) }
        guard annotation.anchorDisposition == .resolved, annotation.expectedRevision == snapshot.revision.token else { return result(.stale) }
        if case .inline(_, _, let target) = annotation.location {
            guard target.start >= 0, target.end > target.start, target.end <= block.text.utf16.count else { return result(.stale) }
            let range = NSRange(location: target.start, length: target.end - target.start)
            guard InlineAnnotationTarget.validRange(range, in: block.text),
                  (block.text as NSString).substring(with: range) == target.quote,
                  target.digest == (try? InlineAnnotationTarget(text: block.text, range: range, revision: snapshot.revision.token))?.digest else { return result(.stale) }
            return result(.verified, captured)
        }
        return result(.verified, block.text)
    }
}

struct PendingSemanticOccurrence: Equatable {
    let pageID: UUID
    let blockID: UUID
    let annotationID: UUID
}
