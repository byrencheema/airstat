import AppKit
import AirStatKit
import AirStatUI

/// Thin lifecycle shell. All real wiring lives in `AppCoordinator` so it can be
/// constructed in tests without an `NSApplication`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.shutdown()
    }

    /// The app has no windows in the ordinary sense; never quit because the panel closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Launching an already-running copy from Spotlight, the Finder or `open`.
    ///
    /// A menu bar app has nothing to raise, so the default behaviour is to do nothing,
    /// and nothing is exactly what a "did that work?" second launch looks like. Settings
    /// is the only window the app owns, so that is what opening it means.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator?.showSettings()
        return true
    }
}
