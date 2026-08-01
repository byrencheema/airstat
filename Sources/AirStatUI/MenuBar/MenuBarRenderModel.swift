import Foundation
import AirStatKit

/// One value of a readout: the number, the widest string it can ever become, and the
/// series behind it.
///
/// Network and disk are inherently *two* numbers, so a readout is modelled as one or
/// two of these rather than as one string. The concatenation that used to happen here
/// — `"↓ 2.4 MB/s  ↑ 340 KB/s"` — is gone: it was why fixed width did not hold, since
/// its width tracked the live value and no reserved string could bound it.
public struct MenuBarLine: Equatable, Sendable {
    /// Single-character direction marker ("↓", "↑", "R", "W"). Only set on paired
    /// readouts, where the two numbers would otherwise be indistinguishable.
    public var glyph: String?
    /// The value, already formatted and unit-suffixed.
    public var valueText: String
    /// Widest string this line can produce. Reserving it is what stops the menu bar
    /// shuffling every time a value crosses from 9% to 10% or KB/s to MB/s.
    public var widestText: String
    /// Oldest-to-newest samples for graph styles, normalised to 0...1.
    public var series: [Float]

    public init(glyph: String? = nil, valueText: String, widestText: String,
                series: [Float] = []) {
        self.glyph = glyph
        self.valueText = valueText
        self.widestText = widestText
        self.series = series
    }
}

/// One readout, reduced to exactly what the drawing code needs.
///
/// Deliberately free of AppKit and of the snapshot types: the view does no
/// interpretation, and this model can be unit-tested without a screen.
public struct MenuBarItemRender: Equatable, Sendable {
    public var id: UUID
    public var style: MenuBarDisplayStyle
    public var colorMode: ColorMode
    /// Short caption such as "CPU", drawn beside the readout. Only ever set for the
    /// styles that draw no number of their own, and only when the user asks for it.
    public var caption: String?
    public var primary: MenuBarLine
    /// Second value, set only for the two-number metrics.
    public var secondary: MenuBarLine?
    /// 0...1 for bar/ring styles. Nil when the metric has no natural maximum.
    public var fraction: Double?
    public var severity: MetricSeverity
    /// Set when the metric is unavailable; the view greys the readout and shows a dash.
    public var isUnavailable: Bool
    public var symbolName: String?
    /// User override for graph styles, in points. Nil uses the style's natural width.
    public var graphWidth: Double?
    public var accessibilityLabel: String

    public init(id: UUID, style: MenuBarDisplayStyle, colorMode: ColorMode, caption: String?,
                primary: MenuBarLine, secondary: MenuBarLine? = nil, fraction: Double?,
                severity: MetricSeverity, isUnavailable: Bool, symbolName: String?,
                graphWidth: Double? = nil, accessibilityLabel: String) {
        self.id = id
        self.style = style
        self.colorMode = colorMode
        self.caption = caption
        self.primary = primary
        self.secondary = secondary
        self.fraction = fraction
        self.severity = severity
        self.isUnavailable = isUnavailable
        self.symbolName = symbolName
        self.graphWidth = graphWidth
        self.accessibilityLabel = accessibilityLabel
    }

}

/// Everything the status item needs to draw one frame.
public struct MenuBarRenderModel: Equatable, Sendable {
    public var items: [MenuBarItemRender]
    public var spacing: Double
    public var usesMonospacedDigits: Bool
    public var usesFixedWidth: Bool
    public var isStale: Bool

    public var accessibilityDescription: String {
        items.map(\.accessibilityLabel).joined(separator: ", ")
    }

    public init(snapshot: SystemSnapshot,
                history: MetricHistory,
                settings: Settings,
                isStale: Bool) {
        let formatter = MetricFormatter(settings: settings.general)
        self.spacing = settings.menuBar.itemSpacing
        self.usesMonospacedDigits = settings.menuBar.usesMonospacedDigits
        self.usesFixedWidth = settings.menuBar.usesFixedWidth
        self.isStale = isStale

        var rendered: [MenuBarItemRender] = []
        rendered.reserveCapacity(settings.menuBar.items.count)
        for config in settings.menuBar.enabledItems {
            guard let item = MenuBarRenderModel.render(config: config,
                                                       snapshot: snapshot,
                                                       history: history,
                                                       formatter: formatter,
                                                       settings: settings) else { continue }
            rendered.append(item)
        }
        self.items = rendered
    }

