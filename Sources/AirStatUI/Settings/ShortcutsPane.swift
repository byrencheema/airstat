import SwiftUI
import AppKit
import AirStatKit

struct ShortcutsPane: View {
    let settings: SettingsStore

    private var bindings: [ShortcutAction: AirStatKit.KeyboardShortcut] {
        settings.settings.shortcuts.bindings
    }

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorderField(action: action, settings: settings)
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                SettingsFootnote("Click a shortcut, then press the combination you want. Escape cancels, Delete clears. A shortcut needs ⌘, ⌃ or ⌥ in it — anything simpler would fire while you were typing in another app.")
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts, id: \.self) { conflict in
                        SettingsCaution(conflict)
                    }
                } header: {
                    Text("Conflicts")
                } footer: {
                    SettingsFootnote("Two actions cannot share one combination — whichever was registered first would win, and which that is is not something you can predict.")
                }
            }

            Section {
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings, section: .shortcuts, title: "Shortcuts")
                }
            } footer: {
                SettingsFootnote("AirStat cannot see whether another app has already claimed a combination — macOS gives no way to ask. If a shortcut does nothing, something else almost certainly has it.")
            }
        }
        .settingsFormStyle()
    }

    /// Two actions on the same key code and modifier set. Compared on the stored
    /// fields rather than the display string, so two different keys that happen to
    /// print the same glyph are not called a conflict.
    private var conflicts: [String] {
        var byCombination: [Combination: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            guard let shortcut = bindings[action] else { continue }
            byCombination[Combination(shortcut), default: []].append(action)
        }
        return byCombination.compactMap { combination, actions in
            guard actions.count > 1 else { return nil }
            let names = actions.map(\.label).joined(separator: " and ")
            return "\(combination.display) is assigned to \(names)."
        }
        .sorted()
    }

    private struct Combination: Hashable {
        let keyCode: UInt16
        let modifierFlags: UInt
        let display: String

        init(_ shortcut: AirStatKit.KeyboardShortcut) {
            keyCode = shortcut.keyCode
            modifierFlags = shortcut.modifierFlags
            display = ShortcutDisplay.string(for: shortcut)
        }

        static func == (a: Self, b: Self) -> Bool {
            a.keyCode == b.keyCode && a.modifierFlags == b.modifierFlags
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifierFlags)
        }
    }
}
