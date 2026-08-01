import SwiftUI
import AppKit
import AirStatKit

/// Root of the click-down panel.
///
/// A stack of modules in the user's order, each carrying its own headline value, over
/// a footer. The panel sizes to its content and has no chrome of its own; it scrolls
/// only in the one case where it would otherwise run off the screen.
public struct PanelRootView: View {

    private let engine: MetricsEngine
    private let settings: SettingsStore

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                        if index > 0, separatorNeeded(before: index) { PanelSeparator() }
                        PanelModuleView(module: module, engine: engine, settings: settings)
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: Self.maximumModuleHeight)
            PanelSeparator()
            PanelFooterView()
        }
        .frame(width: PanelSettings.width)
        .environment(\.metricFormatter, MetricFormatter(settings: settings.settings.general))
    }

    private var modules: [PanelModule] { settings.settings.panel.visibleModules }

    /// A rule earns its place only where it delimits a block of detail.
    ///
    /// Drawing one between every module turned the panel into a ruled table — nine
    /// full-width lines competing with the content they were meant to organise. Between
    /// two collapsed summary rows there is nothing to divide: the rows already read as a
    /// list. So a separator appears only where an expanded module begins or ends, which
    /// is exactly where the eye needs to know a block started.
    private func separatorNeeded(before index: Int) -> Bool {
        let collapsed = settings.settings.panel.collapsedModules
        let previous = modules[index - 1]
        let current = modules[index]
        return !collapsed.contains(previous) || !collapsed.contains(current)
    }

    /// A ceiling the module list refuses to grow past.
    ///
    /// The footer sits outside the scroll region, so Settings and Quit stay on screen
    /// no matter how many modules are enabled or how long the process list gets — the
    /// positioning code has no answer for a window taller than `visibleFrame` beyond
    /// pinning it and letting the bottom fall away. Below the ceiling `fixedSize` still
    /// sizes the window to its content, so nothing scrolls in the ordinary case.
    private static var maximumModuleHeight: CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return .infinity }
        return max(visible - Design.Space.xxl * 3, 240)
    }
}

/// Inset rule between modules. macOS insets its separators to the content margin so
/// they read as dividing the text, not as slicing the window in half.
struct PanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Design.Palette.separator)
            .frame(height: Design.Space.hairline)
            .padding(.horizontal, Design.Space.panelInset)
            .accessibilityHidden(true)
    }
}

struct PanelFooterView: View {
    @Environment(\.panelActions) private var actions

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            PanelFooterButton(title: "Settings…", symbol: "gearshape", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: Design.Space.m)
            PanelFooterButton(title: "Quit", symbol: "power", action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, Design.Space.s)
        .padding(.vertical, Design.Space.xs)
    }
}

/// A footer control styled like a macOS menu item rather than a hyperlink: the whole
/// row highlights on hover, and the hit target is the highlight.
struct PanelFooterButton: View {
    let title: String
    let symbol: String
    let action: @MainActor () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                Text(title)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(isHovering ? Design.Palette.track : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(title)
    }
}
