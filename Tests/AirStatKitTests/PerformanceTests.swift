import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// Timing benchmarks for the work the app repeats forever.
///
/// Scope is deliberately the *per-sample* path: everything here runs once every
/// `general.updateInterval` seconds for as long as the app is open, on a machine whose
/// battery the app exists to report on. A system monitor that is itself the thing
/// waking the CPU has failed at its only job, so these are the paths where a
/// regression matters.
///
/// Every benchmark is driven from fixtures, never from real sensors. The collector
/// contract tests read the SMC and flake when a fan spins down; a timing test reading
/// live hardware would flake far worse and measure the sensor rather than the code.
///
/// Budgets are calibrated against a **debug** build, which is what `swift test` runs.
/// Release is several times faster. See `expectWithinBudget` for why they are set as
/// loosely as they are.
@Suite("Performance", .tags(.performance), .serialized)
struct PerformanceTests {

    // MARK: Fixtures

    /// An hour of history at the default 2 s interval: 1802 samples per series, the
    /// capacity a default install actually reaches after an hour of uptime.
    static let fullCapacity = 1802

    /// History with every series filled to capacity, so the benchmarks measure the
    /// steady state rather than the first minute after launch.
    static func filledHistory(capacity: Int = fullCapacity) -> MetricHistory {
        var history = MetricHistory(capacity: capacity, sampleInterval: 2)
        for i in 0..<capacity {
            let phase = Double(i) / 40
            history.markSampleDate(SnapshotFixtures.referenceDate)
            for key in SeriesKey.allCases {
                // Varied per series and per sample: a ring of one repeated value would
                // let a branch predictor flatter the min/max walks being measured.
                history.record(key, abs(sin(phase + Double(key.hashValue % 7))) * 100)
            }
        }
        return history
    }

    /// Every readout the app offers, enabled at once.
    ///
    /// The worst case a user can actually configure, and the one the bug report
    /// measured the old preview blowing up at. If the per-sample cost is acceptable
    /// here it is acceptable everywhere.
    static func maximalSettings() -> Settings {
        var settings = Settings()
        settings.menuBar.items = MenuBarMetric.allCases.map {
            MenuBarItemConfig(metric: $0, style: .textAndGraph, isEnabled: true)
        }
        return settings
    }

    // MARK: Ring buffer

    @Test("appending a sample is effectively free")
    func ringAppend() {
        var ring = SampleRing(capacity: Self.fullCapacity)
        let result = Benchmark.measure("SampleRing.append x1000", iterations: 200) {
            for i in 0..<1000 { ring.append(Float(i)) }
            Benchmark.blackHole(ring.count)
        }
        // 1000 appends. Each is a store, a modulo and a compare.
        expectWithinBudget(result, nanoseconds: 400_000)
    }

    @Test("one pass over a full ring beats three separate walks")
    func statsSinglePass() {
        let ring = Self.filledHistory()[.cpuTotal]

        let single = Benchmark.measure("ChartStats (one pass)", iterations: 200) {
            Benchmark.blackHole(ChartStats(ring))
        }
        let triple = Benchmark.measure("ring.maximum + .minimum + .average", iterations: 200) {
            Benchmark.blackHole(ring.maximum + ring.minimum + ring.average)
        }
        let copy = Benchmark.measure("ring.values (same data, memcpy)", iterations: 200) {
            Benchmark.blackHole(ring.values)
        }

        perfLog("one pass is "
                + String(format: "%.1fx", triple.fastestNanoseconds / single.fastestNanoseconds)
                + " the speed of three, and "
                + String(format: "%.0fx", single.fastestNanoseconds / copy.fastestNanoseconds)
                + " the cost of copying the same samples")

        // The point of ChartStats existing. If a change ever makes the three-walk form
        // competitive, ChartStats has stopped earning its place.
        #expect(single.fastestNanoseconds < triple.fastestNanoseconds,
                "ChartStats should be faster than three separate O(n) walks")

