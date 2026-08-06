import Foundation

// MARK: - Lenient decoding

/// Decode a key, falling back to a default when it is missing *or malformed*.
///
/// Settings files get hand-edited, truncated by power loss, and written by older
/// builds. A single bad key must never cost the user their whole configuration,
/// so every property in this file decodes through here.
extension KeyedDecodingContainer {
    /// `try?` flattens the `T??` here, so a key that is absent and a key that fails
    /// to decode both land on `fallback` — which is exactly the desired behaviour.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded
    }
}

// MARK: - Units and formatting

public enum TemperatureUnit: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case celsius, fahrenheit

    public var label: String {
        switch self {
        case .celsius: return "Celsius (°C)"
        case .fahrenheit: return "Fahrenheit (°F)"
        }
    }
    public var suffix: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }
}

/// Network rates are conventionally quoted in bits (Mbps) by ISPs and bytes (MB/s)
/// by file transfer UI. Both are offered because both are "correct".
public enum NetworkRateUnit: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case bytes, bits

    public var label: String {
        switch self {
        case .bytes: return "Bytes per second (MB/s)"
        case .bits: return "Bits per second (Mbps)"
        }
    }
}

/// GiB (1024-based, what Activity Monitor's graphs use) vs GB (1000-based, what
/// Finder and Apple's marketing use).
/// Applies to STORAGE only. Physical memory is always formatted in binary units
/// because that is what Apple itself does (18 GB of RAM is 19,327,352,832 bytes).
public enum ByteUnitStyle: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case binary, decimal

    public var label: String {
        switch self {
        case .binary: return "Binary (1 GB = 1024 MB)"
        case .decimal: return "Decimal (1 GB = 1000 MB)"
        }
    }
    public var base: Double { self == .binary ? 1024 : 1000 }
}

public enum AppearanceMode: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

// MARK: - Menu bar

/// A single readout the user can place in the menu bar.
public enum MenuBarMetric: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case cpuUsage, cpuTemperature, cpuFrequency
    case memoryUsage, memoryPressure
    case gpuUsage
    case networkThroughput, networkUpload, networkDownload
    case diskActivity, diskFree
    case battery, batteryTime, systemPower
    case fanSpeed
    case uptime

    public var label: String {
        switch self {
        case .cpuUsage: return "CPU Usage"
        case .cpuTemperature: return "CPU Temperature"
        case .cpuFrequency: return "CPU Frequency"
        case .memoryUsage: return "Memory Usage"
        case .memoryPressure: return "Memory Pressure"
        case .gpuUsage: return "GPU Usage"
        case .networkThroughput: return "Network (Up & Down)"
        case .networkUpload: return "Network Upload"
        case .networkDownload: return "Network Download"
        case .diskActivity: return "Disk Activity"
        case .diskFree: return "Disk Free"
        case .battery: return "Battery"
        case .batteryTime: return "Battery Time Remaining"
        case .systemPower: return "System Power"
        case .fanSpeed: return "Fan Speed"
        case .uptime: return "Uptime"
        }
    }

    /// Which collector must be running for this readout to have data.
    public var requiredSource: CollectorID {
        switch self {
        case .cpuUsage, .cpuFrequency: return .cpu
        case .cpuTemperature, .fanSpeed: return .thermal
        case .memoryUsage, .memoryPressure: return .memory
        case .gpuUsage: return .gpu
        case .networkThroughput, .networkUpload, .networkDownload: return .network
        case .diskActivity, .diskFree: return .disk
        case .battery, .batteryTime, .systemPower: return .power
        case .uptime: return .system
        }
    }

    /// Styles that make sense for this metric. Only the metrics that keep a series
    /// can be graphed; the rest are a number, with or without their icon.
    public var supportedStyles: [MenuBarDisplayStyle] {
        switch self {
        case .uptime, .batteryTime, .cpuFrequency, .diskFree:
            return [.text, .iconAndText]
        default:
            return MenuBarDisplayStyle.allCases
        }
    }
}

