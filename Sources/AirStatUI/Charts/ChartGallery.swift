import SwiftUI
import AirStatKit

/// Every chart component on one surface, driven by fixture data.
///
/// A chart library is only as good as the states it survives, and the states that
/// break charts — a two-sample series, no series at all, a rate that peaked at
/// 118 MB/s next to one that peaked at 2 KB/s — are tedious to stage inside the panel.
/// This composes them all at once so they can be rendered offscreen and looked at.
public struct ChartGallery: View {
    private let snapshot: SystemSnapshot
    private let history: MetricHistory
    private let settings: ChartSettings

    public init(snapshot: SystemSnapshot,
                history: MetricHistory,
                settings: ChartSettings = ChartSettings()) {
        self.snapshot = snapshot
        self.history = history
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            section("Sparkline · styles") {
                ForEach(ChartStyle.allCases, id: \.self) { style in
                    labelled(style.label) {
                        Sparkline(cpuSeries, settings: settings.with(style: style))
                    }
                }
            }

            section("Sparkline · adaptive rate scale") {
                labelled("Download") {
                    Sparkline(ChartSeries(.networkDownload, from: history,
                                          tint: Design.Palette.metric(.network)),
                              settings: settings)
                }
                labelled("Disk read") {
                    Sparkline(ChartSeries(.diskRead, from: history,
                                          tint: Design.Palette.metric(.disk)),
                              settings: settings)
                }
            }

            section("Sparkline · constrained width") {
                HStack(spacing: Design.Space.l) {
                    ForEach([CGFloat(52), 68, 96], id: \.self) { width in
                        Sparkline(ChartSeries(.networkDownload, from: history,
                                              tint: Design.Palette.metric(.network)),
                                  settings: settings)
                            .frame(width: width)
                    }
                    Spacer(minLength: 0)
                }
            }

            section("Sparkline · sparse and empty") {
                labelled("2 samples") {
                    Sparkline(sparseSeries, settings: settings)
                }
                labelled("no history") {
                    Sparkline(emptySeries, settings: settings)
                }
            }

            section("Sparkline · domain edges") {
                labelled("pegged") {
                    Sparkline(peggedSeries, settings: settings)
                }
                labelled("near zero") {
                    Sparkline(floorSeries, settings: settings)
                }
            }

            section("Detail · pegged at 100%") {
                DetailChart(peggedSeries, settings: settings, title: "Pegged")
            }

            section("Detail chart") {
                DetailChart(cpuSeries, settings: settings, title: "CPU")
                DetailChart([ChartSeries(.networkDownload, from: history,
                                         tint: Design.Palette.metric(.network), label: "Down"),
                             ChartSeries(.networkUpload, from: history,
                                         tint: Design.Palette.metric(.gpu), label: "Up")],
                            settings: settings, title: "Network")
                DetailChart(emptySeries, settings: settings, title: "Pending")
            }

            section("Composition") {
                MetricContent(snapshot.memory) { memory in
                    StackedCompositionBar(Self.memorySegments(memory),
                                          format: .memoryBytes, title: "Memory composition")
                }
                MetricContent(snapshot.disk) { disk in
                    if let volume = disk.volumes.first(where: \.isRoot) {
                        StackedCompositionBar(Self.diskSegments(volume),
                                              format: .storageBytes, title: "Disk composition")
                    }
                }
            }

            section("Temperature · zero baseline vs stated band") {
                labelled("0…peak") {
                    Sparkline(ChartSeries(.cpuTemperature, from: history,
                                          tint: Design.Palette.metric(.thermal)),
                              settings: settings)
                }
                labelled("30…100°") {
                    Sparkline(bandedTemperature, settings: settings)
                }
                DetailChart(bandedTemperature, settings: settings, title: "CPU temperature")
            }

            section("Cores") {
                MetricContent(snapshot.cpu) { cpu in
                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        CoreGrid(cpu)
                        // Half width: the cluster must still read as a cluster rather
                        // than dissolving into gaps.
                        CoreGrid(cpu).frame(width: 170)
                    }
                }
            }

