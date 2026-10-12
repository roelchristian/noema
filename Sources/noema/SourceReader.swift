import AppKit
import SwiftUI
import Quartz
import VaultCore

@MainActor final class SourceReader: NSWindowController, NSWindowDelegate {
    private static var readers: [UUID: SourceReader] = [:]
    static var openReaderIDs: Set<UUID> { Set(readers.keys) }
    private var sourceID: UUID
    private var scopedURL: URL?
    private let previewSnapshot: SourcePreviewSnapshot?

    private init(id: UUID, window: NSWindow, scopedURL: URL?, previewSnapshot: SourcePreviewSnapshot?) {
        sourceID = id; self.scopedURL = scopedURL; self.previewSnapshot = previewSnapshot
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }

    static func open(
        _ source: SourceRecord,
        root: URL,
        contentStore: any VaultContentStore,
        isStillValid: (@MainActor @Sendable () -> Bool)? = nil
    ) async throws {
        if let isStillValid, !isStillValid() { return }
        if let gated = contentStore as? GatedVaultContentStore {
            let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            if normalizedRoot != gated.root {
                throw VaultAccessError.wrongVault(
                    expectedVaultID: gated.vaultID,
                    expectedRoot: gated.root,
                    actualVaultID: nil,
                    actualRoot: normalizedRoot,
                    operation: "SourceReader.open"
                )
            }
            try gated.validateAccess(operation: "SourceReader.open")
        }
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
                if let gated = contentStore as? GatedVaultContentStore {
                    try gated.validateAccess(operation: "SourceReader.read")
                }
                let data = try source.metadata.isLinked ? FileVaultRepository.coordinatedRead(url) : FileVaultRepository.readSourceOriginal(source, root: root, contentStore: contentStore)
                guard source.metadata.isLinked || digest(data) == source.metadata.sha256 else {
                    throw VaultError.invalid("The in-vault original changed. Refresh from Files to review the checksum notice.")
                }
                return data
            }.value
            if let gated = contentStore as? GatedVaultContentStore {
                try gated.validateAccess(operation: "SourceReader.present")
            }
            if let isStillValid, !isStillValid() {
                scoped?.stopAccessingSecurityScopedResource()
                return
            }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = source.title; window.isReleasedWhenClosed = false
            let ext = url.pathExtension.lowercased()
            if ["md", "txt", "html", "htm"].contains(ext) {
                guard let text = String(data: data, encoding: .utf8) else { throw VaultError.invalid("Text reader requires UTF-8.") }
                let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
                let reader = ReadingTextView(frame: window.contentView!.bounds)
                reader.isEditable = false; reader.isSelectable = true; reader.autoresizingMask = [.width]
                reader.isVerticallyResizable = true; reader.isHorizontallyResizable = false
                reader.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                reader.textContainer?.widthTracksTextView = true
                reader.textContainerInset = NSSize(width: 24, height: 24)
                let content: SourceReadableContent
                if ext == "md" { content = .markdown(MarkdownService.preview(text)) }
                else if ["html", "htm"].contains(ext), let html = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
                    content = .html(html)
                } else { content = .plainText(text) }
                reader.setAccessibilityLabel(source.title)
                scroll.documentView = reader
                window.contentView = NSHostingView(rootView: ThemedSourceTextReader(scroll: scroll,
                    content: content).systemNoemaTheme())
            } else {
                guard let preview = QLPreviewView(frame: window.contentView!.bounds, style: .normal) else { throw VaultError.unavailable("Quick Look is unavailable for this file.") }
                preview.autoresizingMask = [.width, .height]
                if !source.metadata.isLinked {
                    snapshot = try await Task.detached { try SourcePreviewSnapshot(data: data, filename: source.metadata.storedFilename) }.value
                    if let isStillValid, !isStillValid() {
                        snapshot?.remove()
                        scoped?.stopAccessingSecurityScopedResource()
                        return
                    }
                }
                // Snapshot creation suspends; validate the owning lease again after it
                // and the optional caller predicate, including direct reader entry points.
                if let gated = contentStore as? GatedVaultContentStore {
                    try gated.validateAccess(operation: "SourceReader.presentPreview")
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

private enum SourceReadableContent {
    case markdown([PreviewBlock]), html(NSAttributedString), plainText(String)

    @MainActor func presentation(typography: EditorTypography, theme: NoemaTheme) -> NSAttributedString {
        switch self {
        case .markdown(let blocks): SourceTextPresentation.markdown(blocks, typography: typography, theme: theme)
        case .html(let imported): SourceTextPresentation.html(imported, typography: typography, theme: theme)
        case .plainText(let text): SourceTextPresentation.plainText(text, typography: typography, theme: theme)
        }
    }
}

private struct ThemedSourceTextReader: NSViewRepresentable {
    @Environment(\.noemaTheme) private var theme
    @AppStorage(EditorPreferences.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorPreferences.fontSizeKey) private var fontSize = EditorTypography.defaultSize
    let scroll: NSScrollView
    let content: SourceReadableContent

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView { scroll }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let reader = scroll.documentView as? ReadingTextView else { return }
        let typography = EditorTypography(family: fontFamily, size: fontSize)
        if context.coordinator.typography != typography || context.coordinator.theme != theme {
            reader.replacePresentation(content.presentation(typography: typography, theme: theme), typography: typography)
            context.coordinator.typography = typography
            context.coordinator.theme = theme
        }
        reader.backgroundColor = theme.native(.surfaceElevated)
        scroll.backgroundColor = theme.native(.surfaceElevated)
        reader.linkTextAttributes = [.foregroundColor: theme.nativeText(.accentSecondary), .underlineStyle: NSUnderlineStyle.single.rawValue]
    }
    @MainActor final class Coordinator {
        var typography: EditorTypography?
        var theme: NoemaTheme?
    }
}
