import SwiftUI
import AppKit
import AirStatKit

/// AirStat's visual language.
///
/// The governing idea: this app sits inside macOS, not beside it. Every value here
/// is either lifted from an Apple semantic token or measured against a system
/// surface (the menu bar, a Control Center tile, an Activity Monitor row). Nothing
/// is invented for its own sake, because anything invented is what makes a Mac app
/// read as "not quite native".
public enum Design {

    // MARK: - Spacing

    /// A 4pt base grid. Every margin, gap and inset in the app is a multiple of it,
    /// so vertical rhythm holds even as modules are reordered.
    public enum Space {
        public static let hairline: CGFloat = 1
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24

        /// Horizontal inset for panel content. Matches the leading inset macOS uses
        /// for menu item text, so labels line up with the system menus above them.
        public static let panelInset: CGFloat = 14
        /// Vertical padding inside one module block.
        public static let moduleVertical: CGFloat = 10
        /// Gap between a label and its value in a readout row.
        public static let rowGap: CGFloat = 12
    }

    // MARK: - Typography

    /// Type scale built from `NSFont` system faces so it tracks the user's Dynamic
    /// Type and accessibility text settings rather than freezing point sizes.
    public enum Text {
        /// Module headings: "CPU", "Memory".
        public static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// Row labels: "Usage", "Pressure".
        public static let label = Font.system(size: 11, weight: .regular)
        /// Row values. Monospaced digits so a column of numbers does not shimmer as
        /// digits change width — the single most visible cheapness tell in a stats app.
        public static let value = Font.system(size: 11, weight: .medium).monospacedDigit()
        /// The one large number at the top of a module.
        public static let headline = Font.system(size: 20, weight: .medium).monospacedDigit()
        /// Secondary detail under a headline.
        public static let caption = Font.system(size: 10, weight: .regular)
        /// Smallest legible tier — axis ticks, units, footnotes.
        public static let micro = Font.system(size: 9, weight: .regular)
        /// Process names and other user-supplied strings.
        public static let body = Font.system(size: 11, weight: .regular)
    }

    // MARK: - Colour

    /// Semantic colours. Everything resolves through AppKit's dynamic colours so
    /// light, dark, increased-contrast and vibrancy all follow the system for free.
    public enum Palette {
        public static let primaryText = Color(nsColor: .labelColor)
        public static let secondaryText = Color(nsColor: .secondaryLabelColor)
        public static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
        public static let quaternaryText = Color(nsColor: .quaternaryLabelColor)
        public static let separator = Color(nsColor: .separatorColor)

        /// Selection and the overlay's grab handle. Follows the user's system accent
        /// unless they have chosen one here.
        public static var accent: Color {
            SettingsStore.currentTheme.accent.map(Color.init(themeColor:))
                ?? Color(nsColor: .controlAccentColor)
        }

        /// Per-metric identity colours, used sparingly: in charts, and in the panel
        /// only as a small glyph tint.
        ///
        /// The shipped values are Apple's system palette rather than custom hexes, so
        /// they shift correctly in dark mode and increased contrast. A user override
        /// is a fixed sRGB triple and cannot do that — which is the trade the user
        /// makes by picking one, and the reason nothing is stored until they do.
        public static func metric(_ id: CollectorID) -> Color {
            if let custom = SettingsStore.currentTheme.color(for: id) {
                return Color(themeColor: custom)
            }
            return defaultMetric(id)
        }

        /// What `metric` returns with no override in place. Public so the colour
        /// editor can show what "Default" means and reset back to it.
        public static func defaultMetric(_ id: CollectorID) -> Color {
            switch id {
            case .cpu: return Color(nsColor: .systemBlue)
            case .memory: return Color(nsColor: .systemGreen)
            case .gpu: return Color(nsColor: .systemPurple)
            case .network: return Color(nsColor: .systemTeal)
            case .disk: return Color(nsColor: .systemIndigo)
            case .power: return Color(nsColor: .systemGreen)
            case .thermal: return Color(nsColor: .systemOrange)
            case .processes: return Color(nsColor: .systemGray)
            case .system: return Color(nsColor: .systemGray)
            }
        }

        /// Severity ramp for FILLS — bars, badges, glyph backgrounds — where the colour
        /// sits behind or beside content rather than being read as text.
        ///
        /// Deliberately does NOT go green at "normal": a green dot on every idle metric
        /// is visual noise. Normal is neutral; colour appears only when something wants
        /// attention.
        public static func severity(_ severity: MetricSeverity) -> Color {
            switch severity {
            case .normal: return Color(nsColor: .secondaryLabelColor)
            case .elevated: return Color(nsColor: .systemYellow)
            case .high: return Color(nsColor: .systemOrange)
            case .critical: return Color(nsColor: .systemRed)
            }
        }

