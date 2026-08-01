import Foundation

/// Per-source scheduling state. Generic so each concrete collector keeps its
/// strong type all the way to the snapshot — no `Any` boxing on the hot path.
final class SourceSlot<Source: MetricSource> {
    let source: Source
    private(set) var state: MetricState<Source.Output> = .pending
    private var lastSampled: ContinuousClock.Instant?
    private var isStarted = false
    /// Set when the source reports `.unsupported`. We never call it again this
    /// session — that is the whole point of distinguishing unsupported from failed.
    private(set) var isRetired = false
    private var consecutiveFailures = 0

    init(_ source: Source) { self.source = source }

    var identifier: CollectorID { source.identifier }

    /// Runs the source if it is enabled and due. Returns true when `state` changed.
    @discardableResult
    func tick(now: ContinuousClock.Instant,
              activity: SamplingActivity,
              isEnabled: Bool,
              baseInterval: TimeInterval,
              didWakeFromSleep: Bool) -> Bool {
        guard isEnabled, !isRetired, activity.isSampling else {
            if !isEnabled && isStarted { suspend() ; return false }
            return false
        }

        if !isStarted {
            source.start()
            isStarted = true
        }

        let interval = max(source.preferredInterval, baseInterval) * activity.cadenceMultiplier
        let elapsed: TimeInterval
        if let lastSampled {
            elapsed = Monotonic.seconds(since: lastSampled)
            // Sample slightly early rather than slightly late so a coalesced timer
            // does not systematically stretch the effective interval.
            guard elapsed >= interval * 0.9 else { return false }
        } else {
            elapsed = 0
        }

        let context = SampleContext(elapsed: elapsed,
                                    isFirstSample: lastSampled == nil,
                                    activity: activity,
                                    didWakeFromSleep: didWakeFromSleep)
        let newState = source.collect(context: context)
        lastSampled = now

        switch newState {
        case .value:
            consecutiveFailures = 0
        case .failure(let failure):
            if failure.isPermanent {
                isRetired = true
                source.stop()
                isStarted = false
            } else {
                consecutiveFailures += 1
            }
        }

        let changed = newState != state
        state = newState
        return changed
    }

    /// Release resources but stay eligible to run again later.
    func suspend() {
        guard isStarted else { return }
        source.stop()
        isStarted = false
        lastSampled = nil
    }

    /// Force the next tick to treat its counters as a fresh baseline.
    func invalidateBaseline() { lastSampled = nil }

    func shutdown() {
        suspend()
        state = .pending
    }
}

/// Owns every collector and the sampling timer.
///
/// ## Threading
/// All state on this class is confined to `queue`, a single serial queue at
/// `.utility` QoS. Nothing here touches the main thread except the `onSnapshot`
/// callback, which is dispatched to the main actor. The class is `@unchecked
/// Sendable` because that confinement is enforced by construction, not by types.
public final class SamplingCore: @unchecked Sendable {

    // MARK: Sources

    private let cpuSlot: SourceSlot<CPUCollector>
    private let memorySlot: SourceSlot<MemoryCollector>
    private let gpuSlot: SourceSlot<GPUCollector>
    private let networkSlot: SourceSlot<NetworkCollector>
    private let diskSlot: SourceSlot<DiskCollector>
    private let powerSlot: SourceSlot<PowerCollector>
    private let thermalSlot: SourceSlot<ThermalCollector>
    private let processSlot: SourceSlot<ProcessCollector>
    private let systemSlot: SourceSlot<SystemInfoCollector>

    // MARK: Scheduling

    private let queue = DispatchQueue(label: "com.airstat.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var baseInterval: TimeInterval = 2
    private var activity: SamplingActivity = .menuBar
    private var enabledSources: Set<CollectorID> = Set(CollectorID.allCases)
    private var pendingWakeFlag = false
    private var isRunning = false

    /// Delivered on the main actor after every cycle that produced a change.
    private let onSnapshot: @Sendable @MainActor (SystemSnapshot) -> Void

    public init(onSnapshot: @escaping @Sendable @MainActor (SystemSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
        self.cpuSlot = SourceSlot(CPUCollector())
        self.memorySlot = SourceSlot(MemoryCollector())
        self.gpuSlot = SourceSlot(GPUCollector())
        self.networkSlot = SourceSlot(NetworkCollector())
        self.diskSlot = SourceSlot(DiskCollector())
        self.powerSlot = SourceSlot(PowerCollector())
        self.thermalSlot = SourceSlot(ThermalCollector())
        self.processSlot = SourceSlot(ProcessCollector())
        self.systemSlot = SourceSlot(SystemInfoCollector())
    }

    // MARK: Control

    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            rescheduleTimerLocked()
            sampleLocked()
        }
    }

