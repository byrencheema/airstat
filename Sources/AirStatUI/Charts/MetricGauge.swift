import SwiftUI
import AirStatKit

/// A bounded 0...1 dial.
///
/// Named `MetricGauge` rather than `Gauge` because SwiftUI already owns that name on
/// macOS 13+; the same collision `AirStatKit.Settings` has with `SwiftUI.Settings`.
///
/// Only for values with a real maximum — utilisation, charge, capacity. A rate has no
/// ceiling, so a ring showing "network at 60 %" would be meaningless; use a chart.
public struct MetricGauge: View {

    public enum Style: Equatable, Sendable {
        /// A full circle. Reads as a proportion.
        case ring
        /// A three-quarter dial with a visible start and end. Reads as a measurement.
        case arc
    }

    private let fraction: Double
    private let tint: Color
    private let style: Style
    private let lineWidth: CGFloat
    private let diameter: CGFloat
    private let label: String
    private let caption: String?

    @Environment(\.metricFormatter) private var formatter

    /// - Parameters:
    ///   - fraction: 0...1. Clamped, because a gauge that overflows its own dial is
    ///     not telling the truth about being bounded.
    ///   - label: what the gauge measures, for the screen reader.
    ///   - caption: the text drawn in the middle. Nil draws nothing there.
    public init(fraction: Double,
                tint: Color,
                label: String,
                caption: String? = nil,
                style: Style = .ring,
                diameter: CGFloat = 44,
                lineWidth: CGFloat = 4) {
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.tint = tint
        self.label = label
        self.caption = caption
        self.style = style
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        .frame(width: diameter, height: diameter)
        .overlay { captionText }
        .animation(Design.Motion.respectingAccessibility(Design.Motion.value), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(caption ?? formatter.percent(fraction))
    }

    @ViewBuilder
    private var captionText: some View {
        if let caption {
            SwiftUI.Text(caption)
                .font(Design.Text.caption.monospacedDigit())
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, lineWidth + Design.Space.xxs)
                .accessibilityHidden(true)
        }
    }

    private var sweep: Angle { style == .ring ? .degrees(360) : .degrees(270) }
    private var start: Angle { style == .ring ? .degrees(-90) : .degrees(135) }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let inset = lineWidth / 2
        let radius = min(size.width, size.height) / 2 - inset
        guard radius > 0 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round)

        var track = Path()
        track.addArc(center: centre, radius: radius, startAngle: start,
                     endAngle: start + sweep, clockwise: false)
        context.stroke(track, with: .color(Design.Palette.track), style: stroke)

        guard fraction > 0 else { return }
        var value = Path()
        // A round cap already occupies a visible slice of arc, so the smallest
        // non-zero reading is legible without inflating the sweep it represents.
        value.addArc(center: centre, radius: radius, startAngle: start,
                     endAngle: start + sweep * fraction, clockwise: false)
        context.stroke(value, with: .color(tint), style: stroke)
    }
}
