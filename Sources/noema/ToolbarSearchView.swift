import SwiftUI
import AppKit

/// A small, balanced preview keeps every matching category reachable without
/// allowing a large Pages group to crowd sources and semantic blocks out.
struct ToolbarSearchRow: Identifiable, Equatable {
    enum Category: String, CaseIterable { case pages = "Pages", sources = "Sources", blocks = "Semantic Blocks" }
    let id: String
    let category: Category
    let title: String
    let excerpt: String
    let symbol: String
    let entryID: UUID
    let blockID: UUID?

    static func preview(_ results: SidebarSearchResults, limit: Int = 8) -> [Self] {
        let groups: [[Self]] = [
            results.pages.map { note in
                Self(id: "page:\(note.id)", category: .pages, title: note.title,
                     excerpt: results.pageExcerpts[note.id] ?? "", symbol: "doc.text",
                     entryID: note.id, blockID: nil)
            },
            results.sources.map { source in
                Self(id: "source:\(source.id)", category: .sources, title: source.title,
                     excerpt: results.sourceExcerpts[source.id] ?? "",
                     symbol: source.metadata.isLinked ? "link" : "tray",
                     entryID: source.id, blockID: nil)
            },
            results.blocks.map { hit in
                Self(id: "block:\(hit.id)", category: .blocks, title: hit.pageTitle,
                     excerpt: "\(hit.semantic) · \(hit.preview)",
                     symbol: "tag",
                     entryID: hit.pageID, blockID: hit.blockID)
            }
        ]
        var chosen = Set<String>()
        var index = 0
        while chosen.count < max(0, limit) {
            var found = false
            for group in groups where index < group.count {
                if chosen.count == limit { break }
                chosen.insert(group[index].id)
                found = true
            }
            if !found { break }
            index += 1
        }
        return groups.flatMap { $0.filter { chosen.contains($0.id) } }
    }

    static func nextSelection(current: String?, rows: [Self], offset: Int) -> String? {
        guard !rows.isEmpty else { return nil }
        guard let index = rows.firstIndex(where: { $0.id == current }) else {
            return offset < 0 ? rows.last?.id : rows.first?.id
        }
        return rows[min(max(index + offset, 0), rows.count - 1)].id
    }
}

