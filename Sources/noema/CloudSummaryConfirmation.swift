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
    var id: UUID { request.id }

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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summarize with OpenAI").font(.title2.bold())
            Text(confirmation.title).font(.headline)
            Text("This exact text will leave your device and be sent to OpenAI using \(confirmation.model). The summary will replace the current summary only if the item stays unchanged.")
                .foregroundStyle(.secondary)
            Text("\(confirmation.request.contentByteCount) bytes · selected \(confirmation.request.action == .summarizePage ? "page" : "source") text")
                .font(.caption)
            ScrollView {
                Text(confirmation.request.content).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .frame(minHeight: 220, maxHeight: 400)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Cancellation prevents publication and further requests; it cannot recall text already sent to OpenAI.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelCloudSummary() }.keyboardShortcut(.cancelAction)
                Button("Send to OpenAI") { model.confirmCloudSummary() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640)
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