/// How one readout draws.
///
/// Four, where there were seven. Bar and Ring drew the same fraction a graph draws,
/// smaller and without the history, and neither said what the fraction was of — a 5pt
/// bar beside a 5pt bar is two anonymous slivers. Icon-alone was worse: a stats app
/// whose readout is an icon is showing a picture of a metric instead of the metric.
/// What is left is the number, the number's history, and the number with a mark
/// saying which metric it is.
public enum MenuBarDisplayStyle: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case text
    case graph
    case textAndGraph
    case iconAndText

    public var label: String {
        switch self {
        case .text: return "Text"
        case .graph: return "Graph"
        case .textAndGraph: return "Text & Graph"
        case .iconAndText: return "Icon & Text"
        }
    }
}

public struct MenuBarItemConfig: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var metric: MenuBarMetric
    public var style: MenuBarDisplayStyle
    public var isEnabled: Bool
    /// Draw the metric's name above its number.
    public var showsCaption: Bool

    public init(id: UUID = UUID(), metric: MenuBarMetric, style: MenuBarDisplayStyle = .text,
                isEnabled: Bool = true, showsCaption: Bool = true) {
        self.id = id
        self.metric = metric
        self.style = style
        self.isEnabled = isEnabled
        self.showsCaption = showsCaption
    }

    /// Clamp a decoded config back into a coherent state — an old build may have
    /// stored a style this metric no longer supports.
    public func sanitized() -> MenuBarItemConfig {
        var copy = self
        if !metric.supportedStyles.contains(style) {
            copy.style = metric.supportedStyles.first ?? .text
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, style, isEnabled, showsCaption
    }

    /// A file written by an older build carries a `graphWidth` and may carry a style
    /// that no longer exists. Neither is an error: the unknown key is not read, and
    /// `sanitized()` moves the retired style to one this metric still supports.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        metric = c.value(.metric, or: MenuBarMetric.cpuUsage)
        style = c.value(.style, or: MenuBarDisplayStyle.text)
        isEnabled = c.value(.isEnabled, or: true)
        showsCaption = c.value(.showsCaption, or: true)
    }
}

public struct MenuBarSettings: Sendable, Codable, Equatable {
    public var items: [MenuBarItemConfig]
    /// Use a single status item for everything (tidier, survives menu bar crowding)
    /// versus one status item per metric (individually re-orderable by the user).
    public var usesCombinedItem: Bool

    /// Numbers are always set in a fixed-width face. Previously a toggle; a column of
    /// proportional digits shimmers as it changes, which is the single most visible
    /// cheapness tell in a stats app, and nobody was ever going to want it.
    public static let usesMonospacedDigits = true

    /// Four settings, gone. Each governed one dimension of how the bar is packed, and
    /// between them they were the reason a readout could move, resize or vanish while
    /// the user was looking at it — the one thing a menu bar must never do.
    ///
    /// Previously `usesFixedWidth`. Always on: without it every readout resizes as its
    /// own value changes and drags everything to its right along with it.
    public static let usesFixedWidth = true
    /// Previously `itemSpacing`, a 0–24 slider. 8 is the gap AppKit puts between its
    /// own status items, which is the gap this has to match to look like it belongs.
    public static let itemSpacing: Double = 8
    /// Previously `hidesIdleItems` and `idleThreshold`. A readout that removes itself
    /// when it goes quiet takes the whole bar with it every time it comes back, and
    /// the moment a metric is worth watching is not reliably the moment it is high.
    public static let hidesIdleItems = false

    public init(items: [MenuBarItemConfig] = MenuBarSettings.defaultItems,
                usesCombinedItem: Bool = true) {
        self.items = items
        self.usesCombinedItem = usesCombinedItem
    }

