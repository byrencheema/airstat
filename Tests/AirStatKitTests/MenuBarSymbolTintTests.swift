import Testing
import Foundation
import AppKit
@testable import AirStatKit
@testable import AirStatUI

/// `Icon & Text` draws an SF Symbol beside its number, and for as long as that style has
/// existed the symbol came out black — invisible on a dark menu bar, which is where most
/// of them are. Setting a fill colour before drawing a template `NSImage` does nothing:
/// AppKit tints templates inside controls, not in a view drawing by hand.
///
/// Nothing about that is visible in a test that only asks whether pixels came back, so
/// this suite reads them. The renderer composites the item onto the menu bar's own
/// backdrop, so an ink colour is a luminance against a known ground: light ink on the
/// dark bar, dark ink on the light one, and the failure is ink that stayed dark on both.
@MainActor
@Suite("An Icon & Text symbol takes the menu bar's colour")
struct MenuBarSymbolTintTests {

    /// The backdrops `OffscreenRenderer` composites onto.
    private static let darkBackdrop: CGFloat = 0.13
    private static let lightBackdrop: CGFloat = 0.96
    /// Antialiasing and the renderer's colour conversion both move a pixel a little.
    private static let tolerance: CGFloat = 0.04

    private func settings(style: MenuBarDisplayStyle,
                          metric: MenuBarMetric = .cpuUsage) -> Settings {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: metric, style: style,
                                                    showsCaption: false)]
        return settings
    }

    /// Every pixel of a rendered readout, as luminance in 0...1.
    private func luminances(_ settings: Settings, isDark: Bool) throws -> [CGFloat] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTintTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = OffscreenRenderer.Request(surface: .menuBar, scenario: .nominal,
                                                isDark: isDark, scale: 2, settings: settings)
        let url = try OffscreenRenderer.render(request, to: directory)
        guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
            Issue.record("\(request.fileName) did not decode")
            return []
        }
        var values: [CGFloat] = []
        values.reserveCapacity(rep.pixelsWide * rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                values.append(0.2126 * color.redComponent
                              + 0.7152 * color.greenComponent
                              + 0.0722 * color.blueComponent)
            }
        }
        return values
    }

    /// The whole bug in one assertion. A black symbol on the dark bar puts pixels far
    /// below the backdrop; a correctly tinted one never goes below it at all, because
    /// everything this item draws is the label colour or a faded version of it.
    @Test("nothing an Icon & Text readout draws is darker than the dark menu bar")
    func nothingIsDarkerThanTheDarkBar() throws {
        let values = try luminances(settings(style: .iconAndText), isDark: true)
        let darkest = values.min() ?? 0
        #expect(darkest >= Self.darkBackdrop - Self.tolerance,
                "ink at \(darkest) against a \(Self.darkBackdrop) bar")
    }

    /// The other half: the symbol has to actually be drawn. An image that failed to
    /// rasterise, or one tinted to the backdrop, would sail through the check above.
    @Test("the icon adds light ink of its own, not just the number's")
    func theIconIsDrawn() throws {
        let icon = try luminances(settings(style: .iconAndText), isDark: true)
        let text = try luminances(settings(style: .text), isDark: true)
        let bright = { (values: [CGFloat]) in values.filter { $0 > 0.6 }.count }
        #expect(bright(icon) > bright(text),
                "\(bright(icon)) bright pixels with the icon, \(bright(text)) without")
    }

    /// The same drawing on the light bar. The cache is keyed on the resolved colour
    /// rather than on the `NSColor` object, and `labelColor` is one object that means
    /// two different colours — keyed wrongly, this is where a dark-mode bitmap would
    /// come back to be painted white-on-white.
    @Test("nothing an Icon & Text readout draws is lighter than the light menu bar")
    func nothingIsLighterThanTheLightBar() throws {
        let values = try luminances(settings(style: .iconAndText), isDark: false)
        let lightest = values.max() ?? 1
        #expect(lightest <= Self.lightBackdrop + Self.tolerance,
                "ink at \(lightest) against a \(Self.lightBackdrop) bar")
        #expect((values.min() ?? 1) < 0.4, "no dark ink on the light bar at all")
    }

    /// Every metric that offers the style, at both appearances. The symbols differ in
    /// shape and in how much ink they carry, and the tint runs per symbol.
    @Test("every metric's symbol takes the colour, in both appearances")
    func everyMetricTints() throws {
        for metric in MenuBarMetric.allCases
        where metric.supportedStyles.contains(.iconAndText) {
            let settings = settings(style: .iconAndText, metric: metric)
            let dark = try luminances(settings, isDark: true)
            #expect((dark.min() ?? 0) >= Self.darkBackdrop - Self.tolerance,
                    "\(metric) drew \(dark.min() ?? 0) on the dark bar")
            let light = try luminances(settings, isDark: false)
            #expect((light.max() ?? 1) <= Self.lightBackdrop + Self.tolerance,
                    "\(metric) drew \(light.max() ?? 1) on the light bar")
        }
    }
}
