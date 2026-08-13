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
    private let hotKeys: GlobalHotKeyCenter
    private let updates: UpdateChecker

    private var observers: [any NSObjectProtocol] = []
    /// Where the panel is currently hung. Kept here because with one status item per
    /// readout, "toggle" has a third case: the click came from a different item than
    /// the one the panel is under.
    private var panelAnchor: NSRect?

    init() {
        let store = SettingsStore()
        let engine = MetricsEngine(settingsStore: store)
        let updates = UpdateChecker(settings: store)
        self.settingsStore = store
        self.engine = engine
        self.updates = updates
        self.statusItem = StatusItemController(engine: engine, settings: store)
        self.panel = PanelController(engine: engine, settings: store)
        self.overlay = OverlayController(engine: engine, settings: store)
        self.settingsWindow = SettingsWindowController(engine: engine, settings: store, updates: updates)
        self.thresholdMonitor = ThresholdMonitor(engine: engine, settings: store)
        self.hotKeys = GlobalHotKeyCenter(settings: store)
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

        // A hot key must do exactly what the equivalent menu item does, including
        // leaving the frontmost app alone: the panel is worth having precisely because
        // it can be summoned over another app without interrupting it.
        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePanel: self.togglePanel()
            case .toggleOverlay: self.toggleOverlay()
            case .openSettings: self.showSettings()
            }
        }

        statusItem.install()
        engine.start()
        thresholdMonitor.start()
        hotKeys.start()
        // Arms a delayed check rather than making one: launch is the moment the app is
        // least entitled to the network, and nothing about this feature is urgent.
        updates.start()
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
        updates.stop()
        hotKeys.stop()
        thresholdMonitor.stop()
        engine.stop()
        statusItem.remove()
        overlay.hide()
        settingsStore.flush()
    }

    // MARK: Actions

    private func togglePanel() {
        let anchor = statusItem.anchorRect
        guard panel.isVisible else {
            panelAnchor = anchor
            panel.show(anchoredTo: anchor, on: statusItem.anchorScreen)
            return
        }
        // Clicking a second readout's item moves the panel under it. Dismissing there
        // would read as the click having missed: the user pointed at a different item
        // and got nothing.
        if let anchor, let panelAnchor, anchor != panelAnchor {
            self.panelAnchor = anchor
            panel.reanchor(to: anchor, on: statusItem.anchorScreen)
            return
        }
        panel.hide()
        panelAnchor = nil
    }

    private func showSettings() {
        panel.hide()
        settingsWindow.show()
    }

    private func toggleOverlay() {
        settingsStore.update { $0.overlay.isEnabled.toggle() }
        overlay.syncWithSettings()
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

    @objc private func menuToggleOverlay() { toggleOverlay() }

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
                        self.panelAnchor = self.statusItem.anchorRect
                        self.panel.reanchor(to: self.panelAnchor,
                                            on: self.statusItem.anchorScreen)
                    }
                }
        })
    }
}
