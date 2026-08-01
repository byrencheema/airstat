import SwiftUI
import AirStatKit

/// Per-core utilisation, grouped by core kind.
///
/// This machine has 11 cores — 6 efficiency, 5 performance — and the question it is
/// asked is always the same one: *which* of them are busy. So the cores are drawn as
/// bars that fill from the bottom, clustered by kind with a gap between the clusters,
/// which turns "the P-cores are pinned and the E-cores are idle" into a shape you
/// recognise before you have read a single number.
public struct CoreGrid: View {
    private let cores: [CPULoad]
    private let kinds: [CoreKind]
    private let tint: Color
    private let height: CGFloat
    private let showsClusterLabels: Bool

    @Environment(\.metricFormatter) private var formatter

    public init(cores: [CPULoad],
                kinds: [CoreKind] = [],
                tint: Color = Design.Palette.metric(.cpu),
                height: CGFloat = 26,
                showsClusterLabels: Bool = true) {
        self.cores = cores
        self.kinds = kinds
        self.tint = tint
        self.height = height
        self.showsClusterLabels = showsClusterLabels
    }

    public init(_ snapshot: CPUSnapshot,
                tint: Color = Design.Palette.metric(.cpu),
                height: CGFloat = 26,
                showsClusterLabels: Bool = true) {
        self.init(cores: snapshot.perCore, kinds: snapshot.coreKinds,
                  tint: tint, height: height, showsClusterLabels: showsClusterLabels)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: context, size: size)
            }
            .frame(height: height)
            if showsClusterLabels && !clusters.isEmpty {
                clusterLabels
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Per-core CPU utilisation")
        .accessibilityValue(accessibilityValue)
    }

    /// Contiguous runs of one core kind. Built from the collector's own ordering
    /// rather than assumed, so a machine that reports P-cores first still groups.
    private var clusters: [(kind: CoreKind, range: Range<Int>)] {
        guard !cores.isEmpty else { return [] }
        guard kinds.count == cores.count else {
            return [(.unknown, 0..<cores.count)]
        }
        var result: [(CoreKind, Range<Int>)] = []
        var start = 0
        for index in 1...cores.count {
            if index == cores.count || kinds[index] != kinds[start] {
                result.append((kinds[start], start..<index))
                start = index
            }
        }
        return result
    }

    /// The widest a gap between cores is allowed to get.
    ///
    /// Capping the *bar* instead was wrong: six cores across 190pt gave 32pt slots, a
    /// 12pt bar and 20pt of air between each, which reads as a dashed line rather than
    /// a cluster. Capping the gap makes the bars absorb whatever width is going, so the
    /// grid fills its frame at any size.
    private static let maximumGap: CGFloat = 6

    private func draw(in context: GraphicsContext, size: CGSize) {
        var context = context
        let groups = clusters
        guard !groups.isEmpty, size.width > 0 else { return }

        // Lay out in slot units: one slot per core plus a gap slot between clusters,
        // so the cluster break scales with the bars instead of being a magic number.
        let gaps = CGFloat(max(groups.count - 1, 0))
        let slotWidth = size.width / (CGFloat(cores.count) + gaps * 0.6)
        let barWidth = max(slotWidth - min(slotWidth * 0.28, Self.maximumGap), 2)
        let radius = min(barWidth / 2, Design.Radius.bar)

        var tracks = Path()
        var fills = Path()
        var x: CGFloat = 0

        for (groupIndex, group) in groups.enumerated() {
            for index in group.range {
                let busy = min(max(cores[index].busy, 0), 1)
                let left = x + (slotWidth - barWidth) / 2
                tracks.addRoundedRect(in: CGRect(x: left, y: 0, width: barWidth, height: size.height),
                                      cornerSize: CGSize(width: radius, height: radius))
                // Same rule as everywhere else in the app: a busy core is never
                // invisible, so a 1 % core still shows a sliver above the floor.
                let filled = max(size.height * CGFloat(busy), busy > 0 ? Design.Space.xxs : 0)
                if filled > 0 {
                    fills.addRect(CGRect(x: left, y: size.height - filled,
                                         width: barWidth, height: filled))
                }
                x += slotWidth
            }
            if groupIndex < groups.count - 1 { x += slotWidth * 0.6 }
        }

        context.fill(tracks, with: .color(Design.Palette.track))
        // The fills are plain rectangles clipped to the tracks, so a part-filled core
        // takes the track's rounded floor and gets a flat top — it reads as a column
        // filling up rather than as a separate lozenge floating inside a slot.
        context.clip(to: tracks)
        context.fill(fills, with: .color(tint))
    }

    private var clusterLabels: some View {
        HStack(spacing: Design.Space.l) {
            ForEach(Array(clusters.enumerated()), id: \.offset) { _, group in
                SwiftUI.Text(Self.clusterLabel(group.kind, count: group.range.count))
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private static func clusterLabel(_ kind: CoreKind, count: Int) -> String {
        switch kind {
        case .efficiency: return "\(count) efficiency"
        case .performance: return "\(count) performance"
        case .unknown: return "\(count) cores"
        }
    }

    /// A screen reader gets the shape as numbers: per-cluster averages plus the
    /// busiest single core, which is what the picture is actually saying.
    private var accessibilityValue: String {
        guard !cores.isEmpty else { return "No per-core data" }
        var parts: [String] = []
        for group in clusters {
            let slice = cores[group.range]
            let average = slice.reduce(0.0) { $0 + $1.busy } / Double(slice.count)
            parts.append("\(Self.clusterLabel(group.kind, count: slice.count))"
                         + " averaging \(formatter.percent(average))")
        }
        let busiest = cores.reduce(0.0) { max($0, $1.busy) }
        parts.append("busiest core \(formatter.percent(busiest))")
        return parts.joined(separator: ", ") + "."
    }
}
