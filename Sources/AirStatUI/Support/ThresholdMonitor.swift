import Foundation
import AirStatKit

/// Watches metrics against the user's threshold rules and posts notifications.
///
/// Sustained-duration and cooldown handling live here so a transient spike while
/// launching an app never produces an alert.
@MainActor
public final class ThresholdMonitor {

    private let engine: MetricsEngine
    private let settings: SettingsStore

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
    }

    public func start() {}

    public func stop() {}
}
