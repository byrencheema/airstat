import AppKit
import SwiftUI
import AirStatKit

/// Renders AirStat's surfaces to PNG files without a screen.
///
/// Screen capture needs a TCC grant and produces whatever the machine happened to
/// look like at that instant. Rendering offscreen instead is deterministic — same
/// fixture data, same output, every time — and lets a reviewer force combinations
/// that are awkward to stage by hand: light and dark, 1x and 2x, the failure states,
/// and the moment a value is at its widest.
@MainActor
public enum OffscreenRenderer {

    public enum Surface: String, CaseIterable, Sendable {
        case menuBar, panel, overlay, settings

        public var label: String {
            switch self {
            case .menuBar: return "menu-bar"
            case .panel: return "panel"
            case .overlay: return "overlay"
            case .settings: return "settings"
            }
        }
    }

    public enum Scenario: String, CaseIterable, Sendable {
        case nominal, underLoad, degraded, pending

        public var snapshot: SystemSnapshot {
            switch self {
            case .nominal: return SnapshotFixtures.nominal
            case .underLoad: return SnapshotFixtures.underLoad
            case .degraded: return SnapshotFixtures.degraded
            case .pending: return SnapshotFixtures.pending
            }
        }

        /// The pending state has no history by definition; everything else gets a
        /// realistic waveform so charts are exercised.
        public var history: MetricHistory {
            self == .pending ? MetricHistory() : SnapshotFixtures.history()
        }
    }

    public struct Request: Sendable {
        public var surface: Surface
        public var scenario: Scenario
        public var isDark: Bool
        public var scale: CGFloat
        public var settings: AirStatKit.Settings

        public init(surface: Surface, scenario: Scenario = .nominal, isDark: Bool = false,
                    scale: CGFloat = 2, settings: AirStatKit.Settings = AirStatKit.Settings()) {
            self.surface = surface
            self.scenario = scenario
            self.isDark = isDark
            self.scale = scale
            self.settings = settings
        }

        public var fileName: String {
            "\(surface.label)-\(scenario.rawValue)-\(isDark ? "dark" : "light")@\(Int(scale))x.png"
        }
    }