    /// Builds one readout, or nil when the user asked to hide idle readouts and
    /// this one is at rest.
    private static func render(config: MenuBarItemConfig,
                               snapshot: SystemSnapshot,
                               history: MetricHistory,
                               formatter: MetricFormatter,
                               settings: Settings) -> MenuBarItemRender? {
        let metric = config.metric
        let dash = MetricFormatter.unavailable
        let widest = formatter.widestSample(for: metric)

        var valueText = dash
        var fraction: Double?
        var seriesKey: SeriesKey?
        var severity = MetricSeverity.normal
        var unavailable = true
        // Named, not a bare "unavailable": VoiceOver reads the whole item as one string,
        // and three anonymous "unavailable"s in a row say nothing about what is missing.
        var accessibilityValue = "\(metric.label) unavailable"
        // Set only by the two-number metrics; its presence is what makes the readout
        // stack rather than run on.
        var secondary: MenuBarLine?

        switch metric {
        case .cpuUsage:
            if let cpu = snapshot.cpu.value {
                let busy = cpu.total.busy
                fraction = busy
                valueText = formatter.percent(busy)
                severity = .forUtilization(busy)
                unavailable = false
                accessibilityValue = "CPU \(valueText)"
            }
            seriesKey = .cpuTotal

        case .cpuTemperature:
            if let temp = snapshot.thermal.value?.cpuCelsius {
                valueText = formatter.temperature(temp)
                fraction = min(max(temp / 110, 0), 1)
                severity = .forTemperature(temp)
                unavailable = false
                accessibilityValue = "CPU temperature \(valueText)"
            }
            seriesKey = .cpuTemperature

        case .cpuFrequency:
            // No public API reports Apple Silicon core frequency; leave it explicit.
            break

        case .memoryUsage:
            if let mem = snapshot.memory.value {
                fraction = mem.usedFraction
                valueText = formatter.percent(mem.usedFraction)
                severity = .forUtilization(mem.usedFraction)
                unavailable = false
                accessibilityValue = "Memory \(valueText)"
            }
            seriesKey = .memoryUsed

        case .memoryPressure:
            if let mem = snapshot.memory.value {
                fraction = mem.pressureFraction
                valueText = formatter.percent(mem.pressureFraction)
                severity = .forUtilization(mem.pressureFraction)
                unavailable = false
                accessibilityValue = "Memory pressure \(valueText)"
            }
            seriesKey = .memoryPressure

        case .gpuUsage:
            if let util = snapshot.gpu.value?.primary?.utilization {
                fraction = util
                valueText = formatter.percent(util)
                severity = .forUtilization(util)
                unavailable = false
                accessibilityValue = "GPU \(valueText)"
            }
            seriesKey = .gpuUtilization

        case .networkThroughput:
            // Compact form ("2.4MB") rather than the full one ("2.4 MB/s"). Two full
            // rates side by side are 130 points of menu bar for one readout; the arrow
            // already says this is a flow, and the panel and the accessibility label
            // both still carry the units in full.
            let rateWidest = MenuBarRenderModel.widestCompactNetworkRate(formatter)
            var uploadText = dash
            if let net = snapshot.network.value {
                valueText = formatter.networkRate(net.downloadBytesPerSecond, compact: true)
                uploadText = formatter.networkRate(net.uploadBytesPerSecond, compact: true)
                unavailable = false
                accessibilityValue = "Network down \(formatter.networkRate(net.downloadBytesPerSecond)), "
                    + "up \(formatter.networkRate(net.uploadBytesPerSecond))"
            }
            // Down and up share one scale so the two stacked graphs are comparable;
            // normalising each to its own peak would make a trickle of upload look
            // identical to a saturated link.
            let pair = jointlyNormalized(history, .networkDownload, .networkUpload)
            secondary = MenuBarLine(glyph: "↑", valueText: uploadText,
                                    widestText: rateWidest, series: pair.1)
            return finish(config: config, caption: nil,
                          primary: MenuBarLine(glyph: "↓", valueText: valueText,
                                               widestText: rateWidest, series: pair.0),
                          secondary: secondary, fraction: nil, severity: severity,
                          unavailable: unavailable, accessibility: accessibilityValue,
                          settings: settings)

        case .networkUpload:
            if let net = snapshot.network.value {
                valueText = formatter.networkRate(net.uploadBytesPerSecond)
                unavailable = false
                accessibilityValue = "Network upload \(valueText)"
            }
            seriesKey = .networkUpload

        case .networkDownload:
            if let net = snapshot.network.value {
                valueText = formatter.networkRate(net.downloadBytesPerSecond)
                unavailable = false
                accessibilityValue = "Network download \(valueText)"
            }
            seriesKey = .networkDownload

        case .diskActivity:
            let rateWidest = MenuBarRenderModel.widestCompactDiskRate(formatter)
            var writeText = dash
            if let disk = snapshot.disk.value {
                valueText = formatter.diskRate(disk.readBytesPerSecond, compact: true)
                writeText = formatter.diskRate(disk.writeBytesPerSecond, compact: true)
                unavailable = false
                accessibilityValue = "Disk read \(formatter.diskRate(disk.readBytesPerSecond)), "
                    + "write \(formatter.diskRate(disk.writeBytesPerSecond))"
            }
            let pair = jointlyNormalized(history, .diskRead, .diskWrite)
            secondary = MenuBarLine(glyph: "W", valueText: writeText,
                                    widestText: rateWidest, series: pair.1)
            return finish(config: config, caption: nil,
                          primary: MenuBarLine(glyph: "R", valueText: valueText,
                                               widestText: rateWidest, series: pair.0),
                          secondary: secondary, fraction: nil, severity: severity,
                          unavailable: unavailable, accessibility: accessibilityValue,
                          settings: settings)

        case .diskFree:
            if let root = snapshot.disk.value?.rootVolume {
                valueText = formatter.storage(root.availableBytes)
                let freeFraction = root.totalBytes > 0 ? Double(root.availableBytes) / Double(root.totalBytes) : 0
                fraction = 1 - freeFraction
                severity = .forRemaining(freeFraction)
                unavailable = false
                accessibilityValue = "Disk free \(valueText)"
            }

        case .battery:
            if let power = snapshot.power.value, let pct = power.percentage {
                fraction = pct / 100
                valueText = formatter.percentValue(pct)
                severity = .forRemaining(pct / 100)
                unavailable = false
                accessibilityValue = power.isCharging ? "Battery \(valueText) charging" : "Battery \(valueText)"
            }
            seriesKey = .batteryPercent

        case .batteryTime:
            if let power = snapshot.power.value {
                let remaining = power.isCharging ? power.timeToFull : power.timeToEmpty
                if let remaining {
                    valueText = formatter.duration(remaining)
                    unavailable = false
                    accessibilityValue = "Battery time \(valueText)"
                }
            }

        case .systemPower:
            if let watts = snapshot.power.value?.systemWatts {
                valueText = formatter.watts(watts)
                unavailable = false
                accessibilityValue = "System power \(valueText)"
            }
            seriesKey = .systemWatts

        case .fanSpeed:
            if let fan = snapshot.thermal.value?.fans.first {
                valueText = formatter.rpm(fan.currentRPM)
                fraction = fan.loadFraction
                unavailable = false
                accessibilityValue = "Fan \(valueText)"
            }
            seriesKey = .fanRPM

        case .uptime:
            if let system = snapshot.system.value {
                valueText = formatter.compactUptime(system.uptime)
                unavailable = false
                accessibilityValue = "Uptime \(valueText)"
            }
        }

        let series = seriesKey.map { normalizedSeries(history, key: $0) } ?? []
        return finish(config: config, caption: caption(for: config),
                      primary: MenuBarLine(valueText: valueText, widestText: widest,
                                           series: series),
                      secondary: nil, fraction: fraction, severity: severity,
                      unavailable: unavailable, accessibility: accessibilityValue,
                      settings: settings)
    }

