import Foundation
import UserNotifications
import AirStatKit

/// Watches metrics against the user's threshold rules and posts notifications.
///
/// Sustained-duration and cooldown handling live here so a transient spike while
/// launching an app never produces an alert.
@MainActor
public final class ThresholdMonitor {

    private let engine: MetricsEngine
    private let settings: SettingsStore

    private var observationTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var evaluator = ThresholdEvaluator()
    private var authorization: Authorization = .undetermined
    private var presenter: ForegroundPresenter?

    /// True while the observation loop and any pending authorisation request are
    /// installed.
    ///
    /// Exposed for the same reason `PanelController.activeEventMonitorCount` is: a
    /// task or a delegate that outlives `stop()` is silent, and nothing looks wrong
    /// until the app is posting notifications on behalf of a shut-down monitor.
    public var isRunning: Bool {
        observationTask != nil || authorizationTask != nil || presenter != nil
    }

    private enum Authorization {
        case undetermined
        case requesting
        case granted
        /// Refused by the user, or impossible because the process is not running from
        /// an app bundle. Both are final for this launch, so nothing asks again.
        case unavailable
    }

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
    }

    // MARK: Lifecycle

    public func start() {
        guard observationTask == nil else { return }
        // Observation-driven like the status item rather than a timer of its own: the
        // rules can only ever change answer when a new snapshot or a new setting lands.
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await ThresholdMonitor.awaitChange {
                    _ = self.engine.snapshot
                    _ = self.settings.revision
                }
                guard !Task.isCancelled else { return }
                await Task.yield()
                self.evaluate()
            }
        }
        evaluate()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        if let presenter {
            // The delegate is a process-wide slot on a shared singleton, so this clears
            // it only while it still holds *our* presenter. Nothing else in the app
            // wants that slot today, and a teardown that silently unhooks whoever does
            // want it next is the kind of thing nobody finds for months.
            let center = UNUserNotificationCenter.current()
            if center.delegate === presenter { center.delegate = nil }
            self.presenter = nil
        }
        evaluator.reset()
        authorization = .undetermined
    }

    @MainActor
    private static func awaitChange(_ track: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking { track() } onChange: { continuation.resume() }
        }
    }

    // MARK: Evaluation

    private func evaluate() {
        let notifications = settings.settings.notifications
        guard notifications.isEnabled else {
            evaluator.reset()
            return
        }
        // Nothing is measured until there is somewhere to send the answer. Denial is
        // terminal, so a refused prompt costs one check per sample and no more.
        guard authorization == .granted else {
            requestAuthorizationIfNeeded()
            return
        }

        // A rule for a metric this Mac cannot measure could never fire honestly, and
        // the pane already tells the user so.
        let availability = MetricAvailability(snapshot: engine.snapshot)
        let rules = notifications.enabledRules.filter { availability.note(for: $0.metric) == nil }

        let alerts = evaluator.alerts(for: rules,
                                      readings: ThresholdEvaluator.readings(from: engine.snapshot),
                                      now: Date())
        for alert in alerts { deliver(alert) }
    }

    // MARK: Authorisation

    /// Asks the first time the user actually switches notifications on, never at
    /// launch. A menu bar utility that demands permission on first run is asking for
    /// something the user has not opted into yet.
    private func requestAuthorizationIfNeeded() {
        guard authorization == .undetermined else { return }
        guard Bundle.main.bundleIdentifier != nil else {
            // `UNUserNotificationCenter.current()` traps outside an app bundle, which
            // is how the render and probe CLIs run out of `.build`.
            authorization = .unavailable
            return
        }

        authorization = .requesting
        let center = UNUserNotificationCenter.current()
        authorizationTask = Task { @MainActor [weak self] in
            var granted = false
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // The failure mode of this whole feature is silence, so the one thing
                // that must never be swallowed is why nothing is arriving.
                WindowLog.log("notification authorisation failed: \(error)")
            }
            guard let self, !Task.isCancelled, self.authorization == .requesting else { return }
            self.authorizationTask = nil
            self.authorization = granted ? .granted : .unavailable
            if granted {
                let presenter = ForegroundPresenter()
                center.delegate = presenter
                self.presenter = presenter
            }
            WindowLog.log("notification authorisation \(granted ? "granted" : "refused")")
        }
    }

    // MARK: Delivery

    private func deliver(_ alert: ThresholdAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default

        // One identifier per rule, so a rule that fires again after its cooldown
        // replaces its own stale banner instead of stacking a column of the same
        // warning in Notification Centre.
        let request = UNNotificationRequest(identifier: "threshold.\(alert.ruleID.uuidString)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                WindowLog.log("notification delivery failed: \(error.localizedDescription)")
            }
        }
        WindowLog.log("notification posted metric=\(alert.metric.rawValue) value=\(alert.value) threshold=\(alert.threshold)")
    }
}

/// macOS suppresses banners for the app that is currently frontmost. AirStats is
/// frontmost whenever its settings window has focus, which is exactly where a user
/// goes to set these rules up, so present them anyway.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
