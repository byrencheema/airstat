import Foundation

/// Fixed-capacity ring buffer of `Float` samples.
///
/// `Float` rather than `Double` halves the memory and is far more precision than a
/// 200-pixel sparkline can resolve. Storage is allocated once at init and never
/// grows, so a session running for weeks has exactly the same footprint as one
/// running for a minute.
public struct SampleRing: Sendable, Equatable {
    private var storage: [Float]
    private var head: Int = 0
    public private(set) var count: Int = 0
    public let capacity: Int

    public init(capacity: Int) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.storage = [Float](repeating: 0, count: cap)
    }

    public mutating func append(_ value: Float) {
        storage[head] = value.isFinite ? value : 0
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    public mutating func append(_ value: Double) { append(Float(value)) }

    /// Oldest-to-newest ordered samples. Allocates; call once per render, not per point.
    public var values: [Float] {
        guard count > 0 else { return [] }
        if count < capacity {
            return Array(storage[0..<count])
        }
        return Array(storage[head..<capacity]) + Array(storage[0..<head])
    }

    /// Oldest-to-newest without allocating an intermediate array.
    public func withValues<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R? {
        guard count > 0, count < capacity else { return nil }
        return storage.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[0..<count])) }
    }

    public subscript(index: Int) -> Float {
        precondition(index >= 0 && index < count, "SampleRing index out of range")
        let start = count < capacity ? 0 : head
        return storage[(start + index) % capacity]
    }

    public var last: Float? { count > 0 ? self[count - 1] : nil }

    public var maximum: Float {
        guard count > 0 else { return 0 }
        var m: Float = -.greatestFiniteMagnitude
        for i in 0..<count { m = Swift.max(m, self[i]) }
        return m
    }

    public var minimum: Float {
        guard count > 0 else { return 0 }
        var m: Float = .greatestFiniteMagnitude
        for i in 0..<count { m = Swift.min(m, self[i]) }
        return m
    }

    public var average: Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += self[i] }
        return sum / Float(count)
    }

    public mutating func removeAll() {
        head = 0
        count = 0
    }

    /// Resize preserving the most recent samples.
    public mutating func resized(to newCapacity: Int) -> SampleRing {
        var ring = SampleRing(capacity: newCapacity)
        let keep = Swift.min(count, newCapacity)
        for i in (count - keep)..<count { ring.append(self[i]) }
        return ring
    }
}

/// The named time series AirStat retains for charting.
public enum SeriesKey: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case cpuTotal, cpuUser, cpuSystem, cpuPerformance, cpuEfficiency
    case memoryUsed, memoryPressure, memorySwap
    case gpuUtilization, gpuVRAM
    case networkUpload, networkDownload
    case diskRead, diskWrite, diskUsed
    case batteryPercent, batteryWatts, systemWatts
    case cpuTemperature, gpuTemperature, fanRPM

    public var label: String {
        switch self {
        case .cpuTotal: return "CPU"
        case .cpuUser: return "User"
        case .cpuSystem: return "System"
        case .cpuPerformance: return "P-Cores"
        case .cpuEfficiency: return "E-Cores"
        case .memoryUsed: return "Memory Used"
        case .memoryPressure: return "Memory Pressure"
        case .memorySwap: return "Swap"
        case .gpuUtilization: return "GPU"
        case .gpuVRAM: return "VRAM"
        case .networkUpload: return "Upload"
        case .networkDownload: return "Download"
        case .diskRead: return "Read"
        case .diskWrite: return "Write"
        case .diskUsed: return "Disk Used"
        case .batteryPercent: return "Battery"
        case .batteryWatts: return "Battery Power"
        case .systemWatts: return "System Power"
        case .cpuTemperature: return "CPU Temp"
        case .gpuTemperature: return "GPU Temp"
        case .fanRPM: return "Fan"
        }
    }

    /// Series whose natural range is 0...1 and can share a normalised axis.
    public var isNormalized: Bool {
        switch self {
        case .cpuTotal, .cpuUser, .cpuSystem, .cpuPerformance, .cpuEfficiency,
             .memoryUsed, .memoryPressure, .gpuUtilization, .gpuVRAM, .diskUsed:
            return true
        default:
            return false
        }
    }
}

/// All retained history, keyed by series.
///
/// A value type so the UI can diff cheaply, backed by fixed-size rings so the
/// total allocation is bounded at `capacity * seriesCount * 4` bytes — about
/// 170 KB at the maximum 1-hour-at-1s retention.
public struct MetricHistory: Sendable, Equatable {
    public private(set) var series: [SeriesKey: SampleRing]
    public private(set) var capacity: Int
    /// Wall-clock time of the newest sample, so charts can label their axis.
    public private(set) var lastSampleDate: Date?
    /// Seconds between samples, needed to convert an index into a time offset.
    public var sampleInterval: TimeInterval

    public init(capacity: Int = 300, sampleInterval: TimeInterval = 2) {
        self.capacity = max(2, capacity)
        self.sampleInterval = sampleInterval
        var s = [SeriesKey: SampleRing](minimumCapacity: SeriesKey.allCases.count)
        for key in SeriesKey.allCases { s[key] = SampleRing(capacity: max(2, capacity)) }
        self.series = s
    }

    public mutating func record(_ key: SeriesKey, _ value: Double) {
        series[key]?.append(value)
    }

    public mutating func markSampleDate(_ date: Date) { lastSampleDate = date }

    public subscript(key: SeriesKey) -> SampleRing {
        series[key] ?? SampleRing(capacity: capacity)
    }

    public func values(_ key: SeriesKey) -> [Float] { self[key].values }

    /// Grow or shrink every series, preserving the newest samples.
    public mutating func resize(to newCapacity: Int) {
        let cap = max(2, newCapacity)
        guard cap != capacity else { return }
        for key in series.keys {
            series[key] = series[key]?.resized(to: cap)
        }
        capacity = cap
    }

    public mutating func clear() {
        for key in series.keys { series[key]?.removeAll() }
        lastSampleDate = nil
    }

    /// Total seconds of history currently retained for a series.
    public func span(of key: SeriesKey) -> TimeInterval {
        Double(self[key].count) * sampleInterval
    }
}