        // Budgeted well above what it costs today rather than at what it should cost.
        //
        // ChartStats is the one-pass walk and it is still hundreds of times the cost of
        // copying the identical bytes, because every element reaches it through
        // `SampleRing.subscript`, which pays a modulo and a bounds precondition per
        // sample and does not inline in a debug build. That is a live finding, not a
        // property worth locking in, so this budget is a tripwire against it getting
        // *worse* while it stands. Tighten it if the subscript walk is ever replaced.
        expectWithinBudget(single, nanoseconds: 700_000)
    }

    @Test("reading a full ring out as an array")
    func ringValues() {
        let ring = Self.filledHistory()[.cpuTotal]
        let result = Benchmark.measure("SampleRing.values (1802 samples)", iterations: 200) {
            Benchmark.blackHole(ring.values)
        }
        // Two allocations and two memcpys of a wrapped ring.
        expectWithinBudget(result, nanoseconds: 40_000)
    }

    // MARK: History

    @Test("folding one snapshot into history")
    func historyRecord() {
        var history = Self.filledHistory()
        let keys = SeriesKey.allCases
        let result = Benchmark.measure("MetricHistory.record x21 (one ingest)", iterations: 500) {
            for (i, key) in keys.enumerated() { history.record(key, Double(i)) }
            Benchmark.blackHole(history.capacity)
        }
        // The real per-sample cost of retention: 21 dictionary lookups and 21 appends,
        // paid every update interval for the life of the process.
        expectWithinBudget(result, nanoseconds: 40_000)
    }

    @Test("clearing history on wake from sleep")
    func historyClear() {
        let filled = Self.filledHistory()
        let result = Benchmark.measure("MetricHistory.clear", iterations: 200) {
            var history = filled
            history.clear()
            Benchmark.blackHole(history.capacity)
        }
        expectWithinBudget(result, nanoseconds: 400_000)
    }

    @Test("resizing history when the retention setting changes")
    func historyResize() {
        let filled = Self.filledHistory()
        let result = Benchmark.measure("MetricHistory.resize 1802 -> 900", iterations: 100) {
            var history = filled
            history.resize(to: 900)
            Benchmark.blackHole(history.capacity)
        }
        // Only ever on a settings change, so this is generous by design. It is here to
        // catch a change that turns a user dragging the retention slider into a hang.
        expectWithinBudget(result, nanoseconds: 8_000_000)
    }

    // MARK: Menu bar, the hot path

    @Test("building the whole menu bar model with every readout enabled")
    func menuBarModelMaximal() {
        let settings = Self.maximalSettings()
        let history = Self.filledHistory()
        let snapshot = SnapshotFixtures.nominal

        let result = Benchmark.measure("MenuBarRenderModel, 16 readouts, full history",
                                       iterations: 100) {
            Benchmark.blackHole(MenuBarRenderModel(snapshot: snapshot,
                                                   history: history,
                                                   settings: settings,
                                                   isStale: false))
        }
        // This runs on the main actor on every snapshot and on every settings revision.
        // At the default 2 s cadence a millisecond here is 0.05% of a core; the budget
        // is set at the point where the menu bar would start costing real battery.
        expectWithinBudget(result, nanoseconds: 12_000_000)
    }

    @Test("building the menu bar model with the shipped two readouts")
    func menuBarModelDefault() {
        let settings = Settings()
        let history = Self.filledHistory()
        let snapshot = SnapshotFixtures.nominal

        let result = Benchmark.measure("MenuBarRenderModel, default 2 readouts",
                                       iterations: 200) {
            Benchmark.blackHole(MenuBarRenderModel(snapshot: snapshot,
                                                   history: history,
                                                   settings: settings,
                                                   isStale: false))
        }
        // What almost every user actually pays.
        expectWithinBudget(result, nanoseconds: 1_500_000)
    }

    @Test("deciding whether the status item needs redrawing")
    func menuBarModelEquality() {
        let settings = Self.maximalSettings()
        let history = Self.filledHistory()
        let snapshot = SnapshotFixtures.nominal
        // Two models built separately rather than one assigned to the other. Equal
        // copies share their arrays' storage, so `==` short-circuits on pointer
        // identity and reports single-digit nanoseconds: a number that says nothing
        // about the redraw path, where a freshly built model is always compared
        // against the stored one and no storage is ever shared.
        let a = MenuBarRenderModel(snapshot: snapshot, history: history,
                                   settings: settings, isStale: false)
        let b = MenuBarRenderModel(snapshot: snapshot, history: history,
                                   settings: settings, isStale: false)
        #expect(a == b, "the two models must be equal for this to measure the full walk")

        let result = Benchmark.measure("MenuBarRenderModel == (distinct storage)",
                                       iterations: 500) {
            Benchmark.blackHole(a == b)
        }
        // The comparison that gates every redraw. It walks each item's normalised
        // series, so its cost tracks retained history rather than the handful of
        // pixels a menu bar graph actually occupies.
        expectWithinBudget(result, nanoseconds: 800_000)
    }

    // MARK: Charts

    @Test("preparing every chart series the panel can show")
    func chartSeriesBuild() {
        let history = Self.filledHistory()
        let keys = SeriesKey.allCases

        let result = Benchmark.measure("ChartSeries x21 + scale resolve", iterations: 100) {
            let series = keys.map { ChartSeries($0, from: history, tint: .red) }
            Benchmark.blackHole(ChartScale.resolve(series, adaptive: true))
        }
        // Every open panel rebuilds these as snapshots land.
        expectWithinBudget(result, nanoseconds: 12_000_000)
    }

    // MARK: Notifications

    @Test("evaluating every threshold rule against a snapshot")
    func thresholdEvaluation() {
        var evaluator = ThresholdEvaluator()
        let rules = ThresholdMetric.allCases.map {
            ThresholdRule(metric: $0, isEnabled: true, sustainedFor: 0, cooldown: 0)
        }
        let readings = ThresholdEvaluator.readings(from: SnapshotFixtures.underLoad)
        var now = SnapshotFixtures.referenceDate

        let result = Benchmark.measure("ThresholdEvaluator.alerts, all rules", iterations: 500) {
            now += 1
            Benchmark.blackHole(evaluator.alerts(for: rules, readings: readings, now: now))
        }
        expectWithinBudget(result, nanoseconds: 100_000)
    }

    @Test("reading every watchable metric out of a snapshot")
    func thresholdReadings() {
        let snapshot = SnapshotFixtures.underLoad
        let result = Benchmark.measure("ThresholdEvaluator.readings", iterations: 500) {
            Benchmark.blackHole(ThresholdEvaluator.readings(from: snapshot))
        }
        expectWithinBudget(result, nanoseconds: 60_000)
    }

    // MARK: Settings persistence

    @Test("encoding settings for the debounced save")
    func settingsEncode() {
        let settings = Self.maximalSettings()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let result = Benchmark.measure("Settings encode", iterations: 200) {
            Benchmark.blackHole(try? encoder.encode(settings))
        }
        // Off the main actor and debounced, so this is not a hot path. It is here
        // because the save also *decodes* the existing file to validate it before
        // promoting it to backup, which doubles the cost of every write.
        expectWithinBudget(result, nanoseconds: 3_000_000)
    }

    @Test("decoding settings at launch")
    func settingsDecode() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(Self.maximalSettings())
        let decoder = JSONDecoder()

        let result = Benchmark.measure("Settings decode", iterations: 200) {
            Benchmark.blackHole(try? decoder.decode(Settings.self, from: data))
        }
        // On the launch path, before the first frame.
        expectWithinBudget(result, nanoseconds: 4_000_000)
    }

    @Test("sanitising a decoded settings tree")
    func settingsSanitize() {
        let settings = Self.maximalSettings()
        let result = Benchmark.measure("SettingsStore.sanitize", iterations: 500) {
            Benchmark.blackHole(SettingsStore.sanitize(settings))
        }
        // Runs on every single mutation, so every keystroke in a text field and every
        // frame of a slider drag pays it.
        expectWithinBudget(result, nanoseconds: 200_000)
    }

    // MARK: Formatting

    @Test("formatting the readouts a full menu bar draws")
    func formatting() {
        let formatter = MetricFormatter()
        let result = Benchmark.measure("MetricFormatter x6 values", iterations: 1000) {
            Benchmark.blackHole(formatter.percent(0.734))
            Benchmark.blackHole(formatter.networkRate(2_400_000, compact: true))
            Benchmark.blackHole(formatter.temperature(58.5))
            Benchmark.blackHole(formatter.storage(UInt64(494_384_795_648)))
            Benchmark.blackHole(formatter.watts(21.4))
            Benchmark.blackHole(formatter.duration(7_245))
        }
        expectWithinBudget(result, nanoseconds: 60_000)
    }
}

