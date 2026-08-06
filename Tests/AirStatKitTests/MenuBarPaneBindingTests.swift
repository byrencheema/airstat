import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// A `Picker` in the pane's editing section keeps its binding for the length of a
/// SwiftUI update pass. Restore Defaults and Import replace `menuBar.items` inside
/// that pass, so a binding built for the last readout is read back when a shorter list
/// has taken its place. It used to subscript by index there and take the app down.
@MainActor
@Suite("Menu bar readout bindings outlive the list they were built for")
struct MenuBarPaneBindingTests {

    private func store() -> SettingsStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SettingsStore(directory: dir, saveDebounce: .milliseconds(1))
    }

    /// Two more readouts than the app ships with, so the last one is guaranteed to sit
    /// past the end of the list a reset leaves behind. Counted off `defaultItems` rather
    /// than hardcoded: what the app ships with has changed before and will again, and
    /// the bug this covers is about the *difference* in length, not about four.
    private static let overflowCount = MenuBarSettings.defaultItems.count + 2

    private func overflowingReadouts(_ settings: SettingsStore) -> MenuBarItemConfig {
        let filler: [MenuBarMetric] = [.cpuUsage, .memoryUsage, .diskFree, .uptime,
                                       .batteryTime, .cpuFrequency, .memoryPressure]
        // Network throughput is always last, so the readout the bindings are built for
        // is the same graph-capable metric however long the list has to be.
        let metrics = Array(filler.prefix(Self.overflowCount - 1)) + [.networkThroughput]
        settings.update { s in
            s.menuBar.items = metrics
                .map { MenuBarItemConfig(metric: $0, style: $0.supportedStyles.first ?? .text) }
        }
        return settings.settings.menuBar.items[metrics.count - 1]
    }

    @Test("reading a binding after Restore Defaults returns the captured value")
    func readSurvivesReset() {
        let settings = store()
        let pane = MenuBarPane(settings: settings, engine: nil)
        let last = overflowingReadouts(settings)

        let metric = pane.metricBinding(for: last)
        let style = pane.styleBinding(for: last)
        let caption = pane.captionBinding(for: last)

        settings.resetSection(.menuBar)
        #expect(settings.settings.menuBar.items.count < Self.overflowCount)

        #expect(metric.wrappedValue == last.metric)
        #expect(style.wrappedValue == last.style)
        #expect(caption.wrappedValue == last.showsCaption)
    }

    @Test("writing through a binding whose readout is gone changes nothing")
    func writeAfterResetIsInert() {
        let settings = store()
        let pane = MenuBarPane(settings: settings, engine: nil)
        let last = overflowingReadouts(settings)
        let metric = pane.metricBinding(for: last)

        settings.resetSection(.menuBar)
        let afterReset = settings.settings.menuBar.items
        metric.wrappedValue = .cpuTemperature

        #expect(settings.settings.menuBar.items == afterReset)
    }

    @Test("a binding follows its readout across a reorder")
    func writeFollowsTheItem() {
        let settings = store()
        let pane = MenuBarPane(settings: settings, engine: nil)
        let last = overflowingReadouts(settings)

        let displaced = settings.settings.menuBar.items[0]
        settings.update { $0.menuBar.items.reverse() }
        pane.styleBinding(for: last).wrappedValue = .graph

        // An index-based binding would have written to whatever the reversal left at
        // the last index, which is the readout that started at index 0.
        #expect(settings.settings.menuBar.items.first { $0.id == last.id }?.style == .graph)
        #expect(settings.settings.menuBar.items.first { $0.id == displaced.id }?.style == displaced.style)
    }
}
