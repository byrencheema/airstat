import SwiftUI
import AppKit

/// AirStat's mark.
///
/// Loaded once and marked as a template, which is the whole reason the file on disk is
/// black on transparent: a template image is re-tinted by AppKit for the appearance it
/// is drawn in, so one asset covers light, dark, vibrancy and increased contrast.
/// Colour baked into the artwork would be colour that cannot follow any of them.
public enum Logo {

    /// The mark as a template image, or nil if the resource is missing — the callers
    /// draw nothing rather than an empty box.
    public static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Logo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "AirStats"
        return image
    }()
}

/// The mark at a given size, tinted by whatever `foregroundStyle` is in effect.
public struct LogoMark: View {
    private let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        if let image = Logo.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