struct ToolbarSearchView: View {
    @Bindable var model: AppModel
    let availableWidth: CGFloat
    let showAllResults: () -> Void
    @Environment(\.noemaTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var resultsVisible = false
    @State private var selectedID: String?
    @State private var focusRequest = 0
    @State private var focus = ToolbarSearchFocus()

    private var inline: Bool { availableWidth >= 880 }
    private var fieldWidth: CGFloat { min(300, max(240, availableWidth - 660)) }
    private var popoverVisible: Bool { expanded && (!inline || resultsVisible) }
    private var rows: [ToolbarSearchRow] {
        guard model.searchStatus == .results else { return [] }
        return ToolbarSearchRow.preview(model.visibleSearchResults)
    }
    private var placeholder: String { model.searchMode == .quickOpen ? "Quick Open" : "Search vault" }

    var body: some View {
        HStack(spacing: NoemaSpacing.xs) {
            if expanded && inline {
                searchInput
                    .frame(width: fieldWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96)))
                Button { collapse(restoreFocus: true) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close search (Escape)")
                .accessibilityLabel("Close search")
            } else {
                Button(action: activate) {
                    Label("Search vault", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .help("Find in Vault (⇧⌘F)")
                .accessibilityLabel("Search vault")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
        }
        .background {
            ToolbarSearchPopover(
                presented: popoverVisible, expanded: expanded,
                focus: focus,
                content: AnyView(searchPresentation
                    .environment(\.noemaTheme, theme)
                    .environment(\.accessibilityReduceMotion, reduceMotion)),
                onDismiss: dismissPresentation, onEscape: escape
            )
        }
        .disabled(!model.canPerformWorkspaceCommand(.search))
        .onChange(of: model.searchFocusToken) { activate() }
        .onChange(of: model.searchText) {
            selectedID = nil
            if expanded { resultsVisible = true }
        }
        .onChange(of: model.searchScope) { selectedID = nil }
        .onChange(of: model.searchMode) { selectedID = nil }
        .onChange(of: rows.map(\.id)) {
            if let selectedID, !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
        .onChange(of: model.isLocked) { if model.isLocked { reset() } }
        .onChange(of: model.isVaultAvailable) { if !model.isVaultAvailable { reset() } }
        .onChange(of: inline) {
            if expanded {
                focus.acceptsInputFocus = true
                focusRequest += 1
                resultsVisible = true
            }
        }
        .onDisappear { reset() }
    }

    private var searchInput: some View {
        ToolbarSearchInput(text: $model.searchText, placeholder: placeholder,
                           focusRequest: focusRequest, focus: focus,
                           onFocus: { if expanded { focus.acceptsInputFocus = true; resultsVisible = true } },
                           onCommand: inputCommand)
            .accessibilityLabel(placeholder)
    }

    private var searchPresentation: some View {
        VStack(alignment: .leading, spacing: NoemaSpacing.md) {
            if !inline {
                HStack(spacing: NoemaSpacing.sm) {
                    searchInput.fixedSize(horizontal: false, vertical: true)
                    Button { collapse(restoreFocus: true) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close search")
                }
            }
            if resultsVisible {
                Picker("Search scope", selection: Binding(
                    get: { model.searchScope }, set: { model.setSearchScope($0) }
                )) {
                    ForEach(VaultSearchScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .font(NoemaTypography.metadata)
                .accessibilityLabel("Search scope")
                resultsContent
            } else {
                Text("Type to search, or press Escape to close.")
                    .font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
            }
        }
        .padding(NoemaSpacing.md)
        .frame(width: inline ? 440 : min(440, max(300, availableWidth - 80)))
        .background(theme.color(for: .elevated))
    }

    @ViewBuilder private var resultsContent: some View {
        if model.searchMode != .quickOpen && model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stateMessage("Search your vault", detail: "Type to find pages, sources and semantic blocks.", symbol: "magnifyingglass")
        } else {
            switch model.searchStatus {
            case .idle, .searching:
                NoemaLoadingStatus("Searching…", surface: .elevated)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .failed(let message):
                stateMessage("Search failed", detail: message, symbol: "exclamationmark.triangle")
                Button("Try again") { model.queryChanged() }
            case .results:
                if rows.isEmpty {
                    stateMessage("No matches", detail: "Try another word or broaden the search scope.", symbol: "doc.text.magnifyingglass")
                    if model.searchScope != .all {
                        Button("Search All") { model.setSearchScope(.all) }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: NoemaSpacing.sm) {
                                ForEach(ToolbarSearchRow.Category.allCases, id: \.self) { category in
                                    let group = rows.filter { $0.category == category }
                                    if !group.isEmpty {
                                        Text(category.rawValue)
                                            .font(NoemaTypography.sidebarSection)
                                            .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                                            .padding(.horizontal, NoemaSpacing.sm)
                                        ForEach(group) { row in resultRow(row) }
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 420)
                        .onChange(of: selectedID) {
                            if let selectedID {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                                    proxy.scrollTo(selectedID, anchor: .center)
                                }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("\(model.visibleSearchResults.totalCount) \(model.visibleSearchResults.totalCount == 1 ? "result" : "results")")
                            .font(NoemaTypography.metadata)
                            .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
                            .accessibilityLabel("\(model.visibleSearchResults.totalCount) results in \(model.searchScope.title)")
                        Spacer()
                        Button("Show all results") {
                            focus.shouldRestore = false
                            collapse(restoreFocus: false)
                            showAllResults()
                        }
                    }
                }
            }
        }
    }

    private func stateMessage(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: NoemaSpacing.sm) {
            Image(systemName: symbol).foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
            VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
                Text(title).font(NoemaTypography.interfaceEmphasis)
                Text(detail).font(NoemaTypography.metadata)
                    .foregroundStyle(theme.text(for: .textSecondary, on: .elevated))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NoemaSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    private func resultRow(_ row: ToolbarSearchRow) -> some View {
        Button { open(row) } label: {
            HStack(alignment: .top, spacing: NoemaSpacing.sm) {
                Image(systemName: row.symbol).frame(width: NoemaMetrics.iconWidth)
                    .noemaChromeForeground(.textSecondary)
                VStack(alignment: .leading, spacing: NoemaSpacing.xs) {
                    Text(row.title).font(NoemaTypography.interfaceEmphasis).lineLimit(1)
                        .noemaChromeForeground()
                    if !row.excerpt.isEmpty {
                        Text(row.excerpt).font(NoemaTypography.metadata).lineLimit(2)
                            .noemaChromeForeground(.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(NoemaSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: NoemaMetrics.comfortableRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(NoemaChromeButtonStyle(selected: selectedID == row.id, surface: .elevated))
        .id(row.id)
        .accessibilityLabel("\(row.title), \(row.category.rawValue), \(row.excerpt)")
        .accessibilityAddTraits(selectedID == row.id ? [.isSelected] : [])
    }

    private func activate() {
        guard model.canPerformWorkspaceCommand(.search) else { return }
        if !expanded { focus.capture() }
        focus.shouldRestore = true
        focus.acceptsInputFocus = true
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            expanded = true
            resultsVisible = true
        }
        focusRequest += 1
    }

    private func inputCommand(_ command: ToolbarSearchInput.Command) {
        switch command {
        case .up, .down:
            resultsVisible = true
            selectedID = ToolbarSearchRow.nextSelection(current: selectedID, rows: rows, offset: command == .up ? -1 : 1)
        case .submit:
            if let row = rows.first(where: { $0.id == selectedID }) ?? rows.first { open(row) }
        case .escape: escape()
        }
    }

    private func open(_ row: ToolbarSearchRow) {
        focus.shouldRestore = false
        collapse(restoreFocus: false)
        model.select(row.entryID, scope: row.category == .sources ? .sources : .wiki, block: row.blockID)
    }

    private func escape() {
        if resultsVisible { dismissResults() }
        else { collapse(restoreFocus: true) }
    }

    private func dismissPresentation() {
        if inline { dismissResults() }
        else { collapse(restoreFocus: true) }
    }

    private func dismissResults() {
        focus.acceptsInputFocus = false
        resultsVisible = false
        selectedID = nil
        focus.restore()
    }

    private func collapse(restoreFocus: Bool) {
        focus.acceptsInputFocus = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
            resultsVisible = false
            expanded = false
        }
        selectedID = nil
        if restoreFocus { focus.restore() }
        else { focus.resignSearch() }
    }

    private func reset() {
        focus.shouldRestore = false
        collapse(restoreFocus: false)
        focus.clear()
    }
}

/// The saved responder is weak: a document that disappears during navigation
/// cannot be retained by a search session or unexpectedly focused later.
@MainActor private final class ToolbarSearchFocus {
    weak var previousResponder: NSResponder?
    weak var previousWindow: NSWindow?
    weak var input: NSSearchField?
    var shouldRestore = true
    var acceptsInputFocus = false

    func capture() {
        previousWindow = NSApp.keyWindow
        let responder = previousWindow?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor, let owner = editor.delegate as? NSResponder {
            previousResponder = owner
        } else { previousResponder = responder }
    }

    func restore() {
        guard shouldRestore else { return }
        resignSearch()
        if let previousWindow, let previousResponder, previousWindow.isVisible {
            previousWindow.makeKey()
            previousWindow.makeFirstResponder(previousResponder)
        }
    }

    func resignSearch() {
        guard let input, let window = input.window else { return }
        if window.firstResponder === input || window.firstResponder === input.currentEditor() {
            window.makeFirstResponder(nil)
        }
    }

    func clear() { previousResponder = nil; previousWindow = nil; input = nil }
}

private struct ToolbarSearchInput: NSViewRepresentable {
    enum Command { case up, down, submit, escape }
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let focus: ToolbarSearchFocus
    let onFocus: () -> Void
    let onCommand: (Command) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.setAccessibilityLabel(placeholder)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        focus.input = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        focus.input = field
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            let focus = self.focus
            DispatchQueue.main.async { [weak field] in
                guard focus.acceptsInputFocus, let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchInput
        var lastFocusRequest = -1
        init(_ parent: ToolbarSearchInput) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocus() }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: Command
            switch selector {
            case #selector(NSResponder.moveUp(_:)): command = .up
            case #selector(NSResponder.moveDown(_:)): command = .down
            case #selector(NSResponder.insertNewline(_:)): command = .submit
            case #selector(NSResponder.cancelOperation(_:)): command = .escape
            default: return false
            }
            parent.onCommand(command)
            return true
        }
    }
}

/// A semitransient native popover keeps the toolbar field's window eligible for
/// key input. The one-shot focus restoration happens only when it opens, never
/// on result updates, so ordinary typing and scope controls retain their focus.
private struct ToolbarSearchPopover: NSViewRepresentable {
    let presented: Bool
    let expanded: Bool
    let focus: ToolbarSearchFocus
    let content: AnyView
    let onDismiss: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        context.coordinator.anchor = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: ToolbarSearchPopover
        weak var anchor: NSView?
        let popover = NSPopover()
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        var monitor: Any?
        var closing = false
        var showScheduled = false
        init(_ parent: ToolbarSearchPopover) {
            self.parent = parent
            super.init()
            popover.behavior = .semitransient
            popover.animates = false
            hosting.sizingOptions = [.preferredContentSize]
            popover.contentViewController = hosting
            popover.delegate = self
        }

        func update() {
            hosting.rootView = parent.content
            if parent.expanded && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .keyDown {
                        guard let window = self.anchor?.window,
                              event.window === window || event.window === self.hosting.view.window else { return event }
                        if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                            self.parent.onEscape()
                            return nil
                        }
                    } else if self.popover.isShown,
                              event.window !== self.popover.contentViewController?.view.window,
                              let anchor = self.anchor,
                              (event.window !== anchor.window || !anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))) {
                        self.parent.onDismiss()
                    }
                    return event
                }
            } else if !parent.expanded { removeMonitor() }
            guard parent.presented else {
                if popover.isShown {
                    closing = true
                    popover.close()
                    closing = false
                }
                return
            }
            guard !popover.isShown, !showScheduled else { return }
            showScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.showScheduled = false
                guard self.parent.presented, self.parent.focus.acceptsInputFocus,
                      let anchor = self.anchor, anchor.window != nil else { return }
                self.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
                if let input = self.parent.focus.input, let window = input.window {
                    window.makeKey()
                    window.makeFirstResponder(input)
                }
            }
        }

        func popoverDidClose(_ notification: Notification) {
            if !closing { parent.onDismiss() }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        func stop() {
            removeMonitor()
            closing = true
            popover.close()
        }
    }
}
