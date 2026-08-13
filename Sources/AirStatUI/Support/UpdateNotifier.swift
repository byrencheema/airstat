import Foundation
import AirStatKit

/// Posts one notification per release, the first time a check finds it.
///
/// Separate from `UpdateChecker` rather than folded into it for the same reason
/// `ThresholdMonitor` is separate from `MetricsEngine`: the checker's job is to learn
/// what the newest version is, and it stays testable without `UserNotifications` by
/// not knowing that anyone acts on the answer. What to say and when is decided by
/// `UpdateChecker.releaseToAnnounce`, which is pure; this class only carries it to the
/// system.
///
/// Observation-driven rather than called from the checker's completion, so a release
/// found in a launch where the user had not yet granted permission is still announced
/// in a later one. The stored `notifiedVersion` is what keeps that from becoming a
/// banner every launch forever.
@MainActor
public final class UpdateNotifier {

    private let updates: UpdateChecker
    private let settings: SettingsStore
    private let authority: NotificationAuthority

    private var observationTask: Task<Void, Never>?

    public var isRunning: Bool { observationTask != nil }

    public init(updates: UpdateChecker, settings: SettingsStore, authority: NotificationAuthority) {
        self.updates = updates
        self.settings = settings
        self.authority = authority
    }

    public func start() {
        guard observationTask == nil else { return }
        // The grant is observed alongside the settings because it is the other thing
        // that can turn "nothing to do" into "post it now". Without it, a user who
        // granted permission at the prompt this feature raised would hear nothing
        // until some unrelated setting happened to change.
        let changes = ObservedChanges { [settings, authority] in
            _ = settings.revision
            _ = authority.state
        }
        observationTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.announceIfNeeded()
            }
        }
        announceIfNeeded()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func announceIfNeeded() {
        guard let release = updates.releaseToAnnounce else { return }

        // Asked only now, with a release actually in hand. This is the one feature that
        // ships on, so requesting at launch would put a permission dialog in front of
        // every new user on their first run for a banner that may be months away. The
        // pill in the settings sidebar is what carries the news if this is refused.
        guard authority.request("an available update") else { return }

        // One identifier for the whole feature, not one per version: a user who has
        // been away long enough to miss two releases wants the current notice, not a
        // stack of superseded ones.
        authority.post(identifier: "update.available",
                       title: "AirStats \(release.version) is available",
                       body: "You are running \(currentVersionText). Open About in AirStats settings to download it.")
        updates.markAnnounced(release.version)
        WindowLog.log("update notification posted version=\(release.version)")
    }

    private var currentVersionText: String {
        UpdateChecker.bundleVersion ?? "an older version"
    }
}
