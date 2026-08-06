import Testing
@testable import AirStatKit
@testable import AirStatUI

/// The aggregates and `resized` no longer read through `subscript`; they walk the one
/// or two contiguous runs the samples occupy. That is the same arithmetic done in a
/// different place, so these tests pin the answers against a plain `values` walk at
/// every fill level, including the wrap boundaries where a run is empty.
@Suite("SampleRing contiguous walk")
struct SampleRingWalkTests {

    /// Fills a ring of `capacity` with `appends` samples and returns it alongside the
    /// samples it should be holding, oldest-to-newest.
    private static func ring(capacity: Int, appends: Int) -> (SampleRing, [Float]) {
        var ring = SampleRing(capacity: capacity)
        for i in 0..<appends { ring.append(Float(i) * 0.5 - 3) }
        let all = (0..<appends).map { Float($0) * 0.5 - 3 }
        return (ring, Array(all.suffix(capacity)))
    }

    @Test("runs concatenate to oldest-to-newest at every fill level",
          arguments: [0, 1, 4, 7, 8, 9, 15, 16, 17, 100])
    func runsMatchValues(appends: Int) {
        let (ring, expected) = Self.ring(capacity: 8, appends: appends)
        #expect(ring.values == expected)

        let walked = ring.withUnsafeRuns { older, newer in
            Array(older) + Array(newer)
        }
        #expect(walked == expected)
        #expect(walked.count == ring.count)
        #expect((0..<ring.count).map { ring[$0] } == expected)
    }

    @Test("aggregates agree with the same arithmetic over values",
          arguments: [0, 1, 4, 7, 8, 9, 15, 16, 17, 100])
    func aggregates(appends: Int) {
        let (ring, expected) = Self.ring(capacity: 8, appends: appends)
        guard !expected.isEmpty else {
            #expect(ring.maximum == 0)
            #expect(ring.minimum == 0)
            #expect(ring.average == 0)
            #expect(ring.last == nil)
            return
        }
        #expect(ring.maximum == expected.max())
        #expect(ring.minimum == expected.min())
        #expect(ring.average == expected.reduce(0, +) / Float(expected.count))
        #expect(ring.last == expected.last)
    }

    @Test("resize keeps the newest samples whether or not the ring has wrapped",
          arguments: [2, 5, 8, 13])
    func resizeKeepsNewest(newCapacity: Int) {
        for appends in [0, 3, 8, 21] {
            var (ring, expected) = Self.ring(capacity: 8, appends: appends)
            let resized = ring.resized(to: newCapacity)
            #expect(resized.capacity == newCapacity)
            #expect(resized.values == Array(expected.suffix(newCapacity)),
                    "capacity \(newCapacity) after \(appends) appends")
        }
    }

    @Test("a wrapped ring survives a resize that drops part of its first run")
    func resizeAcrossTheWrap() {
        // head lands mid-storage, so the older run is 5 long and the newer 3, and
        // keeping 6 has to drop 2 from the older run and take all of the newer.
        var ring = SampleRing(capacity: 8)
        for i in 0..<11 { ring.append(Float(i)) }
        #expect(ring.values == [3, 4, 5, 6, 7, 8, 9, 10])
        #expect(ring.resized(to: 6).values == [5, 6, 7, 8, 9, 10])
    }

    @Test("clearing and refilling still reads in order")
    func clearedRingRefills() {
        var ring = SampleRing(capacity: 4)
        for i in 0..<7 { ring.append(Float(i)) }
        ring.removeAll()
        #expect(ring.values.isEmpty)
        #expect(ring.withUnsafeRuns { older, newer in older.count + newer.count } == 0)
        for i in 0..<3 { ring.append(Float(100 + i)) }
        #expect(ring.values == [100, 101, 102])
    }

    @Test("one sample is one run of one")
    func singleSample() {
        var ring = SampleRing(capacity: 8)
        ring.append(Float(4.5))
        let (older, newer) = ring.withUnsafeRuns { (Array($0), Array($1)) }
        #expect(older == [4.5])
        #expect(newer.isEmpty)
        #expect(ring.maximum == 4.5)
        #expect(ring.minimum == 4.5)
        #expect(ring.average == 4.5)
        #expect(ring.last == 4.5)
        #expect(ring[0] == 4.5)
    }

    @Test("at exactly capacity the ring is one full run, and one more append splits it")
    func wrapBoundary() {
        var ring = SampleRing(capacity: 4)
        for i in 1...4 { ring.append(Float(i)) }
        var runs = ring.withUnsafeRuns { (Array($0), Array($1)) }
        #expect(runs.0 == [1, 2, 3, 4])
        #expect(runs.1.isEmpty, "head is back at 0, so nothing belongs to the second run")
        #expect(ring.values == [1, 2, 3, 4])
        #expect(ring.minimum == 1)
        #expect(ring.maximum == 4)
        #expect(ring.average == 2.5)
        #expect(ring.last == 4)

        ring.append(Float(5))
        runs = ring.withUnsafeRuns { (Array($0), Array($1)) }
        #expect(runs.0 == [2, 3, 4])
        #expect(runs.1 == [5])
        #expect(ring.values == [2, 3, 4, 5])
        #expect(ring.average == 3.5)
        #expect(ring.last == 5)
    }

    /// `ChartStats` walks the runs too. Its numbers feed axis labels and the spoken
    /// accessibility summary, so they have to stay bit-identical to the walk they
    /// replaced: same order of accumulation, same `Float`-to-`Double` widening.
    @Test("ChartStats matches the same arithmetic done over values",
          arguments: [0, 1, 7, 8, 9, 100])
    func chartStatsParity(appends: Int) {
        let (ring, expected) = Self.ring(capacity: 8, appends: appends)
        let stats = ChartStats(ring)
        #expect(stats.count == expected.count)
        guard !expected.isEmpty else {
            #expect(stats.minimum == 0)
            #expect(stats.maximum == 0)
            #expect(stats.average == 0)
            #expect(stats.last == nil)
            #expect(stats.isEmpty)
            return
        }
        let widened = expected.map(Double.init)
        #expect(stats.minimum == widened.min())
        #expect(stats.maximum == widened.max())
        #expect(stats.average == widened.reduce(0, +) / Double(widened.count))
        #expect(stats.last == widened.last)
    }

    @Test("history resize and clear touch every series")
    func historyWideOperations() {
        var history = MetricHistory(capacity: 8, sampleInterval: 1)
        for i in 0..<20 {
            for key in SeriesKey.allCases { history.record(key, Double(i)) }
        }
        history.resize(to: 4)
        #expect(history.capacity == 4)
        for key in SeriesKey.allCases {
            #expect(history[key].capacity == 4)
            #expect(history[key].values == [16, 17, 18, 19])
        }

        history.clear()
        for key in SeriesKey.allCases { #expect(history[key].count == 0) }
    }
}