        /// Severity ramp for TEXT and thin glyphs.
        ///
        /// The fill ramp is unusable as foreground in light mode. Measured against the
        /// panel's `#F1F1F1` material, `systemYellow` renders at 1.34:1 and
        /// `systemOrange` at 2.04:1 — so the *worse* the news, the less legible the
        /// number becomes, which is the opposite of what a severity colour is for.
        /// These variants darken in light appearance and keep the vivid system colours
        /// in dark, where they already clear contrast comfortably.
        public static func severityText(_ severity: MetricSeverity) -> Color {
            switch severity {
            case .normal:
                return Color(nsColor: .labelColor)
            case .elevated:
                return Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.isDark ? .systemYellow : NSColor(srgbRed: 0.62, green: 0.44, blue: 0.00, alpha: 1)
                })
            case .high:
                return Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.isDark ? .systemOrange : NSColor(srgbRed: 0.72, green: 0.33, blue: 0.00, alpha: 1)
                })
            case .critical:
                return Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.isDark ? .systemRed : NSColor(srgbRed: 0.75, green: 0.05, blue: 0.10, alpha: 1)
                })
            }
        }

        /// Track behind bars, rings and gauges.
        ///
        /// A bar whose track is invisible communicates magnitude while withholding
        /// scale: 97% and 79% look identical because the eye cannot see where either
        /// ends. `quaternaryLabelColor` at 45% measured 1.07:1 against the panel
        /// material — effectively no track at all. This is deliberately strong enough
        /// to read as a bounded container in both appearances.
        /// Do NOT apply additional opacity to this at the call site — it is already
        /// tuned to land near 1.75:1 against the panel material, and stacking another
        /// `.opacity()` on it is what put the measured track back at 1.19:1.
        public static let track = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(white: 1, alpha: 0.24)
                : NSColor(white: 0, alpha: 0.25)
        })
    }

    // MARK: - Shape

    public enum Radius {
        /// Panel and overlay corners. 12 matches the curvature macOS gives menus and
        /// Control Center popovers at this size.
        public static let panel: CGFloat = 12
        public static let card: CGFloat = 8
        public static let control: CGFloat = 6
        public static let bar: CGFloat = 2.5
    }

    // MARK: - Motion

    /// Animation is used only where it carries meaning: a value changing, a module
    /// expanding. Never decoratively, and never long enough to make the app feel slow.
    public enum Motion {
        /// Numeric readouts crossfading to a new value.
        public static let value = Animation.easeOut(duration: 0.18)
        /// Disclosure, module expand/collapse.
        public static let disclosure = Animation.spring(response: 0.32, dampingFraction: 0.86)
        /// Panel present/dismiss.
        public static let present = Animation.easeOut(duration: 0.14)
        /// Hover highlight.
        public static let hover = Animation.easeOut(duration: 0.12)

        /// Honours "Reduce Motion". Call this instead of using the constants directly
        /// anywhere a position or size changes.
        public static func respectingAccessibility(_ animation: Animation) -> Animation? {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
        }
    }

    // MARK: - Chart geometry

    public enum Chart {
        public static let sparklineHeight: CGFloat = 28
        public static let detailHeight: CGFloat = 64
        public static let lineWidth: CGFloat = 1.5
        public static let fillOpacity: Double = 0.16
        public static let gridOpacity: Double = 0.08
        /// Points below which a series is drawn as a flat baseline rather than a line,
        /// so a chart with two samples does not imply a trend it cannot support.
        public static let minimumPoints = 3
    }

    // MARK: - Menu bar

    /// Constants for the status item. Separated because the menu bar has its own
    /// rules: it is a fixed-height monochrome surface owned by the system.
    public enum MenuBar {
        public static let valueFontSize: CGFloat = 12
        public static let captionFontSize: CGFloat = 9
        /// Type for an item that stacks its caption above its number.
        ///
        /// Smaller than the single-line sizes because two rows have to share the bar's
        /// ~22pt. At the full sizes the two cap-height boxes plus a gap come to 16pt
        /// before any breathing room, which leaves the pair crowding the menu bar's
        /// edges; at these, 12.6pt, which sits comfortably.
        public static let stackedValueFontSize: CGFloat = 10
        public static let stackedCaptionFontSize: CGFloat = 8
        /// Vertical gap between the two rows, between their cap-height boxes rather
        /// than their line boxes.
        public static let stackedRowGap: CGFloat = 1
        public static let graphWidth: CGFloat = 34
        public static let graphHeight: CGFloat = 11
        public static let horizontalInset: CGFloat = 3
    }
}

// MARK: - Environment

/// The formatter, threaded through the view tree so no view constructs its own and
/// unit preferences can never diverge between two readouts on the same screen.
private struct FormatterKey: EnvironmentKey {
    static let defaultValue = MetricFormatter()
}

extension EnvironmentValues {
    public var metricFormatter: MetricFormatter {
        get { self[FormatterKey.self] }
        set { self[FormatterKey.self] = newValue }
    }
}

// MARK: - Shared primitives

/// A label/value line — the atom the whole panel is built from.
///
/// Values are trailing-aligned with monospaced digits so every row in a module forms
/// a clean right edge, which is what lets the eye scan a column of numbers.
public struct ReadoutRow: View {
    private let label: String
    private let value: String
    private let severity: MetricSeverity
    private let isDimmed: Bool

