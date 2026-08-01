import SwiftUI
import AppKit
import AirStatKit

/// How AirStat looks: light or dark, what colour each metric is, and how its charts
/// are drawn.
///
/// One pane, because these are one decision. The colours were their own pane and the
/// charts another, and a user who wanted CPU to be orange had no reason to expect the
/// two to be filed apart.
struct AppearancePane: View {
    let settings: SettingsStore

    private var theme: ThemeSettings { settings.settings.theme }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: settings.binding(\.general.appearance,
                                                            onChange: applyAppearance)) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Theme")
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
                Text("Metric Colours")
            } footer: {
                SettingsFootnote("A colour you pick is used in that metric's charts and in its menu bar readout. Left alone, charts use the system palette and the menu bar stays monochrome like the rest of the bar.")
            }

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
                SettingsFootnote("Selection and the overlay's drag handle. Left alone it follows System Settings.")
            }

            Section {
                Picker("Keep history for", selection: settings.binding(\.charts.historyDuration)) {
                    ForEach(ChartSettings.allowedDurations, id: \.self) { duration in
                        Text(SettingsLabels.duration(duration)).tag(duration)
                    }
                }
                Picker("Chart style", selection: settings.binding(\.charts.style)) {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
            } header: {
                Text("Charts")
            } footer: {
                SettingsFootnote("History lives in memory and is discarded when AirStat quits — \(SettingsLabels.duration(settings.settings.charts.historyDuration)) at \(SettingsLabels.interval(settings.settings.general.updateInterval)) is \(settings.settings.historyCapacity) samples per series.")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings,
                                          sections: SettingsTab.appearance.sections,
                                          title: "Appearance")
                }
            }
        }
        .settingsFormStyle()
    }

    /// The theme is process state rather than a stored value, so the store alone would
    /// change nothing until the next launch.
    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// One editable colour: a swatch that opens the system picker, and — only once the
/// user has actually overridden it — a control to put it back.
///
/// Every row is "the shipped colour, unless you have picked one". The distinction is
/// visible because it is real: the shipped colours are Apple's semantic system colours
/// and re-resolve per appearance, so a row on its default behaves differently in dark
/// mode from one the user has fixed to a triple.
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
                    Button("Use Default") {
                        // Closing first: the wheel is still bound to this swatch, and
                        // leaving it open on a colour that just reverted invites the
                        // user to drag it straight back.
                        ColorPanel.close()
                        set(nil)
                    }
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
