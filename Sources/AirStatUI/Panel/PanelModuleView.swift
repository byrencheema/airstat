import SwiftUI
import AirStatKit

/// The one-glance answer for a module, shown on its header line.
///
/// Everything below the header is detail the user reads second; this is what they
/// read first, so each module contributes exactly one of them.
struct PanelSummary {
    /// Whether the primary reads as a measurement or as a state. A state ("Nominal",
    /// "AC") set at headline size looks like a mistake, so it drops to value size.
    enum Emphasis { case measurement, state }

    var value: String?
    var caption: String?
    /// Replaces the module's own glyph. A full battery icon on a Mac that has no
    /// battery states something untrue before the reader gets to the words.
    var icon: String?
    var symbol: String?
    var severity: MetricSeverity = .normal
    var emphasis: Emphasis = .measurement
    /// The history the header trace draws. `ChartScale` decides the domain from the
    /// key, so a module never picks its own axis.
    var series: SeriesKey?
}

/// One module of the panel: a header that carries the headline value, and detail
/// that the user can collapse away.
struct PanelModuleView: View {
    let module: PanelModule
    let engine: MetricsEngine
    let settings: SettingsStore

    @State private var isHovering = false

    /// Derived from the store rather than read from the environment so a module is
    /// correct wherever it is hosted, and injected below so the primitives it draws
    /// cannot disagree with it.
    var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    var isExpanded: Bool {
        !settings.settings.panel.collapsedModules.contains(module)
    }

    /// What the panel fills its bars and core cells with.
    ///
    /// Deliberately not `Palette.metric`. Nine modules each in their own hue is nine
    /// colours competing at rest, and it leaves nothing louder to say "this one needs
    /// you" — which is the only thing colour is for here. So the panel is drawn in the
    /// label greys, and saturation is reserved for `Palette.severity`.
    ///
    /// `severityText`, not `severity`, even though these are fills.
    ///
    /// The distinction between the two ramps assumes colour sits *behind* content. A
    /// bar has nothing on top of it — the fill is the content, and it is what carries
    /// the reading. `systemYellow` on a light panel measures 1.34:1, so a disk at 97%
    /// full draws its most important state in a colour that cannot be seen. The text
    /// ramp is the one tuned to be read.
    static func barTint(_ severity: MetricSeverity) -> Color {
        Design.Palette.severityText(severity)
    }

    var tint: Color { Self.barTint(.normal) }

    /// Charts sit in the header beside the headline number, so they stay a step quieter
    /// than the bars: a stroked line reads at secondary weight where a filled bar does
    /// not.
    var traceTint: Color { Design.Palette.secondaryText }

    /// The severity a module is currently reporting, used to colour its glyph so the
    /// module in trouble is findable without reading any of the numbers.
    private var headlineSeverity: MetricSeverity { summary.severity }

    /// A module glyph is a thin shape, so it takes `severityText` rather than the fill
    /// ramp. At rest it stays secondary: `severityText(.normal)` is the full label
    /// colour, which would put nine icons at full strength and undo the point of
    /// reserving weight for the module that needs it.
    private var iconColor: Color {
        headlineSeverity == .normal
            ? Design.Palette.secondaryText
            : Design.Palette.severityText(headlineSeverity)
    }

    /// Width of the header trace. Set by `Sparkline`'s peak caption rather than by the
    /// line: on a data-derived scale that caption is the axis, and a trace too narrow
    /// to print "peak 4.4 MB/s" is a picture with no units.
    private static let traceWidth: CGFloat = 68

    /// Kept at or under the height of the headline text beside it, so the trace never
    /// becomes the thing that decides how tall a module is.
    private static let traceHeight = Design.Chart.sparklineHeight - Design.Space.xs

    /// Width of the qualifier column beside a headline value. Sized for the longest
    /// qualifier in use ("charging"); anything longer belongs in the expanded detail,
    /// not in a summary row, because a truncated word reads as a rendering bug.
    private static let captionColumnWidth: CGFloat = 54

