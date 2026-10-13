import AppKit
import VaultCore

/// Labels are presentation only; every existing choice retains its canonical UUID and revision.
enum EditorAnnotationChoice {
    case entity(KnowledgeEntitySnapshot)
    case object(SemanticObjectSnapshot)
    case newEntity(typeKey: String, label: String)
    case newObject(typeKey: String, text: String)

    var title: String {
        switch self {
        case .entity(let value): return "\(value.entity.label) · \(value.entity.typeKey) · \(value.entity.id.uuidString.prefix(8))"
        case .object(let value): return "\(value.object.term ?? value.object.definitionText ?? value.object.typeKey.capitalized) · \(value.object.id.uuidString.prefix(8))"
        case .newEntity(let type, _), .newObject(let type, _): return "Create new \(type)…"
        }
    }
}

extension RichArticleView.Coordinator {
    /// Presentation ranges include a paragraph terminator. Canonical block text does not.
    /// Accept exactly one native selection contained entirely in one canonical block.
    func annotationSelection() -> (UUID, NSRange)? {
        guard let view, view.isEditable, !view.locked, parent.editable, !parent.locked,
              !view.hasMarkedText(), !view.isSettingMarkedText,
              session.semanticEdit != nil, parent.noteID != nil, parent.vaultID != nil, parent.sessionID != nil,
              parent.onAnnotate != nil, parent.annotationChoices != nil,
              selectedBlockIDs.isEmpty, view.selectedRanges.count == 1,
              let storage = view.textStorage else { return nil }
        let selection = view.selectedRange()
        guard selection.location != NSNotFound, selection.length > 0,
              selection.location >= 0, selection.location <= storage.length,
              selection.length <= storage.length - selection.location else { return nil }
        let ranges = rangeIndex?.ordered ?? BlockTextStorage.ranges(storage)
        for (id, rendered) in ranges {
            guard let block = document.block(id), selection.location >= rendered.location else { continue }
            let local = NSRange(location: selection.location - rendered.location, length: selection.length)
            guard local.location <= block.text.utf16.count,
                  local.length <= block.text.utf16.count - local.location,
                  InlineAnnotationTarget.validRange(local, in: block.text) else { continue }
            return (id, local)
        }
        return nil
    }

    func commitAnnotation(blockID: UUID, range: NSRange, referent: SemanticReferent,
                          referentRevision: BlockStoreRevision?, object: SemanticObject?) throws {
        guard let view, annotationSelection() != nil else { throw PersistencePayloadError.invalidAnnotation }
        _ = try session.annotationSelection(blockID: blockID, range: range)
        session.selection = view.selectedRange()
        let before = session.snapshot()
        do {
            if let object { try session.stageAnnotationObject(object) }
            try session.applyAnnotation(.create(blockID: blockID, range: range, referent: referent,
                designation: referent.identity.kind, startAffinity: .after, endAffinity: .before),
                expectedLocalRevision: session.revision, expectedReferentRevision: referentRevision)
        } catch {
            session.restore(before, name: "Restore failed annotation")
            throw error
        }
        guard session.revision != before.revision else { return }
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.undoManager?.registerUndo(withTarget: self) { target in target.restore(before, name: "Annotate selection") }
        view.undoManager?.setActionName("Annotate selection")
        view.undoManager?.endUndoGrouping()
        publish()
        updateAnnotationAvailability()
    }

    func updateAnnotationAvailability() {
        parent.onAnnotationAvailabilityChange?(annotationSelection() != nil)
    }

    @objc func annotateSelection(_ sender: Any?) {
        guard let (blockID, localRange) = annotationSelection(),
              let choices = parent.annotationChoices, let commit = parent.onAnnotate,
              let view else { return }
        capture()
        let identity = session.identity, revision = session.revision
        let nativeRange = view.selectedRange()
        dismissPalette()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let existing = try await choices()
                guard self.session.identity == identity, self.session.revision == revision,
                      self.view?.selectedRange() == nativeRange,
                      self.annotationSelection() != nil else { return }
                var options = existing
                options += ["person", "place", "concept"].map { .newEntity(typeKey: $0, label: "") }
                options += ["question", "definition"].map { .newObject(typeKey: $0, text: "") }
                let alert = NSAlert()
                alert.messageText = "Annotate Selection"
                alert.informativeText = "Choose an existing referent or create a distinct entity or object. The selected text remains editable."
                let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8
                stack.frame = NSRect(x: 0, y: 0, width: 400, height: 64)
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 26), pullsDown: false)
                picker.addItems(withTitles: options.map(\.title))
                picker.setAccessibilityLabel("Annotation referent")
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 26))
                field.placeholderString = "New entity name, question, or definition"
                field.setAccessibilityLabel("New referent name or text")
                field.stringValue = (view.string as NSString).substring(with: nativeRange)
                stack.addArrangedSubview(picker); stack.addArrangedSubview(field)
                alert.accessoryView = stack
                alert.addButton(withTitle: "Annotate"); alert.addButton(withTitle: "Cancel")
                alert.window.initialFirstResponder = picker
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                guard self.session.identity == identity, self.session.revision == revision,
                      self.view?.selectedRange() == nativeRange, self.annotationSelection() != nil else { return }
                let selected = options[picker.indexOfSelectedItem]
                let choice: EditorAnnotationChoice
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                switch selected {
                case .newEntity(let type, _):
                    guard !text.isEmpty else { throw KnowledgeStoreError.invalidLabel }
                    choice = .newEntity(typeKey: type, label: text)
                case .newObject(let type, _):
                    guard !text.isEmpty else { throw KnowledgeStoreError.invalidLabel }
                    choice = .newObject(typeKey: type, text: text)
                default: choice = selected
                }
                try await commit(self, blockID, localRange, choice, revision)
                self.view?.window?.makeFirstResponder(self.view)
                self.updateAnnotationAvailability()
            } catch {
                let alert = NSAlert(); alert.messageText = "Annotation could not be saved"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}


extension RichArticleView.Coordinator {
    func commitAssociationCommand(_ command: EditorAnnotationCommand, referentRevision: BlockStoreRevision?) throws {
        guard let view, view.isEditable, !view.locked, !view.hasMarkedText(), !view.isSettingMarkedText,
            !changing else { throw PersistencePayloadError.invalidAnnotation }
        session.selection = view.selectedRange(); let before = session.snapshot()
        try session.applyAnnotation(command, expectedLocalRevision: session.revision, expectedReferentRevision: referentRevision)
        view.breakUndoCoalescing()
        view.undoManager?.beginUndoGrouping()
        view.undoManager?.registerUndo(withTarget: self) { target in target.restore(before, name: "Change association") }
        view.undoManager?.setActionName("Change association"); view.undoManager?.endUndoGrouping()
        publish(); updateAnnotationAvailability()
    }
}
