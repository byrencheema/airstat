import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AirStatKit

// MARK: - Sparkline

/// The compact history trace that sits beside a module's headline value.
///
/// Drawn in a single `Canvas` from the ring buffer directly: `SampleRing.values`
/// would allocate an array per module per frame, and the panel redraws for the whole
/// life of the session.
struct PanelSparkline: View {

    /// How the vertical axis is derived. A rate has no ceiling, so it scales to its
    /// own peak; a temperature never approaches zero, so scaling from zero would draw
    /// a flat line at the top and hide the shape entirely.
    enum Scale: Equatable {
        case unit
        case zeroToPeak
        case minToPeak
    }

    let ring: SampleRing
    let tint: Color
    let scale: Scale

    /// Beyond this the trace is drawn at sub-pixel resolution, so extra points cost
    /// time and buy nothing.
    private static let maximumPoints = 64

    var body: some View {
        GeometryReader { proxy in
            trace(in: proxy.size)
        }
        .accessibilityHidden(true)
    }

    /// Two shapes over one path build; see `PlotShape` for why this is not a `Canvas`.
    @ViewBuilder
    private func trace(in size: CGSize) -> some View {
        let bounds = verticalBounds
        if ring.count >= Design.Chart.minimumPoints, bounds.upper > bounds.lower {
            let line = linePath(in: size, bounds: bounds)
            ZStack {
                PlotShape(closing(line, in: size))
                    .fill(tint.opacity(Design.Chart.fillOpacity))
                PlotShape(line)
                    .stroke(tint, lineWidth: Design.Chart.lineWidth)
            }
        }
    }

    private func linePath(in size: CGSize, bounds: (lower: Double, upper: Double)) -> Path {
        let inset = Design.Chart.lineWidth / 2
        let usableHeight = max(size.height - inset * 2, 1)
        let step = max(1, ring.count / Self.maximumPoints)

        var indices: [Int] = []
        indices.reserveCapacity(Self.maximumPoints + 1)
        var index = 0
        while index < ring.count {
            indices.append(index)
            index += step
        }
        if indices.last != ring.count - 1 { indices.append(ring.count - 1) }

        let spacing = size.width / CGFloat(max(indices.count - 1, 1))
        var line = Path()
        for (position, sample) in indices.enumerated() {
            let normalized = (Double(ring[sample]) - bounds.lower) / (bounds.upper - bounds.lower)
            let clamped = min(max(normalized, 0), 1)
            let point = CGPoint(x: CGFloat(position) * spacing,
                                y: inset + usableHeight * (1 - clamped))
            position == 0 ? line.move(to: point) : line.addLine(to: point)
        }
        return line
    }

    private func closing(_ line: Path, in size: CGSize) -> Path {
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        return fill
    }

    private var verticalBounds: (lower: Double, upper: Double) {
        switch scale {
        case .unit:
            return (0, 1)
        case .zeroToPeak:
            return (0, max(Double(ring.maximum), .leastNormalMagnitude))
        case .minToPeak:
            let low = Double(ring.minimum)
            let high = Double(ring.maximum)
            // A dead-flat series would divide by zero; give it a band so it draws
            // as a centred horizontal rule rather than vanishing.
            return high - low < 0.001 ? (low - 1, high + 1) : (low, high)
        }
    }
}

// MARK: - Core strip

/// A core cluster shaped like a `PanelBarRow`: what it is, the cores, how busy they
/// are.
///
/// Wraps `CoreGrid` rather than drawing bars, but keeps the cluster on one line with
/// its own aggregate percentage — the panel cannot spend a second line on cluster
/// captions, and "the P-cores are pinned" is a claim that wants a number next to it.
struct PanelCoreRow: View {
    let label: String
    let loads: [CPULoad]
    let busy: Double?
    let tint: Color
    var labelWidth: CGFloat = 58

    @Environment(\.metricFormatter) private var formatter

    /// Vertical range for the fill, and the whole reason a core bar means anything.
    ///
    /// Measured, not guessed: rendering cores at exactly 25/50/75/100% at 12, 16, 20
    /// and 24pt, the 75% and 100% cells are not reliably separable below 20 at 1x. A
    /// shorter strip saves a few points of panel and gives up the magnitude it was
    /// drawn to convey.
    private static let stripHeight: CGFloat = 20

    /// Slot width, fixed rather than filling the row.
    ///
    /// `CoreGrid` divides whatever frame it gets among its cores, so a six-core row and
    /// a five-core row sharing the same width would draw noticeably different bar
    /// widths. Pinning the slot keeps a core the same size in both rows and lets the
    /// six-core strip run visibly longer, which is the truth about the machine.
    private static let slotWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(label)
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            CoreGrid(cores: loads, tint: tint, height: Self.stripHeight,
                     showsClusterLabels: false)
                .frame(width: CGFloat(loads.count) * Self.slotWidth)
            Spacer(minLength: Design.Space.m)
            Text(busy.map { formatter.percent($0) } ?? MetricFormatter.unavailable)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(loads.count) \(label)")
        .accessibilityValue(busy.map { formatter.percent($0) } ?? "")
    }
}

// MARK: - Composition bar

