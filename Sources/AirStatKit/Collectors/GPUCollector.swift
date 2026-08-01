import CoreGraphics
import Foundation
import IOKit
import Metal

/// GPU utilisation and VRAM for every attached device.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
///
/// Identity comes from Metal, utilisation from the `PerformanceStatistics`
/// dictionary that `IOAccelerator` drivers publish. Those key names are
/// driver-specific — Apple Silicon, AMD and Intel each spell them differently and
/// none of them are contractual — so every field is looked up through a candidate
/// list and left `nil` when nothing matches. A GPU whose driver publishes no
/// counters still reports its identity and VRAM; that is a `.value` with a nil
/// utilisation, not a failure.
public final class GPUCollector: MetricSource {
    public typealias Output = GPUSnapshot

    public let identifier: CollectorID = .gpu
    public let preferredInterval: TimeInterval = 1.0

    /// A Metal device paired with the IORegistry node that publishes its counters.
    /// Everything here except `service` is static for the life of the device, so it
    /// is read once per rescan rather than per sample.
    private struct Device {
        let id: String
        let name: String
        let isBuiltIn: Bool
        let isRemovable: Bool
        let hasUnifiedMemory: Bool
        let coreCount: Int?
        let vramTotalBytes: UInt64?
        /// Retained `io_service_t`, or 0 when no accelerator node matched.
        let service: io_service_t
        /// Latched once the driver is proven to publish no `PerformanceStatistics`,
        /// so a permanently counter-less GPU cannot trigger a rescan every sample.
        var statsUnavailable: Bool
    }

    private var devices: [Device] = []
    private var cachedRegistryIDs: [UInt64] = []
    private var primaryDeviceID: String?
    /// Set when a cached service stops answering — an eGPU being unplugged, or the
    /// driver reloading — so the next sample rebuilds the handles instead of crashing
    /// or reporting a frozen number.
    private var needsRescan = false
    /// When the accumulators were last read or primed. The driver's percentages cover
    /// the interval since that instant, so a read taken too soon after one measures
    /// almost no time and cannot honestly be turned into a utilisation figure.
    private var lastReadInstant: ContinuousClock.Instant?

    /// Shortest interval that yields a meaningful utilisation figure. Sampling is at
    /// 1 Hz, so this only ever rejects a read that immediately follows `start()` or a
    /// rescan — never a steady-state sample.
    private static let minimumWindow: TimeInterval = 0.05

    public init() {}

    public func start() {
        rescan(MTLCopyAllDevices())
    }

    public func stop() {
        releaseServices()
        devices = []
        cachedRegistryIDs = []
        primaryDeviceID = nil
        needsRescan = false
        lastReadInstant = nil
    }

    deinit { releaseServices() }

    public func collect(context: SampleContext) -> MetricState<GPUSnapshot> {
        // Sleep can reconfigure displays and reload drivers, so the cached handles
        // and the "which GPU drives the screen" answer are both re-derived on wake.
        if context.didWakeFromSleep { needsRescan = true }

        // Warm, this costs ~0.3 µs and is the only way to notice a device appearing.
        // The expensive half — resolving each device to its IORegistry node — is
        // still done only when the set of devices actually changed.
        let metalDevices = MTLCopyAllDevices()
        if needsRescan || metalDevices.map(\.registryID) != cachedRegistryIDs {
            rescan(metalDevices)
            needsRescan = false
        }

        guard !devices.isEmpty else {
            // Deliberately not `.unsupported`: that would retire the collector for the
            // whole session, and an empty device list is more plausibly a driver
            // reloading than a Mac that genuinely has no GPU.
            return .failure(.failed("No Metal device available"))
        }

        let window = lastReadInstant.map(Monotonic.seconds(since:)) ?? 0
        let windowIsUsable = window >= Self.minimumWindow
        lastReadInstant = Monotonic.now

        var rows: [GPUDevice] = []
        rows.reserveCapacity(devices.count)

        for index in devices.indices {
            let device = devices[index]
            var utilization: Double?
            var renderer: Double?
            var tiler: Double?
            var vramUsed: UInt64?

            if device.service != 0, !device.statsUnavailable {
                if let stats = Self.performanceStatistics(device.service) {
                    // Memory is a level, not an accumulator, so it is always readable;
                    // only the time-averaged percentages need a usable window.
                    vramUsed = Self.bytes(stats, Self.vramUsedKeys)
                    if windowIsUsable {
                        utilization = Self.fraction(stats, Self.utilizationKeys)
                        renderer = Self.fraction(stats, Self.rendererKeys)
                        tiler = Self.fraction(stats, Self.tilerKeys)
                    }
                } else if Self.isAlive(device.service) {
                    devices[index].statsUnavailable = true
                } else {
                    needsRescan = true
                }
            }

            rows.append(GPUDevice(id: device.id,
                                  name: device.name,
                                  utilization: utilization,
                                  vramUsedBytes: vramUsed,
                                  vramTotalBytes: device.vramTotalBytes,
                                  isBuiltIn: device.isBuiltIn,
                                  isRemovable: device.isRemovable,
                                  coreCount: device.coreCount,
                                  rendererUtilization: renderer,
                                  tilerUtilization: tiler,
                                  hasUnifiedMemory: device.hasUnifiedMemory))
        }

        return .value(GPUSnapshot(devices: rows, primaryDeviceID: primaryDeviceID))
    }