    private static func finish(config: MenuBarItemConfig,
                               caption: String?,
                               primary: MenuBarLine,
                               secondary: MenuBarLine?,
                               fraction: Double?,
                               severity: MetricSeverity,
                               unavailable: Bool,
                               accessibility: String,
                               settings: Settings) -> MenuBarItemRender? {
        if settings.menuBar.hidesIdleItems, !unavailable,
           let fraction, fraction < settings.menuBar.idleThreshold {
            return nil
        }
        return MenuBarItemRender(
            id: config.id,
            style: config.style,
            colorMode: config.colorMode,
            caption: caption,
            primary: primary,
            secondary: secondary,
            fraction: fraction,
            severity: severity,
            isUnavailable: unavailable,
            symbolName: symbolName(for: config.metric),
            graphWidth: config.graphWidth,
            accessibilityLabel: accessibility
        )
    }

    /// A caption is a static word that never changes, and on a surface this scarce a
    /// static word is the most expensive thing on it. So it is strictly what the user
    /// asked for, and only on the styles that draw no number of their own — an icon
    /// already names its metric, and a number beside a caption is what made the menu
    /// bar read as two labels and a value.
    private static func caption(for config: MenuBarItemConfig) -> String? {
        switch config.style {
        case .text, .textAndGraph, .icon, .iconAndText:
            return nil
        case .graph, .bar, .ring:
            guard config.showsCaption else { return nil }
        }
        switch config.metric {
        case .cpuUsage: return "CPU"
        case .cpuTemperature: return "TEMP"
        case .cpuFrequency: return "FREQ"
        case .memoryUsage: return "MEM"
        case .memoryPressure: return "PRESS"
        case .gpuUsage: return "GPU"
        case .networkThroughput: return nil
        case .networkUpload: return "NET ↑"
        case .networkDownload: return "NET ↓"
        case .diskActivity: return nil
        case .diskFree: return "FREE"
        case .battery: return "BATT"
        case .batteryTime: return "LEFT"
        case .systemPower: return "PWR"
        case .fanSpeed: return "FAN"
        case .uptime: return "UP"
        }
    }

