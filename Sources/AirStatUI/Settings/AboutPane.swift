import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AirStatKit

struct AboutPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?
    /// Absent in the offscreen renderer, which has no running app to check on behalf
    /// of. The notice below is drawn from stored settings either way; only the button
    /// needs a checker to press.
    var updates: UpdateChecker?

    @State private var transferResult: String?
    @State private var transferFailed = false
    @State private var isConfirmingFullReset = false
    /// Whether the user pressed Check Now in this window.
    ///
    /// "Up to date" and "could not reach the service" are answers to a question the
    /// user asked, and noise otherwise: the automatic check is meant to be invisible
    /// unless it finds something, so its result is not reported here.
    @State private var hasCheckedManually = false

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
                    LogoMark(size: 52)
                        .foregroundStyle(Design.Palette.primaryText)
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text("AirStats").font(.title2.weight(.medium))
                        Text(versionText).foregroundStyle(Design.Palette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, Design.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AirStats, \(versionText)")
            }

            Section {
                if let release = availableRelease {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(Design.Palette.accent)
                            Text("AirStats \(release.version) is available.")
                        }
                        // Not folded into one accessibility element with the line above
                        // it: combining children replaces the link with a description of
                        // one, and the whole point of the row is that it can be opened.
                        Link("Open the download page", destination: release.url)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: Design.Space.l) {
                    Button("Check Now") { checkForUpdates() }
                        .disabled(updates == nil || isChecking)
                        .accessibilityHint("Asks airstats.app whether a newer version exists")
                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Checking for updates")
                    }
                    Spacer()
                }
                if let caution = manualCaution {
                    SettingsCaution(caution)
                } else if let note = manualNote {
                    SettingsFootnote(note)
                } else if let checked = lastCheckedNote {
                    SettingsFootnote(checked)
                }
            } header: {
                Text("Updates")
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
                        Text("Your menu bar readouts, panel layout, overlay, notification rules and shortcuts all go back to how AirStats shipped.")
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

    // MARK: Updates

    /// Read from stored settings rather than from the checker's status, so the notice
    /// is here on the next launch too: a release is worth mentioning until it is
    /// installed, not for the ten minutes after it was found.
    private var availableRelease: UpdateRelease? {
        updates?.availableRelease ?? UpdateChecker.availableRelease(in: settings.settings)
    }

    private var isChecking: Bool { updates?.isChecking ?? false }

    private var manualNote: String? {
        guard hasCheckedManually, updates?.status == .upToDate else { return nil }
        return "AirStats is up to date."
    }

    private var manualCaution: String? {
        guard hasCheckedManually, case .unavailable(let message)? = updates?.status else { return nil }
        return message
    }

    /// Standing answer to "is this thing actually running?", which the button alone
    /// cannot give: with the automatic check deliberately silent, a user who has never
    /// pressed anything otherwise sees nothing at all here.
    private var lastCheckedNote: String? {
        guard let checked = settings.settings.updates.lastCheckedAt else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return "Last checked \(relative.localizedString(for: checked, relativeTo: Date()))."
    }

    private func checkForUpdates() {
        hasCheckedManually = true
        updates?.checkNow()
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
        panel.nameFieldStringValue = "AirStats Settings.json"
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
            transferResult = "\(url.lastPathComponent) is not a settings file AirStats can read. Your settings are unchanged."
        }
    }
}
