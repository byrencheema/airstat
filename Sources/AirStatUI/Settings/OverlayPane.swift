import SwiftUI
import AirStatKit

struct OverlayPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var dropTarget: PanelModule?

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    private var overlay: OverlaySettings { settings.settings.overlay }

    var body: some View {
        Form {
            Section {
                Toggle("Show the overlay", isOn: settings.binding(\.overlay.isEnabled))
            } header: {
                Text("Overlay")
            } footer: {
                SettingsFootnote("A small always-visible window with the readouts you pick. It never takes keyboard focus and never appears in the app switcher.")
            }

            Section {
                moduleList
                moduleControls
            } header: {
                Text("Modules")
            } footer: {
                SettingsFootnote(overlay.modules.count == 1
                    ? "Drag to reorder. \(overlay.modules[0].label) cannot be removed — an empty overlay would be an invisible window."
                    : "Drag to reorder, or use the arrows. Only the modules listed here are drawn, and only their metrics are sampled while the overlay is visible.")
            }

            Section {
                Picker("Position", selection: settings.binding(\.overlay.corner)) {
                    ForEach(OverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }
                if overlay.corner == .free {
                    LabeledContent("Saved position", value: savedPositionText)
                        .foregroundStyle(Design.Palette.secondaryText)
                    Button("Forget Saved Position") {
                        settings.update {
                            $0.overlay.originX = nil
                            $0.overlay.originY = nil
                        }
                    }
                    .disabled(overlay.originX == nil && overlay.originY == nil)
                }
                LabeledContent("Width") {
                    HStack(spacing: Design.Space.l) {
                        Slider(value: settings.quantized(\.overlay.width, step: 4), in: 160...480)
                            .frame(minWidth: 140)
                        Text(SettingsLabels.points(overlay.width))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Use compact layout", isOn: settings.binding(\.overlay.isCompact))
            } header: {
                Text("Placement")
            } footer: {
                SettingsFootnote("Custom Position keeps wherever you last dragged it. If that display is disconnected, the overlay returns to the top right rather than vanishing.")
            }

            Section {
                LabeledContent("Opacity") {
                    HStack(spacing: Design.Space.l) {
                        Slider(value: settings.quantized(\.overlay.opacity, step: 0.05), in: 0.2...1)
                            .frame(minWidth: 140)
                        Text(SettingsLabels.percent(overlay.opacity))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Fade when not in use", isOn: settings.binding(\.overlay.dimsWhenInactive))
                if overlay.dimsWhenInactive {
                    LabeledContent("Faded opacity") {
                        HStack(spacing: Design.Space.l) {
                            Slider(value: settings.quantized(\.overlay.inactiveOpacity, step: 0.05),
                                   in: 0.15...1)
                                .frame(minWidth: 140)
                            Text(SettingsLabels.percent(overlay.inactiveOpacity))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(Design.Palette.secondaryText)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Transparency")
            } footer: {
                SettingsFootnote("Opacity never goes below 20%, and the faded value is held at or under the normal one — an overlay you cannot see is an overlay you cannot get back.")
            }

            Section {
                Toggle("Click through the overlay", isOn: settings.binding(\.overlay.isClickThrough))
                Toggle("Float above everything", isOn: settings.binding(\.overlay.floatsAboveEverything))
                Toggle("Show on all spaces", isOn: settings.binding(\.overlay.showsOnAllSpaces))
            } header: {
                Text("Behaviour")
            } footer: {
                SettingsFootnote("Click-through sends every click beneath the overlay, so you can no longer drag it — switch it off here to move it.")
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings,
                                          sections: SettingsTab.overlay.sections,
                                          title: "Overlay")
                }
            }
        }
        .settingsFormStyle()
    }

    // MARK: Modules

    private var moduleList: some View {
        SettingsListBox {
            ForEach(Array(overlay.modules.enumerated()), id: \.element) { index, module in
                SettingsListRow(isFirst: index == 0, isDropTarget: module == dropTarget) {
                    HStack(spacing: Design.Space.m) {
                        ModuleLabel(module: module)
                        Spacer(minLength: Design.Space.m)
                        if let reason = availability.note(for: module) {
                            UnavailableBadge(reason: reason)
                        }
                        ReorderControls(canMoveUp: index > 0,
                                        canMoveDown: index < overlay.modules.count - 1,
                                        itemLabel: module.label) { offset in
                            move(module, by: offset)
                        }
                        Button {
                            settings.update { $0.overlay.modules.removeAll { $0 == module } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .disabled(overlay.modules.count <= 1)
                        .help(overlay.modules.count <= 1
                              ? "The overlay needs at least one module."
                              : "Remove \(module.label) from the overlay")
                        .accessibilityLabel("Remove \(module.label)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(module.label)
                }
                .draggable(module.rawValue) {
                    Text(module.label).padding(Design.Space.xs)
                }
                .dropDestination(for: String.self) { payload, _ in
                    dropTarget = nil
                    guard let raw = payload.first, let dragged = PanelModule(rawValue: raw) else { return false }
                    return move(dragged, to: index)
                } isTargeted: { targeted in
                    dropTarget = targeted ? module : (dropTarget == module ? nil : dropTarget)
                }
            }
        }
        .accessibilityLabel("Overlay modules")
    }

    private var moduleControls: some View {
        HStack(spacing: Design.Space.m) {
            Menu {
                ForEach(availableModules, id: \.self) { module in
                    Button(module.label) {
                        settings.update { $0.overlay.modules.append(module) }
                    }
                }
            } label: {
                Label("Add Module", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(availableModules.isEmpty)
            .help(availableModules.isEmpty ? "Every module is already in the overlay." : "")
            .accessibilityLabel("Add a module to the overlay")

            Spacer()
        }
    }

    private var availableModules: [PanelModule] {
        PanelModule.allCases.filter { !overlay.modules.contains($0) }
    }

    private func move(_ module: PanelModule, by offset: Int) {
        settings.update { s in
            guard let index = s.overlay.modules.firstIndex(of: module) else { return }
            let target = index + offset
            guard s.overlay.modules.indices.contains(target) else { return }
            s.overlay.modules.swapAt(index, target)
        }
    }

    private func move(_ module: PanelModule, to destination: Int) -> Bool {
        guard let source = overlay.modules.firstIndex(of: module), source != destination,
              overlay.modules.indices.contains(destination) else { return false }
        settings.update { s in
            guard s.overlay.modules.indices.contains(source),
                  s.overlay.modules.indices.contains(destination) else { return }
            s.overlay.modules.insert(s.overlay.modules.remove(at: source), at: destination)
        }
        return true
    }

    private var savedPositionText: String {
        guard let x = overlay.originX, let y = overlay.originY else { return "Not set" }
        return "\(Int(x)), \(Int(y))"
    }
}