    /// Graph series normalised to 0...1. Unbounded metrics (throughput) scale to
    /// their own peak in the window so the shape stays legible at any magnitude.
    private static func normalizedSeries(_ history: MetricHistory, key: SeriesKey) -> [Float] {
        let ring = history[key]
        guard ring.count > 1 else { return [] }
        let values = ring.values
        if key.isNormalized {
            return values.map { min(max($0, 0), 1) }
        }
        let peak = max(ring.maximum, .leastNonzeroMagnitude)
        return values.map { min(max($0 / peak, 0), 1) }
    }

    /// Two unbounded series scaled against their shared peak, so the pair can be read
    /// against each other rather than each against itself.
    private static func jointlyNormalized(_ history: MetricHistory,
                                          _ first: SeriesKey,
                                          _ second: SeriesKey) -> ([Float], [Float]) {
        let a = history[first]
        let b = history[second]
        guard a.count > 1 || b.count > 1 else { return ([], []) }
        let peak = max(max(a.maximum, b.maximum), .leastNonzeroMagnitude)
        let scale = { (values: [Float]) in values.map { min(max($0 / peak, 0), 1) } }
        return (scale(a.values), scale(b.values))
    }

    /// The widest string the compact rate form can produce, generated *through* the
    /// formatter so it follows the user's bits-versus-bytes and binary-versus-decimal
    /// choices instead of assuming them.
    private static func widestCompactNetworkRate(_ formatter: MetricFormatter) -> String {
        let probe = formatter.networkUnit == .bits
            ? 999 * 1_000_000 / 8.0
            : 999 * pow(formatter.byteStyle.base, 2)
        return formatter.networkRate(probe, compact: true)
    }

    private static func widestCompactDiskRate(_ formatter: MetricFormatter) -> String {
        formatter.diskRate(999 * pow(formatter.byteStyle.base, 2), compact: true)
    }

    private static func symbolName(for metric: MenuBarMetric) -> String? {
        switch metric {
        case .cpuUsage, .cpuFrequency: return "cpu"
        case .cpuTemperature: return "thermometer.medium"
        case .memoryUsage, .memoryPressure: return "memorychip"
        case .gpuUsage: return "cube.transparent"
        case .networkThroughput, .networkUpload, .networkDownload: return "network"
        case .diskActivity, .diskFree: return "internaldrive"
        case .battery, .batteryTime: return "battery.100"
        case .systemPower: return "bolt"
        case .fanSpeed: return "fan"
        case .uptime: return "clock"
        }
    }
}
