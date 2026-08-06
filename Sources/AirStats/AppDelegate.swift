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
}
