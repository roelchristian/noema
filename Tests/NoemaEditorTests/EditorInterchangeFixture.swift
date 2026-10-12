import SwiftUI
import VaultCore
@testable import noema

// Legacy Markdown fixtures adapt at the test boundary; production editor input
// and publication remain structured documents.
private final class InterchangeFixtureState {
    var source: String
    var document: BlockDocument
    init(_ source: String) { self.source = source; document = BlockDocumentCodec.decode(source) }
}

extension RichArticleView {
    init(text: Binding<String>, reading: Bool, locked: Bool, action: EditorAction?,
         onBegin: @escaping () -> Void, onEnd: @escaping () -> Void,
         onWikiLink: @escaping (String) -> Void, onWikiQuery: @escaping (String?) -> Void = { _ in },
         noteID: UUID? = nil, vaultID: UUID? = nil, sessionID: UUID? = nil,
         hidesAISummary: Bool = false) {
        let state = InterchangeFixtureState(text.wrappedValue)
        self.init(document: Binding(get: {
            if state.source != text.wrappedValue {
                state.source = text.wrappedValue; state.document = BlockDocumentCodec.decode(state.source)
            }
            return state.document
        }, set: {
            state.document = $0; state.source = BlockDocumentCodec.encode($0)
            text.wrappedValue = state.source
        }), reading: reading,
            locked: locked, action: action, onBegin: onBegin, onEnd: onEnd,
            onWikiLink: onWikiLink, onWikiQuery: onWikiQuery, noteID: noteID,
            vaultID: vaultID, sessionID: sessionID, hidesAISummary: hidesAISummary)
    }
    var text: String { BlockDocumentCodec.encode(document) }
}
extension RichArticleView.Coordinator {
    func load(_ source: String) { load(parent.document) }
    var lastText: String? { lastDocument.map(BlockDocumentCodec.encode) }
}
extension SummarizedArticleView {
    var editorText: Binding<String> {
        let captured = editorDocument
        return Binding(get: { BlockDocumentCodec.encode(captured.wrappedValue) },
            set: { captured.wrappedValue = BlockDocumentCodec.decode($0) })
    }
}