            section("Gauges") {
                HStack(spacing: Design.Space.xl) {
                    MetricContent(snapshot.cpu) { cpu in
                        MetricGauge(fraction: cpu.total.busy,
                                    tint: Design.Palette.metric(.cpu),
                                    label: "CPU usage",
                                    caption: MetricFormatter().percent(cpu.total.busy))
                    }
                    MetricContent(snapshot.memory) { memory in
                        MetricGauge(fraction: memory.pressureFraction,
                                    tint: Design.Palette.metric(.memory),
                                    label: "Memory pressure",
                                    caption: MetricFormatter().percent(memory.pressureFraction),
                                    style: .arc)
                    }
                    // A desktop reports no percentage at all, and a gauge reading zero
                    // would be a fabricated value rather than an absent one.
                    MetricContent(snapshot.power) { power in
                        if let percentage = power.percentage {
                            MetricGauge(fraction: percentage / 100,
                                        tint: Design.Palette.metric(.power),
                                        label: "Battery",
                                        caption: MetricFormatter().percentValue(percentage))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Design.Space.panelInset)
    }

    // MARK: Series

    private var cpuSeries: ChartSeries {
        ChartSeries(.cpuTotal, from: history, tint: Design.Palette.metric(.cpu))
    }

    /// Two samples: enough to draw a straight line between, which is exactly the
    /// trend the app must refuse to imply.
    private var sparseSeries: ChartSeries {
        var ring = SampleRing(capacity: history.capacity)
        ring.append(0.21)
        ring.append(0.58)
        return ChartSeries(key: .cpuTotal, samples: ring,
                           tint: Design.Palette.metric(.cpu),
                           span: 2 * history.sampleInterval)
    }

    /// Runs of exactly 1.0 with dips between them. Two things must survive this: the
    /// stroke at the top of the domain must not be sliced by the frame, and the
    /// smoothing must not arc above 100 % on the way out of a plateau.
    private var peggedSeries: ChartSeries {
        var ring = SampleRing(capacity: 120)
        for index in 0..<120 {
            let phase = Double(index) / 12
            ring.append(phase.truncatingRemainder(dividingBy: 2) < 1.2 ? 1.0 : 0.34)
        }
        return ChartSeries(key: .cpuTotal, samples: ring,
                           tint: Design.Palette.metric(.cpu), span: 240)
    }

    /// Values just above zero: the baseline equivalent of the pegged case.
    private var floorSeries: ChartSeries {
        var ring = SampleRing(capacity: 120)
        for index in 0..<120 {
            ring.append(index % 17 == 0 ? 0.02 : 0)
        }
        return ChartSeries(key: .cpuTotal, samples: ring,
                           tint: Design.Palette.metric(.cpu), span: 240)
    }

    /// The same samples as the row above it, against a stated band instead of zero.
    /// 30 °C is below anything a running Mac reports and 100 °C is where it throttles,
    /// so the band is a fact about the hardware rather than a fit to the window.
    private var bandedTemperature: ChartSeries {
        ChartSeries(.cpuTemperature, from: history,
                    tint: Design.Palette.metric(.thermal), domain: 30...100)
    }

    private var emptySeries: ChartSeries {
        ChartSeries(key: .cpuTotal, samples: SampleRing(capacity: 2),
                    tint: Design.Palette.metric(.cpu), span: 0)
    }

    // MARK: Segments

    public static func memorySegments(_ memory: MemorySnapshot) -> [CompositionSegment] {
        let tint = Design.Palette.metric(.memory)
        let shades = ChartPalette.composition(tint, count: 4)
        return [
            CompositionSegment(id: "app", label: "App", value: Double(memory.appBytes),
                               tint: shades[0]),
            CompositionSegment(id: "wired", label: "Wired", value: Double(memory.wiredBytes),
                               tint: shades[1]),
            CompositionSegment(id: "compressed", label: "Compressed", shortLabel: "Comp",
                               value: Double(memory.compressedBytes), tint: shades[2]),
            CompositionSegment(id: "cached", label: "Cached", value: Double(memory.cachedBytes),
                               tint: shades[3]),
            CompositionSegment(id: "free", label: "Free", value: Double(memory.freeBytes),
                               tint: Design.Palette.track, isRemainder: true),
        ]
    }

    public static func diskSegments(_ volume: VolumeInfo) -> [CompositionSegment] {
        let tint = Design.Palette.metric(.disk)
        let shades = ChartPalette.composition(tint, count: 2)
        // Purgeable space is already counted as used by the filesystem, so it is
        // subtracted out rather than added on; the three segments sum to the total.
        let purgeable = min(volume.purgeableBytes, volume.totalBytes - volume.freeBytes)
        let used = volume.totalBytes - volume.freeBytes - purgeable
        return [
            CompositionSegment(id: "used", label: "Used", value: Double(used), tint: shades[0]),
            CompositionSegment(id: "purgeable", label: "Purgeable", shortLabel: "Purge",
                               value: Double(purgeable), tint: shades[1]),
            CompositionSegment(id: "free", label: "Free", value: Double(volume.freeBytes),
                               tint: Design.Palette.track, isRemainder: true),
        ]
    }

    // MARK: Chrome

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            SwiftUI.Text(title.uppercased())
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
            content()
        }
    }

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Design.Space.l) {
            SwiftUI.Text(title)
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: 68, alignment: .leading)
            content()
        }
    }
}

extension ChartSettings {
    /// Convenience for exercising one setting at a time.
    func with(style: ChartStyle) -> ChartSettings {
        var copy = self
        copy.style = style
        return copy
    }
}
