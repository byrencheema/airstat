import AppKit

// Command-line modes short-circuit before any UI exists, so `--probe` works over
// SSH and in CI where there is no window server.
if DiagnosticsCLI.runIfRequested() {
    exit(0)
}

// Menu bar accessory: no Dock icon, no app menu. Set before `run()` so the app
// never flashes a Dock tile on launch.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