/// The per-sample cost of the engine itself, separated because it is main-actor bound.
@MainActor
@Suite("Performance, main actor", .tags(.performance), .serialized)
struct MainActorPerformanceTests {

    /// An engine over a throwaway directory, so a benchmark never touches the user's
    /// real settings file. `HOME` does not redirect `applicationSupportDirectory`;
    /// `SettingsStore(directory:)` is the only thing that isolates a test instance.
    private static func makeEngine() -> (MetricsEngine, SettingsStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatPerf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // No debounce window worth waiting for; these tests never assert on the file.
        let store = SettingsStore(directory: dir, saveDebounce: .seconds(3600))
        return (MetricsEngine(settingsStore: store), store)
    }

    @Test("ingesting a snapshot and folding it into history")
    func engineIngest() {
        let (engine, store) = Self.makeEngine()
        withExtendedLifetime(store) {
            let snapshot = SnapshotFixtures.nominal
            let result = Benchmark.measure("MetricsEngine.ingest", iterations: 500) {
                engine.ingest(snapshot)
            }
            // The whole per-sample main-actor cost: assign the snapshot, bump the
            // observable, and record up to 21 series. Everything the UI redraws hangs
            // off this, so it is the number that decides whether a 1 s interval is
            // reasonable to offer at all.
            expectWithinBudget(result, nanoseconds: 200_000)
        }
    }