    public static func render(_ request: Request, to directory: URL) throws -> URL {
        let appearance = NSAppearance(named: request.isDark ? .darkAqua : .aqua)!
        var image: NSImage?

        // Drawing appearance must be current for the whole render, or SwiftUI's
        // semantic colours resolve against the process default instead of the
        // appearance under test — which silently makes every dark render look light.
        appearance.performAsCurrentDrawingAppearance {
            image = renderImage(request, appearance: appearance)
        }

        guard let image, let data = pngData(image, scale: request.scale) else {
            throw RenderError.renderFailed(request.surface)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(request.fileName)
        try data.write(to: url)
        return url
    }

    private static func renderImage(_ request: Request, appearance: NSAppearance) -> NSImage? {
        switch request.surface {
        case .menuBar:
            return renderMenuBar(request, appearance: appearance)
        case .panel:
            return renderHosted(PanelPreviewHost(request: request), appearance: appearance,
                                width: PanelSettings.width)
        case .overlay:
            return renderHosted(OverlayPreviewHost(request: request), appearance: appearance,
                                width: request.settings.overlay.width)
        case .settings:
            return renderHosted(SettingsPreviewHost(request: request), appearance: appearance,
                                width: 620)
        }
    }

    /// The status item is a hand-drawn AppKit view, so it is captured through the
    /// view's own display path rather than SwiftUI's renderer — this is the exact
    /// code that runs in the real menu bar.
    private static func renderMenuBar(_ request: Request, appearance: NSAppearance) -> NSImage? {
        let model = MenuBarRenderModel(snapshot: request.scenario.snapshot,
                                       history: request.scenario.history,
                                       settings: request.settings,
                                       isStale: false)
        let view = MenuBarContentView(frame: .zero)
        view.appearance = appearance
        view.update(with: model)

        let size = view.intrinsicContentSize
        guard size.width > 0, size.height > 0 else { return nil }
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Composite onto the menu bar's own backdrop so contrast can be judged
        // honestly; a status item drawn on transparency tells you nothing.
        //
        // Done through an explicit bitmap context rather than NSImage.lockFocus():
        // this process runs with activation policy .prohibited and has no window
        // server focus stack, so lockFocus silently produces a transparent image.
        let backdrop = request.isDark
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)

        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width),
                                            pixelsHigh: Int(size.height),
                                            bitsPerSample: 8,
                                            samplesPerPixel: 4,
                                            hasAlpha: true,
                                            isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0,
                                            bitsPerPixel: 0) else { return nil }
        canvas.size = size

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: canvas)
        NSGraphicsContext.current = context
        // Fill through CGContext rather than NSColor.setFill/NSRect.fill: the AppKit
        // fill path depends on graphics state this windowless process does not have,
        // and silently no-ops, leaving a transparent backdrop.
        if let cg = context?.cgContext {
            cg.setFillColor(backdrop.cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
            // Composited via CGContext with an explicit normal blend mode.
            // `NSImageRep.draw(in:)` inherits the context's compositing operation,
            // which defaults to .copy here and replaced the backdrop with the view's
            // own transparent pixels — producing an image that looked entirely empty.
            if let cgImage = rep.cgImage {
                cg.setBlendMode(.normal)
                cg.draw(cgImage, in: CGRect(origin: .zero, size: size))
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(canvas)
        return image
    }

    private static func renderHosted<Content: View>(_ content: Content,
                                                    appearance: NSAppearance,
                                                    width: CGFloat) -> NSImage? {
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = appearance
        let fitting = hosting.fittingSize
        let size = NSSize(width: max(width, fitting.width),
                          height: max(fitting.height, 1))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// Writes at the requested backing scale so 1x and 2x rendering can be compared —
    /// hairlines and text snapping look different at each, and Retina-only review
    /// hides real 1x defects.
    private static func pngData(_ image: NSImage, scale: CGFloat) -> Data? {
        let pointSize = image.size
        let pixelWidth = Int((pointSize.width * scale).rounded())
        let pixelHeight = Int((pointSize.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelWidth,
                                         pixelsHigh: pixelHeight,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = pointSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: pointSize),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    public enum RenderError: Error, CustomStringConvertible {
        case renderFailed(Surface)
        public var description: String {
            switch self {
            case .renderFailed(let surface): return "failed to render \(surface.label)"
            }
        }
    }
}

// MARK: - Preview hosts

/// Wraps each surface with the chrome it has in the real app, so the render shows
/// what the user sees rather than a bare content view.
private struct PanelPreviewHost: View {
    let request: OffscreenRenderer.Request

    var body: some View {
        // Stands SwiftUI's `.regularMaterial` in for the panel window's real
        // `NSVisualEffectView`, which draws nothing offscreen. The sheen over it is the
        // same one the window applies, so the glass edge at least renders here.
        PanelRootView(engine: PreviewEngine.make(request), settings: PreviewEngine.store(request))
            .floatingSurface(in: RoundedRectangle(cornerRadius: Design.Radius.panel,
                                                  style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
    }
}

private struct OverlayPreviewHost: View {
    let request: OffscreenRenderer.Request

    var body: some View {
        OverlayRootView(engine: PreviewEngine.make(request), settings: PreviewEngine.store(request))
    }
}

private struct SettingsPreviewHost: View {
    let request: OffscreenRenderer.Request

    var body: some View {
        // The engine must be passed here, not just the store: the panes gate metric
        // choices on whether a collector is supported on this machine, and without an
        // engine every availability check silently answers "pending" — which is why
        // all four scenario renders were byte-identical.
        SettingsRootView(settings: PreviewEngine.store(request),
                         engine: PreviewEngine.make(request))
            // The window's glass, stood in for the same way the panel's is: its real
            // `NSVisualEffectView` draws nothing offscreen, so without this the whole
            // settings render is content floating on transparency.
            .floatingSurface(in: RoundedRectangle(cornerRadius: Design.Radius.panel,
                                                  style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
    }
}

/// Builds an engine primed with fixture data instead of live samples.
@MainActor
enum PreviewEngine {
    private static var engineCache: [String: MetricsEngine] = [:]
    private static var storeCache: [String: SettingsStore] = [:]

    static func store(_ request: OffscreenRenderer.Request) -> SettingsStore {
        let key = cacheKey(request)
        if let existing = storeCache[key] { return existing }
        // A temporary directory keeps rendering from touching the user's real settings.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatRender-\(UUID().uuidString)")
        let store = SettingsStore(directory: directory)
        store.update { $0 = request.settings }
        storeCache[key] = store
        return store
    }

    static func make(_ request: OffscreenRenderer.Request) -> MetricsEngine {
        let key = cacheKey(request)
        if let existing = engineCache[key] { return existing }
        let engine = MetricsEngine(settingsStore: store(request))
        engine.loadFixture(snapshot: request.scenario.snapshot, history: request.scenario.history)
        engineCache[key] = engine
        return engine
    }

    private static func cacheKey(_ request: OffscreenRenderer.Request) -> String {
        "\(request.surface.rawValue)-\(request.scenario.rawValue)-\(request.isDark)"
    }
}
