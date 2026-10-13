import AppKit
import VaultCore

extension RichArticleView {
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        typealias Snapshot = EditorSession.DocumentSnapshot
        var parent: RichArticleView
        weak var view: ArticleTextView?
        let session = EditorSession()
        var document: BlockDocument {
            get { session.document }
            set { session.replaceDocument(newValue) }
        }
        var publicationTask: Task<Void, Never>?
        var presentationDocument: BlockDocument { parent.hidesAISummary && document.aiSummary != nil ? document.withoutAISummary : document }
        var renderedDocument: BlockDocument?
        var renderedHeadings: Bool?
        var rangeIndex: BlockTextStorage.RangeIndex?
        var deferredComposition = false
        var lastDocument: BlockDocument?
        var lastTheme: NoemaTheme?
        var lastTypography: EditorTypography?
        var lastMacros: String?
        var lastAction: UUID?
        var changing = false
        var presentationRefreshPending = false
        let palette = BlockPalette()
        lazy var suggestions = BlockSuggestionPanel(palette: palette)
        var slashRange: NSRange?
        var dismissedSlash: Int?
        var pendingSingleBlock: (UUID, Int)?
        var selectedBlockIDs: Set<UUID> = []
        var blockSelectionAnchor: UUID?
        var blockSelectionFocus: UUID?
        func clearBlockSelection() {
            selectedBlockIDs = []; blockSelectionAnchor = nil; blockSelectionFocus = nil
            view?.selectedBlockIDs = []
        }
        func selectBlock(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
            guard let view, view.isEditable, !view.locked, document.block(id) != nil else { return }
            let ordered = rangeIndex?.ordered.map { $0.0 } ?? document.flattened.map(\.id)
            if modifiers.contains(.shift), let anchor = blockSelectionAnchor,
               let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: id) {
                selectedBlockIDs = Set(ordered[min(start, end)...max(start, end)])
            } else if modifiers.contains(.command) {
                if !selectedBlockIDs.insert(id).inserted { selectedBlockIDs.remove(id) }
                blockSelectionAnchor = id
            } else {
                selectedBlockIDs = [id]; blockSelectionAnchor = id
            }
            blockSelectionFocus = id
            view.selectedBlockIDs = selectedBlockIDs
            dismissPalette()
        }
        var actionBlocks: [EditorBlock] {
            selectedBlockIDs.isEmpty ? current().map { [$0.0] } ?? [] : document.selectedBlocks(selectedBlockIDs)
        }
        func canReorder(_ id: UUID, before target: UUID) -> Bool {
            let ids = selectedBlockIDs.contains(id) ? document.normalizedSelection(selectedBlockIDs) : [id]
            return !ids.isEmpty && !ids.contains(target) && ids.allSatisfy { document.canReorder($0, before: target) }
        }
        func copyBlocks(to pasteboard: NSPasteboard = .general) {
            guard !actionBlocks.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.setString(BlockDocumentCodec.readable(BlockDocument(blocks: actionBlocks)), forType: .string)
        }
        init(_ parent: RichArticleView) {
            self.parent = parent; super.init()
            suggestions.dismiss = { [weak self] in self?.dismissPalette() }
            palette.choose = { [weak self] in self?.apply($0, removingQuery: true) }
        }
        func observeScrolling(in scroll: NSScrollView) {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrollBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        @objc private func scrollBoundsChanged(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView else { return }
            let offset = clip.bounds.minY
            Task { @MainActor [weak self] in self?.parent.onScrollOffset(offset) }
        }
        func load(_ value: BlockDocument) {
            publicationTask?.cancel()
            pendingSingleBlock = nil; deferredComposition = false
            clearBlockSelection()
            session.load(value, identity: .init(pageID: parent.noteID, vaultID: parent.vaultID, sessionID: parent.sessionID), selection: view?.selectedRange() ?? NSRange(location: 0, length: 0))
            lastDocument = value
            parent.onSemanticLoad?(self)
            suggestions.close(); render(selection: view?.selectedRange() ?? NSRange(location: 0, length: 0))
            parent.onSessionReady?(self)
        }
        func render(selection: NSRange) {
            guard let view else { return }
            changing = true
            view.typography = parent.typography
            if let storage = view.textStorage {
                if let previous = renderedDocument, let rangeIndex, renderedHeadings == view.showSemanticHeadings {
                    let oldRange = rangeIndex.ordered.first(where: { id, _ in previous.block(id) != presentationDocument.block(id) })?.1
                    if let oldRange { view.invalidateDecorations(in: oldRange) }
                    let affected = BlockTextStorage.apply(document: presentationDocument, previous: previous, to: storage, index: rangeIndex, theme: parent.theme, showSemanticHeadings: view.showSemanticHeadings, typography: parent.typography)
                    view.invalidateDecorations(in: affected)
                } else {
                    storage.setAttributedString(BlockTextStorage.render(presentationDocument, theme: parent.theme, showSemanticHeadings: view.showSemanticHeadings, typography: parent.typography))
                    rangeIndex = BlockTextStorage.RangeIndex(storage)
                }
                renderedDocument = presentationDocument
                renderedHeadings = view.showSemanticHeadings
                view.blockRangeIndex = rangeIndex
            }
            view.updateSemanticHeadingTopInset()
            let count = view.string.utf16.count
            let limit = selection.length == 0 ? max(0, count - 1) : count
            let location = min(selection.location, limit)
            view.setSelectedRange(NSRange(location: location, length: min(selection.length, max(0, count - location))))
            refreshSemanticRanges()
            session.selection = view.selectedRange(); lastTheme = parent.theme; lastTypography = parent.typography; changing = false; updateTypingAttributes()
        }
        /// Preference changes only replace attributes when the visible text is
        /// unchanged. Native undo entries and all selected character ranges stay
        /// attached to the same storage, including pending editing transactions.
        func refreshPresentation(typography: EditorTypography? = nil) {
            guard let view, let storage = view.textStorage else { return }
            let typography = typography ?? parent.typography
            view.typography = typography
            let rendered = BlockTextStorage.render(presentationDocument, theme: parent.theme,
                showSemanticHeadings: view.showSemanticHeadings, typography: typography)
            let selections = view.selectedRanges
            let affinity = view.selectionAffinity
            let clip = view.enclosingScrollView?.contentView
            let scrollOrigin = clip?.bounds.origin
            changing = true
            if rendered.string == storage.string {
                storage.beginEditing()
                rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
                    storage.setAttributes(attributes, range: range)
                }
                storage.endEditing()
            } else {
                // TeX macro changes can alter displayed characters. Preserve
                // legal ranges while allowing that existing content refresh.
                storage.setAttributedString(rendered)
            }
            rangeIndex?.rebuild(storage)
            view.blockRangeIndex = rangeIndex
            renderedDocument = presentationDocument
            renderedHeadings = view.showSemanticHeadings
            view.updateSemanticHeadingTopInset()
            let count = storage.length
            view.setSelectedRanges(selections.map { value in
                let range = value.rangeValue
                let location = min(range.location, count)
                return NSValue(range: NSRange(location: location, length: min(range.length, count - location)))
            }, affinity: affinity, stillSelecting: false)
            if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
            if let clip, let scrollOrigin {
                clip.scroll(to: scrollOrigin)
                view.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            lastTheme = parent.theme
            lastTypography = typography
            changing = false
            updateTypingAttributes()
            refreshSemanticRanges()
            view.needsDisplay = true
        }
        func capture() {
            if let storage = view?.textStorage {
                var captured = BlockTextStorage.capture(storage, previous: presentationDocument)
                if parent.hidesAISummary, let summary = document.aiSummary { captured.blocks.insert(summary, at: 0) }
                document = captured
                rangeIndex?.rebuild(storage)
                pendingSingleBlock = nil; deferredComposition = false
            }
        }
        func publish() {
            refreshSemanticRanges()
            publicationTask?.cancel()
            publicationTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self,
                      self.view?.hasMarkedText() != true, self.view?.isSettingMarkedText != true else { return }
                self.publishSnapshot()
            }
            updatePalette(); updateWikiQuery()
        }
        private func publishSnapshot() {
            guard parent.document == lastDocument else { return }
            session.selection = view?.selectedRange() ?? session.selection
            let snapshot = session.snapshot()
            guard parent.noteID == snapshot.identity.pageID,
                  parent.vaultID == snapshot.identity.vaultID,
                  parent.sessionID == snapshot.identity.sessionID,
                  session.markPublished(snapshot) else { return }
            lastDocument = snapshot.document
            if let onSnapshot = parent.onSnapshot { onSnapshot(snapshot) }
            else { parent.document = snapshot.document }
        }
        /// Save/navigation also preserves an in-progress native composition.
        func flushPublication() {
            invalidatePublication()
            guard parent.document == lastDocument else { return }
            if deferredComposition || view?.hasMarkedText() == true || pendingSingleBlock != nil { capture() }
            publishSnapshot()
        }
        func invalidatePublication() { publicationTask?.cancel(); publicationTask = nil }

        func current() -> (EditorBlock, NSRange)? {
            guard let view, let storage = view.textStorage, storage.length > 0 else { return nil }
            let location = min(view.selectedRange().location, storage.length - 1)
            guard let (id, range) = rangeIndex?.block(at: location), let block = document.block(id) else { return nil }
            return (block, range)
        }
        func selection(for cursor: BlockCursor) -> NSRange {
            guard view?.textStorage != nil, let range = rangeIndex?.range(for: cursor.id) else { return NSRange(location: 0, length: 0) }
            return NSRange(location: range.location + min(max(0, cursor.offset), range.length - 1), length: 0)
        }
        func restore(_ snapshot: Snapshot, name: String, blockSelection: Set<UUID> = []) {
            guard let view, snapshot.identity == session.identity, snapshot.generation == session.generation else { return }
            session.selection = view.selectedRange()
            updateAnnotationAvailability()
            let inverse = session.snapshot()
            let inverseBlocks = selectedBlockIDs
            view.undoManager?.registerUndo(withTarget: self) { target in target.restore(inverse, name: name, blockSelection: inverseBlocks) }
            session.restore(snapshot, name: name); render(selection: snapshot.selection)
            selectedBlockIDs = blockSelection.filter { document.block($0) != nil }
            view.selectedBlockIDs = selectedBlockIDs
            blockSelectionAnchor = document.normalizedSelection(selectedBlockIDs).first
            publish()
            view.undoManager?.setActionName(name)
        }
        func transaction(_ name: String, _ change: () -> BlockCursor?) {
            guard let view, view.isEditable, !view.locked, !changing, !view.hasMarkedText(), !view.isSettingMarkedText else { return }
            capture(); session.selection = view.selectedRange(); let before = session.snapshot()
            let beforeBlocks = selectedBlockIDs
            let cursor = change()
            guard document != before.document else { return }
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            view.undoManager?.registerUndo(withTarget: self) { target in target.restore(before, name: name, blockSelection: beforeBlocks) }
            view.undoManager?.setActionName(name)
            view.undoManager?.endUndoGrouping()
            render(selection: before.selection)
            changing = true
            if let cursor { view.setSelectedRange(selection(for: cursor)) }
            changing = false
            selectedBlockIDs = selectedBlockIDs.filter { document.block($0) != nil }
            view.selectedBlockIDs = selectedBlockIDs
            updateTypingAttributes(); publish(); view.scrollRangeToVisible(view.selectedRange())
        }
        func mutate(_ command: BlockMutation, id: UUID? = nil, name: String) {
            guard let view, let (block, range) = current() else { return }
            let offset = view.selectedRange().location - range.location
            let batch = !selectedBlockIDs.isEmpty && (id == nil || selectedBlockIDs.contains(id!))
            transaction(name) {
                let result = batch ? document.apply(command, to: selectedBlockIDs) : document.apply(command, to: id ?? block.id)
                switch command {
                case .split, .mergeBackward, .delete, .removeKeepingChildren, .duplicate: return result
                case .reorder, .reorderAfter: return result.map { _ in BlockCursor(block.id, offset: offset) }
                default: return result.map { BlockCursor($0.id, offset: offset) }
                }
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let view, !changing, !view.locked else { return }
            if view.hasMarkedText() || view.isSettingMarkedText { deferredComposition = true; return }
            if !deferredComposition, let (id, location) = pendingSingleBlock, let storage = view.textStorage, location < storage.length {
                var range = NSRange()
                let actualID = (storage.attribute(.blockID, at: location, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? String).flatMap(UUID.init(uuidString:))
                if actualID == id {
                    var content = range; if (storage.string as NSString).substring(with: range).hasSuffix("\n") { content.length -= 1 }
                    let runs = BlockTextStorage.runs(storage, range: content)
                    session.updateRuns(id, runs: runs, selection: view.selectedRange()); rangeIndex?.applyLocalEdit(blockID: id, delta: range.length - (rangeIndex?.range(for: id)?.length ?? range.length))
                } else { capture() }
            } else { capture() }
            pendingSingleBlock = nil
            deferredComposition = false
            renderedDocument = presentationDocument
            if let storage = view.textStorage {
                changing = true
                let affected = current().flatMap { rangeIndex?.rhythmAffectedRange(for: $0.0.id, storage: storage) }
                BlockTextStorage.updateParagraphRhythm(storage, in: affected, index: rangeIndex, typography: parent.typography)
                if view.showSemanticHeadings { BlockTextStorage.updateSemanticHeadingSpacing(storage, in: affected, index: rangeIndex, typography: parent.typography) }
                changing = false
            }
            view.updateSemanticHeadingTopInset()
            // Native undo restores the attributed runs saved before a font
            // preference change. Reapply the currently displayed typography to
            // those runs without registering another edit or discarding redo.
            if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
                refreshActiveBlockPresentation()
            }
            if presentationRefreshPending {
                presentationRefreshPending = false
                refreshPresentation(); lastMacros = parent.texMacros
            }
            if let affected = current()?.1 { view.invalidateDecorations(in: affected) }
            if let (block, _) = current(), block.kind != .code, block.kind != .math, let command = BlockCommand.shortcut(block.text) {
                transaction(command.title) { document.update(block.id) { $0.runs = [] }; return document.apply(command.mutation, to: block.id) }
            } else if !convertInlineAtCaret() { publish() }
            updateTypingAttributes()
        }
        private func refreshActiveBlockPresentation() {
            guard let view, let storage = view.textStorage, let (block, range) = current() else { return }
            let depth = storage.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int ?? 0
            let typography = lastTypography ?? parent.typography
            let rendered = BlockTextStorage.renderBlock(block, depth: depth, theme: parent.theme, typography: typography)
            guard rendered.string == (storage.string as NSString).substring(with: range) else { return }
            changing = true; storage.beginEditing()
            rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, part, _ in
                storage.setAttributes(attributes, range: NSRange(location: range.location + part.location, length: part.length))
            }
            storage.endEditing()
            let affected = rangeIndex?.rhythmAffectedRange(for: block.id, storage: storage)
            BlockTextStorage.updateParagraphRhythm(storage, in: affected, index: rangeIndex, typography: typography)
            if view.showSemanticHeadings { BlockTextStorage.updateSemanticHeadingSpacing(storage, in: affected, index: rangeIndex, typography: typography) }
            changing = false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            updateAnnotationAvailability()
            guard !changing, let view, !view.hasMarkedText(), !view.isSettingMarkedText else { return }
            if view.selectedRange().length == 0, view.string.hasSuffix("\n"), view.selectedRange().location == view.string.utf16.count {
                changing = true; view.setSelectedRange(NSRange(location: max(0, view.string.utf16.count - 1), length: 0)); changing = false
            }
            clearBlockSelection()
            session.selection = view.selectedRange()
            updateAnnotationAvailability()
            parent.onSemanticSelection?(view.semanticAssociations(in: view.selectedRange()).map { $0.annotation.id })
            updateTypingAttributes(); updatePalette(); updateWikiQuery()
        }
        func updateTypingAttributes() {
            guard let view, !view.hasMarkedText(), !view.isSettingMarkedText, let storage = view.textStorage, storage.length > 0 else { return }
            let location = min(view.selectedRange().location, storage.length - 1)
            var attrs = storage.attributes(at: location, effectiveRange: nil)
            if view.selectedRange().length == 0, location > 0,
               storage.attribute(.blockID, at: location - 1, effectiveRange: nil) as? String == attrs[.blockID] as? String {
                let prevAttrs = storage.attributes(at: location - 1, effectiveRange: nil)
                let prevStyle = BlockTextStorage.style(prevAttrs)
                let currStyle = BlockTextStorage.style(attrs)
                if (prevStyle.math && !currStyle.math) || (prevStyle.code && !currStyle.code) {
                    if let (block, blockRange) = current() {
                        var exited = prevStyle
                        exited.math = false
                        exited.rawMath = nil
                        exited.code = false
                        let depth = storage.attribute(.blockDepth, at: blockRange.location, effectiveRange: nil) as? Int ?? 0
                        let paragraph = attrs[.paragraphStyle]
                        attrs = BlockTextStorage.attributes(exited, block: block, depth: depth, theme: parent.theme, typography: parent.typography)
                        attrs[.paragraphStyle] = paragraph
                    }
                } else {
                    // Inherit the preceding run when typing immediately after formatted content.
                    attrs = prevAttrs
                }
            }
            view.typingAttributes = attrs
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard textView.isEditable, view?.locked == false, !document.unsupportedVersion, !parent.locked else { return false }
            clearBlockSelection()
            if textView.hasMarkedText() || view?.isSettingMarkedText == true {
                deferredComposition = true; pendingSingleBlock = nil; return true
            }
            guard let (block, blockRange) = current() else { return true }
            if block.kind == .divider { return false }
            pendingSingleBlock = range.location >= blockRange.location && NSMaxRange(range) <= NSMaxRange(blockRange) - 1 ? (block.id, blockRange.location) : nil
            // Cross-block replacements merge the selected text and preserve surviving descendants.
            if !textView.hasMarkedText(), NSMaxRange(range) >= NSMaxRange(blockRange) && range.length > 0 {
                transaction("Replace selection") {
                    let runs = [RichRun(replacementString ?? "", style: BlockTextStorage.style(textView.typingAttributes))]
                    return replaceSelection(with: runs, range: range)
                }
                return false
            }
            return true
        }
        func prepareMarkedReplacement(_ range: NSRange) -> NSRange {
            guard let view, let (_, blockRange) = current(), range.length > 0,
                  NSMaxRange(range) >= NSMaxRange(blockRange) else { return range }
            transaction("Replace composition selection") { replaceSelection(with: [], range: range) }
            return view.selectedRange()
        }
        func updatePalette() {
            guard let view, view.isEditable, !view.locked, current()?.0.kind != .code, current()?.0.kind != .math,
                  let range = BlockCommand.slashRange(in: view.string, selection: view.selectedRange()) else {
                suggestions.close(); slashRange = nil; dismissedSlash = nil; return
            }
            let changed = slashRange != range; slashRange = range
            guard dismissedSlash != range.location else { return }
            if changed || !suggestions.isShown { palette.update(BlockCommand.matching(String((view.string as NSString).substring(with: range).dropFirst()))) }
            do {
                guard let window = view.window else { return }
                view.layoutManager?.ensureLayout(for: view.textContainer!)
                var actualRange = NSRange()
                // Keep suggestions aligned with the slash, even as the query grows,
                // wraps, or changes the menu height.
                let screenRect = view.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: &actualRange)
                let viewport = window.convertToScreen(view.convert(view.visibleRect, to: nil))
                let available = viewport.intersection(window.screen?.visibleFrame ?? window.frame)
                guard !available.isEmpty else { suggestions.close(); return }
                let frame = BlockSuggestionPanel.frame(caret: screenRect, available: available, desired: palette.preferredContentSize)
                suggestions.show(frame: frame, of: window)
                window.makeFirstResponder(view)
            }
        }
        func dismissPalette() { dismissedSlash = slashRange?.location; suggestions.close() }
        func apply(_ command: BlockCommand, removingQuery: Bool) {
            if !removingQuery {
                mutate(command.mutation, name: command.title)
                return
            }
            guard let view, let (block, range) = current() else { return }
            var offset = view.selectedRange().location - range.location
            let query = removingQuery ? slashRange : nil
            dismissPalette()
            transaction(command.title) {
                if let query, query.location >= range.location, NSMaxRange(query) <= NSMaxRange(range) {
                    let local = NSRange(location: query.location - range.location, length: query.length)
                    document.update(block.id) { value in
                        value.runs = value.slicing(NSRange(location: 0, length: local.location)) + value.slicing(NSRange(location: NSMaxRange(local), length: max(0, value.utf16Count - NSMaxRange(local))))
                    }
                    offset = local.location
                }
                _ = document.apply(command.mutation, to: block.id)
                return BlockCursor(block.id, offset: offset)
            }
        }
        func handleKey(_ event: NSEvent) -> Bool {
            guard let view, view.isEditable, !view.locked, let (block, range) = current() else { return false }
            if suggestions.isShown {
                switch event.keyCode {
                case 125: palette.move(1); return true
                case 126: palette.move(-1); return true
                case 36, 76: palette.execute(); return true
                case 53: dismissPalette(); return true
                default: break
                }
            }
            let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift), option = event.modifierFlags.contains(.option)
            if !selectedBlockIDs.isEmpty {
                if event.keyCode == 51 || event.keyCode == 117 { mutate(.delete, name: "Delete blocks"); return true }
                if command, event.charactersIgnoringModifiers?.lowercased() == "c" { copyBlocks(); return true }
                if command, event.charactersIgnoringModifiers?.lowercased() == "d" { mutate(.duplicate, name: "Duplicate blocks"); return true }
                if command && option && (event.keyCode == 126 || event.keyCode == 125) {
                    mutate(.move(event.keyCode == 126 ? -1 : 1), name: "Move blocks"); return true
                }
                if shift && (event.keyCode == 126 || event.keyCode == 125), let anchor = blockSelectionFocus ?? document.normalizedSelection(selectedBlockIDs).last {
                    let ordered = rangeIndex?.ordered.map { $0.0 } ?? []
                    if let index = ordered.firstIndex(of: anchor), ordered.indices.contains(index + (event.keyCode == 126 ? -1 : 1)) {
                        selectBlock(ordered[index + (event.keyCode == 126 ? -1 : 1)], modifiers: .shift)
                    }
                    return true
                }
            }
            if command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "b": format("bold"); return true
                case "i": format("italic"); return true
                case "u": format("underline"); return true
                case "k": editLink(); return true
                case "a":
                    if shift && !option { annotateSelection(nil); return true }
                    if option { view.selectEntireDocument(nil) } else { view.selectAll(nil) }; return true
                default: break
                }
                if option {
                    if event.keyCode == 126 { mutate(.move(-1), name: "Move block up"); return true }
                    if event.keyCode == 125 { mutate(.move(1), name: "Move block down"); return true }
                }
                if shift && (event.keyCode == 36 || event.keyCode == 76), block.kind == .task { mutate(.checked, name: "Toggle task"); return true }
            }
            let offset = view.selectedRange().location - range.location
            switch event.keyCode {
            case 36, 76:
                if shift, (block.kind == .code || block.kind == .math) { return false }
                if block.kind == .divider { mutate(.split(block.utf16Count), name: "New paragraph"); return true }
                transaction("Split block") {
                    deleteSelectionFromStorage()
                    return document.apply(.split(offset), to: block.id)
                }; return true
            case 51:
                if offset == 0 && view.selectedRange().length == 0 {
                    if block.kind == .paragraph, let depth = view.textStorage?.attribute(.blockDepth, at: range.location, effectiveRange: nil) as? Int, depth > 0 { mutate(.outdent, name: "Outdent block") }
                    else { mutate(.mergeBackward, name: "Merge block") }
                    return true
                }
            case 48:
                if block.kind == .code || block.kind == .math { return false }
                mutate(shift ? .outdent : .indent, name: shift ? "Outdent block" : "Indent block"); return true
            case 53:
                if slashRange != nil { dismissPalette() }
                parent.onWikiQuery(nil)
                return true
            default: break
            }
            return false
        }
        @discardableResult func replaceSelection(with runs: [RichRun], range requested: NSRange? = nil) -> BlockCursor? {
            guard let view, let storage = view.textStorage else { return nil }
            let selection = requested ?? view.selectedRange(), ranges = BlockTextStorage.ranges(storage)
            guard let startIndex = ranges.firstIndex(where: { NSLocationInRange(selection.location, $0.1) }) else { return nil }
            let endLocation = min(NSMaxRange(selection), max(0, storage.length - 1))
            let endIndex = ranges.firstIndex(where: { NSLocationInRange(endLocation, $0.1) }) ?? startIndex
            let (startID, startRange) = ranges[startIndex], (endID, endRange) = ranges[endIndex]
            guard let first = document.block(startID), let last = document.block(endID) else { return nil }
            let start = min(first.utf16Count, selection.location - startRange.location), end = min(last.utf16Count, max(0, endLocation - endRange.location))
            let before = first.slicing(NSRange(location: 0, length: start))
            let after = last.slicing(NSRange(location: end, length: last.utf16Count - end))
            document.update(startID) { $0.runs = before + runs + after }
            if endIndex > startIndex {
                for index in stride(from: endIndex, through: startIndex + 1, by: -1) { _ = document.apply(.removeKeepingChildren, to: ranges[index].0) }
            }
            return BlockCursor(startID, offset: start + runs.reduce(0) { $0 + $1.text.utf16.count })
        }
        func deleteSelectionFromStorage() {
            guard let view, view.selectedRange().length > 0 else { return }
            _ = replaceSelection(with: [])
        }
        func convertInlineAtCaret() -> Bool {
            guard let view, let (block, range) = current(), block.kind != .code, block.kind != .math, block.kind != .divider, view.selectedRange().length == 0 else { return false }
            let offset = view.selectedRange().location - range.location
            let before = (block.text as NSString).substring(to: min(offset, block.utf16Count))
            let patterns: [(String, String)] = [(#"\*\*([^*\n]+)\*\*$"#, "bold"), (#"(?<!\*)\*([^*\n]+)\*$"#, "italic"), (#"`([^`\n]+)`$"#, "code"), (#"~~([^~\n]+)~~$"#, "strike"), (#"(?<!\$)\$([^$\n]+)\$$"#, "math")]
            for (pattern, styleName) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: before.utf16.count)) else { continue }
                var runs = block.slicing(match.range(at: 1))
                if styleName == "math" {
                    let raw = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
                    guard !raw.isEmpty else { continue }
                    let rendered = TeXMath.render(raw, display: false)
                    var style = runs.first?.style ?? InlineStyle()
                    style.math = true
                    style.rawMath = raw
                    runs = [RichRun(rendered.isEmpty ? raw : rendered, style: style)]
                } else {
                    for index in runs.indices {
                        switch styleName { case "bold": runs[index].style.bold = true; case "italic": runs[index].style.italic = true; case "code": runs[index].style.code = true; default: runs[index].style.strike = true }
                    }
                }
                let insertedLen = runs.reduce(0) { $0 + $1.text.utf16.count }
                transaction("Inline " + styleName) {
                    document.update(block.id) { value in value.runs = value.slicing(NSRange(location: 0, length: match.range.location)) + runs + value.slicing(NSRange(location: NSMaxRange(match.range), length: value.utf16Count - NSMaxRange(match.range))) }
                    return BlockCursor(block.id, offset: match.range.location + insertedLen)
                }
                return true
            }
            if let open = before.range(of: "[[", options: .backwards), before.hasSuffix("]]"), let syntaxRange = Range(NSRange(open.lowerBound..<before.endIndex, in: before), in: before) {
                let syntax = String(before[syntaxRange]), runs = BlockDocumentCodec.inline(syntax)
                guard runs.contains(where: { $0.style.wikiTarget != nil }) else { return false }
                let local = NSRange(open.lowerBound..<before.endIndex, in: before)
                transaction("Wiki link") {
                    document.update(block.id) { $0.runs = $0.slicing(NSRange(location: 0, length: local.location)) + runs + $0.slicing(NSRange(location: NSMaxRange(local), length: $0.utf16Count - NSMaxRange(local))) }
                    return BlockCursor(block.id, offset: local.location + runs.map { $0.text.utf16.count }.reduce(0, +))
                }; return true
            }
            return false
        }
        func format(_ name: String, link: String? = nil) {
            guard let view, let storage = view.textStorage, let (block, blockRange) = current() else { return }
            let selection = view.selectedRange()
            func apply(_ value: inout InlineStyle, enabled: Bool) {
                switch name {
                case "bold": value.bold = enabled
                case "italic": value.italic = enabled
                case "underline": value.underline = enabled
                case "strike": value.strike = enabled
                case "code": value.code = enabled
                case "math": value.math = enabled; if !enabled { value.rawMath = nil }
                case "highlight": value.highlight = enabled
                case "link": value.link = link; value.wikiTarget = nil
                default: break
                }
            }
            let firstStyle = selection.length > 0 ? BlockTextStorage.style(storage.attributes(at: selection.location, effectiveRange: nil)) : BlockTextStorage.style(view.typingAttributes)
            let enabled: Bool
            switch name { case "bold": enabled = !firstStyle.bold; case "italic": enabled = !firstStyle.italic; case "underline": enabled = !firstStyle.underline; case "strike": enabled = !firstStyle.strike; case "code": enabled = !firstStyle.code; case "math": enabled = !firstStyle.math; case "highlight": enabled = !firstStyle.highlight; default: enabled = true }
            if selection.length == 0 {
                var style = firstStyle; apply(&style, enabled: enabled)
                let depth = storage.attribute(.blockDepth, at: blockRange.location, effectiveRange: nil) as? Int ?? 0
                view.typingAttributes = BlockTextStorage.attributes(style, block: block, depth: depth, theme: parent.theme, typography: parent.typography); return
            }
            transaction("Format " + name) {
                for (id, range) in BlockTextStorage.ranges(storage) {
                    let intersection = NSIntersectionRange(selection, NSRange(location: range.location, length: max(0, range.length - 1)))
                    guard intersection.length > 0 else { continue }
                    let local = NSRange(location: intersection.location - range.location, length: intersection.length)
                    document.update(id) { value in
                        var styled = value.slicing(local)
                        for index in styled.indices {
                            apply(&styled[index].style, enabled: enabled)
                            if name == "math", enabled {
                                let raw = styled[index].style.rawMath ?? styled[index].text
                                styled[index].style.rawMath = raw
                                let rendered = TeXMath.render(raw, display: false)
                                if !rendered.isEmpty { styled[index].text = rendered }
                            }
                        }
                        value.runs = value.slicing(NSRange(location: 0, length: local.location)) + styled + value.slicing(NSRange(location: NSMaxRange(local), length: value.utf16Count - NSMaxRange(local)))
                    }
                }
                return nil
            }
            view.setSelectedRange(selection)
        }
        func editLink() {
            guard let view else { return }
            let selected = view.selectedRange()
            let alert = NSAlert(); alert.messageText = "Hyperlink"; alert.informativeText = "Enter a URL. Leave it empty to remove the link."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); field.placeholderString = "https://example.com"
            if let storage = view.textStorage, selected.location < storage.length { field.stringValue = String(describing: storage.attribute(.link, at: selected.location, effectiveRange: nil) ?? "") }
            alert.accessoryView = field; alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn { view.setSelectedRange(selected); format("link", link: field.stringValue.isEmpty ? nil : field.stringValue) }
            view.window?.makeFirstResponder(view)
        }
        func perform(_ operation: EditorAction.Operation) {
            guard let view else { return }
            if view.locked { if case .block = operation {} else { return } }
            view.window?.makeFirstResponder(view)
            switch operation {
            case .wrap(let prefix, _):
                switch prefix { case "**": format("bold"); case "*": format("italic"); case "underline", "strike", "code", "math", "highlight": format(prefix); case "link": editLink(); case "block-actions": showBlockMenu(); case "annotate-selection": annotateSelection(nil); default: view.insertText("[[", replacementRange: view.selectedRange()) }
            case .block(let id):
                func expand(_ blocks: inout [EditorBlock]) -> Bool {
                    for index in blocks.indices {
                        if blocks[index].id == id { return true }
                        if expand(&blocks[index].children) { blocks[index].metadata.collapsed = false; return true }
                    }
                    return false
                }
                guard expand(&document.blocks) else { return }
                render(selection: view.selectedRange()); view.setSelectedRange(selection(for: BlockCursor(id))); view.scrollRangeToVisible(view.selectedRange())
            case .wikiLink(let title):
                let range = wikiRange() ?? view.selectedRange()
                view.insertText("[[" + title + "]]", replacementRange: range)
            }
        }
        func wikiRange() -> NSRange? {
            guard let view else { return nil }
            let before = (view.string as NSString).substring(to: view.selectedRange().location)
            guard let range = before.range(of: "[[", options: .backwards) else { return nil }
            let query = before[range.upperBound...]
            guard !query.contains("]"), !query.contains("\n"), query.count < 100 else { return nil }
            return NSRange(range.lowerBound..<before.endIndex, in: before)
        }
        func updateWikiQuery() {
            guard let view, view.isEditable, let range = wikiRange() else { parent.onWikiQuery(nil); return }
            parent.onWikiQuery(String((view.string as NSString).substring(with: range).dropFirst(2)))
        }
        func paste(_ pasteboard: NSPasteboard) {
            guard let view, let (block, range) = current() else { return }
            let offset = view.selectedRange().location - range.location
            var pasted: [EditorBlock] = []
            if let data = pasteboard.data(forType: .rtf), let rich = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                let ns = rich.string as NSString; var cursor = 0
                while cursor < ns.length {
                    let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
                    var content = line; if ns.substring(with: line).hasSuffix("\n") { content.length -= 1 }
                    pasted.append(EditorBlock(runs: BlockTextStorage.runs(rich, range: content))); cursor = NSMaxRange(line)
                }
                if rich.containsAttachments, !pasted.isEmpty { pasted[0].metadata.extra["pastedRTF"] = data.base64EncodedString() }
            } else if let plain = pasteboard.string(forType: .string) { pasted = BlockDocumentCodec.decode(plain).blocks }
            guard !pasted.isEmpty else { NSSound.beep(); return }
            pasted = pasted.map { $0.renewedIdentity() }
            transaction("Paste blocks") {
                deleteSelectionFromStorage()
                guard let currentBlock = document.block(block.id) else { return nil }
                let before = currentBlock.slicing(NSRange(location: 0, length: min(offset, currentBlock.utf16Count)))
                let after = currentBlock.slicing(NSRange(location: min(offset, currentBlock.utf16Count), length: max(0, currentBlock.utf16Count - offset)))
                if pasted.count == 1 && pasted[0].children.isEmpty && pasted[0].kind == .paragraph {
                    document.update(block.id) { $0.runs = before + pasted[0].runs + after }
                    return BlockCursor(block.id, offset: offset + pasted[0].utf16Count)
                }
                // Insert via the same split/reorder commands; preserve the suffix and source subtrees.
                document.update(block.id) { $0.runs = before }
                let end = document.apply(.split(document.block(block.id)?.utf16Count ?? 0), to: block.id)!
                document.update(end.id) { $0.runs = after }
                var insertionID = block.id
                for value in pasted {
                    let next = document.apply(.split(document.block(insertionID)?.utf16Count ?? 0), to: insertionID)!
                    document.update(next.id) { target in var copy = value; copy.id = next.id; target = copy }
                    insertionID = next.id
                }
                return BlockCursor(insertionID, offset: document.block(insertionID)?.utf16Count ?? 0)
            }
        }
        func showBlockMenu() {
            guard let view, let (_, range) = current() else { return }
            let rect = view.rect(for: range)
            contextMenu().popUp(positioning: nil, at: NSPoint(x: view.textContainerOrigin.x, y: rect.minY + 20), in: view)
        }
        func contextMenu() -> NSMenu {
            let menu = NSMenu()
            let annotation = NSMenuItem(title: "Annotate Selection…", action: #selector(annotateSelection(_:)), keyEquivalent: "A")
            annotation.target = self; annotation.keyEquivalentModifierMask = [.command, .shift]
            annotation.isEnabled = annotationSelection() != nil
            menu.addItem(annotation)
            let structure = NSMenu(), tags = NSMenu()
            for command in BlockCommand.all {
                let item = NSMenuItem(title: command.title, action: #selector(contextCommand(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = command.id; item.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil)
                let targets = actionBlocks
                if !targets.isEmpty {
                    let matches = targets.filter { block in
                        if let semantic = command.semantic { return block.metadata.semantic == (semantic.isEmpty ? nil : semantic) }
                        if case .transform(let kind) = command.mutation { return block.kind == kind }
                        return false
                    }.count
                    item.state = matches == targets.count ? .on : (matches > 0 ? .mixed : .off)
                }
                (command.semantic == nil ? structure : tags).addItem(item)
            }
            let unknown = Set(actionBlocks.compactMap { $0.metadata.semantic }).filter { SemanticPresentation.find($0) == nil }.sorted()
            for designation in unknown {
                let item = NSMenuItem(title: designation, action: nil, keyEquivalent: "")
                item.state = .on; tags.addItem(item)
            }
            for (title, submenu) in [("Turn into", structure), ("Semantic tag", tags)] { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item) }
            if let block = actionBlocks.first {
                let targets = actionBlocks
                let statuses = SemanticPresentation.find(block.metadata.semantic)?.statuses.filter { status in
                    targets.allSatisfy { SemanticPresentation.find($0.metadata.semantic)?.statuses.contains(status) == true }
                } ?? []
                if !statuses.isEmpty || block.metadata.status != nil {
                    let submenu = NSMenu()
                    for status in ["None"] + statuses {
                        addAction(status.capitalized, value: "status:" + (status == "None" ? "" : status), to: submenu)
                        let selected = status == "None" ? nil : status
                        let matches = targets.filter { $0.metadata.status == selected }.count
                        submenu.items.last?.state = matches == targets.count ? .on : (matches > 0 ? .mixed : .off)
                    }
                    if let status = block.metadata.status, !statuses.contains(status) {
                        let preserved = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                        preserved.state = .on; submenu.addItem(preserved)
                    }
                    let item = NSMenuItem(title: "Status", action: nil, keyEquivalent: ""); item.submenu = submenu; menu.addItem(item)
                }
                if block.kind == .task { addAction("Toggle checked", value: "checked", to: menu) }
                if block.kind == .toggle { addAction(block.metadata.collapsed ? "Expand" : "Collapse", value: "collapse", to: menu) }
                if block.kind == .code { addAction("Code language…", value: "language", to: menu) }
            }
            menu.addItem(.separator())
            for (title, value) in [("Duplicate", "duplicate"), ("Copy Markdown", "copy"), ("Copy link to block", "link"), ("Move up", "up"), ("Move down", "down"), ("Indent", "indent"), ("Outdent", "outdent"), ("Delete", "delete")] { addAction(title, value: value, to: menu) }
            let format = NSMenu()
            for title in ["Bold", "Italic", "Underline", "Strike", "Code", "Math", "Highlight", "Link"] { addAction(title, value: "format:" + title.lowercased(), to: format) }
            let item = NSMenuItem(title: "Inline format", action: nil, keyEquivalent: ""); item.submenu = format; menu.addItem(item)
            return menu
        }
        private func addAction(_ title: String, value: String, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = value; menu.addItem(item)
        }
        @objc func contextCommand(_ item: NSMenuItem) {
            if let id = item.representedObject as? String, let command = BlockCommand.all.first(where: { $0.id == id }) { apply(command, removingQuery: false) }
        }
        @objc func contextAction(_ item: NSMenuItem) {
            guard let value = item.representedObject as? String, let block = actionBlocks.first else { return }
            if value.hasPrefix("status:") { let status = String(value.dropFirst(7)); mutate(.status(status.isEmpty ? nil : status), name: "Change status"); return }
            if value.hasPrefix("format:") { let name = String(value.dropFirst(7)); if name == "link" { editLink() } else { format(name) }; return }
            switch value {
            case "duplicate": mutate(.duplicate, name: "Duplicate block")
            case "delete": mutate(.delete, name: "Delete block")
            case "up": mutate(.move(-1), name: "Move block up")
            case "down": mutate(.move(1), name: "Move block down")
            case "indent": mutate(.indent, name: "Indent block")
            case "outdent": mutate(.outdent, name: "Outdent block")
            case "checked": mutate(.checked, name: "Toggle task")
            case "collapse": mutate(.collapse, name: "Toggle children")
            case "copy": copyBlocks()
            case "link":
                guard let noteID = parent.noteID else { return }
                transaction("Create block link") { document.originalSource = nil; return nil }
                let url = "noema://page/" + noteID.uuidString + "?block=" + block.id.uuidString
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
            case "language":
                let alert = NSAlert(); alert.messageText = "Code language"; let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24)); field.stringValue = block.metadata.language ?? ""
                alert.accessoryView = field; alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { mutate(.language(field.stringValue.isEmpty ? nil : field.stringValue), name: "Code language") }
            default: break
            }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // Editable text reserves ordinary clicks for caret/selection; ArticleTextView
            // routes Command-click and the accessible menu directly to followLink.
            guard !textView.isEditable else { return true }
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            followLink(url)
            return true
        }
        func followLink(_ url: URL) {
            if url.scheme == "noema", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "title" })?.value { parent.onWikiLink(target); return }
            if url.scheme == "noema", url.host == "page" { parent.onBlockLink(url); return }
            if ["http", "https", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        }
    }
}
