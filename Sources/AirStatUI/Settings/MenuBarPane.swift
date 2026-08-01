import SwiftUI
import AppKit
import AirStatKit

struct MenuBarPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var selection: MenuBarItemConfig.ID?
    @State private var dropTarget: MenuBarItemConfig.ID?

    private var items: [MenuBarItemConfig] { settings.settings.menuBar.items }

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex { $0.id == selection }
    }

    var body: some View {
        Form {
            Section {
                MenuBarPreviewStrip(model: previewModel, isEmpty: previewModel.items.isEmpty)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Preview")
            }

            Section {
                readoutList
                readoutListControls
            } header: {
                Text("Readouts")
            }

            if let index = selectedIndex {
                itemDetail(index: index)
            }

            Section {
                LabeledContent("Spacing between readouts") {
                    HStack(spacing: Design.Space.l) {
                        Slider(value: settings.quantized(\.menuBar.itemSpacing, step: 1), in: 0...24)
                            .frame(minWidth: 140)
                        Text(SettingsLabels.points(settings.settings.menuBar.itemSpacing))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .contain)

                Toggle("Reserve space for the widest value",
                       isOn: settings.binding(\.menuBar.usesFixedWidth))
                Toggle("Combine into one menu bar item",
                       isOn: settings.binding(\.menuBar.usesCombinedItem))
            } header: {
                Text("Layout")
            }

            Section {
                Toggle("Hide readouts that are idle", isOn: settings.binding(\.menuBar.hidesIdleItems))
                if settings.settings.menuBar.hidesIdleItems {
                    LabeledContent("Idle below") {
                        HStack(spacing: Design.Space.l) {
                            Slider(value: settings.quantized(\.menuBar.idleThreshold, step: 0.01),
                                   in: 0...0.5)
                                .frame(minWidth: 140)
                            Text(SettingsLabels.percent(settings.settings.menuBar.idleThreshold))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(Design.Palette.secondaryText)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Quiet Mode")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings,
                                          sections: SettingsTab.menuBar.sections,
                                          title: "Menu Bar")
                }
            }
        }
        .settingsFormStyle()
        // Opening on a selected readout means the configuration controls are visible
        // rather than hidden behind a click nothing hints at.
        .onAppear { if selection == nil { selection = items.first?.id } }
    }

    // MARK: Readout list

    private var readoutList: some View {
        SettingsListBox {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SettingsListRow(isFirst: index == 0,
                                isSelected: item.id == selection,
                                isDropTarget: item.id == dropTarget) {
                    readoutRow(item, index: index)
                }
                .onTapGesture { selection = item.id }
                .draggable(item.id.uuidString) {
                    Text(item.metric.label).padding(Design.Space.xs)
                }
                .dropDestination(for: String.self) { payload, _ in
                    dropTarget = nil
                    guard let dragged = payload.first else { return false }
                    return move(idString: dragged, to: index)
                } isTargeted: { targeted in
                    dropTarget = targeted ? item.id : (dropTarget == item.id ? nil : dropTarget)
                }
            }
        }
        .accessibilityLabel("Menu bar readouts")
    }

    private func readoutRow(_ item: MenuBarItemConfig, index: Int) -> some View {
        HStack(spacing: Design.Space.m) {
            Toggle(isOn: enabledBinding(for: item)) {
                Text(item.metric.label)
            }
            .toggleStyle(.checkbox)
            .disabled(isLastEnabled(item))
            .help(isLastEnabled(item)
                  ? "At least one readout must stay visible so the menu bar item remains clickable."
                  : "Show \(item.metric.label) in the menu bar")

            Spacer(minLength: Design.Space.m)

            if let reason = availability.note(for: item.metric) {
                UnavailableBadge(reason: reason)
            } else {
                Text(item.style.label)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
            }

            ReorderControls(canMoveUp: index > 0,
                            canMoveDown: index < items.count - 1,
                            itemLabel: item.metric.label) { offset in
                move(item, by: offset)
            }

            Button {
                selection = item.id
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            .buttonStyle(.borderless)
            .help("Configure \(item.metric.label)")
            .accessibilityLabel("Configure \(item.metric.label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.metric.label)
        .accessibilityValue("\(item.isEnabled ? "Shown" : "Hidden"), \(item.style.label) style")
    }

    private var readoutListControls: some View {
        HStack(spacing: Design.Space.m) {
            Menu {
                ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                    Button {
                        add(metric)
                    } label: {
                        // Still selectable: a settings file travels between Macs, and
                        // a readout this machine cannot serve may work on the next.
                        Text(availability.note(for: metric) == nil
                             ? metric.label
                             : "\(metric.label) (unavailable here)")
                    }
                }
            } label: {
                Label("Add Readout", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add a readout")

            Button {
                if let index = selectedIndex { remove(at: index) }
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selectedIndex == nil || items.count <= 1)
            .help(items.count <= 1 ? "The last readout cannot be removed." : "Remove the selected readout")
            .accessibilityLabel("Remove the selected readout")

            Spacer()
        }
    }

    // MARK: Selected readout

    @ViewBuilder
    private func itemDetail(index: Int) -> some View {
        let item = items[index]
        Section {
            Picker("Metric", selection: metricBinding(index: index)) {
                ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                    Text(metric.label).tag(metric)
                }
            }

            Picker("Display as", selection: styleBinding(index: index)) {
                ForEach(item.metric.supportedStyles, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.menu)

            Toggle("Show caption", isOn: captionBinding(index: index))

            if item.style == .graph || item.style == .textAndGraph {
                LabeledContent("Graph width") {
                    HStack(spacing: Design.Space.l) {
                        Slider(value: graphWidthBinding(index: index), in: 20...120)
                            .frame(minWidth: 140)
                        Text(SettingsLabels.points(item.graphWidth ?? Double(Design.MenuBar.graphWidth)))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text(item.metric.label)
        } footer: {
            if let reason = availability.note(for: item.metric) {
                SettingsCaution(reason)
            }
        }
    }

    // MARK: Model access

    /// Bindings are index-based rather than id-based so a rename or reorder cannot
    /// silently write to the wrong item.
    private func enabledBinding(for item: MenuBarItemConfig) -> Binding<Bool> {
        Binding(get: { item.isEnabled },
                set: { isOn in
                    settings.update { s in
                        guard let index = s.menuBar.items.firstIndex(where: { $0.id == item.id }) else { return }
                        s.menuBar.items[index].isEnabled = isOn
                    }
                })
    }

    private func metricBinding(index: Int) -> Binding<MenuBarMetric> {
        Binding(get: { items[index].metric },
                set: { metric in
                    settings.update { s in
                        guard s.menuBar.items.indices.contains(index) else { return }
                        s.menuBar.items[index].metric = metric
                        // `sanitized()` in the store will clamp an unsupported style,
                        // but doing it here keeps the picker from flashing a value it
                        // is about to lose.
                        if !metric.supportedStyles.contains(s.menuBar.items[index].style) {
                            s.menuBar.items[index].style = metric.supportedStyles.first ?? .text
                        }
                    }
                })
    }

    private func styleBinding(index: Int) -> Binding<MenuBarDisplayStyle> {
        Binding(get: { items[index].style },
                set: { style in
                    settings.update { s in
                        guard s.menuBar.items.indices.contains(index) else { return }
                        s.menuBar.items[index].style = style
                    }
                })
    }

    private func captionBinding(index: Int) -> Binding<Bool> {
        Binding(get: { items[index].showsCaption },
                set: { shows in
                    settings.update { s in
                        guard s.menuBar.items.indices.contains(index) else { return }
                        s.menuBar.items[index].showsCaption = shows
                    }
                })
    }

    private func graphWidthBinding(index: Int) -> Binding<Double> {
        Binding(get: { items[index].graphWidth ?? Double(Design.MenuBar.graphWidth) },
                set: { width in
                    settings.update { s in
                        guard s.menuBar.items.indices.contains(index) else { return }
                        s.menuBar.items[index].graphWidth = (width / 2).rounded() * 2
                    }
                })
    }

    /// The item the store would refuse to disable, or nil when more than one is on.
    private var lastEnabledItem: MenuBarItemConfig? {
        let enabled = items.filter(\.isEnabled)
        return enabled.count == 1 ? enabled.first : nil
    }

    private func isLastEnabled(_ item: MenuBarItemConfig) -> Bool {
        lastEnabledItem?.id == item.id
    }

    /// Drop handler. Returns false for a payload that is not one of our rows, so a
    /// stray drag from another app is refused rather than silently ignored.
    private func move(idString: String, to destination: Int) -> Bool {
        guard let id = UUID(uuidString: idString),
              let source = items.firstIndex(where: { $0.id == id }),
              source != destination else { return false }
        settings.update { s in
            guard s.menuBar.items.indices.contains(source),
                  s.menuBar.items.indices.contains(destination) else { return }
            let moved = s.menuBar.items.remove(at: source)
            s.menuBar.items.insert(moved, at: destination)
        }
        return true
    }

    private func move(_ item: MenuBarItemConfig, by offset: Int) {
        settings.update { s in
            guard let index = s.menuBar.items.firstIndex(where: { $0.id == item.id }) else { return }
            let target = index + offset
            guard s.menuBar.items.indices.contains(target) else { return }
            s.menuBar.items.swapAt(index, target)
        }
    }

    private func add(_ metric: MenuBarMetric) {
        let config = MenuBarItemConfig(metric: metric,
                                       style: metric.supportedStyles.first ?? .text)
        settings.update { $0.menuBar.items.append(config) }
        selection = config.id
    }

    private func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        settings.update { s in
            guard s.menuBar.items.indices.contains(index) else { return }
            s.menuBar.items.remove(at: index)
        }
        selection = nil
    }

    // MARK: Preview

    /// Built from live data when the app is running and from fixtures when it is
    /// not, but through the same model either way — the preview never invents a
    /// value, it renders whatever the metric actually reports.
    private var previewModel: MenuBarRenderModel {
        MenuBarRenderModel(snapshot: SettingsPreview.snapshot(engine),
                           history: SettingsPreview.history(engine),
                           settings: settings.settings,
                           // Never stale-dimmed. This preview answers "what will my
                           // menu bar look like", and greying it because the last
                           // sample is a few seconds old would read as the setting
                           // being broken. The real menu bar still dims.
                           isStale: false)
    }
}