/// Legend for a composition bar, on the panel's two-column grid.
///
/// Four segments on one line only fit at 9pt, which is below the size a number should
/// ever be set at when the user is expected to read it. At 10pt they need two rows —
/// and on the same column rhythm as `PanelDetailGrid`, so the legend lines up with the
/// readouts under it instead of forming a third alignment.
///
/// The remainder segment is deliberately absent: it is drawn as bare track, and "the
/// empty part of the bar is the empty part" needs no swatch to explain it.
struct PanelSegmentLegend: View {
    let segments: [CompositionSegment]
    let format: ChartValueFormat

    @Environment(\.metricFormatter) private var formatter

    var body: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Space.xl,
             verticalSpacing: Design.Space.xxs) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { segment in
                        entry(segment).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if row.count == 1 { Color.clear.frame(height: 0) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func entry(_ segment: CompositionSegment) -> some View {
        HStack(spacing: Design.Space.xs) {
            RoundedRectangle(cornerRadius: Design.Space.hairline, style: .continuous)
                .fill(segment.tint)
                .frame(width: Design.Space.s, height: Design.Space.s)
            Text(segment.shortLabel)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
            Spacer(minLength: Design.Space.xs)
            Text(format.string(segment.value, using: formatter))
                .font(Design.Text.caption.monospacedDigit())
                .foregroundStyle(Design.Palette.primaryText)
        }
        .lineLimit(1)
    }

    private var visible: [CompositionSegment] { segments.filter { !$0.isRemainder } }

    private var rows: [[CompositionSegment]] {
        stride(from: 0, to: visible.count, by: 2).map { start in
            Array(visible[start..<min(start + 2, visible.count)])
        }
    }
}

// MARK: - Bar row

/// A readout whose value has a real maximum, with the bar inline rather than on its
/// own line — the panel cannot afford a second line for every gauge.
struct PanelBarRow: View {
    let label: String
    let value: String
    let fraction: Double
    let tint: Color
    /// Fixed so the bars of consecutive rows start at the same x and read as a column.
    var labelWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(label)
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
            CapacityBar(fraction: fraction, tint: tint)
            Text(value)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - Detail grid

struct PanelDetailEntry: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    var severity: MetricSeverity = .normal

    init(_ label: String, _ value: String, severity: MetricSeverity = .normal) {
        self.label = label
        self.value = value
        self.severity = severity
    }
}

/// Supporting detail in two columns. The panel is 340pt wide and a readout needs
/// about half of that, so pairing them halves the height of every module.
struct PanelDetailGrid: View {
    let entries: [PanelDetailEntry]

    var body: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Space.xl,
             verticalSpacing: Design.Space.xxs) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { entry in
                        ReadoutRow(entry.label, entry.value, severity: entry.severity)
                            .frame(maxWidth: .infinity)
                    }
                    // Keeps a trailing odd entry in the left column instead of
                    // letting it stretch across both.
                    if row.count == 1 { Color.clear.frame(height: 0) }
                }
            }
        }
    }

    private var rows: [[PanelDetailEntry]] {
        stride(from: 0, to: entries.count, by: 2).map { start in
            Array(entries[start..<min(start + 2, entries.count)])
        }
    }
}

// MARK: - Process icons

/// What to draw beside a process name.
enum PanelProcessIcon {
    case bundle(NSImage)
    /// No bundle to take an icon from — most processes, since launchd, logd and
    /// WindowServer are plain executables.
    case executable
}

/// Icons for the process list.
///
/// Every row resolves to something, so the list has one left edge. Half the rows
/// carrying an icon and half not is worse than either choice made consistently.
///
/// `NSWorkspace.icon(forFile:)` stats the bundle, so it is resolved once per
/// executable path and never again — including the misses, so a daemon does not
/// re-hit the filesystem every time the panel redraws.
@MainActor
enum PanelAppIcon {
    private static var cache: [String: PanelProcessIcon] = [:]

    /// The cache is keyed by executable path, and the set of paths a long session sees
    /// is not the set of apps installed: every build tool, helper and short-lived daemon
    /// that ever reached the top of the process list adds one and nothing ever took one
    /// away. 224 icons measured at 3.1 MB of dirty heap, so an uncapped cache is real
    /// growth over a day of uptime. Flushed wholesale rather than evicted one at a time —
    /// the next panel redraw re-resolves only the dozen rows it actually shows, and that
    /// is cheaper than tracking use counts for the life of the process.
    private static let cacheLimit = 512

    static func icon(for process: ProcessRow) -> PanelProcessIcon {
        guard let path = process.executablePath else { return .executable }
        if let cached = cache[path] { return cached }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        let resolved: PanelProcessIcon
        if let bundle = bundlePath(for: path), FileManager.default.fileExists(atPath: bundle) {
            resolved = .bundle(NSWorkspace.shared.icon(forFile: bundle))
        } else {
            resolved = .executable
        }
        cache[path] = resolved
        return resolved
    }

    /// The enclosing app bundle: "/Applications/Claude.app/Contents/Frameworks/Claude"
    /// → "/Applications/Claude.app".
    ///
    /// A running process's executable is almost never the bundle itself — it lives
    /// several directories inside one — so testing the path for a ".app" suffix
    /// resolves nothing on a real machine. Taking the first ".app" component also gets
    /// helpers right: Safari's XPC services correctly show Safari's icon.
    private static func bundlePath(for path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }
}
