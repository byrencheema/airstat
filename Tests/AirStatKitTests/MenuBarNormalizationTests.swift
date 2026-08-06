import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// The menu bar's graph series, checked value for value against the straightforward
/// spelling of the same arithmetic.
///
/// `MenuBarRenderModel` normalises history in one pass over one buffer rather than
/// walking the ring for a peak and then mapping the samples into a second array. That
/// is a pure speed change: it is supposed to draw the identical graph. The reference
/// below is the obvious two-allocation form, kept here on purpose so any future
/// rearrangement of the fast path has something to be wrong against.
@Suite("Menu bar normalisation is the same arithmetic, done once")
struct MenuBarNormalizationTests {

    // MARK: Reference

    /// Normalisation written the slow, obvious way: copy the samples, walk the ring
    /// again for the peak, map into a fresh array.
    private func reference(_ history: MetricHistory, _ key: SeriesKey) -> [Float] {
        let ring = history[key]
        guard ring.count > 1 else { return [] }
        let values = ring.values
        if key.isNormalized {
            return values.map { min(max($0, 0), 1) }
        }
        let peak = max(ring.maximum, .leastNonzeroMagnitude)
        return values.map { min(max($0 / peak, 0), 1) }
    }

    /// The paired form: both series against one shared peak.
    private func referencePair(_ history: MetricHistory,
                               _ first: SeriesKey,
                               _ second: SeriesKey) -> ([Float], [Float]) {
        let a = history[first]
        let b = history[second]
        guard a.count > 1 || b.count > 1 else { return ([], []) }
        let peak = max(max(a.maximum, b.maximum), .leastNonzeroMagnitude)
        let scale = { (values: [Float]) in values.map { min(max($0 / peak, 0), 1) } }
        return (scale(a.values), scale(b.values))
    }

    // MARK: Fixtures

    private func history(capacity: Int, samples: [SeriesKey: [Double]]) -> MetricHistory {
        var history = MetricHistory(capacity: capacity, sampleInterval: 2)
        let longest = samples.values.map(\.count).max() ?? 0
        for index in 0..<longest {
            for (key, values) in samples where index < values.count {
                history.record(key, values[index])
            }
        }
        return history
    }

    /// The series the model actually hands the drawing code, for one enabled metric.
    private func drawn(_ metric: MenuBarMetric, _ history: MetricHistory) -> (MenuBarLine, MenuBarLine?) {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: metric, style: .textAndGraph)]
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: history,
                                       settings: settings,
                                       isStale: false)
        let item = model.items[0]
        return (item.primary, item.secondary)
    }

    // MARK: Unbounded series

    /// The ring has not wrapped yet: the samples are contiguous and in order.
    @Test("an unwrapped ring normalises exactly as the two-pass form does")
    func unwrappedRing() {
        let samples = (0..<50).map { 400 + sin(Double($0) / 3) * 2_600 }
        let history = history(capacity: 1802, samples: [.fanRPM: samples])

        let series = drawn(.fanSpeed, history).0.series
        #expect(series == reference(history, .fanRPM))
        #expect(series.count == 50)
        // Not vacuously equal: an unbounded series is supposed to reach its own peak.
        #expect(series.max() == 1)
    }

    /// The steady state after an hour of uptime: the ring is full, so its samples wrap
    /// and the oldest one is no longer at index zero.
    @Test("a wrapped, full ring normalises exactly as the two-pass form does")
    func wrappedRing() {
        let samples = (0..<200).map { abs(sin(Double($0) / 7)) * 90 }
        let history = history(capacity: 64, samples: [.systemWatts: samples])
        #expect(history[.systemWatts].count == 64)

        let series = drawn(.systemPower, history).0.series
        #expect(series == reference(history, .systemWatts))
        #expect(series.count == 64)
    }

    /// An idle fan, or any unbounded metric before anything happens. The peak is zero,
    /// so the divisor is the floor the code substitutes rather than a division by zero.
    @Test("an all-zero series stays zero rather than turning into NaN")
    func allZeroRing() {
        let history = history(capacity: 32, samples: [.fanRPM: Array(repeating: 0, count: 40)])

        let series = drawn(.fanSpeed, history).0.series
        #expect(series == reference(history, .fanRPM))
        #expect(series.count == 32)
        #expect(series.allSatisfy { $0 == 0 })
    }

    /// Below zero is not meaningful on a graph that starts at its baseline, and the
    /// clamp is what keeps a discharging battery from drawing off the bottom of the box.
    @Test("negative samples clamp to the baseline")
    func negativeSamples() {
        let samples = (0..<40).map { Double($0) - 20 }
        let history = history(capacity: 1802, samples: [.systemWatts: samples])

        let series = drawn(.systemPower, history).0.series
        #expect(series == reference(history, .systemWatts))
        #expect(series.prefix(20).allSatisfy { $0 == 0 })
    }

    // MARK: Bounded series

    /// Fractions are already 0...1, so they are clamped and not rescaled: a CPU sitting
    /// at 20% must draw a fifth of the box, not a full one.
    @Test("a bounded series is clamped, never stretched to its own peak")
    func boundedSeriesIsNotRescaled() {
        let samples = Array(repeating: 0.2, count: 30)
        let history = history(capacity: 1802, samples: [.cpuTotal: samples])

        let series = drawn(.cpuUsage, history).0.series
        #expect(series == reference(history, .cpuTotal))
        #expect(series.allSatisfy { $0 == 0.2 })
    }

    // MARK: Paired series

    /// Down and up share one scale. Normalising each to its own peak would make a
    /// trickle of upload look identical to a saturated link, which is the whole reason
    /// the joint form exists.
    @Test("a paired metric scales both series against their shared peak")
    func pairSharesItsPeak() {
        let down = (0..<120).map { abs(sin(Double($0) / 9)) * 40_000_000 }
        let up = (0..<120).map { abs(sin(Double($0) / 9)) * 400_000 }
        let history = history(capacity: 64, samples: [.networkDownload: down, .networkUpload: up])

        let (primary, secondary) = drawn(.networkThroughput, history)
        let expected = referencePair(history, .networkDownload, .networkUpload)
        #expect(primary.series == expected.0)
        #expect(secondary?.series == expected.1)

        // The property the shared peak buys: the quiet side stays visibly quiet.
        #expect(primary.series.max() == 1)
        #expect((secondary?.series.max() ?? 1) < 0.02)
    }

    /// One direction silent is the common case on a download, and it must not rescale
    /// the silent side up to fill its half of the box.
    @Test("a pair with one silent side keeps the silent side flat")
    func pairWithOneSilentSide() {
        let down = (0..<80).map { 1_000_000 + Double($0) * 1_000 }
        let history = history(capacity: 64, samples: [.networkDownload: down,
                                                      .networkUpload: Array(repeating: 0, count: 80)])

        let (primary, secondary) = drawn(.networkThroughput, history)
        let expected = referencePair(history, .networkDownload, .networkUpload)
        #expect(primary.series == expected.0)
        #expect(secondary?.series == expected.1)
        #expect(secondary?.series.allSatisfy { $0 == 0 } == true)
    }

    /// A ring holding one sample draws nothing: a graph needs two points to be a line,
    /// and the drawing code checks the count it is given.
    @Test("a single sample produces no series at all")
    func singleSampleIsNoSeries() {
        let history = history(capacity: 1802, samples: [.fanRPM: [1_500]])
        #expect(drawn(.fanSpeed, history).0.series.isEmpty)
        #expect(reference(history, .fanRPM).isEmpty)
    }
}