    public init(_ label: String, _ value: String,
                severity: MetricSeverity = .normal, isDimmed: Bool = false) {
        self.label = label
        self.value = value
        self.severity = severity
        self.isDimmed = isDimmed
    }

    public var body: some View {
        HStack(spacing: Design.Space.rowGap) {
            SwiftUI.Text(label)
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.Space.m)
            SwiftUI.Text(value)
                .font(Design.Text.value)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .opacity(isDimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var valueColor: Color {
        severity == .normal ? Design.Palette.primaryText : Design.Palette.severity(severity)
    }
}

/// Horizontal capacity bar. Used for anything with a real 0...1 maximum, and never
/// for a rate, which has none.
public struct CapacityBar: View {
    private let fraction: Double
    private let tint: Color
    private let height: CGFloat

    public init(fraction: Double, tint: Color, height: CGFloat = 5) {
        self.fraction = min(max(fraction, 0), 1)
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Design.Palette.track)
                Capsule(style: .continuous)
                    .fill(tint)
                    // Never let a non-zero value render as an invisible sliver; the
                    // minimum width keeps 0.4% readable as "a little" rather than "none".
                    .frame(width: max(fraction > 0 ? height : 0, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(Design.Motion.respectingAccessibility(Design.Motion.value), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A value that is genuinely unavailable, rendered as an explanation rather than a
/// number. Central so every module fails the same way.
public struct UnavailableNote: View {
    private let failure: MetricFailure

    public init(_ failure: MetricFailure) { self.failure = failure }

    public var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Design.Palette.tertiaryText)
            SwiftUI.Text(failure.message)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unavailable. \(failure.message)")
    }

    private var symbol: String {
        switch failure {
        case .unsupported: return "minus.circle"
        case .denied: return "lock"
        case .failed: return "exclamationmark.triangle"
        case .pending: return "clock"
        }
    }
}

/// Renders a metric's content when it is available and an explanation when it is not.
/// Every module routes through this so no code path can accidentally show a zero for
/// a value the app does not actually have.
public struct MetricContent<Value: Sendable & Equatable, Content: View>: View {
    private let state: MetricState<Value>
    private let content: (Value) -> Content

    public init(_ state: MetricState<Value>, @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.content = content
    }

    public var body: some View {
        switch state {
        case .value(let value):
            content(value)
        case .failure(let failure):
            UnavailableNote(failure)
        }
    }
}

// MARK: - Surfaces

extension View {
    /// Background for a surface that floats above content the app does not own.
    ///
    /// On macOS 26 this is Liquid Glass. Apple's guidance puts glass in the functional
    /// layer — chrome that floats over content — and never in the content layer, and
    /// the overlay is the one surface here that is unambiguously the former: it sits
    /// on top of whatever the user happens to be looking at.
    ///
    /// Nothing else in the app takes this. The panel and the settings sidebar are
    /// already drawn with `NSVisualEffectView`'s `.menu` and `.sidebar` materials,
    /// which macOS 26 renders as glass on its own; putting `glassEffect` on top of
    /// them would be glass sampling glass, which is the documented anti-pattern and
    /// looks it. Form rows are content and take no material at all.
    ///
    /// Currently `.regularMaterial` everywhere, because the toolchain cannot build the
    /// glass path yet: `glassEffect` needs the macOS 26 SDK from Xcode 26, and this
    /// project builds against Xcode 16's macOS 15 SDK. It is not a deployment-target
    /// question — `Package.swift` targets macOS 14 and an `#available(macOS 26)` check
    /// would handle that fine — the symbol simply does not exist to compile against.
    ///
    /// This exists as its own modifier so that turning it on is a change to one
    /// function rather than a hunt through the view tree. Once Xcode 26 is installed:
    ///
    ///     if #available(macOS 26.0, *) {
    ///         glassEffect(.regular, in: shape)
    ///     } else {
    ///         background(.regularMaterial, in: shape)
    ///     }
    ///
    /// Reduce Transparency needs no handling at the call site in either form; the
    /// system substitutes an opaque fill for both material and glass.
    func floatingSurface(in shape: some Shape) -> some View {
        background(.regularMaterial, in: shape)
    }
}

// MARK: - Theme colour bridging

extension Color {
    /// A stored override, as a drawable colour. Built in sRGB because that is the
    /// space the components were captured in.
    public init(themeColor: ThemeColor) {
        self.init(.sRGB, red: themeColor.red, green: themeColor.green, blue: themeColor.blue)
    }

    /// This colour as storable components, or nil if it cannot be resolved into sRGB.
    ///
    /// A dynamic system colour resolves against whatever appearance is current when
    /// this is called, which is exactly right here: the user is looking at the swatch
    /// they are about to replace, and what they saw is what gets written down.
    public var themeColor: ThemeColor? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return ThemeColor(red: Double(srgb.redComponent),
                          green: Double(srgb.greenComponent),
                          blue: Double(srgb.blueComponent))
    }
}

extension NSAppearance {
    /// True when this appearance resolves to a dark variant. Used by the dynamic
    /// colours above, which must pick different values per appearance rather than
    /// relying on a single static colour that only works in one of them.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