    /// The trace's left edge is set by whatever the headline number happens to be wide,
    /// so the sparklines on two expanded modules can sit a few points out of step.
    ///
    /// Left alone deliberately. Reserving a column for the number as well fixes it, but
    /// at 340pt the header has no budget for a fourth reserved column: measured, a 76pt
    /// value column truncated "Memory" to "Mem…" and a network rate to "2.4…". A number
    /// you cannot read is a worse trade than two traces a few points apart, and the
    /// numbers themselves — the thing being scanned — already share a right edge via
    /// `captionColumnWidth`.

    /// Reserved width for the process list's value column, sized for the widest
    /// reading it can hold ("412.6%", "4.3 GB") so the column never reflows as
    /// processes come and go.
    static let processValueWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            detail
                .padding(.horizontal, Design.Space.panelInset)
                .padding(.top, Design.Space.xxs)
        }
        .padding(.vertical, Design.Space.xxs)
        .environment(\.metricFormatter, formatter)
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggleCollapsed) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: "chevron.right")
                    .font(Design.Text.micro.weight(.semibold))
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Design.Space.m)
                Image(systemName: summary.icon ?? module.symbolName)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(iconColor)
                    .frame(width: Design.Space.xl)
                Text(module.label)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.s)
                trace
                headlineValue
            }
            .padding(.horizontal, Design.Space.panelInset)
            .contentShape(Rectangle())
            .background(hoverHighlight)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(module.label)
        .accessibilityValue(summary.value ?? "")
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder
    private var hoverHighlight: some View {
        RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            .fill(isHovering ? Design.Palette.track : .clear)
            .padding(.horizontal, Design.Space.s)
    }

    /// The header trace, drawn only while the module is expanded.
    ///
    /// Collapsed modules form a list, and a list only reads as one if its rows share a
    /// shape. Only some metrics have a chartable series, so drawing traces in the
    /// collapsed state gave GPU and Network a squiggle (and Network a "peak" caption)
    /// while Disk, Battery and Temperature had none — a ragged column that made the
    /// summary harder to scan than the numbers alone. Expanded, the trace has room and
    /// context, so it stays there.
    @ViewBuilder
    private var trace: some View {
        if isExpanded, let key = summary.series {
            let series = ChartSeries(key, from: engine.history, tint: traceTint)
            if series.stats.supportsTrend {
                Sparkline(series, settings: settings.settings.charts, height: Self.traceHeight)
                    .frame(width: Self.traceWidth)
            }
        }
    }

    @ViewBuilder
    private var headlineValue: some View {
        if let value = summary.value {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                if let symbol = summary.symbol {
                    Image(systemName: symbol)
                        .font(Design.Text.caption.weight(.semibold))
                        .foregroundStyle(Design.Palette.secondaryText)
                }
                Text(value)
                    .font(summary.emphasis == .measurement ? Design.Text.headline : Design.Text.value)
                    .foregroundStyle(Design.Palette.severityText(summary.severity))
                    .lineLimit(1)
                    .contentTransition(.numericText())
                // The qualifier sits in a reserved column so it cannot push the number.
                //
                // Inline, a caption shifted its value left by its own width, so across the
                // collapsed list the numbers ended at x = 254, 282, 285, 300, 323, 324 —
                // a 70pt ragged spread that made the column impossible to scan even though
                // the right edge looked tidy. Reserving the slot whether or not a caption
                // exists puts every number's right edge on the same line.
                Text(summary.caption ?? "")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .lineLimit(1)
                    .frame(width: Self.captionColumnWidth, alignment: .leading)
                    .accessibilityHidden(summary.caption == nil)
            }
        }
    }

    private func toggleCollapsed() {
        withAnimation(Design.Motion.respectingAccessibility(Design.Motion.disclosure)) {
            settings.update { s in
                if s.panel.collapsedModules.contains(module) {
                    s.panel.collapsedModules.remove(module)
                } else {
                    s.panel.collapsedModules.insert(module)
                }
            }
        }
    }

    // MARK: Summary

    private var summary: PanelSummary {
        switch module {
        case .cpu:
            guard let cpu = engine.cpu.value else { return PanelSummary() }
            return PanelSummary(value: formatter.percent(cpu.total.busy),
                                severity: .forUtilization(cpu.total.busy),
                                series: .cpuTotal)
        case .memory:
            guard let memory = engine.memory.value else { return PanelSummary() }
            return PanelSummary(value: formatter.memory(memory.usedBytes),
                                caption: "used",
                                severity: .forUtilization(memory.usedFraction),
                                series: .memoryUsed)
        case .gpu:
            guard let gpu = engine.gpu.value, let device = gpu.primary else { return PanelSummary() }
            guard let utilization = device.utilization else {
                return PanelSummary(value: device.name, emphasis: .state)
            }
            return PanelSummary(value: formatter.percent(utilization),
                                // Device identity belongs in the expanded detail: it is
                                // the only caption long enough to break the column.
                                caption: nil,
                                severity: .forUtilization(utilization),
                                series: .gpuUtilization)
        case .network:
            guard let network = engine.network.value else { return PanelSummary() }
            // The Wi-Fi row below already names the connection; the caption is only
            // needed when there is no signal row to carry it.
            return PanelSummary(value: formatter.networkRate(network.downloadBytesPerSecond),
                                caption: network.wifi == nil ? network.connectionType.label : nil,
                                symbol: "arrow.down",
                                series: .networkDownload)
        case .disk:
            guard let disk = engine.disk.value, let root = disk.rootVolume else { return PanelSummary() }
            let remaining = root.totalBytes > 0
                ? Double(root.availableBytes) / Double(root.totalBytes) : 0
            return PanelSummary(value: formatter.storage(root.availableBytes),
                                caption: "free",
                                severity: .forRemaining(remaining))
        case .battery:
            guard let power = engine.power.value else { return PanelSummary() }
            guard power.hasBattery, let percentage = power.percentage else {
                return PanelSummary(value: power.isPluggedIn ? "AC" : MetricFormatter.unavailable,
                                    icon: "powerplug",
                                    emphasis: .state)
            }
            return PanelSummary(value: formatter.percentValue(percentage),
                                caption: power.isCharging ? "charging" : nil,
                                severity: power.isCharging ? .normal : .forRemaining(percentage / 100))
        case .thermal:
            guard let thermal = engine.thermal.value else { return PanelSummary() }
            guard let celsius = thermal.cpuCelsius else {
                return PanelSummary(value: thermal.pressure.label,
                                    severity: Self.severity(of: thermal.pressure),
                                    emphasis: .state)
            }
            // No trace: charts here are drawn from a zero baseline, and on that axis a
            // die swinging 44–58 °C is a flat line four fifths of the way up. The
            // caption would be the only thing saying anything.
            return PanelSummary(value: formatter.temperature(celsius),
                                severity: .forTemperature(celsius))
        case .processes:
            guard let processes = engine.processes.value else { return PanelSummary() }
            return PanelSummary(value: formatter.count(processes.totalProcessCount),
                                caption: "running")
        case .system:
            guard let system = engine.system.value else { return PanelSummary() }
            return PanelSummary(value: formatter.uptime(system.uptime), caption: "uptime")
        }
    }

    /// Thermal pressure is its own scale; mapping it onto the shared severity ramp is
    /// what lets one colour language cover every module.
    static func severity(of pressure: ThermalPressure) -> MetricSeverity {
        switch pressure {
        case .nominal: return .normal
        case .fair: return .elevated
        case .serious: return .high
        case .critical: return .critical
        }
    }
}