    /// Two readouts, not three.
    ///
    /// Network throughput is by far the widest element — two values plus units — and a
    /// menu bar item that is wider than everything Apple ships gets silently dropped on a
    /// notched display when a few other extras are present. CPU and memory are what a
    /// stats app is for; network stays one click away in Settings for those who want it.
    ///
    /// Both carry their name above their number rather than an icon beside it. An icon
    /// is a guess the reader has to make — a chip glyph is CPU to whoever drew it and
    /// "some hardware" to everyone else — while "CPU" is four narrow characters set at
    /// eight points in the metric's own colour, above the number, in a column the
    /// number was already paying for. The default drops the sparkline: at 34pt wide it
    /// reads as a scribble, and it was the single widest element left.
    public static let defaultItems: [MenuBarItemConfig] = [
        MenuBarItemConfig(metric: .cpuUsage, style: .text, showsCaption: true),
        MenuBarItemConfig(metric: .memoryUsage, style: .text, showsCaption: true),
    ]

    public var enabledItems: [MenuBarItemConfig] { items.filter(\.isEnabled) }

    private enum CodingKeys: String, CodingKey {
        case items, usesCombinedItem
    }

    /// Files written before the packing settings were removed still load: the keys
    /// they carry for spacing, fixed width and quiet mode are simply not read, and an
    /// unknown key has never been an error here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedItems = c.value(.items, or: MenuBarSettings.defaultItems)
        // An empty menu bar would leave the user with no way back into the app.
        items = decodedItems.isEmpty ? MenuBarSettings.defaultItems : decodedItems.map { $0.sanitized() }
        usesCombinedItem = c.value(.usesCombinedItem, or: true)
    }
}

// MARK: - Panel

public enum PanelModule: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case cpu, memory, gpu, network, disk, battery, thermal, processes, system

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .disk: return "Disk"
        case .battery: return "Battery"
        case .thermal: return "Temperature"
        case .processes: return "Top Processes"
        case .system: return "System"
        }
    }

    public var requiredSource: CollectorID {
        switch self {
        case .cpu: return .cpu
        case .memory: return .memory
        case .gpu: return .gpu
        case .network: return .network
        case .disk: return .disk
        case .battery: return .power
        case .thermal: return .thermal
        case .processes: return .processes
        case .system: return .system
        }
    }

    public var symbolName: String { requiredSource.symbolName }
}

/// What the panel remembers between openings.
///
/// The panel used to be configurable — module order, which modules were on, width,
/// process row count and sort, sparklines, focus behaviour. All of it is gone: the
/// panel is a glance surface reached by one click, and a settings pane with eight
/// controls governing it was more configuration than the surface earns. What remains
/// is the one piece of state the user still sets, and they set it by clicking a
/// heading in the panel itself rather than by opening a window.
public struct PanelSettings: Sendable, Codable, Equatable {
    /// Modules the user has collapsed to just their summary row.
    public var collapsedModules: Set<PanelModule>

    /// Fixed layout, previously the `width` setting. 340pt fits the widest module
    /// summary without wrapping and leaves the panel narrower than the narrowest
    /// MacBook screen at any status item position.
    public static let width: Double = 340
    /// Previously `processRowCount` and `processSortKey`.
    public static let processRowCount = 5
    public static let processSortKey: ProcessSortKey = .cpu
    /// Previously `showsSparklines`; an expanded module always draws its series now.
    public static let showsSparklines = true
    /// Previously `staysOpenOnFocusLoss`. The panel closes when it loses focus, which
    /// is what a menu bar popover does and what clicking outside one means.
    public static let staysOpenOnFocusLoss = false

    public init(collapsedModules: Set<PanelModule> = PanelSettings.defaultCollapsed) {
        self.collapsedModules = collapsedModules
    }

    /// Everything except CPU and Memory starts collapsed.
    ///
    /// A collapsed module still shows its heading and its headline value, so nothing
    /// glanceable is lost — only the detail rows are hidden. With all nine expanded the
    /// panel is ~736pt, about 80% of the usable height on a 14-inch MacBook, and every
    /// module competes at equal weight. Collapsed by default it reads as a summary you
    /// can scan, and the detail is one click away where the user actually wants it.
    public static let defaultCollapsed: Set<PanelModule> = [
        .gpu, .network, .disk, .battery, .thermal, .processes, .system,
    ]