    /// In the main-actor suite because `StatusItemController.slice` is main-actor
    /// isolated, which it should be: it is only ever called from `render()`.
    @Test("slicing the model down to one readout per status item")
    func menuBarSlice() {
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: PerformanceTests.filledHistory(),
                                       settings: PerformanceTests.maximalSettings(),
                                       isStale: false)
        let ids = model.items.map(\.id)

        let result = Benchmark.measure("slice x16 (separate status items)", iterations: 200) {
            for id in ids {
                Benchmark.blackHole(StatusItemController.slice(model, readout: id))
            }
        }
        // Paid once per status item per redraw when the combine switch is off, so the
        // separate-items layout multiplies this by the number of enabled readouts.
        expectWithinBudget(result, nanoseconds: 1_000_000)
    }

    @Test("a settings mutation, which every slider drag repeats")
    func settingsUpdate() {
        let (engine, store) = Self.makeEngine()
        withExtendedLifetime(engine) {
            var value = 0.5
            let result = Benchmark.measure("SettingsStore.update", iterations: 300) {
                value = value > 0.9 ? 0.5 : value + 0.01
                store.update { $0.overlay.opacity = value }
            }
            // Copies the tree, mutates, sanitises, compares for equality and schedules
            // a save. A slider drag runs this at display rate.
            expectWithinBudget(result, nanoseconds: 400_000)
        }
    }
}
