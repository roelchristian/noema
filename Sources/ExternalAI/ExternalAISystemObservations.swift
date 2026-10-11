@preconcurrency import AppKit
import Foundation

/// Native callbacks revoke synchronously, without waiting for an actor or the UI event loop.
final class ExternalAISystemObservations: @unchecked Sendable {
    private var workspaceTokens: [NSObjectProtocol] = []
    private var applicationTokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []

    init(registry: ExternalAIAuthorizationRegistry, enabled: Bool) {
        guard enabled else { return }
        let revoke: @Sendable (Notification) -> Void = { [weak registry] _ in registry?.revoke() }
        workspaceTokens = [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification].map {
            NSWorkspace.shared.notificationCenter.addObserver(forName: $0, object: nil, queue: nil, using: revoke)
        }
        applicationTokens = [NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil, using: revoke)]
        distributedTokens = [DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil, using: revoke)]
    }

    deinit {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        applicationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        distributedTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }
}
