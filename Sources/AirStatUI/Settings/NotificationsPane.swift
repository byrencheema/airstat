import SwiftUI
import AirStatKit

struct NotificationsPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    /// Option lists rather than free entry: the model clamps both, and a picker
    /// makes the units unambiguous where a bare number would not.
    private static let sustainedOptions: [TimeInterval] = [0, 10, 30, 60, 120, 300, 600]
    private static let cooldownOptions: [TimeInterval] = [60, 300, 900, 1800, 3600, 21600, 86400]

    private var rules: [ThresholdRule] { settings.settings.notifications.rules }
    private var isEnabled: Bool { settings.settings.notifications.isEnabled }

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about these conditions",
                       isOn: settings.binding(\.notifications.isEnabled))
            } header: {
                Text("Notifications")
            }

            Section {
                ForEach(rules) { rule in
                    ruleRows(rule)
                }
            } header: {
                Text("Rules")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings,
                                          sections: SettingsTab.notifications.sections,
                                          title: "Notifications")
                }
            }
        }
        .settingsFormStyle()
    }

    /// Timing controls appear only for a rule that is on, so seven rules do not
    /// present twenty-one pickers the user has no reason to look at.
    @ViewBuilder
    private func ruleRows(_ rule: ThresholdRule) -> some View {
        let unavailable = availability.note(for: rule.metric)

        Toggle(isOn: enabledBinding(rule)) {
            HStack(spacing: Design.Space.m) {
                Text(rule.metric.label)
                if unavailable == nil {
                    thresholdControl(rule)
                } else {
                    UnavailableBadge(reason: unavailable ?? "")
                }
            }
        }
        // A rule whose metric this Mac cannot measure could never fire, so the
        // control says so rather than accepting a setting that does nothing.
        .disabled(!isEnabled || unavailable != nil)
        .accessibilityValue(unavailable ?? accessibilityValue(rule))

        if rule.isEnabled, unavailable == nil {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Picker("Only after it holds for", selection: sustainedBinding(rule)) {
                    ForEach(Self.sustainedOptions, id: \.self) { seconds in
                        Text(SettingsLabels.duration(seconds)).tag(seconds)
                    }
                }
                Picker("Then stay quiet for", selection: cooldownBinding(rule)) {
                    ForEach(Self.cooldownOptions, id: \.self) { seconds in
                        Text(SettingsLabels.duration(seconds)).tag(seconds)
                    }
                }
                SettingsFootnote(summary(rule))
            }
            .padding(.leading, Design.Space.xl)
            .disabled(!isEnabled)
        }
    }

    /// Thermal pressure is a four-level system state, not a measurement, so it gets
    /// the levels by name instead of a number with no unit.
    @ViewBuilder
    private func thresholdControl(_ rule: ThresholdRule) -> some View {
        if rule.metric == .thermalPressure {
            Picker("", selection: thresholdBinding(rule)) {
                ForEach(ThermalPressure.allLevels, id: \.self) { level in
                    Text(level.label).tag(Double(level.rawValue))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("\(rule.metric.label) level")
        } else {
            HStack(spacing: Design.Space.xs) {
                TextField("", value: thresholdBinding(rule), format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .accessibilityLabel("\(rule.metric.label) threshold in \(unitName(rule.metric))")
                Stepper("", value: thresholdBinding(rule), in: range(for: rule.metric), step: 1)
                    .labelsHidden()
                    .accessibilityHidden(true)
                Text(rule.metric.unitSuffix)
                    .foregroundStyle(Design.Palette.secondaryText)
            }
        }
    }

    private func summary(_ rule: ThresholdRule) -> String {
        let value = rule.metric == .thermalPressure
            ? (ThermalPressure(rawValue: Int(rule.threshold))?.label ?? "\(Int(rule.threshold))")
            : "\(Int(rule.threshold))\(rule.metric.unitSuffix)"
        let sustained = rule.sustainedFor <= 0
            ? "as soon as it happens"
            : "after \(SettingsLabels.duration(rule.sustainedFor)) of it holding"
        return "Notifies \(sustained), then not again for \(SettingsLabels.duration(rule.cooldown)). Threshold: \(value). Needs the \(rule.metric.requiredSource.label) collector, which this rule keeps running."
    }

    private func accessibilityValue(_ rule: ThresholdRule) -> String {
        rule.isEnabled ? "On, threshold \(Int(rule.threshold)) \(unitName(rule.metric))" : "Off"
    }

    private func unitName(_ metric: ThresholdMetric) -> String {
        switch metric {
        case .cpuUsage, .memoryPressure, .batteryLow, .batteryFull: return "percent"
        case .diskFree: return "gigabytes"
        case .cpuTemperature: return "degrees"
        case .thermalPressure: return "level"
        }
    }

    private func range(for metric: ThresholdMetric) -> ClosedRange<Double> {
        switch metric {
        case .cpuUsage, .memoryPressure, .batteryLow, .batteryFull: return 1...100
        case .diskFree: return 1...500
        case .cpuTemperature: return 40...110
        case .thermalPressure: return 0...3
        }
    }

    // MARK: Bindings

    private func mutate(_ rule: ThresholdRule, _ body: @escaping (inout ThresholdRule) -> Void) {
        settings.update { s in
            guard let index = s.notifications.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            body(&s.notifications.rules[index])
        }
    }

    private func enabledBinding(_ rule: ThresholdRule) -> Binding<Bool> {
        Binding(get: { rule.isEnabled },
                set: { isOn in mutate(rule) { $0.isEnabled = isOn } })
    }

    private func thresholdBinding(_ rule: ThresholdRule) -> Binding<Double> {
        let bounds = range(for: rule.metric)
        return Binding(get: { rule.threshold },
                       set: { value in
                           mutate(rule) { $0.threshold = min(max(value, bounds.lowerBound), bounds.upperBound) }
                       })
    }

    private func sustainedBinding(_ rule: ThresholdRule) -> Binding<TimeInterval> {
        Binding(get: { rule.sustainedFor },
                set: { value in mutate(rule) { $0.sustainedFor = value } })
    }

    private func cooldownBinding(_ rule: ThresholdRule) -> Binding<TimeInterval> {
        Binding(get: { rule.cooldown },
                set: { value in mutate(rule) { $0.cooldown = value } })
    }
}

private extension ThermalPressure {
    /// `ThermalPressure` is not `CaseIterable` in the Kit and that file is a
    /// contract, so the levels are enumerated here rather than changing it.
    static var allLevels: [ThermalPressure] { [.nominal, .fair, .serious, .critical] }
}
