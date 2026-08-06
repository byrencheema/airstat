import Testing
import Foundation

/// Marks the timing benchmarks so they can be run or skipped as a group:
///
///     swift test --filter Performance          # just these
///     swift test --skip Performance            # everything else
///
/// They are ordinary tests rather than a separate tool because a benchmark nobody
/// runs is a benchmark that silently stops compiling.
extension Tag {
    @Tag static var performance: Self
}

/// A measured benchmark result. Times are per iteration.
struct BenchmarkResult {
    let name: String
    let iterations: Int
    /// Fastest iteration observed.
    ///
    /// The headline figure, not the mean. Benchmark noise on a machine with other
    /// work on it is one-sided: scheduling, interrupts and thermal drift can only
    /// ever make an iteration slower, never faster. So the minimum is the closest
    /// thing to the cost of the code itself, and it is far steadier across runs than
    /// any average, which is what keeps these assertions from flaking.
    let fastest: Duration
    /// Middle iteration, kept as the sanity check on the minimum: a median far above
    /// the minimum means the machine was busy, not that the code is slow.
    let median: Duration

    var fastestNanoseconds: Double { Self.nanoseconds(fastest) }
    var medianNanoseconds: Double { Self.nanoseconds(median) }

    static func nanoseconds(_ d: Duration) -> Double {
        let (seconds, attoseconds) = d.components
        return Double(seconds) * 1e9 + Double(attoseconds) * 1e-9
    }

    /// Reads as "12.4 µs" rather than as a raw attosecond pair.
    static func describe(_ nanos: Double) -> String {
        if nanos < 1_000 { return String(format: "%.0f ns", nanos) }
        if nanos < 1_000_000 { return String(format: "%.1f µs", nanos / 1_000) }
        return String(format: "%.2f ms", nanos / 1_000_000)
    }

    var summary: String {
        "\(name): \(Self.describe(fastestNanoseconds)) fastest, "
            + "\(Self.describe(medianNanoseconds)) median, over \(iterations) iterations"
    }
}

enum Benchmark {

    /// Runs `body` `iterations` times after `warmup` untimed runs and reports the
    /// per-iteration cost.
    ///
    /// The warmup exists because the first run of anything here pays for one-time
    /// work that is not what is being measured: lazily-allocated ring storage, the
    /// first `NumberFormatter` touch, and the dirtying of pages the allocator has
    /// only just handed over.
    static func measure(_ name: String,
                        iterations: Int = 50,
                        warmup: Int = 5,
                        body: () -> Void) -> BenchmarkResult {
        for _ in 0..<warmup { body() }

        var samples: [Duration] = []
        samples.reserveCapacity(iterations)
        let clock = ContinuousClock()
        for _ in 0..<iterations {
            samples.append(clock.measure(body))
        }
        samples.sort()
        return BenchmarkResult(name: name,
                               iterations: iterations,
                               fastest: samples[0],
                               median: samples[samples.count / 2])
    }

    /// Stops the optimiser deleting work whose result nothing reads.
    ///
    /// Every benchmark body here ends by feeding its result through this. Without it
    /// a release build is entitled to notice that, say, a `ChartStats` is constructed
    /// and never looked at, delete the whole loop, and report a benchmark that runs
    /// in no time at all.
    ///
    /// `withExtendedLifetime` behind an opaque call, rather than storing into a global:
    /// a global store would need the value boxed, and boxing allocates inside the timed
    /// loop, which is exactly the cost these benchmarks are trying to attribute.
    @inline(never)
    static func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }
}

/// Asserts a benchmark came in under budget, and always reports what it measured.
///
/// The budgets in this suite are regression tripwires, not specifications. They are
/// set well above the measured cost on the development machine, because a CI box or a
/// laptop with a build running is entitled to be several times slower and a benchmark
/// that fails for that reason teaches everyone to ignore it. What they catch is the
/// change that makes something an order of magnitude worse, which is the failure that
/// actually reaches users.
func expectWithinBudget(_ result: BenchmarkResult,
                        nanoseconds budget: Double,
                        sourceLocation: SourceLocation = #_sourceLocation) {
    let measured = result.fastestNanoseconds
    let ratio = measured / budget
    perfLog("\(result.summary) [budget \(BenchmarkResult.describe(budget)), "
            + String(format: "%.0f%% used]", ratio * 100))
    let message = "\(result.name) took \(BenchmarkResult.describe(measured)), "
        + "over its \(BenchmarkResult.describe(budget)) budget"
    #expect(measured < budget,
            Comment(rawValue: message),
            sourceLocation: sourceLocation)
}

/// Benchmarks are only worth running if the numbers are visible, and a passing
/// `#expect` prints nothing at all.
func perfLog(_ text: String) {
    print("  [perf] \(text)")
}
