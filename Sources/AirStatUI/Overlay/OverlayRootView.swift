import SwiftUI
import AppKit
import AirStatKit

/// Interaction state the window controller owns and the overlay's content reacts to.
///
/// Width lives here rather than being read straight from settings so a resize drag
/// can update sixty times a second without writing sixty configuration files; the
/// controller persists the final value once the drag ends.
@MainActor
@Observable
final class OverlayLayout {
    var width: Double
    /// True while the click-through escape hatch is held, so the overlay can show
    /// that it is temporarily grabbable.
    var isGrabbable: Bool = false

    init(width: Double) { self.width = width }
}

/// The overlay's own presentation: denser and quieter than the panel.
///
/// The panel is a place you look *at*; the overlay is something you look *past*.
/// So a module here is one header line, an optional bar, and at most a couple of
/// supporting lines — never the panel's full expansion.
struct OverlayRootView: View {
    let engine: MetricsEngine
    let settings: SettingsStore
    var layout: OverlayLayout?

    private var overlay: OverlaySettings { settings.settings.overlay }

    /// A decoded configuration can repeat a module; identity in a `ForEach` must be
    /// unique or SwiftUI will reuse the wrong view.
    private var modules: [PanelModule] {
        var seen = Set<PanelModule>()
        return overlay.modules.filter { seen.insert($0).inserted }
    }

    private var width: CGFloat { CGFloat(layout?.width ?? overlay.width) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            ForEach(modules, id: \.self) { module in
                OverlayModuleView(module: module, engine: engine, isCompact: overlay.isCompact)
            }
        }
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Space.m)
        .frame(width: width, alignment: .leading)
        .environment(\.metricFormatter, MetricFormatter(settings: settings.settings.general))
        .floatingSurface(in: shape)
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: Design.Space.hairline)
        }
        .animation(Design.Motion.respectingAccessibility(Design.Motion.hover),
                   value: layout?.isGrabbable ?? false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AirStat overlay")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
    }

    /// The border is normally just enough edge definition to survive a busy
    /// wallpaper; while the escape hatch is held it turns accent-coloured, which is
    /// the only signal the user gets that a click-through overlay is grabbable again.
    private var borderColor: Color {
        (layout?.isGrabbable ?? false) ? Design.Palette.accent : Design.Palette.separator
    }
}

// MARK: - One module

private struct OverlayModuleView: View {
    let module: PanelModule
    let engine: MetricsEngine
    let isCompact: Bool

