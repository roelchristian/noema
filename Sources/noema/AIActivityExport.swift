import AppKit
import UniformTypeIdentifiers
import VaultCore

/// User-selected exports own only a new external JSON file. They never replace
/// existing files or route writes into known vault, recovery or activity roots.
enum AIActivityExportDestination {
    enum Failure: Error, LocalizedError, Equatable {
        case invalidDestination, protectedLocation, alreadyExists, writeFailed
        var errorDescription: String? {
            switch self {
            case .invalidDestination: "Choose a new JSON file for the activity export."
            case .protectedLocation: "Save activity exports outside Noema vaults and application storage."
            case .alreadyExists: "Activity exports do not replace existing files. Choose a new filename."
            case .writeFailed: "Activity metadata could not be saved. Choose a new filename and try again."
            }
        }
    }

    @MainActor static func protectedRoots(model: AppModel?) -> [URL] {
        var roots = [model?.root, model?.sessionManager.accessGate.currentState.root,
                     model?.localStorageRoot].compactMap { $0 }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("KnowledgeVault", isDirectory: true))
        }
        roots.append(SQLiteAIActivityStore.defaultURL.deletingLastPathComponent())
        return roots
    }

    static func validate(_ destination: URL, protectedRoots: [URL]) throws {
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.hasDirectoryPath,
              destination.pathExtension.lowercased() == "json" else { throw Failure.invalidDestination }
        // The new export leaf does not exist: resolve its existing parent first.
        // Resolving the full nonexistent URL can otherwise leave directory aliases unresolved.
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = parent.appendingPathComponent(destination.lastPathComponent)
            .resolvingSymlinksInPath().standardizedFileURL.path
        for root in protectedRoots {
            let protected = root.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == protected || resolved.hasPrefix(protected.hasSuffix("/") ? protected : protected + "/") {
                throw Failure.protectedLocation
            }
        }
        // Compare directory identities as well as spelling: case variants can name
        // the same directory on APFS, while case-sensitive siblings remain valid.
        let protectedIdentities = protectedRoots.compactMap {
            (try? $0.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
        }
        var ancestor = parent
        for _ in 0...parent.pathComponents.count where !protectedIdentities.isEmpty {
            if let identity = (try? ancestor.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject,
               protectedIdentities.contains(where: { $0.isEqual(identity) }) {
                throw Failure.protectedLocation
            }
            if ancestor.path == "/" { break }
            let next = ancestor.deletingLastPathComponent().standardizedFileURL
            if next.path == ancestor.path { break }
            ancestor = next
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw Failure.alreadyExists }
    }

    static func write(_ data: Data, to destination: URL, protectedRoots: [URL]) throws {
        try validate(destination, protectedRoots: protectedRoots)
        // The OS must refuse any file created between validation and write as well.
        // withoutOverwriting cannot be combined with atomic replacement.
        do { try data.write(to: destination, options: .withoutOverwriting) }
        catch { throw Failure.writeFailed }
    }
}

/// The native panel selects a URL before any bytes are written. Capture the initial
/// roots and recheck current roots after selection so lock/switch cannot relax routing.
@MainActor final class AIActivityExportPanel: NSObject, NSOpenSavePanelDelegate {
    private let panel = NSSavePanel()
    private let capturedRoots: [URL]
    private let currentRoots: @MainActor () -> [URL]

    init(currentRoots: @escaping @MainActor () -> [URL]) {
        self.currentRoots = currentRoots
        capturedRoots = currentRoots()
        super.init()
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = false
        panel.nameFieldStringValue = "Noema AI Activity.json"
        panel.title = "Export Activity Metadata"
        panel.message = "Choose a new JSON file outside Noema vaults. Existing files will not be replaced."
        panel.delegate = self
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try AIActivityExportDestination.validate(url, protectedRoots: capturedRoots + currentRoots())
    }

    func begin(data: Data, completion: @escaping @MainActor (AIActivityExportDestination.Failure?) -> Void) {
        panel.begin { [self] response in
            panel.orderOut(nil)
            guard response == .OK, let destination = panel.url else { completion(nil); return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            do {
                try AIActivityExportDestination.write(data, to: destination, protectedRoots: capturedRoots + currentRoots())
                completion(nil)
            } catch { completion((error as? AIActivityExportDestination.Failure) ?? .writeFailed) }
        }
    }

    func cancel() { panel.cancel(nil) }
}