    public func stop() {
        queue.async { [self] in
            isRunning = false
            timer?.cancel()
            timer = nil
            forEachSlot { $0.shutdown() }
        }
    }

    public func setBaseInterval(_ interval: TimeInterval) {
        queue.async { [self] in
            let clamped = min(max(interval, 0.5), 60)
            guard clamped != baseInterval else { return }
            baseInterval = clamped
            rescheduleTimerLocked()
        }
    }

    public func setActivity(_ newActivity: SamplingActivity) {
        queue.async { [self] in
            guard newActivity != activity else { return }
            let wasSuspended = !activity.isSampling
            activity = newActivity
            rescheduleTimerLocked()
            // Coming back from suspension, sample immediately so the user never
            // sees a stale menu bar after unlocking the screen.
            if wasSuspended && newActivity.isSampling {
                forEachSlot { $0.invalidateBaseline() }
                pendingWakeFlag = true
                sampleLocked()
            } else if newActivity > .menuBar {
                sampleLocked()
            }
        }
    }

    /// The set of collectors anything on screen actually needs. Sources outside
    /// this set are never sampled and release their resources.
    public func setEnabledSources(_ sources: Set<CollectorID>) {
        queue.async { [self] in
            guard sources != enabledSources else { return }
            let removed = enabledSources.subtracting(sources)
            enabledSources = sources
            forEachSlot { slot in
                if removed.contains(slot.identifier) { slot.suspend() }
            }
            if isRunning { sampleLocked() }
        }
    }

    /// Called on wake from sleep: cumulative counters may have reset and every
    /// rate is meaningless until re-baselined.
    public func noteWakeFromSleep() {
        queue.async { [self] in
            pendingWakeFlag = true
            forEachSlot { $0.invalidateBaseline() }
        }
    }

    /// Sample once, right now, regardless of cadence. Used when the panel opens.
    public func sampleNow() {
        queue.async { [self] in
            guard isRunning else { return }
            sampleLocked()
        }
    }

    // MARK: Internals

    private func forEachSlot(_ body: (any SlotErasing) -> Void) {
        body(cpuSlot); body(memorySlot); body(gpuSlot); body(networkSlot)
        body(diskSlot); body(powerSlot); body(thermalSlot); body(processSlot)
        body(systemSlot)
    }

    private func rescheduleTimerLocked() {
        timer?.cancel()
        timer = nil
        guard isRunning, activity.isSampling else { return }

        let interval = baseInterval * activity.cadenceMultiplier
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the kernel coalesce our wakeups with other timers.
        // This is the difference between "Very Low" and "Low" energy impact.
        let leeway = max(0.1, interval * 0.25)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(leeway * 1000)))
        t.setEventHandler { [weak self] in self?.sampleLocked() }
        t.resume()
        timer = t
    }

    private func sampleLocked() {
        let now = Monotonic.now
        let didWake = pendingWakeFlag
        pendingWakeFlag = false

        var changed = false
        func run<S: MetricSource>(_ slot: SourceSlot<S>) {
            if slot.tick(now: now,
                         activity: activity,
                         isEnabled: enabledSources.contains(slot.identifier),
                         baseInterval: baseInterval,
                         didWakeFromSleep: didWake) {
                changed = true
            }
        }

        run(systemSlot)
        run(cpuSlot)
        run(memorySlot)
        run(gpuSlot)
        run(networkSlot)
        run(diskSlot)
        run(powerSlot)
        run(thermalSlot)
        // Processes are by far the most expensive source; only ever sampled when
        // the panel that displays them is actually on screen.
        if activity >= .panel { run(processSlot) }

        guard changed else { return }

        let snapshot = SystemSnapshot(
            cpu: cpuSlot.state,
            memory: memorySlot.state,
            gpu: gpuSlot.state,
            network: networkSlot.state,
            disk: diskSlot.state,
            power: powerSlot.state,
            thermal: thermalSlot.state,
            processes: processSlot.state,
            system: systemSlot.state,
            capturedAt: Date(),
            capturedInstant: now
        )

        let callback = onSnapshot
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(snapshot) } }
    }
}

/// Type-erased slot operations that do not depend on the source's `Output`.
protocol SlotErasing: AnyObject {
    var identifier: CollectorID { get }
    func suspend()
    func invalidateBaseline()
    func shutdown()
}

extension SourceSlot: SlotErasing {}
