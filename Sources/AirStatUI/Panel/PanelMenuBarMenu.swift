import SwiftUI
import AirStatKit

/// The gear at the trailing edge of a module's header row.
///
/// Changing how a readout draws in the menu bar used to mean opening Settings, finding
/// the readout in a list that names metrics rather than modules, and matching it to the
/// row you were looking at. The row already knows which readout it speaks for, so the
/// control belongs on the row.
struct PanelMenuBarMenu: View {
    let control: PanelMenuBarControl
    /// True while the pointer is anywhere on the header row. The gear is quiet by
    /// default — nine of them down the panel at full strength is the same wall the
    /// module glyphs were toned down to avoid — and steps up to match the row's own
    /// hover highlight so it reads as part of what is being pointed at.
    let isRowHovered: Bool

    /// Narrow, and deliberately narrower than the module glyph opposite it.
    ///
    /// Every point this takes comes out of the headline value beside it, and the panel
    /// has none to spare: at 16pt wide with the row's full trailing inset behind it,
    /// Memory's "10.2 GB" rendered as "10…". The glyph is 10pt of art, so 12pt of
    /// column is all it needs, and the row's trailing padding is cut to match because
    /// a gear carries its own visual margin in a way a number does not.
    static let width: CGFloat = Design.Space.l
    /// Gap between the headline value and the gear. Small on purpose: the qualifier
    /// column to its left is mostly empty space already, so the gear does not need a
    /// gap of its own to stand clear of the number.
    static let leadingGap: CGFloat = Design.Space.xxs
    /// Inset from the panel edge, in place of `Design.Space.panelInset`.
    static let trailingInset: CGFloat = Design.Space.m

    private var isPinnedOn: Bool { control.isShown && !control.canHide }

    var body: some View {
        Menu {
            Toggle(isOn: control.shownBinding) {
                Text("Show in menu bar")
            }
            .disabled(isPinnedOn)

            // A disabled item rather than a tooltip: a menu item that refuses to move
            // and says nothing is indistinguishable from one that is broken, and help
            // tags do not reliably appear on menu content.
            if isPinnedOn {
                Text(PanelMenuBarControl.lastReadoutExplanation)
            }

            Divider()

            // Straight from `metric.supportedStyles`, so a style added to the model
            // appears here with nothing in the panel changing. Optional selection is
            // what lets the picker tick nothing at all when the metric is not in the
            // menu bar, or when its readouts disagree about style.
            Picker(selection: control.styleBinding) {
                ForEach(control.styles, id: \.self) { style in
                    Text(style.label).tag(Optional(style))
                }
            } label: {
                Text("Menu bar style")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "gearshape")
                .font(Design.Text.caption)
                .foregroundStyle(isRowHovered ? Design.Palette.secondaryText
                                              : Design.Palette.quaternaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Self.width)
        .accessibilityLabel("\(control.metric.label) menu bar options")
        .accessibilityValue(control.accessibilityValue)
        .accessibilityHint("Choose whether \(control.metric.label) appears in the menu bar and how it is drawn")
        .help("Menu bar options for \(control.metric.label)")
    }
}
