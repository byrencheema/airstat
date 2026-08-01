import SwiftUI
import AirStatKit

struct ChartsPane: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Keep history for", selection: settings.binding(\.charts.historyDuration)) {
                    ForEach(ChartSettings.allowedDurations, id: \.self) { duration in
                        Text(SettingsLabels.duration(duration)).tag(duration)
                    }
                }
                LabeledContent("Samples kept", value: "\(settings.settings.historyCapacity)")
                    .foregroundStyle(Design.Palette.secondaryText)
            } header: {
                Text("History")
            } footer: {
                SettingsFootnote("History lives in memory only and is discarded when AirStat quits. A longer window at a faster update interval means more samples: \(SettingsLabels.duration(settings.settings.charts.historyDuration)) at \(SettingsLabels.interval(settings.settings.general.updateInterval)) is \(settings.settings.historyCapacity) samples per series.")
            }

            Section {
                Picker("Style", selection: settings.binding(\.charts.style)) {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Smooth curves", isOn: settings.binding(\.charts.smoothsCurves))
                Toggle("Show grid", isOn: settings.binding(\.charts.showsGrid))
                Toggle("Show value labels", isOn: settings.binding(\.charts.showsValueLabels))
            } header: {
                Text("Drawing")
            } footer: {
                SettingsFootnote("Smoothing changes only the drawn line. Samples are never averaged, so a spike is still a spike in the number.")
            }

            Section {
                Toggle("Scale rate charts to their peak",
                       isOn: settings.binding(\.charts.usesAdaptiveScale))
            } header: {
                Text("Scale")
            } footer: {
                SettingsFootnote("Network and disk have no maximum, so their charts scale to the peak in view: the shape stays readable, but height is not comparable between moments — the value label is. Percentages always use a fixed 0–100.")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings, section: .charts, title: "Charts")
                }
            }
        }
        .settingsFormStyle()
    }
}
