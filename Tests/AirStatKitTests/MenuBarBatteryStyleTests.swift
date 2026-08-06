import Testing
import Foundation
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@Suite("The battery indicator style is offered to the battery and to nothing else")
struct BatteryStyleAvailabilityTests {

    @Test("only the battery metric offers it")
    func onlyBatteryOffersIt() {
        for metric in MenuBarMetric.allCases {
            let offered = metric.supportedStyles.contains(.battery)
            #expect(offered == (metric == .battery), "\(metric) offered \(offered)")
        }
    }

    /// `supportedStyles.first` is what `sanitized()` falls back to, so leading the list
    /// is the whole mechanism that makes the indicator the battery's default.
    @Test("it leads the battery's list, so a clamped battery lands on it")
    func batteryDefaultsToIt() {
        #expect(MenuBarMetric.battery.supportedStyles.first == .battery)
    }

    @Test("a metric that cannot draw it is clamped off it")
    func unsupportedStyleIsClamped() {
        let cpu = MenuBarItemConfig(metric: .cpuUsage, style: .battery).sanitized()
        #expect(cpu.style != .battery)
        #expect(MenuBarMetric.cpuUsage.supportedStyles.contains(cpu.style))
    }

    @Test("a battery already on it keeps it")
    func supportedStyleSurvivesSanitizing() {
        let item = MenuBarItemConfig(metric: .battery, style: .battery).sanitized()
        #expect(item.style == .battery)
    }

    /// A settings file is hand-editable and older builds wrote styles this one has
    /// retired, so the clamp has to hold on the decode path too.
    @Test("a stored battery style on a CPU readout is clamped on decode")
    func decodedStyleIsClamped() throws {
        let json = #"{"menuBar":{"items":[{"metric":"cpuUsage","style":"battery"}]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.menuBar.items[0].style != .battery)
    }

    @Test("the styles that draw their own glyph take no caption")
    func glyphStylesRefuseCaptions() {
        #expect(!MenuBarDisplayStyle.battery.supportsCaption)
        #expect(!MenuBarDisplayStyle.iconAndText.supportsCaption)
        #expect(MenuBarDisplayStyle.text.supportsCaption)
    }
}

@Suite("The shipped menu bar is CPU, temperature, GPU and the battery")
struct MenuBarDefaultItemsTests {

    @Test("four readouts, in order")
    func defaultsAreInOrder() {
        #expect(MenuBarSettings.defaultItems.map(\.metric)
                == [.cpuUsage, .cpuTemperature, .gpuUsage, .battery])
    }

    @Test("the battery ships as the indicator, the rest as captioned numbers")
    func defaultStyles() {
        let items = MenuBarSettings.defaultItems
        #expect(items.dropLast().allSatisfy { $0.style == .text && $0.showsCaption })
        #expect(items.last?.style == .battery)
    }

    /// Every default has to survive the clamp, or a fresh install would silently start
    /// on a style other than the one shipped.
    @Test("every default is already sanitized")
    func defaultsAreSanitized() {
        for item in MenuBarSettings.defaultItems {
            #expect(item.sanitized().style == item.style)
        }
    }
}

@Suite("The indicator's charge, charging and low flags travel on the model")
struct BatteryRenderModelTests {

    private func item(_ snapshot: SystemSnapshot,
                      style: MenuBarDisplayStyle = .battery) -> MenuBarItemRender {
        let config = MenuBarItemConfig(metric: .battery, style: style, showsCaption: false)
        let model = MenuBarRenderModel(
            snapshot: snapshot,
            history: SnapshotFixtures.history(),
            settings: Settings(menuBar: MenuBarSettings(items: [config])),
            isStale: false)
        return model.items[0]
    }

    private func snapshot(percent: Double, charging: Bool) -> SystemSnapshot {
        var snapshot = SnapshotFixtures.nominal
        snapshot.power = .value(SnapshotFixtures.power(percent: percent, charging: charging))
        return snapshot
    }

    @Test("the charge arrives as a fraction, not a percentage")
    func chargeIsAFraction() {
        #expect(item(snapshot(percent: 76, charging: false)).batteryCharge == 0.76)
    }

    @Test("charging is carried, and a charging battery is never low")
    func chargingIsCarried() {
        let charging = item(snapshot(percent: 9, charging: true))
        #expect(charging.isBatteryCharging)
        #expect(!charging.isBatteryLow)
    }

    @Test("low is exactly at or below the threshold")
    func lowThreshold() {
        let cutoff = MenuBarItemRender.lowBatteryFraction * 100
        #expect(item(snapshot(percent: cutoff, charging: false)).isBatteryLow)
        #expect(!item(snapshot(percent: cutoff + 1, charging: false)).isBatteryLow)
    }

