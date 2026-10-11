import SwiftUI
import Foundation
import PDFKit
import ExternalAI
import VaultCore
import Synchronization

enum CloudSummarySnapshot: Sendable {
    case page(PageSummarySnapshot)
    case source(SourceSummarySnapshot)
}
struct CloudSummaryConfirmation: Identifiable, Sendable {
    let request: ExternalAISummaryRequest
    let snapshot: CloudSummarySnapshot
    let title: String
    let model: String
    let selection: UUID?
    let editorRevision: UUID
    let presentation: CloudConsentPresentation
    var id: UUID { request.id }

    init(request: ExternalAISummaryRequest, snapshot: CloudSummarySnapshot, title: String,
         model: String, selection: UUID?, editorRevision: UUID,
         presentation: CloudConsentPresentation = .expanded) {
        self.request = request
        self.snapshot = snapshot
        self.title = title
        self.model = model
        self.selection = selection
        self.editorRevision = editorRevision
        self.presentation = presentation
    }

    static func extractedText(_ snapshot: SourceSummarySnapshot) throws -> String {
        let filename = snapshot.source.metadata.originalFilename.lowercased()
        var text: String
        if filename.hasSuffix(".pdf") {
            guard let pdf = PDFDocument(data: snapshot.original) else { throw ExternalAIError.emptyContent }
            text = pdf.string ?? ""
        } else {
            guard let decoded = String(data: snapshot.original, encoding: .utf8) else { throw ExternalAIError.emptyContent }
            text = decoded
            if filename.hasSuffix(".html") || filename.hasSuffix(".htm") {
                text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            }
            // Source Markdown frontmatter is local metadata, never submitted with the body.
            if text.hasPrefix("---\n") || text.hasPrefix("---\r\n") {
                let lines = text.components(separatedBy: "\n")
                guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else {
                    throw ExternalAIError.emptyContent
                }
                text = lines.dropFirst(end + 1).joined(separator: "\n")
            }
        }
        return BlockDocumentCodec.markdownBody(BlockDocumentCodec.encode(BlockDocumentCodec.decode(text).withoutAISummary))
    }
}

struct CloudSummaryConsentSheet: View {
    @Bindable var model: AppModel
    let confirmation: CloudSummaryConfirmation
    @State private var previewExpanded: Bool

    init(model: AppModel, confirmation: CloudSummaryConfirmation) {
        self.model = model
        self.confirmation = confirmation
        _previewExpanded = State(initialValue: confirmation.presentation.previewInitiallyExpanded)
    }

    private var operationTitle: String {
        switch confirmation.request.action {
        case .summarizePage, .summarizeSource: "Summarize with OpenAI"
        case .suggestTitle: "Suggest Title with OpenAI"
        case .lccClassification: "Suggest LCC Classification with OpenAI"
        }
    }
    private var publicationDescription: String {
        switch confirmation.request.action {
        case .summarizePage, .summarizeSource:
            "The summary replaces the current summary only if the item stays unchanged."
        case .suggestTitle, .lccClassification:
            "Review the suggestion before applying it. Generating it does not change the title, classification or summary."
        }
    }
    private var targetDescription: String {
        switch confirmation.request.target { case .page: "page"; case .source: "source" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(operationTitle).font(.title2.bold())
            Text(confirmation.title).font(.headline)
            Text("Send this selected \(targetDescription) text to OpenAI? It leaves your device, and API charges may apply.")
                .foregroundStyle(.secondary)
            Text("OpenAI · \(confirmation.model) · \(confirmation.request.contentByteCount) bytes of text")
                .font(.caption).accessibilityIdentifier("cloudConsent.requestDetails")
            DisclosureGroup("Preview exact text", isExpanded: $previewExpanded) {
                ScrollView {
                    Text(confirmation.request.content).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .accessibilityIdentifier("cloudConsent.exactText")
                }
                .frame(minHeight: 220, maxHeight: 400)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            }
            .accessibilityIdentifier("cloudConsent.exactTextDisclosure")
            .accessibilityHint("Shows the full text for this submission. Expanding the preview does not send it.")
            Text("Approval applies only to this submission. \(publicationDescription)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Cancellation prevents publication and further requests; it cannot recall text already sent to OpenAI.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelCloudSummary() }.keyboardShortcut(.cancelAction)
                Button("Send to OpenAI") { model.confirmCloudSummary() }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cloudConsent.approveSubmission")
            }
        }.padding(24).frame(width: 580)
    }
}

struct CloudSummaryStatus: View {
    @Bindable var model: AppModel
    let target: ExternalAISummaryTarget
    var body: some View {
        if model.cloudSummaryTarget == target {
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing or generating with OpenAI…").font(.caption)
                Button("Cancel") { model.cancelCloudSummary() }
            }
        }
    }
}

/// MainActor changes invalidate this synchronous predicate. Repository actors check it after
/// their final await hop, so editor/selection ABA and cancelled queued writes fail closed.
final class CloudSummaryPublicationGuard: Sendable {
    private let request = Mutex<UUID?>(nil)
    func arm(requestID: UUID) { request.withLock { $0 = requestID } }
    func invalidate() { request.withLock { $0 = nil } }
    func validate(requestID: UUID) throws {
        try Task.checkCancellation()
        try request.withLock { current in
            guard current == requestID else { throw ExternalAIError.staleContent }
        }
    }
}
