import SwiftUI
import AirStatKit

/// The menu bar readout a panel module speaks for.
///
/// The panel lists modules and the menu bar lists readouts, and the two lists are not
/// the same shape: one module can cover several readouts (Battery covers charge, time
/// remaining and system power) and one covers none at all (Top Processes has no menu
/// bar readout to offer).
///
/// The metric chosen here is the one whose value the module's header row is already
/// showing, because that row is where the gear sits. Temperature's headline is the CPU
/// die, not the fans, so it maps to `.cpuTemperature`; Disk's headline is free space,
/// so it maps to `.diskFree`. Anything else would put a control on a row that changes
/// a number the row is not displaying.
///
/// Declared here rather than on `MenuBarMetric` itself: the panel is what needs the
/// mapping, and the settings model has no business knowing the panel exists.
extension PanelModule {
    var menuBarMetric: MenuBarMetric? {
        switch self {
        case .cpu: return .cpuUsage
        case .memory: return .memoryUsage
        case .gpu: return .gpuUsage
        case .network: return .networkThroughput
        case .disk: return .diskFree
        case .battery: return .battery
        case .thermal: return .cpuTemperature
        case .system: return .uptime
        // No menu bar readout counts processes, and inventing one from the panel would
        // put a readout in Settings the user cannot explain.
        case .processes: return nil
        }
    }
}

/// Everything the panel's per-row gear needs to know and do, with no view attached.
///
/// A menu only exists while it is open, and a menu that only opens on a real click
/// cannot be driven offscreen — so the whole of what the menu shows and what each of
/// its actions writes lives here, where it can be tested without a click.
///
/// The user may have zero, one, or several readouts configured for the same metric
/// (Settings lets them add the same one twice). All three are handled the same way:
/// the control speaks for *every* config carrying its metric, so the tick beside
/// "Show in menu bar" is never a half-truth about a set of readouts that disagree.
@MainActor
struct PanelMenuBarControl {
    let metric: MenuBarMetric
    let settings: SettingsStore

    init?(module: PanelModule, settings: SettingsStore) {
        guard let metric = module.menuBarMetric else { return nil }
        self.metric = metric
        self.settings = settings
    }

    // MARK: What the menu shows

    /// Every readout the user has configured for this metric, in menu bar order.
    var configs: [MenuBarItemConfig] {
        settings.settings.menuBar.items.filter { $0.metric == metric }
    }

    /// The styles the menu offers, straight from the metric.
    ///
    /// Never a list written out here: a style added to `MenuBarDisplayStyle` and
    /// admitted by `supportedStyles` has to appear in this menu without the panel
    /// being touched, and a hardcoded copy is how it would silently not.
    var styles: [MenuBarDisplayStyle] { metric.supportedStyles }

    /// Whether the menu bar is currently drawing this metric at all.
    var isShown: Bool { configs.contains(where: \.isEnabled) }

    /// The style to tick, or nil when the metric is absent from the menu bar or its
    /// readouts are set to different styles. Nil ticks nothing, which is the honest
    /// answer in both cases.
    var style: MenuBarDisplayStyle? {
        let configs = configs
        guard let first = configs.first else { return nil }
        return configs.allSatisfy { $0.style == first.style } ? first.style : nil
    }

    /// Whether hiding this metric is something the store would actually honour.
    ///
    /// `SettingsStore.sanitize` re-enables the first readout the moment the enabled
    /// set empties, so offering the user a toggle that flips back on its own would be
    /// a control that lies. Something else has to still be enabled afterwards.
    var canHide: Bool {
        settings.settings.menuBar.enabledItems.contains { $0.metric != metric }
    }

    /// Shown in place of the toggle's ordinary state when hiding is refused, so the
    /// disabled control comes with its reason rather than just being dead.
    static let lastReadoutExplanation =
        "The menu bar keeps at least one readout, so this is the one that has to stay."

    var accessibilityValue: String {
        guard isShown else { return "Not in the menu bar" }
        guard let style else { return "In the menu bar" }
        return "In the menu bar, \(style.label)"
    }

    // MARK: What the menu writes

    /// Show or hide the metric.
    ///
    /// Hiding *disables* the readouts rather than deleting them, so the style and
    /// caption the user picked survive being switched off and come back with it. A
    /// metric that has never been configured gets one readout created at the first
    /// style it supports.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        if shown {
            // No style passed: switching a readout back on restores the one the user
            // last chose for it, which is the whole reason hiding disables rather
            // than deletes.
            enable(style: nil)
        } else {
            guard canHide else { return }
            let ids = idsForMetric
            settings.update { s in
                for index in s.menuBar.items.indices where ids.contains(s.menuBar.items[index].id) {
                    s.menuBar.items[index].isEnabled = false
                }
            }
        }
    }

    /// Pick a style.
    ///
    /// Picking a style for a metric that is not in the menu bar puts it there: the
    /// user asked to see it drawn a particular way, and leaving the choice recorded
    /// on something invisible would look like the menu did nothing. A metric already
    /// on screen only changes style — its enabled state is the toggle's business.
    func setStyle(_ style: MenuBarDisplayStyle?) {
        guard let style, styles.contains(style) else { return }
        if !isShown {
            enable(style: style)
            return
        }
        let ids = idsForMetric
        settings.update { s in
            for index in s.menuBar.items.indices where ids.contains(s.menuBar.items[index].id) {
                s.menuBar.items[index].style = style
            }
        }
    }

    /// Put the metric in the menu bar. A nil style leaves each existing readout on the
    /// style it already carries; a created readout has to be given one.
    private func enable(style: MenuBarDisplayStyle?) {
        let ids = idsForMetric
        let metric = metric
        let fallback = styles.first ?? .text
        settings.update { s in
            if ids.isEmpty {
                s.menuBar.items.append(MenuBarItemConfig(metric: metric, style: style ?? fallback))
                return
            }
            for index in s.menuBar.items.indices where ids.contains(s.menuBar.items[index].id) {
                s.menuBar.items[index].isEnabled = true
                if let style { s.menuBar.items[index].style = style }
            }
        }
    }

    /// Ids, never indices.
    ///
    /// A captured index into `menuBar.items` is what took the app down in B1: the list
    /// can be replaced wholesale (Restore Defaults, Import) or reordered between a
    /// binding being made and being read, and the index then addresses somebody else's
    /// readout — or nothing at all. Resolving by `MenuBarItemConfig.ID` inside the
    /// `update` block cannot do either.
    private var idsForMetric: Set<MenuBarItemConfig.ID> {
        Set(configs.map(\.id))
    }

    // MARK: Bindings

    var shownBinding: Binding<Bool> {
        Binding(get: { isShown }, set: { setShown($0) })
    }

    var styleBinding: Binding<MenuBarDisplayStyle?> {
        Binding(get: { style }, set: { setStyle($0) })
    }
}