    // MARK: Device handles

    private func rescan(_ metalDevices: [any MTLDevice]) {
        releaseServices()
        cachedRegistryIDs = metalDevices.map(\.registryID)
        devices = metalDevices.map(Self.makeDevice)
        primaryDeviceID = Self.displayDeviceID()
            ?? devices.first(where: \.isBuiltIn)?.id
            ?? devices.first?.id

        // Prime each accumulator with a discarded read. The driver reports utilisation
        // over the interval since the last read *by any process*, so without this the
        // first sample inherits a window of unknown length — observed reporting 98% on
        // a fully idle GPU because a benchmark had read the node minutes earlier.
        for device in devices where device.service != 0 {
            _ = Self.performanceStatistics(device.service)
        }
        lastReadInstant = Monotonic.now
    }

    private func releaseServices() {
        for device in devices where device.service != 0 {
            IOObjectRelease(device.service)
        }
    }

    private static func makeDevice(_ metal: any MTLDevice) -> Device {
        let service = accelerator(forRegistryID: metal.registryID)
        // On unified-memory Macs this is the working-set budget the GPU is willing to
        // hand out, not dedicated VRAM — the honest ceiling, but `hasUnifiedMemory`
        // has to travel with it so the UI does not label it as a discrete card's memory.
        let workingSet = metal.recommendedMaxWorkingSetSize
        return Device(id: String(metal.registryID),
                      name: metal.name,
                      isBuiltIn: metal.location == .builtIn,
                      isRemovable: metal.isRemovable || metal.location == .external,
                      hasUnifiedMemory: metal.hasUnifiedMemory,
                      coreCount: integerProperty(service, "gpu-core-count"),
                      vramTotalBytes: workingSet > 0 ? workingSet : nil,
                      service: service,
                      statsUnavailable: false)
    }

    /// A Metal device's `registryID` is the IORegistry entry ID of its accelerator
    /// node, which makes this the exact pairing rather than a name-matching guess.
    private static func accelerator(forRegistryID registryID: UInt64) -> io_service_t {
        guard let matching = IORegistryEntryIDMatching(registryID) else { return 0 }
        // IOServiceGetMatchingService consumes the matching dictionary.
        return IOServiceGetMatchingService(kIOMainPortDefault, matching)
    }

    /// The GPU actually driving the main display. Falls back to the built-in device,
    /// which is the right answer on a laptop with a single GPU.
    private static func displayDeviceID() -> String? {
        guard let device = CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID()) else { return nil }
        return String(device.registryID)
    }

    /// Separates "this driver publishes no counters" from "this service is gone".
    /// Only the second is worth a rescan.
    private static func isAlive(_ service: io_service_t) -> Bool {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS
    }

    // MARK: PerformanceStatistics

    /// Verified present on this M3 Pro (AGXAcceleratorG15X). The AMD and Intel
    /// spellings are included because the driver, not the OS, decides these names.
    private static let utilizationKeys = [
        "Device Utilization %", "Device Utilization", "GPU Activity(%)", "GPU Core Utilization",
    ]
    private static let rendererKeys = ["Renderer Utilization %", "Renderer Utilization"]
    private static let tilerKeys = ["Tiler Utilization %", "Tiler Utilization"]
    /// "In use system memory" is the system-wide GPU-resident total on Apple Silicon.
    /// Metal's `currentAllocatedSize` is deliberately not used as a fallback: it counts
    /// only this process's allocations (81 KB here) and would read as an empty GPU.
    private static let vramUsedKeys = [
        "In use system memory", "vramUsedBytes", "gartUsedBytes", "Alloc system memory",
    ]

    /// Reading this dictionary *resets* the driver's utilisation accumulator: the
    /// percentages describe the interval since the last read, by anyone. Two reads a
    /// few microseconds apart therefore return the real figure and then 0. Nothing to
    /// fix here — one read per sample is exactly right — but it means a second process
    /// polling the same node (Activity Monitor, another stats app) can occasionally
    /// steal an interval and make one sample read low. Collisions can only ever
    /// understate, never inflate, so the number is not silently corrected.
    private static func performanceStatistics(_ service: io_service_t) -> [String: Any]? {
        guard let property = IORegistryEntryCreateCFProperty(
            service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return property.takeRetainedValue() as? [String: Any]
    }

    private static func number(_ stats: [String: Any], _ candidates: [String]) -> Double? {
        for key in candidates {
            if let value = stats[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }

    /// Every candidate key is expressed as a percentage by its driver, so the only
    /// conversion needed is the divide; the clamp guards against a driver briefly
    /// reporting over 100 during a mode switch.
    private static func fraction(_ stats: [String: Any], _ candidates: [String]) -> Double? {
        guard let percent = number(stats, candidates) else { return nil }
        return max(0, min(1, percent / 100))
    }

    private static func bytes(_ stats: [String: Any], _ candidates: [String]) -> UInt64? {
        guard let value = number(stats, candidates), value >= 0 else { return nil }
        return UInt64(value)
    }

    private static func integerProperty(_ service: io_service_t, _ key: String) -> Int? {
        guard service != 0,
              let property = IORegistryEntryCreateCFProperty(
                  service, key as CFString, kCFAllocatorDefault, 0
              ),
              let value = property.takeRetainedValue() as? NSNumber
        else { return nil }
        return value.intValue
    }
}