    /// A desktop reports no battery at all. Nothing may be drawn from a charge that was
    /// never read, so the readout has to come back empty rather than at zero.
    @Test("a machine with no battery carries no charge")
    func noBatteryCarriesNothing() {
        let item = item(SnapshotFixtures.degraded)
        #expect(item.isUnavailable)
        #expect(item.batteryCharge == nil)
    }

    /// The number is off the screen in this style, so the accessibility tree is the only
    /// place it still exists.
    @Test("VoiceOver still gets the percentage and the state")
    func accessibilityKeepsTheNumber() {
        #expect(item(snapshot(percent: 76, charging: false)).accessibilityLabel == "Battery 76%")
        #expect(item(snapshot(percent: 34, charging: true)).accessibilityLabel
                == "Battery 34%, charging")
        #expect(item(snapshot(percent: 8, charging: false)).accessibilityLabel
                == "Battery 8%, low")
    }

    /// The fields are on every readout, so they have to stay nil on the ones that are
    /// not a battery rather than defaulting to a plausible-looking zero.
    @Test("other readouts carry no battery state")
    func otherMetricsCarryNothing() {
        let config = MenuBarItemConfig(metric: .cpuUsage, style: .text)
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: SnapshotFixtures.history(),
                                       settings: Settings(menuBar: MenuBarSettings(items: [config])),
                                       isStale: false)
        #expect(model.items[0].batteryCharge == nil)
        #expect(!model.items[0].isBatteryCharging)
    }

    /// The indicator names its own metric, and a caption beside it would say "BATT"
    /// next to the most recognisable glyph in the menu bar.
    @Test("the indicator takes no caption even when one is asked for")
    func indicatorRefusesCaptions() {
        let config = MenuBarItemConfig(metric: .battery, style: .battery, showsCaption: true)
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: SnapshotFixtures.history(),
                                       settings: Settings(menuBar: MenuBarSettings(items: [config])),
                                       isStale: false)
        #expect(model.items[0].caption == nil)
    }
}

@MainActor
@Suite("The indicator holds its width and draws at both scales")
struct BatteryDrawingTests {

    private func model(percent: Double, charging: Bool) -> MenuBarRenderModel {
        var snapshot = SnapshotFixtures.nominal
        snapshot.power = .value(SnapshotFixtures.power(percent: percent, charging: charging))
        let config = MenuBarItemConfig(metric: .battery, style: .battery, showsCaption: false)
        return MenuBarRenderModel(snapshot: snapshot,
                                  history: SnapshotFixtures.history(),
                                  settings: Settings(menuBar: MenuBarSettings(items: [config])),
                                  isStale: false)
    }

    private func width(percent: Double, charging: Bool = false) -> CGFloat {
        let view = MenuBarContentView(frame: .zero)
        view.update(with: model(percent: percent, charging: charging))
        return view.intrinsicContentSize.width
    }

    /// The one thing a menu bar must never do is move, and the charge changes every
    /// sample. The shell is a fixed size and only its fill moves inside it.
    @Test("the item is the same width empty, full and charging")
    func widthIsFixed() {
        let full = width(percent: 100)
        #expect(width(percent: 0) == full)
        #expect(width(percent: 8) == full)
        #expect(width(percent: 51) == full)
        #expect(width(percent: 64, charging: true) == full)
    }

    /// The indicator draws no number, so it should be narrower than the same readout
    /// spelled out. If it is not, it is not worth the drawing.
    @Test("it is narrower than the same readout as text")
    func narrowerThanText() {
        let view = MenuBarContentView(frame: .zero)
        var snapshot = SnapshotFixtures.nominal
        snapshot.power = .value(SnapshotFixtures.power(percent: 76, charging: false))
        let text = MenuBarItemConfig(metric: .battery, style: .text, showsCaption: true)
        view.update(with: MenuBarRenderModel(
            snapshot: snapshot, history: SnapshotFixtures.history(),
            settings: Settings(menuBar: MenuBarSettings(items: [text])), isStale: false))
        #expect(width(percent: 76) < view.intrinsicContentSize.width)
    }

    /// Exercises the real drawing path, including the bolt's cleared gap, at both
    /// backing scales and in both appearances. It cannot judge how it looks; it can
    /// prove that every state produces pixels instead of trapping or coming back blank.
    @Test("every battery state renders at both scales in both appearances")
    func rendersEveryState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatBatteryTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .battery, style: .battery,
                                                    showsCaption: false)]
        for scenario in OffscreenRenderer.Scenario.allCases {
            for isDark in [false, true] {
                for scale in [CGFloat(1), 2] {
                    let request = OffscreenRenderer.Request(
                        surface: .menuBar, scenario: scenario, isDark: isDark,
                        scale: scale, settings: settings)
                    let url = try OffscreenRenderer.render(request, to: directory)
                    let bytes = try Data(contentsOf: url)
                    #expect(bytes.count > 0, "\(request.fileName) came back empty")
                }
            }
        }
    }
}
