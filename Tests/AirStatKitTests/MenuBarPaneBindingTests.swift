import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// A `Picker` in the pane's editing section keeps its binding for the length of a
/// SwiftUI update pass. Restore Defaults and Import replace `menuBar.items` inside
/// that pass, so a binding built for the fourth readout is read back when only two
/// exist. It used to subscript by index there and take the app down with it.
@MainActor
@Suite("Menu bar readout bindings outlive the list they were built for")
struct MenuBarPaneBindingTests {

    private func store() -> SettingsStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SettingsStore(directory: dir, saveDebounce: .milliseconds(1))
    }

    /// Four readouts, so the last one sits past the end of the two shipped defaults.
    private func fourReadouts(_ settings: SettingsStore) -> MenuBarItemConfig {
        settings.update { s in
            s.menuBar.items = [MenuBarMetric.cpuUsage, .memoryUsage, .diskFree, .networkThroughput]
                .map { MenuBarItemConfig(metric: $0, style: $0.supportedStyles.first ?? .text) }
        }
        return settings.settings.menuBar.items[3]
    }

    @Test("reading a binding after Restore Defaults returns the captured value")
    func readSurvivesReset() {
        let settings = store()
        let pane = MenuBarPane(settings: settings, engine: nil)
        let last = fourReadouts(settings)

        let metric = pane.metricBinding(for: last)
        let style = pane.styleBinding(for: last)
        let caption = pane.captionBinding(for: last)

        settings.resetSection(.menuBar)
        #expect(settings.settings.menuBar.items.count < 4)

        #expect(metric.wrappedValue == last.metric)
        #expect(style.wrappedValue == last.style)
        #expect(caption.wrappedValue == last.showsCaption)
    }

    @Test("writing through a binding whose readout is gone changes nothing")
    func writeAfterResetIsInert() {
        let settings = store()
        let pane = MenuBarPane(settings: settings, engine: nil)
        let last = fourReadouts(settings)
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
        let last = fourReadouts(settings)

        let displaced = settings.settings.menuBar.items[0]
        settings.update { $0.menuBar.items.reverse() }
        pane.styleBinding(for: last).wrappedValue = .graph

        // An index-based binding would have written to whatever the reversal left at
        // index 3, which is the readout that started at index 0.
        #expect(settings.settings.menuBar.items.first { $0.id == last.id }?.style == .graph)
        #expect(settings.settings.menuBar.items.first { $0.id == displaced.id }?.style == displaced.style)
    }
}
