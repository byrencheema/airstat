import Foundation
import IOKit
import SystemConfiguration

/// Static machine identity plus uptime.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
///
/// Everything here except `uptime` is fixed for the life of the process, so it is
/// resolved once in `start()` and cached. `collect()` then costs a `Date()` and a
/// struct copy, which is what lets this collector stay in the sampling set even at
/// `.occluded` activity without costing anything measurable.
public final class SystemInfoCollector: MetricSource {
    public typealias Output = SystemInfoSnapshot

    public let identifier: CollectorID = .system
    /// Nothing here changes minute to minute; 30s is purely so the uptime readout
    /// does not visibly lag.
    public let preferredInterval: TimeInterval = 30.0

    /// Populated by `start()`. `uptime` inside it is stale by design — `collect()`
    /// recomputes that field on every sample and leaves the rest untouched.
    private var identity: SystemInfoSnapshot?

    public init() {}

    public func start() {
        identity = Self.resolveIdentity()
    }

    public func stop() {
        identity = nil
    }

    public func collect(context: SampleContext) -> MetricState<SystemInfoSnapshot> {
        // Re-resolve only if start() was skipped or a previous resolve failed; on the
        // normal path this branch is never taken.
        if identity == nil { identity = Self.resolveIdentity() }
        guard var snapshot = identity else {
            return .failure(.failed("sysctl could not read machine identity"))
        }
        // Wall-clock since KERN_BOOTTIME, deliberately not ProcessInfo.systemUptime:
        // systemUptime is suspended while the machine sleeps, so after an overnight
        // sleep it under-reports by hours. uptime(1) uses the boot-time difference and
        // that is the number users compare against. Verified against uptime(1).
        snapshot.uptime = max(0, Date().timeIntervalSince(snapshot.bootTime))
        return .value(snapshot)
    }

    // MARK: Static resolution

    /// Returns nil only when a sysctl that cannot legitimately fail on macOS does,
    /// which the caller reports as a transient failure rather than papering over.
    private static func resolveIdentity() -> SystemInfoSnapshot? {
        guard let modelIdentifier = sysctlString("hw.model"),
              let memoryBytes = sysctlInteger("hw.memsize"),
              let logicalCores = sysctlInteger("hw.logicalcpu"),
              let physicalCores = sysctlInteger("hw.physicalcpu"),
              let bootTime = bootTime()
        else { return nil }

        // perflevel0 is the fastest cluster and perflevel1 the slowest; both keys are
        // absent on Intel, where the whole package is one performance level. Reporting
        // 0/0 there is honest — the split does not exist — rather than guessed.
        let performanceCores = sysctlInteger("hw.perflevel0.logicalcpu")
        let efficiencyCores = sysctlInteger("hw.perflevel1.logicalcpu")
        let hasClusters = performanceCores != nil && efficiencyCores != nil

        let version = ProcessInfo.processInfo.operatingSystemVersion

        return SystemInfoSnapshot(
            hostName: sysctlString("kern.hostname") ?? ProcessInfo.processInfo.hostName,
            computerName: computerName() ?? sysctlString("kern.hostname") ?? "",
            modelIdentifier: modelIdentifier,
            modelName: marketingName(fallbackIdentifier: modelIdentifier),
            chipName: sysctlString("machdep.cpu.brand_string") ?? "",
            osName: "macOS",
            osVersion: format(version),
            osBuild: sysctlString("kern.osversion") ?? "",
            uptime: max(0, Date().timeIntervalSince(bootTime)),
            bootTime: bootTime,
            physicalCores: Int(physicalCores),
            logicalCores: Int(logicalCores),
            performanceCores: hasClusters ? Int(performanceCores!) : 0,
            efficiencyCores: hasClusters ? Int(efficiencyCores!) : 0,
            totalMemoryBytes: memoryBytes,
            isAppleSilicon: (sysctlInteger("hw.optional.arm64") ?? 0) == 1,
            gpuCoreCount: gpuCoreCount()
        )
    }

    /// Matches `sw_vers -productVersion`, which drops a zero patch component.
    /// No assumption about the major number: macOS 26 formats as "26.5.2".
    private static func format(_ v: OperatingSystemVersion) -> String {
        v.patchVersion == 0
            ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func computerName() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    // MARK: sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    /// Width-agnostic: `hw.memsize` is 64-bit while the core counts are 32-bit, and
    /// reading either with the wrong width silently returns garbage.
    private static func sysctlInteger(_ name: String) -> UInt64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<UInt32>.size:
            var value: UInt32 = 0
            var length = size
            guard sysctlbyname(name, &value, &length, nil, 0) == 0 else { return nil }
            return UInt64(value)
        case MemoryLayout<UInt64>.size:
            var value: UInt64 = 0
            var length = size
            guard sysctlbyname(name, &value, &length, nil, 0) == 0 else { return nil }
            return value
        default:
            return nil
        }
    }

    private static func bootTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }

    // MARK: IORegistry

    /// The name a user would recognise from About This Mac ("MacBook Pro (14-inch,
    /// Nov 2023)"). There is no public API for it, but Apple Silicon publishes it in
    /// the device tree, which is a plain property read — far cheaper than the
    /// `system_profiler` subprocess the same string would otherwise cost. Intel Macs
    /// have no such node, and their model identifiers do encode the family, so the
    /// fallback derives it from the identifier there.
    private static func marketingName(fallbackIdentifier identifier: String) -> String {
        if let name = deviceTreeProductString("product-name"), !name.isEmpty { return name }
        if let name = deviceTreeProductString("product-description"), !name.isEmpty { return name }
        return familyName(for: identifier) ?? identifier
    }

    private static func deviceTreeProductString(_ key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(entry, key as CFString,
                                                            kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let text = property as? String { return text }
        // Device tree strings arrive as NUL-terminated OSData.
        guard let data = property as? Data else { return nil }
        return String(data: data.prefix(while: { $0 != 0 }), encoding: .utf8)
    }

    private static func familyName(for identifier: String) -> String? {
        let families = [
            ("MacBookPro", "MacBook Pro"), ("MacBookAir", "MacBook Air"),
            ("MacBook", "MacBook"), ("MacPro", "Mac Pro"), ("Macmini", "Mac mini"),
            ("MacStudio", "Mac Studio"), ("iMacPro", "iMac Pro"), ("iMac", "iMac"),
            ("VirtualMac", "Virtual Machine"), ("ADP", "Developer Transition Kit"),
        ]
        return families.first { identifier.hasPrefix($0.0) }?.1
    }

    /// Apple Silicon only; Intel and virtual machines have no AGX accelerator and the
    /// count stays nil rather than being invented.
    private static func gpuCoreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AGXAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var count: Int?
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard count == nil else { continue }
            if let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString,
                                                          kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                count = value.intValue
            }
        }
        return count
    }
}