    /// Every module, in declaration order. Was a stored order plus an enabled set;
    /// with the ordering and toggling UI gone there is one canonical arrangement, and
    /// a new release's modules appear without a stored order having to be migrated.
    public var visibleModules: [PanelModule] { PanelModule.allCases }

    private enum CodingKeys: String, CodingKey {
        case collapsedModules
    }

    /// Decoded leniently, and settings files written before the panel pane was removed
    /// still load: the keys they carry for order, width and the rest are simply not
    /// read, and an unknown key has never been an error here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collapsedModules = c.value(.collapsedModules, or: PanelSettings.defaultCollapsed)
    }
}

// MARK: - Charts

public enum ChartStyle: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case line, filledLine, bars

    public var label: String {
        switch self {
        case .line: return "Line"
        case .filledLine: return "Filled Line"
        case .bars: return "Bars"
        }
    }
}

/// What the charts remember.
///
/// Two settings, where there were six. Grid, value labels, curve smoothing and
/// adaptive scaling were each a toggle governing one detail of how a 28-point
/// sparkline is drawn — four decisions the app is better placed to make than the
/// user, and four rows of settings standing between them and the two that change
/// what a chart actually says. They are constants now, at the values every one of
/// them shipped switched on.
public struct ChartSettings: Sendable, Codable, Equatable {
    /// Seconds of history retained and drawn.
    public var historyDuration: TimeInterval
    public var style: ChartStyle

    /// Previously `showsGrid`.
    public static let showsGrid = true
    /// Previously `usesAdaptiveScale`: rate charts scale to the peak in the window,
    /// because a rate has no maximum to scale against instead.
    public static let usesAdaptiveScale = true
    /// Previously `showsValueLabels`.
    public static let showsValueLabels = true
    /// Previously `smoothsCurves`. Smooths the drawn line only; samples are never
    /// averaged, so a spike is still a spike in the number beside it.
    public static let smoothsCurves = true

    public init(historyDuration: TimeInterval = 300,
                style: ChartStyle = .filledLine) {
        self.historyDuration = historyDuration
        self.style = style
    }

    public static let allowedDurations: [TimeInterval] = [60, 300, 600, 1800, 3600]

    private enum CodingKeys: String, CodingKey {
        case historyDuration, style
    }

    /// Files written before the drawing toggles were removed still load: the keys they
    /// carry are simply not read, and an unknown key has never been an error here.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        historyDuration = min(max(c.value(.historyDuration, or: 300.0), 30), 3600)
        style = c.value(.style, or: ChartStyle.filledLine)
    }
}

// MARK: - Overlay

public enum OverlayCorner: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight, free

    public var label: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .free: return "Custom Position"
        }
    }
}

