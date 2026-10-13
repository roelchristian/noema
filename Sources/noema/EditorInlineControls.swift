import AppKit
import SwiftUI
import VaultCore

/// Presentation evidence only. Native text storage and EditorSession retain editing authority.
struct EditorInlineSnapshot: Equatable {
    enum State: Equatable { case off, on, mixed }
    let identity: EditorSession.Identity
    let generation: UUID
    let revision: UInt64
    let selection: NSRange
    let states: [String: State]
    let canAnnotate: Bool
}

@MainActor final class EditorInlineControls {
    private weak var coordinator: RichArticleView.Coordinator?
    private var snapshot: EditorInlineSnapshot?
    private var panel: InlineControlPanel?
    private var resizeObserver: NSObjectProtocol?

    init(coordinator: RichArticleView.Coordinator) { self.coordinator = coordinator }

    func close() {
        snapshot = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver); self.resizeObserver = nil }
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    }

    func update() {
        guard let coordinator, !coordinator.contextualInteractionsRetired, !coordinator.contextualIdentitySuspended, let view = coordinator.view, let window = view.window,
              window.firstResponder === view, view.isEditable, !view.locked,
              coordinator.parent.editable, !coordinator.parent.locked, !coordinator.changing,
              (coordinator.parent.onSemanticLoad == nil || coordinator.session.semanticEdit != nil),
              !view.hasMarkedText(), !view.isSettingMarkedText,
              NSEvent.pressedMouseButtons == 0, !coordinator.suggestions.isShown,
              coordinator.wikiRange() == nil, coordinator.selectedBlockIDs.isEmpty,
              view.selectedRanges.count == 1, let storage = view.textStorage else { close(); return }
        let range = view.selectedRange()
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location < storage.length, range.length <= storage.length - range.location,
              !(view.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { close(); return }
        var values: [String: [Bool]] = [:]
        storage.enumerateAttributes(in: range) { attributes, _, _ in
            let style = BlockTextStorage.style(attributes)
            for (name, active) in [("bold", style.bold), ("italic", style.italic),
                                   ("underline", style.underline), ("strike", style.strike),
                                   ("code", style.code), ("highlight", style.highlight),
                                   ("link", style.link != nil)] { values[name, default: []].append(active) }
        }
        let states = values.mapValues { values -> EditorInlineSnapshot.State in
            values.allSatisfy { $0 } ? .on : (values.contains(true) ? .mixed : .off)
        }
        let next = EditorInlineSnapshot(identity: coordinator.session.identity,
            generation: coordinator.session.generation, revision: coordinator.session.revision, selection: range, states: states,
            canAnnotate: coordinator.annotationSelection() != nil)
        let panel: InlineControlPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = InlineControlPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.hidesOnDeactivate = true; panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true; panel.level = .floating
            panel.setAccessibilityLabel("Selection formatting")
            self.panel = panel
        }
        if resizeObserver == nil {
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.update() }
            }
        }
        if snapshot != next {
            snapshot = next
            panel.contentView = NSHostingView(rootView: InlineControlBar(snapshot: next) { [weak self] name in
                self?.execute(name, evidence: next)
            })
        }
        let width: CGFloat = 306, height: CGFloat = 38
        let anchor = view.firstRect(forCharacterRange: range, actualRange: nil)
        let viewport = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        guard anchor.intersects(viewport), viewport.width >= 90, viewport.height >= height else { close(); return }
        let actualWidth = min(width, viewport.width - 8)
        let x = min(max(anchor.midX - actualWidth / 2, viewport.minX + 4), viewport.maxX - actualWidth - 4)
        let above = anchor.maxY + 6
        let y = above + height <= viewport.maxY ? above : max(viewport.minY + 4, anchor.minY - height - 6)
        panel.setFrame(NSRect(x: x, y: y, width: actualWidth, height: height), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    private func execute(_ name: String, evidence: EditorInlineSnapshot) {
        guard snapshot == evidence else { return }
        guard let coordinator, !coordinator.contextualInteractionsRetired, !coordinator.contextualIdentitySuspended, let view = coordinator.view, view.isEditable, !view.locked,
              coordinator.parent.editable, !coordinator.parent.locked,
              (coordinator.parent.onSemanticLoad == nil || coordinator.session.semanticEdit != nil),
              !view.hasMarkedText(), !view.isSettingMarkedText,
              coordinator.session.identity == evidence.identity,
              coordinator.session.generation == evidence.generation,
              coordinator.session.revision == evidence.revision,
              view.selectedRange() == evidence.selection else { close(); return }
        close()
        // The panel never becomes key; selection remains the native NSTextView selection.
        view.window?.makeFirstResponder(view)
        if name == "annotate" {
            guard evidence.canAnnotate, coordinator.annotationSelection() != nil else { return }
            coordinator.annotateSelection(nil)
        } else if name == "link" { coordinator.editLink() }
        else { coordinator.format(name); update() }
    }
}

private final class InlineControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct InlineControlBar: View {
    let snapshot: EditorInlineSnapshot
    let execute: (String) -> Void
    private let commands = [("bold", "bold", "Bold"), ("italic", "italic", "Italic"),
        ("underline", "underline", "Underline"), ("strike", "strikethrough", "Strikethrough"),
        ("code", "chevron.left.forwardslash.chevron.right", "Code"),
        ("highlight", "highlighter", "Highlight"), ("link", "link", "Link")]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(commands, id: \.0) { command in
                    control(command.0, symbol: command.1, label: command.2)
                }
                Divider().frame(height: 18).padding(.horizontal, 3)
                control("annotate", symbol: "tag", label: "Annotate")
                    .disabled(!snapshot.canAnnotate)
            }.padding(5)
        }
        .scrollIndicators(.hidden)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
    private func control(_ name: String, symbol: String, label: String) -> some View {
        let state = snapshot.states[name] ?? .off
        return Button { execute(name) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .background(state == .off ? Color.clear : Color.accentColor.opacity(state == .on ? 0.18 : 0.08),
                    in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .bottom) {
                    if state == .mixed { Capsule().fill(Color.secondary).frame(width: 8, height: 2).padding(.bottom, 2) }
                }
        }
        .buttonStyle(.borderless).help(label).accessibilityLabel(label)
        .accessibilityValue(state == .on ? "On" : state == .mixed ? "Mixed" : "Off")
    }
}