    @Environment(\.metricFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            switch readout {
            case .value(let readout):
                OverlayHeaderRow(readout: readout)
                if let fraction = readout.fraction {
                    // The bar carries the metric's identity colour, whatever the value
                    // is doing: the length is the reading, and a bar that also changed
                    // hue was saying the same thing twice in a louder voice.
                    CapacityBar(fraction: fraction, tint: readout.tint, height: 3)
                }
                if let secondary = readout.secondary {
                    OverlaySecondaryRow(detail: secondary)
                }
                if !isCompact {
                    ForEach(readout.details) { detail in
                        ReadoutRow(detail.label, detail.value)
                    }
                }
            case .failure(let failure):
                OverlayHeaderRow(readout: OverlayReadout(module: module, value: nil))
                UnavailableNote(failure)
            }
        }
    }

    // MARK: Snapshot → readout

    /// Every module collapses to the same shape, so the overlay has exactly one
    /// layout to get right instead of nine.
    private var readout: MetricState<OverlayReadout> {
        switch module {
        case .cpu: return cpuReadout
        case .memory: return memoryReadout
        case .gpu: return gpuReadout
        case .network: return networkReadout
        case .disk: return diskReadout
        case .battery: return batteryReadout
        case .thermal: return thermalReadout
        case .processes: return processReadout
        case .system: return systemReadout
        }
    }

    private var cpuReadout: MetricState<OverlayReadout> {
        engine.cpu.map { cpu in
            var readout = OverlayReadout(module: module, value: formatter.percent(cpu.total.busy))
            readout.fraction = cpu.total.busy
            readout.details = [
                OverlayDetail("user", "User", formatter.percent(cpu.total.user)),
                OverlayDetail("system", "System", formatter.percent(cpu.total.system)),
                OverlayDetail("load", "Load", formatter.fixed(cpu.loadAverage.one, decimals: 2)),
            ]
            return readout
        }
    }

    private var memoryReadout: MetricState<OverlayReadout> {
        engine.memory.map { memory in
            var readout = OverlayReadout(module: module, value: formatter.percent(memory.usedFraction))
            readout.fraction = memory.usedFraction
            readout.secondary = OverlayDetail("used", "",
                                              "\(formatter.memory(memory.usedBytes)) of \(formatter.memory(memory.totalBytes))")
            readout.details = [
                OverlayDetail("pressure", "Pressure", formatter.percent(memory.pressureFraction)),
                OverlayDetail("swap", "Swap", formatter.memory(memory.swapUsedBytes)),
            ]
            return readout
        }
    }

    private var gpuReadout: MetricState<OverlayReadout> {
        engine.gpu.map { gpu in
            let device = gpu.primary
            let utilization = device?.utilization
            var readout = OverlayReadout(
                module: module,
                value: utilization.map { formatter.percent($0) } ?? MetricFormatter.unavailable)
            readout.fraction = utilization
            if let device, let used = device.vramUsedBytes, let total = device.vramTotalBytes, total > 0 {
                readout.details = [
                    OverlayDetail("vram", device.memoryLabel,
                                  "\(formatter.memory(used)) of \(formatter.memory(total))"),
                ]
            }
            return readout
        }
    }

    private var networkReadout: MetricState<OverlayReadout> {
        engine.network.map { network in
            // Arrows rather than "Down"/"Up" labels: at this width the glyph carries
            // the meaning in a fraction of the space a word would need.
            var readout = OverlayReadout(
                module: module,
                value: "↓ " + formatter.networkRate(network.downloadBytesPerSecond))
            readout.secondary = OverlayDetail("up", "",
                                              "↑ " + formatter.networkRate(network.uploadBytesPerSecond))
            var details = [OverlayDetail("type", "Link", network.connectionType.label)]
            if let ssid = network.wifi?.ssid {
                details.append(OverlayDetail("ssid", "Network", ssid))
            }
            readout.details = details
            return readout
        }
    }

    private var diskReadout: MetricState<OverlayReadout> {
        engine.disk.map { disk in
            let root = disk.rootVolume
            var readout = OverlayReadout(
                module: module,
                value: root.map { formatter.percent($0.usedFraction) } ?? MetricFormatter.unavailable)
            readout.fraction = root?.usedFraction
            if let root {
                readout.secondary = OverlayDetail("free", "", "\(formatter.storage(root.freeBytes)) free")
            }
            readout.details = [
                OverlayDetail("read", "Read", formatter.diskRate(disk.readBytesPerSecond)),
                OverlayDetail("write", "Write", formatter.diskRate(disk.writeBytesPerSecond)),
            ]
            return readout
        }
    }

    private var batteryReadout: MetricState<OverlayReadout> {
        engine.power.map { power in
            guard power.hasBattery, let percentage = power.percentage else {
                // A desktop Mac has no battery to report; system draw is the honest
                // substitute, and an em dash when even that is unavailable.
                var readout = OverlayReadout(module: module, value: formatter.watts(power.systemWatts))
                readout.secondary = OverlayDetail("source", "", power.isPluggedIn ? "AC power" : "")
                return readout
            }
            var readout = OverlayReadout(module: module,
                                         value: formatter.percentValue(percentage))
            readout.fraction = percentage / 100
            readout.secondary = OverlayDetail("state", "", batteryCaption(power))
            readout.details = [
                OverlayDetail("power", "Draw", formatter.watts(power.batteryWatts)),
            ]
            return readout
        }
    }

    private func batteryCaption(_ power: PowerSnapshot) -> String {
        if power.isFullyCharged { return "Fully charged" }
        if power.isCharging {
            guard let full = power.timeToFull else { return "Charging" }
            return "\(formatter.duration(full)) to full"
        }
        guard let empty = power.timeToEmpty else {
            return power.isPluggedIn ? "Plugged in" : "On battery"
        }
        return "\(formatter.duration(empty)) left"
    }

    private var thermalReadout: MetricState<OverlayReadout> {
        engine.thermal.map { thermal in
            var readout = OverlayReadout(module: module,
                                         value: formatter.temperature(thermal.cpuCelsius))
            readout.secondary = OverlayDetail("pressure", "", thermal.pressure.label)
            if let fan = thermal.fans.first {
                readout.details = [OverlayDetail("fan", fan.name, formatter.rpm(fan.currentRPM))]
            }
            return readout
        }
    }

    private var processReadout: MetricState<OverlayReadout> {
        engine.processes.map { snapshot in
            var readout = OverlayReadout(module: module,
                                         value: formatter.count(snapshot.totalProcessCount))
            let top = snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }
            if let first = top.first {
                readout.secondary = OverlayDetail("top", first.name,
                                                  formatter.unclampedPercent(first.cpuPercent))
            }
            readout.details = top.dropFirst().prefix(3).map {
                OverlayDetail("pid-\($0.pid)", $0.name, formatter.unclampedPercent($0.cpuPercent))
            }
            return readout
        }
    }

    private var systemReadout: MetricState<OverlayReadout> {
        engine.system.map { system in
            var readout = OverlayReadout(module: module, value: formatter.uptime(system.uptime))
            readout.secondary = OverlayDetail("chip", "", system.chipName)
            readout.details = [
                OverlayDetail("os", system.osName, system.osVersion),
                OverlayDetail("host", "Host", system.computerName),
            ]
            return readout
        }
    }
}

