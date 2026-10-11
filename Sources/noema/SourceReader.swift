import AppKit
import SwiftUI
import Quartz
import VaultCore

@MainActor final class SourceReader: NSWindowController, NSWindowDelegate {
    private static var readers: [UUID: SourceReader] = [:]
    private var sourceID: UUID
    private var scopedURL: URL?
    private let previewSnapshot: SourcePreviewSnapshot?

    private init(id: UUID, window: NSWindow, scopedURL: URL?, previewSnapshot: SourcePreviewSnapshot?) {
        sourceID = id; self.scopedURL = scopedURL; self.previewSnapshot = previewSnapshot
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }

    static func open(_ source: SourceRecord, root: URL, contentStore: any VaultContentStore) async throws {
        if let existing = readers[source.id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let url: URL
        var scoped: URL?
        if let bookmark = source.metadata.linkedBookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            guard !stale else { throw VaultError.unavailable("Link this source again to renew access.") }
            if url.startAccessingSecurityScopedResource() { scoped = url }
        } else {
            guard source.metadata.storedFilename == URL(fileURLWithPath: source.metadata.storedFilename).lastPathComponent,
                  !source.metadata.storedFilename.hasPrefix(".") else { throw VaultError.invalid("Invalid source path.") }
            url = root.appendingPathComponent("Sources/" + source.id.uuidString.lowercased()).appendingPathComponent(source.metadata.storedFilename)
            if root.startAccessingSecurityScopedResource() { scoped = root }
        }
        var snapshot: SourcePreviewSnapshot?
        do {
            let data = try await Task.detached {
                let data = try source.metadata.isLinked ? FileVaultRepository.coordinatedRead(url) : FileVaultRepository.readSourceOriginal(source, root: root, contentStore: contentStore)
                guard source.metadata.isLinked || digest(data) == source.metadata.sha256 else {
                    throw VaultError.invalid("The in-vault original changed. Refresh from Files to review the checksum notice.")
                }
                return data
            }.value
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = source.title; window.isReleasedWhenClosed = false
            let ext = url.pathExtension.lowercased()
            if ["md", "txt", "html", "htm"].contains(ext) {
                guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalid("Text reader requires UTF-8.") }
                let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
                let reader = NSTextView(frame: window.contentView!.bounds)
                reader.isEditable = false; reader.isSelectable = true; reader.autoresizingMask = [.width]
                reader.isVerticallyResizable = true; reader.textContainer?.widthTracksTextView = true
                reader.textContainerInset = NSSize(width: 24, height: 24)
                reader.font = .systemFont(ofSize: 14); reader.textColor = .textColor; reader.backgroundColor = .textBackgroundColor
                if ext == "md", let markdown = try? AttributedString(markdown: text) {
                    reader.textStorage?.setAttributedString(NSAttributedString(markdown))
                } else if ["html", "htm"].contains(ext), let html = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
                    reader.textStorage?.setAttributedString(html)
                } else { reader.string = text }
                reader.setAccessibilityLabel(source.title)
                scroll.documentView = reader
                window.contentView = NSHostingView(rootView: ThemedSourceTextReader(scroll: scroll,
                    original: reader.attributedString()).systemNoemaTheme())
            } else {
                guard let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal) else { throw VaultError.unavailable("Quick Look is unavailable for this file.") }
                preview.autoresizingMask = [.width, .height]
                if !source.metadata.isLinked {
                    snapshot = try await Task.detached { try SourcePreviewSnapshot(data: data, filename: source.metadata.storedFilename) }.value
                }
                preview.previewItem = (snapshot?.url ?? url) as NSURL
                window.contentView = preview
            }
            let controller = SourceReader(id: source.id, window: window, scopedURL: scoped, previewSnapshot: snapshot)
            readers[source.id] = controller; window.center(); controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        } catch { snapshot?.remove(); scoped?.stopAccessingSecurityScopedResource(); throw error }
    }

    static func updateTitle(id: UUID, title: String) { readers[id]?.window?.title = title }
    static func close(id: UUID) { readers[id]?.window?.close() }
    static func closeAll() { for reader in Array(readers.values) { reader.window?.close() } }

    func windowWillClose(_ notification: Notification) {
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        previewSnapshot?.remove()
        Self.readers.removeValue(forKey: sourceID)
    }
}

private struct ThemedSourceTextReader: NSViewRepresentable {
    @Environment(\.noemaTheme) private var theme
    let scroll: NSScrollView
    let original: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView { scroll }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let reader = scroll.documentView as? NSTextView else { return }
        let selection = reader.selectedRange()
        reader.textStorage?.setAttributedString(original)
        // Imported formatting remains intact; full palettes override only foreground color.
        if theme.usesFullPalette {
            reader.textStorage?.addAttribute(.foregroundColor, value: theme.nativeText(),
                range: NSRange(location: 0, length: original.length))
        }
        reader.textColor = theme.nativeText()
        reader.backgroundColor = theme.native(.surfaceElevated)
        scroll.backgroundColor = theme.native(.surfaceElevated)
        reader.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary)]
        reader.setSelectedRange(selection)
    }
}
