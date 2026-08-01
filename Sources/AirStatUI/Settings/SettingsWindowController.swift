import AppKit
import SwiftUI
import AirStatKit

/// Standard document-less preferences window.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private var window: NSWindow?

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
        super.init()
    }

    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Two preferences are process state rather than stored values, so they take
        // effect only when something applies them. Doing it here means opening
        // settings always reconciles the app with what the user asked for, whatever
        // happened at launch.
        applyProcessPreferences()
        // A menu bar app is an accessory; it must activate explicitly or the
        // settings window opens behind whatever the user was doing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    /// Panes of forms, chart galleries and colour wells cost 12.6 MB of dirty,
    /// non-reclaimable heap (`footprint`, MALLOC_SMALL, this machine) once they have
    /// been built. Settings is opened rarely and closed for the rest of the session, so
    /// keeping that resident until quit is the worst of both worlds — the window is
    /// discarded on close and rebuilt on the next `show`.
    public func windowWillClose(_ notification: Notification) {
        // The colour panel is not ours and does not go with the window; left alone it
        // stays on screen editing a swatch that no longer exists.
        ColorPanel.close()
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow()
        let root = SettingsRootView(settings: settings, engine: engine) { [weak window] tab in
            window?.title = tab.label
        }
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "AirStat Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // Stock window chrome. A transparent titlebar over a cleared background was
        // what squared off the corners and made this stop looking like a Mac settings
        // window: the frame view rounds and masks the content it owns, and it only
        // owns it while the window is drawing itself normally.
        window.setContentSize(SettingsRootView.windowSize)
        window.setFrameAutosaveName("AirStatSettingsWindow")
        return window
    }

    private func applyProcessPreferences() {
        switch settings.settings.general.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.setActivationPolicy(settings.settings.general.showsDockIcon ? .regular : .accessory)
    }
}

/// The settings window's content: a source list of panes beside the selected one,
/// which is the shape macOS System Settings uses.
struct SettingsRootView: View {
    let settings: SettingsStore
    let engine: MetricsEngine?
    /// Lets the window title follow the selected pane, which is what System
    /// Settings does and what `navigationTitle` used to give us for free.
    var onPaneChange: ((SettingsTab) -> Void)?

    @State private var tab: SettingsTab

    /// Fixed rather than resizable, so the offscreen renderer measures the same
    /// window the user gets. Each pane scrolls its own form.
    static let windowSize = NSSize(width: 760, height: 560)

    init(settings: SettingsStore, engine: MetricsEngine? = nil, initialTab: SettingsTab? = nil,
         onPaneChange: ((SettingsTab) -> Void)? = nil) {
        self.settings = settings
        self.engine = engine
        self.onPaneChange = onPaneChange
        _tab = State(initialValue: initialTab ?? SettingsTab.renderDefault)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsRootView.sidebarWidth)
                .background(VisualEffect(material: .sidebar))
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The material macOS gives a window's content area, beside the one it
                // gives a source list. Glass was tried here and does not belong: this
                // is a settings window, not a floating panel, and Apple does not make
                // one you can see the desktop through.
                .background(VisualEffect(material: .contentBackground))
        }
        .frame(width: windowWidth, height: windowHeight)
        .onAppear { onPaneChange?(tab) }
        .onChange(of: tab) { _, newValue in
            // The colour wheel belongs to the row that opened it. Leaving another
            // pane's swatch being edited from a floating window is how you end up
            // dragging a colour onto something you cannot see.
            ColorPanel.close()
            onPaneChange?(newValue)
        }
    }

    /// Laid out by hand rather than with `NavigationSplitView`, which drew an opaque
    /// black 0.5pt rule between the columns — measured `#000000` at the seam in both
    /// appearances, in the real window as well as the render. The sidebar's own
    /// material is what separates the columns on macOS; there is no rule to draw.
    ///
    /// Buttons rather than a `List`: every row stays keyboard-focusable, and the
    /// source list survives offscreen rendering, which an `NSTableView` does not.
    private var sidebar: some View {
        ScrollView {
            VStack(spacing: Design.Space.xxs) {
                ForEach(SettingsTab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: item.symbolName)
                                // SF Symbols differ in width, and a Label leaves that
                                // difference in the layout: the eight titles started
                                // at x positions spanning 6pt. A fixed box centres
                                // them, and the explicit size keeps the widest glyph
                                // (keyboard, menubar.rectangle) from spilling out of
                                // it and dragging its title along.
                                .font(.system(size: 13))
                                .frame(width: 22, alignment: .center)
                            Text(item.label)
                        }
                            // The source-list selection pair, not the accent colour:
                            // these two track each other through graphite, increased
                            // contrast and an inactive window, which accent plus a
                            // hardcoded white does not.
                            .foregroundStyle(item == tab
                                             ? Color(nsColor: .alternateSelectedControlTextColor)
                                             : Design.Palette.primaryText)
                            .padding(.horizontal, Design.Space.m)
                            .padding(.vertical, Design.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                                    .fill(item == tab
                                          ? Color(nsColor: .selectedContentBackgroundColor)
                                          : Color.clear)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control,
                                                           style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // One element per row rather than a container holding an image
                    // and a label, so VoiceOver announces "General, selected,
                    // button" instead of walking into the row's decoration.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(item == tab ? [.isSelected, .isButton] : .isButton)
                    .accessibilityHint("Show \(item.label) settings")
                }
            }
            .padding(Design.Space.m)
        }
        .accessibilityLabel("Settings sections")
    }

    private var windowWidth: CGFloat { SettingsRootView.windowSize.width }
    private var windowHeight: CGFloat { SettingsRootView.windowSize.height }
    private static let sidebarWidth: CGFloat = 184

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralPane(settings: settings)
        case .menuBar: MenuBarPane(settings: settings, engine: engine)
        case .appearance: AppearancePane(settings: settings)
        case .overlay: OverlayPane(settings: settings, engine: engine)
        case .notifications: NotificationsPane(settings: settings, engine: engine)
        case .about: AboutPane(settings: settings, engine: engine)
        }
    }
}
