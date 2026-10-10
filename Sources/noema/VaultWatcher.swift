import Foundation
import CoreServices

final class VaultWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let changed: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "noema.FileEvents")
    init(url: URL, changed: @escaping @Sendable () -> Void) {
        self.presentedItemURL = url; self.changed = changed
        self.presentedItemOperationQueue = OperationQueue()
        self.presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        // FSEvents also catches editors that do not participate in file coordination.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, eventQueue); FSEventStreamStart(stream) }
    }
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        if let stream {
            eventQueue.sync { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            self.stream = nil
        }
    }
    func presentedItemDidChange() { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func presentedSubitem(at url: URL, didGain version: NSFileVersion) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) { completionHandler(nil); changed() }
}