public struct OverlaySettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var modules: [PanelModule]
    public var corner: OverlayCorner
    /// Saved frame in screen coordinates, used when `corner == .free`.
    public var originX: Double?
    public var originY: Double?
    public var width: Double
    public var opacity: Double
    /// Let clicks pass through to whatever is beneath the overlay.
    public var isClickThrough: Bool
    /// Keep above other windows, including full-screen spaces.
    public var floatsAboveEverything: Bool
    public var showsOnAllSpaces: Bool
    /// Fade the overlay down until the pointer is near it.
    public var dimsWhenInactive: Bool
    public var inactiveOpacity: Double
    public var isCompact: Bool

    public init(isEnabled: Bool = false,
                modules: [PanelModule] = [.cpu, .memory, .network],
                corner: OverlayCorner = .topRight,
                originX: Double? = nil,
                originY: Double? = nil,
                width: Double = 220,
                opacity: Double = 0.9,
                isClickThrough: Bool = false,
                floatsAboveEverything: Bool = true,
                showsOnAllSpaces: Bool = true,
                dimsWhenInactive: Bool = true,
                inactiveOpacity: Double = 0.55,
                isCompact: Bool = true) {
        self.isEnabled = isEnabled
        self.modules = modules
        self.corner = corner
        self.originX = originX
        self.originY = originY
        self.width = width
        self.opacity = opacity
        self.isClickThrough = isClickThrough
        self.floatsAboveEverything = floatsAboveEverything
        self.showsOnAllSpaces = showsOnAllSpaces
        self.dimsWhenInactive = dimsWhenInactive
        self.inactiveOpacity = inactiveOpacity
        self.isCompact = isCompact
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, modules, corner, originX, originY, width, opacity
        case isClickThrough, floatsAboveEverything, showsOnAllSpaces
        case dimsWhenInactive, inactiveOpacity, isCompact
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.value(.isEnabled, or: false)
        let decodedModules = c.value(.modules, or: [PanelModule.cpu, .memory, .network])
        modules = decodedModules.isEmpty ? [.cpu, .memory, .network] : decodedModules
        corner = c.value(.corner, or: OverlayCorner.topRight)
        originX = try? c.decodeIfPresent(Double.self, forKey: .originX)
        originY = try? c.decodeIfPresent(Double.self, forKey: .originY)
        width = min(max(c.value(.width, or: 220.0), 160), 480)
        // Never let a stored opacity make the overlay invisible and unrecoverable.
        opacity = min(max(c.value(.opacity, or: 0.9), 0.2), 1)
        isClickThrough = c.value(.isClickThrough, or: false)
        floatsAboveEverything = c.value(.floatsAboveEverything, or: true)
        showsOnAllSpaces = c.value(.showsOnAllSpaces, or: true)
        dimsWhenInactive = c.value(.dimsWhenInactive, or: true)
        inactiveOpacity = min(max(c.value(.inactiveOpacity, or: 0.55), 0.15), 1)
        isCompact = c.value(.isCompact, or: true)
    }
}

// MARK: - Notifications

public enum ThresholdMetric: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case cpuUsage, memoryPressure, diskFree, batteryLow, batteryFull, cpuTemperature, thermalPressure

    public var label: String {
        switch self {
        case .cpuUsage: return "Sustained CPU usage above"
        case .memoryPressure: return "Memory pressure above"
        case .diskFree: return "Startup disk free space below"
        case .batteryLow: return "Battery drops below"
        case .batteryFull: return "Battery reaches"
        case .cpuTemperature: return "CPU temperature above"
        case .thermalPressure: return "Thermal pressure reaches"
        }
    }

    public var unitSuffix: String {
        switch self {
        case .cpuUsage, .memoryPressure, .batteryLow, .batteryFull: return "%"
        case .diskFree: return "GB"
        case .cpuTemperature: return "°"
        case .thermalPressure: return ""
        }
    }

    public var defaultThreshold: Double {
        switch self {
        case .cpuUsage: return 90
        case .memoryPressure: return 80
        case .diskFree: return 10
        case .batteryLow: return 20
        case .batteryFull: return 100
        case .cpuTemperature: return 95
        case .thermalPressure: return 2
        }
    }

    public var requiredSource: CollectorID {
        switch self {
        case .cpuUsage: return .cpu
        case .memoryPressure: return .memory
        case .diskFree: return .disk
        case .batteryLow, .batteryFull: return .power
        case .cpuTemperature, .thermalPressure: return .thermal
        }
    }
}

