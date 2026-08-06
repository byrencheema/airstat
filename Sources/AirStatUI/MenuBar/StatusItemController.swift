import AppKit
import AirStatKit
import Observation

/// Owns the `NSStatusItem` and the custom view drawn inside it.
///
/// The menu bar is the most scrutinised surface in the app: it sits two pixels from
/// Apple's own glyphs, redraws constantly, and must never jitter, blur, or push its
/// neighbours around. Everything here exists to serve that.
@MainActor
public final class StatusItemController {

    public var onPrimaryAction: (() -> Void)?
    public var onSecondaryAction: (() -> Void)?
    public var onVisibilityChange: ((Bool) -> Void)?

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private var statusItem: NSStatusItem?
    private var contentView: MenuBarContentView?
    private var renderTask: Task<Void, Never>?
    private var visibilityObservation: NSKeyValueObservation?
    private var lastReportedVisibility: Bool?

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
    }

    // MARK: Installation

    public func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = [.removalAllowed]
        item.autosaveName = "AirStatStatusItem"

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("AirStats system statistics")

        let content = MenuBarContentView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            content.topAnchor.constraint(equalTo: button.topAnchor),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        self.statusItem = item
        self.contentView = content

        observeVisibility(of: item)
        beginRendering()
        render()
    }

    public func remove() {
        renderTask?.cancel()
        renderTask = nil
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        contentView = nil
    }

    // MARK: Geometry

    /// Screen-space rect of the status item button, for anchoring the panel.
    /// Nil when the item is not currently on screen.
    public var anchorRect: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    public var anchorScreen: NSScreen? {
        statusItem?.button?.window?.screen ?? NSScreen.main
    }

    public func presentMenu(_ menu: NSMenu) {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach immediately so the next left-click goes back to our action.
        statusItem.menu = nil
    }

    // MARK: Visibility

    /// `NSStatusItem.isVisible` goes false when the item is pushed off the menu bar
    /// (too many items, or hidden behind the notch). That is the strongest signal we
    /// have that nobody can see our readouts, so it drives sampling throttling.
    private func observeVisibility(of item: NSStatusItem) {
        visibilityObservation = item.observe(\.isVisible, options: [.initial, .new]) { [weak self] item, _ in
            let visible = item.isVisible
            Task { @MainActor [weak self] in
                guard let self, self.lastReportedVisibility != visible else { return }
                self.lastReportedVisibility = visible
                self.onVisibilityChange?(visible)
            }
        }
    }

    // MARK: Rendering

    /// Re-render whenever the engine publishes or settings change. Observation-driven
    /// rather than timer-driven: no snapshot, no redraw, no wakeup.
    private func beginRendering() {
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await StatusItemController.awaitChange {
                    _ = self.engine.snapshot
                    _ = self.settings.revision
                }
                guard !Task.isCancelled else { return }
                await Task.yield()
                self.render()
            }
        }
    }

    @MainActor
    private static func awaitChange(_ track: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking { track() } onChange: { continuation.resume() }
        }
    }

    private func render() {
        guard let contentView else { return }
        let model = MenuBarRenderModel(snapshot: engine.snapshot,
                                       history: engine.history,
                                       settings: settings.settings,
                                       isStale: engine.isStale)
        contentView.update(with: model)
        statusItem?.length = contentView.intrinsicContentSize.width
        statusItem?.button?.setAccessibilityValue(model.accessibilityDescription)
    }

    // MARK: Input

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            onSecondaryAction?()
        } else {
            onPrimaryAction?()
        }
    }
}
