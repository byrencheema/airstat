import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AirStatKit

struct AboutPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var transferResult: String?
    @State private var transferFailed = false
    @State private var isConfirmingFullReset = false

    /// Live identity when the app is running; the render harness has no engine, so
    /// it shows the same fixture machine every other rendered surface shows.
    private var systemState: MetricState<SystemInfoSnapshot> {
        engine?.system ?? .value(SnapshotFixtures.system())
    }

    private var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Design.Space.xl) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Design.Palette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text("AirStat").font(.title2.weight(.medium))
                        Text(versionText).foregroundStyle(Design.Palette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, Design.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AirStat, \(versionText)")
            }

            Section {
                MetricContent(systemState) { system in
                    Group {
                        LabeledContent("Computer", value: system.computerName)
                        LabeledContent("Model", value: system.modelName)
                        LabeledContent("Chip", value: system.chipName)
                        LabeledContent("Cores", value: coreText(system))
                        LabeledContent("Memory", value: formatter.memory(system.totalMemoryBytes))
                        LabeledContent("System", value: "\(system.osName) \(system.osVersion) (\(system.osBuild))")
                        LabeledContent("Uptime", value: formatter.compactUptime(system.uptime))
                    }
                }
            } header: {
                Text("This Mac")
            } footer: {
                SettingsFootnote("Read from sysctl and the IO registry on this machine. Nothing here is sent anywhere.")
            }

            Section {
                HStack(spacing: Design.Space.l) {
                    Button("Export…") { export() }
                        .accessibilityHint("Writes your settings to a JSON file")
                    Button("Import…") { importSettings() }
                        .accessibilityHint("Replaces your settings from a JSON file")
                    Spacer()
                }
                if let transferResult {
                    if transferFailed {
                        SettingsCaution(transferResult)
                    } else {
                        SettingsFootnote(transferResult)
                    }
                }
                LabeledContent("Location", value: settings.settingsFileURL.path)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([settings.settingsFileURL])
                }
            } header: {
                Text("Settings File")
            } footer: {
                SettingsFootnote("Importing replaces every section at once. A key the file gets wrong falls back to its default rather than failing the import, so a file from another version still loads.")
            }

            Section {
                Menu("Restore One Section…") {
                    ForEach(SettingsStore.SettingsSection.allCases, id: \.self) { section in
                        Button(section.label) { settings.resetSection(section) }
                    }
                }
                .fixedSize()

                Button("Restore All Settings…", role: .destructive) { isConfirmingFullReset = true }
                    .confirmationDialog("Restore every setting to its defaults?",
                                        isPresented: $isConfirmingFullReset) {
                        Button("Restore All Settings", role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Your menu bar readouts, panel layout, overlay, notification rules and shortcuts all go back to how AirStat shipped.")
                    }
            } header: {
                Text("Reset")
            } footer: {
                if let diagnostic = settings.loadDiagnostic {
                    SettingsCaution(diagnostic)
                }
            }
        }
        .settingsFormStyle()
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else {
            // Running the bare SwiftPM binary rather than the assembled .app.
            return "Development build"
        }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    private func coreText(_ system: SystemInfoSnapshot) -> String {
        var text = "\(system.logicalCores)"
        if system.performanceCores > 0 || system.efficiencyCores > 0 {
            text += " (\(system.performanceCores) performance, \(system.efficiencyCores) efficiency)"
        }
        if let gpu = system.gpuCoreCount {
            text += " · \(gpu) GPU"
        }
        return text
    }

    // MARK: Import / export

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AirStat Settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportJSON().write(to: url, options: .atomic)
            transferFailed = false
            transferResult = "Exported to \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferResult = "Could not export: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.importJSON(Data(contentsOf: url))
            transferFailed = false
            transferResult = "Imported from \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferResult = "\(url.lastPathComponent) is not a settings file AirStat can read. Your settings are unchanged."
        }
    }
}