public struct ThresholdRule: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var metric: ThresholdMetric
    public var threshold: Double
    public var isEnabled: Bool
    /// Seconds the condition must hold before notifying, so a one-second CPU spike
    /// while launching an app does not fire an alert.
    public var sustainedFor: TimeInterval
    /// Minimum seconds between repeat notifications for this rule.
    public var cooldown: TimeInterval

    public init(id: UUID = UUID(), metric: ThresholdMetric, threshold: Double? = nil,
                isEnabled: Bool = false, sustainedFor: TimeInterval = 30,
                cooldown: TimeInterval = 900) {
        self.id = id
        self.metric = metric
        self.threshold = threshold ?? metric.defaultThreshold
        self.isEnabled = isEnabled
        self.sustainedFor = sustainedFor
        self.cooldown = cooldown
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, threshold, isEnabled, sustainedFor, cooldown
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, or: UUID())
        metric = c.value(.metric, or: ThresholdMetric.cpuUsage)
        threshold = c.value(.threshold, or: metric.defaultThreshold)
        isEnabled = c.value(.isEnabled, or: false)
        sustainedFor = min(max(c.value(.sustainedFor, or: 30.0), 0), 3600)
        cooldown = min(max(c.value(.cooldown, or: 900.0), 60), 86400)
    }
}

public struct NotificationSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var rules: [ThresholdRule]

    public init(isEnabled: Bool = false, rules: [ThresholdRule] = NotificationSettings.defaultRules) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public static var defaultRules: [ThresholdRule] {
        ThresholdMetric.allCases.map { ThresholdRule(metric: $0) }
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.value(.isEnabled, or: false)
        var decoded = c.value(.rules, or: NotificationSettings.defaultRules)
        // Add rules for any metric introduced since the file was written.
        let present = Set(decoded.map(\.metric))
        for metric in ThresholdMetric.allCases where !present.contains(metric) {
            decoded.append(ThresholdRule(metric: metric))
        }
        rules = decoded
    }

    public var enabledRules: [ThresholdRule] { rules.filter(\.isEnabled) }
}

// MARK: - Shortcuts

/// A recorded key combination. Stored as a raw key code plus modifier bitmask so it
/// survives keyboard layout changes.
public struct KeyboardShortcut: Sendable, Codable, Equatable, Hashable {
    public var keyCode: UInt16
    public var modifierFlags: UInt
    public var characters: String

    public init(keyCode: UInt16, modifierFlags: UInt, characters: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
    }
}

public enum ShortcutAction: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case togglePanel, toggleOverlay, openSettings

    public var label: String {
        switch self {
        case .togglePanel: return "Show / Hide Panel"
        case .toggleOverlay: return "Show / Hide Overlay"
        case .openSettings: return "Open Settings"
        }
    }
}

public struct ShortcutSettings: Sendable, Codable, Equatable {
    public var bindings: [ShortcutAction: KeyboardShortcut]

    public init(bindings: [ShortcutAction: KeyboardShortcut] = [:]) {
        self.bindings = bindings
    }

    private enum CodingKeys: String, CodingKey { case bindings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bindings = c.value(.bindings, or: [:])
    }
}

// MARK: - General

public struct GeneralSettings: Sendable, Codable, Equatable {
    /// Seconds between sampling cycles. Individual collectors may run slower.
    public var updateInterval: TimeInterval
    public var launchAtLogin: Bool
    public var appearance: AppearanceMode
    public var temperatureUnit: TemperatureUnit
    public var networkRateUnit: NetworkRateUnit
    public var byteUnitStyle: ByteUnitStyle
    public var showsPercentSign: Bool
    /// Drop to a quarter cadence when the menu bar item is not visible.
    public var throttlesWhenOccluded: Bool
    /// Suspend sampling entirely while on battery below a threshold.
    public var pausesOnLowPower: Bool
    /// Fetch the public IP address (the only feature that leaves the machine).
    public var fetchesPublicIP: Bool
    public var showsDockIcon: Bool

