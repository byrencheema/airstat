import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// The panel's per-row gear opens an `NSMenu`, and a menu only exists while a real
/// click is holding it open — nothing offscreen can press it. So everything the menu
/// would show, and everything each of its items writes, is exercised here instead.
@MainActor
@Suite("The panel's menu bar gear")
struct PanelMenuBarControlTests {

    private func store() -> SettingsStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SettingsStore(directory: dir, saveDebounce: .milliseconds(1))
    }

    /// A store whose readout list is stated outright.
    ///
    /// Every test about a metric that is *not* in the menu bar has to name the list it
    /// starts from rather than leaning on `defaultItems`. These tests originally used
    /// the defaults and assumed GPU was absent from them, which was true when they were
    /// written and false one commit later when the shipped defaults became CPU, CPU
    /// Temp, GPU and Battery. Nothing about the behaviour under test had changed.
    private func store(items: [MenuBarItemConfig]) -> SettingsStore {
        let settings = store()
        settings.update { $0.menuBar.items = items }
        return settings
    }

    /// The readouts these tests treat as "everything except the metric in question".
    /// CPU alone, so it is never the metric being probed and never the last enabled one.
    private var withoutGPU: [MenuBarItemConfig] {
        [MenuBarItemConfig(metric: .cpuUsage), MenuBarItemConfig(metric: .memoryUsage)]
    }

    private func control(_ module: PanelModule, _ settings: SettingsStore) -> PanelMenuBarControl {
        guard let control = PanelMenuBarControl(module: module, settings: settings) else {
            Issue.record("\(module.label) has no menu bar metric")
            fatalError("unreachable")
        }
        return control
    }

    // MARK: Mapping

    @Test("every module but Top Processes offers a readout, and it reads the same sensor")
    func mappingMatchesTheModule() {
        for module in PanelModule.allCases {
            guard let metric = module.menuBarMetric else {
                #expect(module == .processes)
                continue
            }
            // A gear that changed a readout fed by a different collector would be a
            // control on the wrong row.
            #expect(metric.requiredSource == module.requiredSource,
                    "\(module.label) points at \(metric.label)")
        }
    }

    @Test("no module has a gear the panel cannot serve")
    func everyModuleResolves() {
        let settings = store()
        #expect(PanelMenuBarControl(module: .processes, settings: settings) == nil)
        for module in PanelModule.allCases where module != .processes {
            #expect(PanelMenuBarControl(module: module, settings: settings) != nil)
        }
    }

    // MARK: The style list

    @Test("the styles offered are the metric's own, never a list of the panel's")
    func stylesComeFromTheMetric() {
        let settings = store()
        for module in PanelModule.allCases where module != .processes {
            let control = control(module, settings)
            #expect(control.styles == control.metric.supportedStyles)
            #expect(!control.styles.isEmpty)
        }
        // Deliberately not asserted against a written-out list: a style added to the
        // model has to reach this menu without a test being edited, which is the whole
        // reason the menu reads `supportedStyles`. What is asserted is that the two
        // lists differ — Uptime keeps no series, so it cannot be graphed — because a
        // menu that hardcoded one list for everything would pass the check above.
        #expect(control(.system, settings).styles.contains(.graph) == false)
        #expect(control(.cpu, settings).styles.contains(.graph))
        #expect(control(.cpu, settings).styles != control(.system, settings).styles)
    }

    // MARK: Showing a metric that has never been configured

    @Test("showing a metric with no readout creates one, enabled, at its first style")
    func showCreatesAConfig() {
        let settings = store(items: withoutGPU)
        let gpu = control(.gpu, settings)
        #expect(gpu.configs.isEmpty)
        #expect(gpu.isShown == false)
        #expect(gpu.style == nil)

        gpu.setShown(true)

        let created = settings.settings.menuBar.items.filter { $0.metric == .gpuUsage }
        #expect(created.count == 1)
        #expect(created.first?.isEnabled == true)
        #expect(created.first?.style == MenuBarMetric.gpuUsage.supportedStyles.first)
        #expect(gpu.isShown)
    }

    @Test("picking a style for a metric that is not shown puts it in the menu bar")
    func styleOnAHiddenMetricShowsIt() {
        let settings = store(items: withoutGPU)
        let gpu = control(.gpu, settings)
        gpu.setStyle(.textAndGraph)

        #expect(gpu.isShown)
        #expect(gpu.style == .textAndGraph)
        #expect(settings.settings.menuBar.items.filter { $0.metric == .gpuUsage }.count == 1)
    }

    @Test("hiding disables the readout rather than deleting it, so the style survives")
    func hideKeepsTheConfig() {
        let settings = store()
        let cpu = control(.cpu, settings)
        cpu.setStyle(.graph)
        let id = cpu.configs.first?.id

        cpu.setShown(false)
        #expect(cpu.isShown == false)
        #expect(cpu.configs.count == 1)
        #expect(cpu.configs.first?.id == id)
        #expect(cpu.configs.first?.style == .graph)

        cpu.setShown(true)
        #expect(cpu.isShown)
        #expect(cpu.configs.first?.id == id)
        #expect(cpu.configs.first?.style == .graph)
    }

    // MARK: The last enabled readout

    @Test("the last readout standing refuses to be hidden, and says so before it is tried")
    func lastEnabledCannotHide() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        }
        let cpu = control(.cpu, settings)
        #expect(cpu.isShown)
        #expect(cpu.canHide == false)

        cpu.setShown(false)
        // The store would have re-enabled it anyway; the point is that the control
        // never offers the action, so nothing appears to work and then undo itself.
        #expect(cpu.isShown)
        #expect(settings.settings.menuBar.enabledItems.count == 1)
    }

    @Test("two readouts for one metric still count as the last one between them")
    func duplicateConfigsAreOneReadout() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage, style: .text),
                               MenuBarItemConfig(metric: .cpuUsage, style: .graph)]
        }
        let cpu = control(.cpu, settings)
        #expect(cpu.canHide == false)
        cpu.setShown(false)
        #expect(cpu.isShown)
    }

    @Test("a second metric frees the first to be hidden")
    func anotherMetricUnlocksHiding() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage),
                               MenuBarItemConfig(metric: .memoryUsage)]
        }
        let cpu = control(.cpu, settings)
        #expect(cpu.canHide)
        cpu.setShown(false)
        #expect(cpu.isShown == false)
        #expect(settings.settings.menuBar.enabledItems.map(\.metric) == [.memoryUsage])
    }

    // MARK: Several readouts on one metric

    @Test("readouts that disagree about style tick nothing, and picking one settles them")
    func mixedStylesTickNothing() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage, style: .text),
                               MenuBarItemConfig(metric: .cpuUsage, style: .graph),
                               MenuBarItemConfig(metric: .memoryUsage, style: .text)]
        }
        let cpu = control(.cpu, settings)
        #expect(cpu.style == nil)

        cpu.setStyle(.iconAndText)
        #expect(cpu.style == .iconAndText)
        #expect(cpu.configs.count == 2)
        // The neighbouring metric is untouched.
        #expect(settings.settings.menuBar.items.first { $0.metric == .memoryUsage }?.style == .text)
    }

    @Test("changing style leaves a hidden readout hidden")
    func styleDoesNotEnableAShownMetricsDisabledTwin() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage, style: .text, isEnabled: true),
                               MenuBarItemConfig(metric: .memoryUsage, isEnabled: true)]
        }
        let cpu = control(.cpu, settings)
        cpu.setStyle(.graph)
        #expect(settings.settings.menuBar.items.filter(\.isEnabled).count == 2)
        #expect(cpu.style == .graph)
    }

    // MARK: Writes are addressed by id, not by index

    @Test("a write lands on its own readout after the list is reordered")
    func writeFollowsTheIdAcrossAReorder() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .memoryUsage, style: .text),
                               MenuBarItemConfig(metric: .diskFree, style: .text),
                               MenuBarItemConfig(metric: .cpuUsage, style: .text)]
        }
        let cpu = control(.cpu, settings)
        let binding = cpu.styleBinding
        settings.update { $0.menuBar.items.reverse() }

        binding.wrappedValue = .graph

        // An index-captured binding would have written to whatever the reversal left
        // where CPU used to be, which is Memory.
        #expect(settings.settings.menuBar.items.first { $0.metric == .cpuUsage }?.style == .graph)
        #expect(settings.settings.menuBar.items.first { $0.metric == .memoryUsage }?.style == .text)
        #expect(settings.settings.menuBar.items.first { $0.metric == .diskFree }?.style == .text)
    }

    @Test("a binding read after the readout list is replaced answers rather than trapping")
    func bindingSurvivesAReset() {
        let settings = store()
        settings.update { s in
            s.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage),
                               MenuBarItemConfig(metric: .memoryUsage),
                               MenuBarItemConfig(metric: .diskFree),
                               MenuBarItemConfig(metric: .uptime, style: .iconAndText)]
        }
        let uptime = control(.system, settings)
        let style = uptime.styleBinding
        let shown = uptime.shownBinding
        #expect(style.wrappedValue == .iconAndText)

        settings.resetSection(.menuBar)
        // Counted off the shipped defaults rather than written out: what this test is
        // about is the binding surviving the list being replaced, not how long the
        // replacement happens to be.
        #expect(settings.settings.menuBar.items.count == MenuBarSettings.defaultItems.count)

        // The readout the binding spoke for is gone; reading it answers "absent"
        // instead of subscripting past the end of the list.
        #expect(style.wrappedValue == nil)
        #expect(shown.wrappedValue == false)
    }

    // MARK: Refusals

    @Test("a style the metric does not support is refused rather than stored")
    func unsupportedStyleIsRefused() {
        let settings = store()
        let uptime = control(.system, settings)
        #expect(uptime.styles.contains(.graph) == false)

        uptime.setStyle(.graph)
        #expect(uptime.configs.isEmpty)
        #expect(uptime.isShown == false)
    }

    @Test("setting the state it is already in writes nothing")
    func redundantWritesAreInert() {
        let settings = store()
        let cpu = control(.cpu, settings)
        let before = settings.settings.menuBar.items
        cpu.setShown(true)
        #expect(settings.settings.menuBar.items == before)
    }

    // MARK: What the menu announces

    @Test("the accessibility value says both halves of the state")
    func accessibilityValueDescribesTheState() {
        let settings = store(items: withoutGPU)
        let gpu = control(.gpu, settings)
        #expect(gpu.accessibilityValue == "Not in the menu bar")

        gpu.setStyle(.textAndGraph)
        #expect(gpu.accessibilityValue == "In the menu bar, Text & Graph")
    }
}