// MARK: - Rows

private struct OverlayHeaderRow: View {
    let readout: OverlayReadout

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: readout.symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(readout.tint)
                .frame(width: 11)
            SwiftUI.Text(readout.title)
                .font(Design.Text.sectionHeader)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
            Spacer(minLength: Design.Space.m)
            if let value = readout.value {
                SwiftUI.Text(value)
                    .font(Design.Text.value)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readout.title)
        .accessibilityValue(readout.value ?? "")
    }
}

/// The one supporting line a compact module is allowed. Deliberately quieter than
/// `ReadoutRow`: it is context for the header, not a readout in its own right.
private struct OverlaySecondaryRow: View {
    let detail: OverlayDetail

    var body: some View {
        HStack(spacing: Design.Space.s) {
            if !detail.label.isEmpty {
                SwiftUI.Text(detail.label)
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Design.Space.xs)
            SwiftUI.Text(detail.value)
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.label)
        .accessibilityValue(detail.value)
    }
}

// MARK: - Model

private struct OverlayDetail: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String

    init(_ id: String, _ label: String, _ value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// `Equatable` and `Sendable` because it travels inside a `MetricState`, which is how
/// every module gets the same honest handling of an unavailable metric for free.
private struct OverlayReadout: Equatable, Sendable {
    var title: String
    var symbol: String
    var tint: Color
    /// Nil renders no value at all, which is what the header shows above an
    /// `UnavailableNote` — never a zero standing in for a number we do not have.
    var value: String?
    var fraction: Double?
    var secondary: OverlayDetail?
    var details: [OverlayDetail] = []

    init(module: PanelModule, value: String?) {
        self.title = module.label
        self.symbol = module.symbolName
        self.tint = Design.Palette.metric(module.requiredSource)
        self.value = value
    }
}