    public init(updateInterval: TimeInterval = 2,
                launchAtLogin: Bool = false,
                appearance: AppearanceMode = .system,
                temperatureUnit: TemperatureUnit = .celsius,
                networkRateUnit: NetworkRateUnit = .bytes,
                byteUnitStyle: ByteUnitStyle = .decimal,
                showsPercentSign: Bool = true,
                throttlesWhenOccluded: Bool = true,
                pausesOnLowPower: Bool = false,
                fetchesPublicIP: Bool = false,
                showsDockIcon: Bool = false) {
        self.updateInterval = updateInterval
        self.launchAtLogin = launchAtLogin
        self.appearance = appearance
        self.temperatureUnit = temperatureUnit
        self.networkRateUnit = networkRateUnit
        self.byteUnitStyle = byteUnitStyle
        self.showsPercentSign = showsPercentSign
        self.throttlesWhenOccluded = throttlesWhenOccluded
        self.pausesOnLowPower = pausesOnLowPower
        self.fetchesPublicIP = fetchesPublicIP
        self.showsDockIcon = showsDockIcon
    }

    public static let allowedIntervals: [TimeInterval] = [0.5, 1, 2, 3, 5, 10, 30]

    private enum CodingKeys: String, CodingKey {
        case updateInterval, launchAtLogin, appearance, temperatureUnit, networkRateUnit
        case byteUnitStyle, showsPercentSign, throttlesWhenOccluded, pausesOnLowPower
        case fetchesPublicIP, showsDockIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updateInterval = min(max(c.value(.updateInterval, or: 2.0), 0.5), 60)
        launchAtLogin = c.value(.launchAtLogin, or: false)
        appearance = c.value(.appearance, or: AppearanceMode.system)
        temperatureUnit = c.value(.temperatureUnit, or: TemperatureUnit.celsius)
        networkRateUnit = c.value(.networkRateUnit, or: NetworkRateUnit.bytes)
        byteUnitStyle = c.value(.byteUnitStyle, or: ByteUnitStyle.decimal)
        showsPercentSign = c.value(.showsPercentSign, or: true)
        throttlesWhenOccluded = c.value(.throttlesWhenOccluded, or: true)
        pausesOnLowPower = c.value(.pausesOnLowPower, or: false)
        fetchesPublicIP = c.value(.fetchesPublicIP, or: false)
        showsDockIcon = c.value(.showsDockIcon, or: false)
    }
}

// MARK: - Root

// MARK: - Theme

/// One user-chosen colour, stored as sRGB components.
///
/// Components rather than a hex string because that is what `ColorPicker` hands back
/// and what `NSColor` wants, and round-tripping through hex would quantise a colour
/// the user picked to eight bits per channel every time the file was written.
public struct ThemeColor: Sendable, Codable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: c.value(.red, or: 0.5),
                  green: c.value(.green, or: 0.5),
                  blue: c.value(.blue, or: 0.5))
    }
}

/// User overrides for the app's colours.
///
/// Every field is optional, and nil means "use what the app shipped". That is the
/// whole design: the defaults are Apple's semantic system colours, which already
/// track light, dark, increased-contrast and vibrancy correctly, and a stored copy
/// of one of them would freeze it at whatever it resolved to on the day it was
/// picked. So an untouched install stores nothing and keeps following the system;
/// only a colour the user deliberately chose is written down.
public struct ThemeSettings: Sendable, Codable, Equatable {
    /// Per-metric identity colours, keyed by `CollectorID.rawValue`.
    ///
    /// Keyed by the raw string rather than by `CollectorID` so a collector that is
    /// renamed or removed in a later build leaves an ignorable entry behind instead
    /// of failing the whole decode.
    ///
    /// The one thing this type stores. The accent colour was editable here too, and
    /// should not have been: selection is a system-wide choice the user already made
    /// in System Settings, and an app that quietly disagrees with it is not theming
    /// itself, it is ignoring them. A previously stored `accent` key decodes to
    /// nothing and is dropped on the next save.
    public var metrics: [String: ThemeColor]

    public init(metrics: [String: ThemeColor] = [:]) {
        self.metrics = metrics
    }

    public func color(for id: CollectorID) -> ThemeColor? { metrics[id.rawValue] }

    public mutating func setColor(_ color: ThemeColor?, for id: CollectorID) {
        metrics[id.rawValue] = color
    }

