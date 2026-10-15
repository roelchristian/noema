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
    @Binding var document: BlockDocument
    var editable: Bool
    var locked: Bool
    var action: EditorAction?
    var onWikiLink: (String) -> Void
    var onWikiQuery: (String?) -> Void = { _ in }
    var noteID: UUID? = nil
    var vaultID: UUID? = nil
    var sessionID: UUID? = nil
    var hidesAISummary = false
    var onSessionReady: ((Coordinator) -> Void)? = nil
    var onSessionEnded: ((Coordinator) -> Void)? = nil
    var onSnapshot: ((EditorSession.DocumentSnapshot) -> Void)? = nil
    var onBlockLink: (URL) -> Void = { _ in }
    var onSemanticLoad: ((Coordinator) -> Void)? = nil
    var annotationChoices: (() async throws -> [EditorAnnotationChoice])? = nil
    var onAnnotate: ((Coordinator, UUID, NSRange, EditorAnnotationChoice, UInt64) async throws -> Void)? = nil
    var onInspectAssociation: ((UUID) -> Void)? = nil
    var onSemanticSelection: (([UUID]) -> Void)? = nil
    var onAnnotationAvailabilityChange: ((Bool) -> Void)? = nil
    var onScrollOffset: (CGFloat) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let view = ArticleTextView(); view.isRichText = true; view.allowsUndo = true; view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.showSemanticHeadings = showSemanticHeadings
        view.typography = typography
        view.textContainerInset = NSSize(width: 0, height: 24); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.setAccessibilityLabel("Article block editor")
        view.setAccessibilityHelp("Click unlocked page text to edit. Command-click a link or use Open Link in its context menu. Unlock a locked article first. Slash opens block commands. The block handle changes format and semantic designation, inserts below, and deletes. The Block context menu keeps status, move, and formatting. Command Option A selects the document.")
        view.registerForDraggedTypes([ArticleTextView.dragType])
        view.delegate = context.coordinator; context.coordinator.view = view; scroll.documentView = view
        view.updateReadingGeometry()
        context.coordinator.load(document)
        context.coordinator.lastMacros = texMacros
        context.coordinator.observeScrolling(in: scroll)
        onSessionReady?(context.coordinator)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // SwiftUI can update the outgoing identity-keyed view after creating its
        // replacement. That view must retain its original page and callbacks.
        let identity = EditorSession.Identity(pageID: noteID, vaultID: vaultID, sessionID: sessionID)
        guard onSemanticLoad == nil || coordinator.hostedIdentity == identity else {
            coordinator.contextualIdentitySuspended = true
            coordinator.inlineControls.close()
            coordinator.dismissHandleMenu()
            coordinator.activeInsertionMenu?.cancelTracking()
            coordinator.activeInsertionMenu = nil
            coordinator.activeBlockMenuContext = nil
            return
        }
        coordinator.contextualIdentitySuspended = false
        coordinator.parent = self
        guard let view = coordinator.view else { return }
        let headingsChanged = view.showSemanticHeadings != showSemanticHeadings
        let macrosChanged = coordinator.lastMacros != texMacros
        view.showSemanticHeadings = showSemanticHeadings
        view.typography = typography
        view.locked = locked || coordinator.document.unsupportedVersion || (onSemanticLoad != nil && coordinator.session.semanticEdit == nil)
        view.isEditable = editable && !view.locked; view.theme = theme
        view.openLink = { [weak coordinator] in coordinator?.followLink($0) }
        view.handleKey = { [weak coordinator] in coordinator?.handleKey($0) ?? false }
        view.annotationAction = { [weak coordinator] in coordinator?.annotateSelection(nil) }
        view.annotationAvailable = { [weak coordinator] in coordinator?.annotationSelection() != nil }
        view.contextualSelectionCompleted = { [weak coordinator] in coordinator?.inlineControls.update() }
        view.contextualInteractionDismiss = { [weak coordinator] in coordinator?.inlineControls.close() }
        view.insertBlockMenu = { [weak coordinator] in coordinator?.insertionMenu(after: $0) ?? NSMenu() }
        view.blockMenu = { [weak coordinator] in coordinator?.contextMenu() ?? NSMenu() }
        view.presentHandleMenu = { [weak coordinator] in coordinator?.presentHandleMenu(for: $0) }
        view.activateBlock = { [weak coordinator] id, command in coordinator?.mutate(command, id: id, name: "Change block") }
        view.selectBlock = { [weak coordinator] in coordinator?.selectBlock($0, modifiers: $1) }
        view.selectedBlockIDs = coordinator.selectedBlockIDs
        view.canReorder = { [weak coordinator] in coordinator?.canReorder($0, before: $1) ?? false }
        view.pasteContent = { [weak coordinator] in coordinator?.paste($0) }
        view.insertionPointColor = theme.native(.accentPrimary)
        view.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
        if coordinator.lastDocument != document || coordinator.session.identity != EditorSession.Identity(pageID: noteID, vaultID: vaultID, sessionID: sessionID) {
            coordinator.load(document); coordinator.lastMacros = texMacros; view.undoManager?.removeAllActions()
        } else if coordinator.lastTheme != theme || coordinator.lastTypography != typography || headingsChanged || macrosChanged {
            if !view.hasMarkedText(), !view.isSettingMarkedText {
                coordinator.refreshPresentation(); coordinator.lastMacros = texMacros
                coordinator.presentationRefreshPending = false
            } else { coordinator.presentationRefreshPending = true }
        }
        view.locked = locked || coordinator.document.unsupportedVersion || (onSemanticLoad != nil && coordinator.session.semanticEdit == nil)
        view.isEditable = editable && !view.locked
        if !view.isEditable {
            coordinator.inlineControls.close()
            coordinator.dismissHandleMenu()
        }
        coordinator.updateAnnotationAvailability()
        if let action, coordinator.lastAction != action.id {
            if case .block = action.operation { coordinator.lastAction = action.id; coordinator.perform(action.operation) }
            else if view.isEditable { coordinator.lastAction = action.id; coordinator.perform(action.operation) }
        }
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.contextualInteractionsRetired = true
        coordinator.activeInsertionMenu?.cancelTracking()
        coordinator.activeInsertionMenu = nil
        coordinator.activeBlockMenuContext = nil
        coordinator.dismissHandleMenu()
        coordinator.flushPublication()
        coordinator.parent.onSessionEnded?(coordinator)
        NotificationCenter.default.removeObserver(coordinator, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        coordinator.inlineControls.close()
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
    private var document: BlockDocument { model.editorDocument }
    private var summaryBusy: Bool {
        model.currentNote.map { model.isSummarizing(target: .page($0.id)) } ?? false
    }
    var editorDocument: Binding<BlockDocument> {
        let identity = EditorSession.Identity(pageID: model.currentNote?.id,
            vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID)
        return Binding(get: { model.editorDocument }, set: { document in
            guard model.editorIdentity == identity else { return }
            model.editorDocument = document
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSummary, summaryBusy || document.aiSummary != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let id = model.currentNote?.id, summaryBusy {
                        AISummaryStatus(model: model, target: .page(id))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                            .readingColumn(reservesEditorGutter: true)
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
                                }.font(.caption).foregroundStyle(.secondary)
                                    .transition(.opacity)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Label("Summary", systemImage: "list.bullet.rectangle").font(.headline)
                                        Spacer()
                                        Button("Hide") { disclosure.toggle() }.buttonStyle(.link).font(.caption)
                                            .accessibilityLabel("Hide AI-generated summary")
                                    }
                                    Text(aiSummaryProvenanceLabel(provider: summary.metadata.extra["aiProvider"], model: summary.metadata.extra["aiModel"]))
                                        .font(.caption).foregroundStyle(.secondary)
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
                        .padding(.vertical, disclosure.collapsed ? 16 : 24)
                        .readingColumn(reservesEditorGutter: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                Divider().scaleEffect(y: 0.5).frame(height: 0.5)
            }
            RichArticleView(document: editorDocument, editable: model.canEditPage, locked: model.editingLocked, action: model.editorAction, onWikiLink: model.followWikiLink, onWikiQuery: { model.wikiQuery = $0 }, noteID: model.currentNote?.id, vaultID: model.sessionState.vaultID, sessionID: model.sessionState.sessionID, hidesAISummary: true, onSessionReady: model.registerHostedEditor, onSessionEnded: model.unregisterHostedEditor, onSnapshot: model.acceptEditorSnapshot, onBlockLink: model.openBlockURL, onSemanticLoad: model.configureSemanticEditor, annotationChoices: model.annotationChoices, onAnnotate: model.annotateSelection, onInspectAssociation: model.inspectSemanticAssociation, onSemanticSelection: model.semanticSelectionChanged, onAnnotationAvailabilityChange: { model.canAnnotateSelection = $0 }, onScrollOffset: { disclosure.scrolled(to: $0) })
                .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: disclosure.collapsed)
        .onChange(of: document.aiSummary?.text) { summaryExpanded = false }
        .onChange(of: disclosure.collapsed) { if disclosure.collapsed { summaryExpanded = false } }
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
