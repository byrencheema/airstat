import SwiftUI
import AppKit
import AirStatKit

struct GeneralPane: View {
    let settings: SettingsStore

    /// `LoginItem.synchronize` reports a real failure — a missing bundle, a
    /// revoked approval — and the toggle is worthless if that is swallowed.
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Picker("Update interval", selection: settings.binding(\.general.updateInterval)) {
                    ForEach(GeneralSettings.allowedIntervals, id: \.self) { interval in
                        Text(SettingsLabels.interval(interval)).tag(interval)
                    }
                }
                Toggle("Slow down when the menu bar is hidden",
                       isOn: settings.binding(\.general.throttlesWhenOccluded))
                Toggle("Pause sampling on Low Power Mode",
                       isOn: settings.binding(\.general.pausesOnLowPower))
            } header: {
                Text("Sampling")
            } footer: {
                SettingsFootnote("How often AirStat reads the machine. Faster costs more energy, and a collector nothing is displaying is not sampled at all.")
            }

            Section {
                Picker("Appearance", selection: settings.binding(\.general.appearance,
                                                                 onChange: applyAppearance)) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Show icon in the Dock",
                       isOn: settings.binding(\.general.showsDockIcon, onChange: applyDockIcon))
            } header: {
                Text("Appearance")
            } footer: {
                SettingsFootnote("AirStat normally lives only in the menu bar. A Dock icon also gives it an app switcher entry.")
            }

            Section {
                Picker("Temperature", selection: settings.binding(\.general.temperatureUnit)) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Network rate", selection: settings.binding(\.general.networkRateUnit)) {
                    ForEach(NetworkRateUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Storage sizes", selection: settings.binding(\.general.byteUnitStyle)) {
                    ForEach(ByteUnitStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Show the percent sign", isOn: settings.binding(\.general.showsPercentSign))
            } header: {
                Text("Units")
            } footer: {
                SettingsFootnote("Memory is always shown in binary units, because that is what Apple reports — 18 GB of RAM is 19,327,352,832 bytes.")
            }

            Section {
                Toggle("Open AirStat at login",
                       isOn: settings.binding(\.general.launchAtLogin, onChange: applyLoginItem))
                if let loginItemError {
                    SettingsCaution(loginItemError)
                }
            } header: {
                Text("Startup")
            } footer: {
                SettingsFootnote("Registered through Login Items, where you can also revoke it. Nothing is installed outside the app.")
            }

            Section {
                Toggle("Look up my public IP address",
                       isOn: settings.binding(\.general.fetchesPublicIP))
            } header: {
                Text("Privacy")
            } footer: {
                SettingsFootnote("The only part of AirStat that touches the network. It asks an external lookup service, which necessarily sees your address. Everything else is read from this Mac and never leaves it.")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings, section: .general, title: "General")
                }
            }
        }
        .settingsFormStyle()
    }

    // MARK: Side effects
    //
    // Both of these are process-level state rather than stored preferences, so the
    // store's value alone would change nothing until the next launch.

    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyDockIcon(_ shows: Bool) {
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        // Switching policy drops key window status; take it back so the settings
        // window the user is standing in does not slide behind everything.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLoginItem(_ enabled: Bool) {
        if let error = LoginItem.synchronize(enabled: enabled) {
            loginItemError = "macOS refused to \(enabled ? "register" : "remove") the login item: \(error.localizedDescription)"
            // The stored preference must not claim something the system rejected.
            settings.update { $0.general.launchAtLogin = LoginItem.isEnabled }
        } else {
            loginItemError = nil
        }
    }
}