    /// Puts every metric on one colour, or back on the colours the app ships with.
    ///
    /// Nil clears the whole dictionary rather than writing nine copies of a default:
    /// an absent entry is what makes a metric follow Apple's semantic colour through
    /// appearance and contrast changes, and a stored copy of that colour would not.
    public mutating func setAllColors(_ color: ThemeColor?) {
        guard let color else { metrics.removeAll(); return }
        for id in CollectorID.allCases { metrics[id.rawValue] = color }
    }

    /// The single colour every metric is currently set to, or nil if any is on its
    /// default or differs from the rest.
    public var uniformColor: ThemeColor? {
        var shared: ThemeColor?
        for id in CollectorID.allCases {
            guard let color = metrics[id.rawValue] else { return nil }
            if let shared, shared != color { return nil }
            shared = color
        }
        return shared
    }

    private enum CodingKeys: String, CodingKey { case metrics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metrics = c.value(.metrics, or: [:])
    }
}

public struct Settings: Sendable, Codable, Equatable {
    /// Bumped when a migration is needed. Unknown future versions are loaded
    /// leniently rather than discarded.
    public var schemaVersion: Int
    public var general: GeneralSettings
    public var menuBar: MenuBarSettings
    public var panel: PanelSettings
    public var charts: ChartSettings
    public var overlay: OverlaySettings
    public var notifications: NotificationSettings
    public var shortcuts: ShortcutSettings
    public var theme: ThemeSettings

    public static let currentSchemaVersion = 1

    public init(schemaVersion: Int = Settings.currentSchemaVersion,
                general: GeneralSettings = .init(),
                menuBar: MenuBarSettings = .init(),
                panel: PanelSettings = .init(),
                charts: ChartSettings = .init(),
                overlay: OverlaySettings = .init(),
                notifications: NotificationSettings = .init(),
                shortcuts: ShortcutSettings = .init(),
                theme: ThemeSettings = .init()) {
        self.schemaVersion = schemaVersion
        self.general = general
        self.menuBar = menuBar
        self.panel = panel
        self.charts = charts
        self.overlay = overlay
        self.notifications = notifications
        self.shortcuts = shortcuts
        self.theme = theme
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, general, menuBar, panel, charts, overlay, notifications
        case shortcuts, theme
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = c.value(.schemaVersion, or: Settings.currentSchemaVersion)
        general = c.value(.general, or: GeneralSettings())
        menuBar = c.value(.menuBar, or: MenuBarSettings())
        panel = c.value(.panel, or: PanelSettings())
        charts = c.value(.charts, or: ChartSettings())
        overlay = c.value(.overlay, or: OverlaySettings())
        notifications = c.value(.notifications, or: NotificationSettings())
        shortcuts = c.value(.shortcuts, or: ShortcutSettings())
        theme = c.value(.theme, or: ThemeSettings())
    }

    /// Collectors that must run to satisfy everything currently on screen.
    ///
    /// This drives the engine's enabled-source set, and is why a user who only
    /// wants a CPU readout never pays for IOKit battery or SMC sensor polling.
    public func requiredSources(panelVisible: Bool, overlayVisible: Bool) -> Set<CollectorID> {
        var sources = Set<CollectorID>()
        for item in menuBar.enabledItems { sources.insert(item.metric.requiredSource) }
        if panelVisible {
            for module in panel.visibleModules { sources.insert(module.requiredSource) }
        }
        if overlayVisible {
            for module in overlay.modules { sources.insert(module.requiredSource) }
        }
        if notifications.isEnabled {
            for rule in notifications.enabledRules { sources.insert(rule.metric.requiredSource) }
        }
        // System info is cheap, static, and needed for the about/uptime readouts.
        sources.insert(.system)
        return sources
    }

    /// Number of retained samples implied by the chart history and update interval.
    public var historyCapacity: Int {
        let interval = max(general.updateInterval, 0.5)
        return min(max(Int(charts.historyDuration / interval) + 2, 30), 4096)
    }
}
