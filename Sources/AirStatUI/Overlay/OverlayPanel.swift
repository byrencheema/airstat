import AppKit

/// Mouse handling the overlay window hands back to its controller.
///
/// Returning `true` means the controller consumed the event and AppKit must not see
/// it, which is how a drag on the overlay never reaches the SwiftUI content.
@MainActor
protocol OverlayInteractionHandler: AnyObject {
    func overlayMouseDown(_ event: NSEvent) -> Bool
    func overlayMouseDragged(_ event: NSEvent) -> Bool
    func overlayMouseUp(_ event: NSEvent) -> Bool
    func overlayRightMouseDown(_ event: NSEvent)
}

/// The overlay's window.
///
/// A `.nonactivatingPanel` because the overlay must never become key: taking key
/// status would pull the insertion point out of whatever the user is typing in, and
/// an always-on-top readout that steals focus is worse than no readout at all.
final class OverlayPanel: NSPanel {

    weak var interaction: (any OverlayInteractionHandler)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isRestorable = false
        // Dragging is handled explicitly rather than by AppKit's window-background
        // drag: AppKit gives no notification when the drag ends, and the drop is
        // exactly where the overlay has to snap to a corner and persist its position.
        isMovableByWindowBackground = false
        isMovable = true
        title = "AirStat Overlay"
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Intercepting here rather than in a view keeps the SwiftUI hosting view as the
    /// content view — which is what lets the window size itself to its content — while
    /// still giving the controller first refusal on every mouse event.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if interaction?.overlayMouseDown(event) == true { return }
        case .leftMouseDragged:
            if interaction?.overlayMouseDragged(event) == true { return }
        case .leftMouseUp:
            if interaction?.overlayMouseUp(event) == true { return }
        case .rightMouseDown:
            interaction?.overlayRightMouseDown(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Tracking-area owner for the overlay.
///
/// A separate object rather than a custom view so the hosting view can stay the
/// window's content view; `NSTrackingArea` sends its messages to whatever owner it is
/// given, and an `NSResponder` subclass is the smallest thing that can receive them.
final class OverlayHoverProxy: NSResponder {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onPointerMoved: ((NSEvent) -> Void)?

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }
    override func mouseMoved(with event: NSEvent) { onPointerMoved?(event) }
}
