import SwiftUI
import AirStatKit

/// Editor for the app's colour overrides.
///
/// Every row is "the shipped colour, unless you have picked one". The distinction
/// matters enough to be visible: the shipped colours are Apple's semantic system
/// colours and re-resolve per appearance, so a row still on its default behaves
/// differently in dark mode from one the user has fixed to a triple. Each row
/// therefore says which state it is in and offers a way back.
struct ColorsPane: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ColorRow(label: "Accent",
                         symbol: "cursorarrow.rays",
                         current: Design.Palette.accent,
                         isOverridden: theme.accent != nil,
                         set: { color in
                             settings.update { $0.theme.accent = color }
                         })
            } header: {
                Text("Accent")
            } footer: {
                SettingsFootnote("Used for selection and the overlay's drag handle. Left alone it follows the accent colour set in System Settings.")
            }

            Section {
                ForEach(CollectorID.allCases, id: \.self) { id in
                    ColorRow(label: id.label,
                             symbol: id.symbolName,
                             current: Design.Palette.metric(id),
                             isOverridden: theme.color(for: id) != nil,
                             set: { color in
                                 settings.update { $0.theme.setColor(color, for: id) }
                             })
                }
            } header: {
                Text("Metrics")
            } footer: {
                SettingsFootnote("Each metric's identity colour, used in charts and as the module glyph tint in settings. A colour you choose is stored exactly as picked, so unlike the defaults it will not adapt between light and dark.")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings, section: .theme, title: "Colors")
                }
            }
        }
        .settingsFormStyle()
    }

    private var theme: ThemeSettings { settings.settings.theme }
}

/// One editable colour: a swatch that opens the system picker, and — only once the
/// user has actually overridden it — a control to put it back.
private struct ColorRow: View {
    let label: String
    let symbol: String
    let current: Color
    let isOverridden: Bool
    let set: (ThemeColor?) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Design.Space.m) {
                // Revert appears only when there is something to revert to, so a row
                // on its default does not carry a permanently disabled control.
                if isOverridden {
                    Button("Use Default") { set(nil) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .accessibilityHint("Returns \(label) to the colour AirStat ships with")
                }
                ColorPicker("", selection: binding, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("\(label) colour")
            }
        } label: {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(current)
                Text(label)
                Text(isOverridden ? "Custom" : "Default")
                    .font(.callout)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(isOverridden ? "Custom colour" : "Default colour")
        }
    }

    /// Reads through to whatever is being drawn — the override if there is one, the
    /// shipped colour if not — so opening the picker starts on the colour on screen
    /// rather than on black.
    private var binding: Binding<Color> {
        Binding(get: { current },
                set: { newValue in
                    // A colour that will not resolve into sRGB cannot be stored, and
                    // storing a wrong one is worse than declining the edit.
                    guard let stored = newValue.themeColor else { return }
                    set(stored)
                })
    }
}
