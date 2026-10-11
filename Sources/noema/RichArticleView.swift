import SwiftUI
import AppKit
import VaultCore

struct RichArticleView: NSViewRepresentable {
    @Environment(\.noemaTheme) var theme
    @AppStorage(EditorPreferences.showSemanticHeadingsKey) var showSemanticHeadings = false
    @AppStorage(EditorPreferences.texMacrosKey) var texMacros = ""
    @AppStorage(EditorPreferences.fontFamilyKey) var fontFamily = ""
    @AppStorage(EditorPreferences.fontSizeKey) var fontSize = EditorTypography.defaultSize
    var typography: EditorTypography { EditorTypography(family: fontFamily, size: fontSize) }
    @Binding var text: String
    var reading: Bool
    var locked: Bool
    var action: EditorAction?
    var onBegin: () -> Void
    var onEnd: () -> Void
    var onWikiLink: (String) -> Void
    var onWikiQuery: (String?) -> Void = { _ in }
    var noteID: UUID? = nil
    var onBlockLink: (URL) -> Void = { _ in }
    var onScrollOffset: (CGFloat) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = ArticleTextView(); view.isRichText = true; view.allowsUndo = true; view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.showSemanticHeadings = showSemanticHeadings
        view.textContainerInset = NSSize(width: 80, height: 24); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Article block editor")
        view.setAccessibilityHelp("Click to edit. Unlock a locked article first. Slash opens block commands. Use the Block context menu for structure, tags, and status. Command Option A selects the document.")
        view.registerForDraggedTypes([ArticleTextView.dragType])
        view.delegate = context.coordinator; context.coordinator.view = view; scroll.documentView = view
        context.coordinator.load(text)
        context.coordinator.observeScrolling(in: scroll)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard let view = coordinator.view else { return }
        let headingsChanged = view.showSemanticHeadings != showSemanticHeadings
        let macrosChanged = coordinator.lastMacros != texMacros
        coordinator.lastMacros = texMacros
        view.showSemanticHeadings = showSemanticHeadings
        view.locked = locked || coordinator.document.unsupportedVersion
        view.isEditable = !reading && !view.locked; view.theme = theme
        view.begin = onBegin; view.end = onEnd
        view.lockedClick = onBegin
        view.handleKey = { [weak coordinator] in coordinator?.handleKey($0) ?? false }
        view.blockMenu = { [weak coordinator] in coordinator?.contextMenu() ?? NSMenu() }
        view.activateBlock = { [weak coordinator] id, command in coordinator?.mutate(command, id: id, name: "Change block") }
        view.canReorder = { [weak coordinator] in coordinator?.document.canReorder($0, before: $1) ?? false }
        view.pasteContent = { [weak coordinator] in coordinator?.paste($0) }
        view.insertionPointColor = theme.native(.accentPrimary)
        view.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
        if coordinator.lastText != text { coordinator.load(text); view.undoManager?.removeAllActions() }
        else if coordinator.lastTheme != theme || coordinator.lastTypography != typography || headingsChanged || macrosChanged { coordinator.render(selection: view.selectedRange()) }
        if let action, coordinator.lastAction != action.id {
            if case .block = action.operation { coordinator.lastAction = action.id; coordinator.perform(action.operation) }
            else if view.isEditable { coordinator.lastAction = action.id; coordinator.perform(action.operation) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        coordinator.suggestions.close()
        coordinator.view?.delegate = nil
    }
}


struct SummarizedArticleView: View {
    @Bindable var model: AppModel
    var showsSummary = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summaryExpanded = false
    @State private var disclosure = SummaryDisclosureState()
    private var document: BlockDocument { BlockDocumentCodec.decode(model.body) }
    var editorText: Binding<String> {
        Binding(get: {
            let document = BlockDocumentCodec.decode(model.body)
            return document.aiSummary == nil ? model.body : BlockDocumentCodec.encode(document.withoutAISummary)
        }, set: { text in
            let summary = BlockDocumentCodec.decode(model.body).aiSummary
            if let summary {
                var edited = BlockDocumentCodec.decode(text)
                edited.blocks.insert(summary, at: 0)
                model.body = BlockDocumentCodec.encode(edited)
            } else { model.body = text }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSummary, model.generatingAISummary || document.aiSummary != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if showsSummary, model.generatingAISummary {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text("Generating AI Summary...")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 80).padding(.vertical, 8)
                            .frame(maxWidth: 980).frame(maxWidth: .infinity)
                    }
                    if showsSummary, let summary = document.aiSummary {
                        Group {
                            if disclosure.collapsed {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles").accessibilityLabel("AI-generated summary")
                                    Text(summary.text.replacingOccurrences(of: "\n", with: " "))
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("Show") { disclosure.toggle() }.buttonStyle(.link).fixedSize()
                                        .accessibilityLabel("Show AI-generated summary")
                                    deleteSummaryButton
                                }.font(.caption).foregroundStyle(.secondary)
                                    .transition(.opacity)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label("Summary", systemImage: "list.bullet.rectangle").font(.headline)
                                        Spacer()
                                        Button("Hide") { disclosure.toggle() }.buttonStyle(.link).font(.caption)
                                            .accessibilityLabel("Hide AI-generated summary")
                                        deleteSummaryButton
                                    }
                                    Text("AI-generated summary").font(.caption).foregroundStyle(.secondary)
                                    Text(summary.text).textSelection(.enabled)
                                        .lineLimit(summaryExpanded ? nil : 3)
                                    Button(summaryExpanded ? "Show less" : "Show more") { summaryExpanded.toggle() }
                                        .buttonStyle(.link).font(.caption)
                                        .accessibilityLabel(summaryExpanded ? "Show less AI-generated summary" : "Show full AI-generated summary")
                                        .accessibilityValue(summaryExpanded ? "Expanded" : "Three-line preview")
                                }
                                .transition(.opacity)
                            }
                        }
                        .padding(.horizontal, 80).padding(.vertical, disclosure.collapsed ? 16 : 24)
                        .frame(maxWidth: 980, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                Divider().scaleEffect(y: 0.5).frame(height: 0.5)
            }
            RichArticleView(text: editorText, reading: model.reading, locked: model.editingLocked, action: model.editorAction, onBegin: model.beginEditing, onEnd: model.finishEditing, onWikiLink: model.followWikiLink, onWikiQuery: { model.wikiQuery = $0 }, noteID: model.currentNote?.id, onBlockLink: model.openBlockURL, onScrollOffset: { disclosure.scrolled(to: $0) })
                .frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: disclosure.collapsed)
        .onChange(of: document.aiSummary?.text) { summaryExpanded = false }
        .onChange(of: disclosure.collapsed) { if disclosure.collapsed { summaryExpanded = false } }
    }
    private var deleteSummaryButton: some View {
        Button("Delete", role: .destructive) { model.deleteAISummary() }
        .buttonStyle(.link).font(.caption).fixedSize()
        .accessibilityLabel("Delete AI-generated summary")
        .help("Delete AI-generated summary")
        .disabled(model.editingLocked || model.generatingAISummary)
    }

}


struct SummaryDisclosureState {
    private(set) var collapsed = false
    private(set) var scrolledDown = false
    mutating func scrolled(to offset: CGFloat) {
        // Separate thresholds avoid layout changes repeatedly toggling the summary.
        if !scrolledDown, offset > 24 { scrolledDown = true; collapsed = true }
        else if scrolledDown, offset <= 1 { scrolledDown = false; collapsed = false }
    }
    mutating func toggle() { collapsed.toggle() }
}
