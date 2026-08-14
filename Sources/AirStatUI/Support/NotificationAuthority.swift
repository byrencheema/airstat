import Foundation
import Observation
import UserNotifications

/// The app's one relationship with `UNUserNotificationCenter`.
///
/// Two features post notifications now — threshold alerts and the update notice — and
/// both of them need the same grant and the same foreground-presentation delegate.
/// Neither is a thing there can be two of: `requestAuthorization` shows the user one
/// prompt whoever asks, and `center.delegate` is a single process-wide slot, so a
/// second owner silently unhooks the first. Sharing one object is what keeps the
/// prompt to one and the delegate honest.
///
/// Nothing here asks at launch. `request(_:)` is called at the moment a feature has
/// something to say, which is the only moment the user can judge the request.
/// `@Observable` so a caller that only had something to say once can be woken when the
/// answer to "may I say it?" finally arrives. The prompt is a dialog a user can leave
/// on screen for a minute, and `request(_:)` returns false for all of it.
@MainActor
@Observable
public final class NotificationAuthority {

    public enum State: Sendable, Equatable {
        case undetermined
        case requesting
        case granted
        /// Refused by the user, or impossible because the process is not running from
        /// an app bundle. Both are final for this launch, so nothing asks again.
        case unavailable
    }

    public private(set) var state: State = .undetermined

    private var task: Task<Void, Never>?
    private var presenter: ForegroundPresenter?

    public init() {}

    /// True while a prompt is out or a delegate is installed, so a caller can assert
    /// that `reset()` really let go. Same reason `PanelController` publishes its
    /// monitor count: a delegate that outlives teardown is silent, and nothing looks
    /// wrong until the app is presenting banners on behalf of a shut-down feature.
    public var isRunning: Bool { task != nil || presenter != nil }

    /// Asks if nobody has yet, and reports whether posting is worth attempting.
    ///
    /// Returns false while the prompt is out. The caller is expected to be driven by
    /// something that will come back around — an observation, a later check — rather
    /// than to await an answer here, because the answer can be a user staring at a
    /// dialog for a minute.
    @discardableResult
    public func request(_ reason: @autoclosure () -> String) -> Bool {
        switch state {
        case .granted: return true
        case .requesting, .unavailable: return false
        case .undetermined: break
        }

        guard Bundle.main.bundleIdentifier != nil else {
            // `UNUserNotificationCenter.current()` traps outside an app bundle, which
            // is how the render and probe CLIs run out of `.build`.
            state = .unavailable
            return false
        }

        state = .requesting
        let why = reason()
        let center = UNUserNotificationCenter.current()
        task = Task { @MainActor [weak self] in
            var granted = false
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // The failure mode of this whole feature is silence, so the one thing
                // that must never be swallowed is why nothing is arriving.
                WindowLog.log("notification authorisation failed: \(error)")
            }
            guard let self, !Task.isCancelled, self.state == .requesting else { return }
            self.task = nil
            self.state = granted ? .granted : .unavailable
            if granted {
                let presenter = ForegroundPresenter()
                center.delegate = presenter
                self.presenter = presenter
            }
            WindowLog.log("notification authorisation \(granted ? "granted" : "refused") for \(why)")
        }
        return false
    }

    /// Hands a notification to the system. No-op unless the grant is in hand, so a
    /// caller never has to check twice.
    public func post(identifier: String, title: String, body: String) {
        guard state == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                WindowLog.log("notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        if let presenter {
            // The delegate is a process-wide slot on a shared singleton, so this clears
            // it only while it still holds *our* presenter. Nothing else in the app
            // wants that slot today, and a teardown that silently unhooks whoever does
            // want it next is the kind of thing nobody finds for months.
            let center = UNUserNotificationCenter.current()
            if center.delegate === presenter { center.delegate = nil }
            self.presenter = nil
        }
        state = .undetermined
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
