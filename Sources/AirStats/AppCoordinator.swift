import AppKit
import AirStatKit
import AirStatUI

/// Wires the engine, the settings store and every piece of UI together, and owns
/// the system-level observers (sleep, wake, screen lock, display changes) that
/// decide how hard AirStats is allowed to work.
@MainActor
final class AppCoordinator {

    private let settingsStore: SettingsStore
    private let engine: MetricsEngine

    private let statusItem: StatusItemController
    private let panel: PanelController
    private let overlay: OverlayController
    private let settingsWindow: SettingsWindowController
    private let thresholdMonitor: ThresholdMonitor

    private var observers: [any NSObjectProtocol] = []

    init() {
        let store = SettingsStore()
        let engine = MetricsEngine(settingsStore: store)
        self.settingsStore = store
        self.engine = engine
        self.statusItem = StatusItemController(engine: engine, settings: store)
        self.panel = PanelController(engine: engine, settings: store)
        self.overlay = OverlayController(engine: engine, settings: store)
        self.settingsWindow = SettingsWindowController(engine: engine, settings: store)
        self.thresholdMonitor = ThresholdMonitor(engine: engine, settings: store)
    }

    // MARK: Lifecycle

    func start() {
        statusItem.onPrimaryAction = { [weak self] in self?.togglePanel() }
        statusItem.onSecondaryAction = { [weak self] in self?.showContextMenu() }
        statusItem.onVisibilityChange = { [weak self] visible in
            self?.engine.setMenuBarOccluded(!visible)
        }

        panel.onVisibilityChange = { [weak self] visible in
            self?.engine.setPanelVisible(visible)
        }
        panel.onRequestSettings = { [weak self] in self?.showSettings() }
        panel.onRequestQuit = { NSApp.terminate(nil) }

        overlay.onVisibilityChange = { [weak self] visible in
            self?.engine.setOverlayVisible(visible)
        }

        statusItem.install()
        engine.start()
        thresholdMonitor.start()
        overlay.syncWithSettings()

        registerSystemObservers()
        LoginItem.synchronize(enabled: settingsStore.settings.general.launchAtLogin)
    }

    func shutdown() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        thresholdMonitor.stop()
        engine.stop()
        statusItem.remove()
        overlay.hide()
        settingsStore.flush()
    }

    // MARK: Actions

    private func togglePanel() {
        if panel.isVisible {
            panel.hide()
        } else {
            panel.show(anchoredTo: statusItem.anchorRect, on: statusItem.anchorScreen)
        }
    }

    private func showSettings() {
        panel.hide()
        settingsWindow.show()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(menuShowSettings), keyEquivalent: ",")
            .target = self
        let overlayItem = menu.addItem(withTitle: "Show Overlay",
                                       action: #selector(menuToggleOverlay), keyEquivalent: "")
        overlayItem.target = self
        overlayItem.state = settingsStore.settings.overlay.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AirStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.presentMenu(menu)
    }

    @objc private func menuShowSettings() { showSettings() }

    @objc private func menuToggleOverlay() {
        settingsStore.update { $0.overlay.isEnabled.toggle() }
        overlay.syncWithSettings()
    }

    // MARK: System observers

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })
        // Display sleep is far more common than system sleep on a desktop Mac and
        // is just as good a reason to stop sampling.
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })

        // Screen reconfiguration moves the status item and can invalidate the
        // panel's anchor; re-anchor rather than leaving the panel stranded.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.overlay.screenConfigurationChanged()
                    if self.panel.isVisible {
                        self.panel.reanchor(to: self.statusItem.anchorRect,
                                            on: self.statusItem.anchorScreen)
                    }
                }
        })
    }
}
