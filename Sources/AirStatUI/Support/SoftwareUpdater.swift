import Foundation
import Observation
import Sparkle

/// AirStats' whole update mechanism: Sparkle, plus the small amount of state SwiftUI
/// needs to draw a button and a toggle against it.
///
/// Sparkle owns the schedule, the download, the signature checks, the install and the
/// relaunch. Nothing here decides any of that. What it does is bridge two Objective-C
/// properties into something a view can observe: `SPUUpdater` publishes
/// `canCheckForUpdates` through KVO and nothing else, so a pane reading
/// `lastUpdateCheckDate` directly would keep showing whatever was true when it was
/// first drawn.
///
/// The automatic-check preference lives in Sparkle's own UserDefaults rather than in
/// `Settings`. Two stores for one switch is how an app ends up honouring only one of
/// them: Sparkle reads its copy whatever AirStats thinks.
@MainActor
@Observable
public final class SoftwareUpdater {

    /// False while a check is in flight, which is also what tells us one has finished:
    /// Sparkle raises no notification when it writes `lastUpdateCheckDate`, so the
    /// footnote follows the only property it does publish.
    public private(set) var canCheck: Bool = false
    public private(set) var lastCheck: Date?
    public private(set) var checksAutomatically: Bool

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Retained here because `SPUStandardUpdaterController` holds its delegate weakly.
    @ObservationIgnored private let feed: FeedOverride
    @ObservationIgnored private var observation: NSKeyValueObservation?

    public init() {
        let feed = FeedOverride()
        // Started from `start()` instead, so the first appcast request happens when the
        // rest of the app comes up rather than while it is still being assembled.
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: feed,
                                                     userDriverDelegate: nil)
        self.feed = feed
        self.controller = controller
        self.checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    public func start() {
        controller.startUpdater()
        sync()
        observation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// The user asked. Sparkle answers in its own window, with an update, an error or
    /// "you are up to date", which is the reason this app links it at all.
    public func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    public func setChecksAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    private func sync() {
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }
}

/// Sends Sparkle to a staging appcast when `defaults write com.airstat.AirStats
/// AirStatsFeedURL <https url>` is set, so a release can be tested end to end against a
/// preview host without editing Info.plist and rebuilding. Unset, Sparkle uses the
/// `SUFeedURL` the app ships with.
private final class FeedOverride: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "AirStatsFeedURL")
    }
}
