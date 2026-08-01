import SwiftUI
import AppKit
import AirStatKit

/// The shortcut rows, as sections for another pane's `Form`.
///
/// Three recorder rows did not need a source-list entry of their own, so these live
/// in General now. They are still their own file: the conflict detection below is the
/// substance of the feature and does not belong in a pane about sampling and units.
struct ShortcutsFormSections: View {
    let settings: SettingsStore

    private var bindings: [ShortcutAction: AirStatKit.KeyboardShortcut] {
        settings.settings.shortcuts.bindings
    }

    var body: some View {
        Group {
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorderField(action: action, settings: settings)
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                SettingsFootnote("Click one, then press the combination. It needs ⌘, ⌃ or ⌥ in it, or it would fire while you were typing in another app. AirStat cannot tell whether another app already has a combination — macOS gives no way to ask.")
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts, id: \.self) { conflict in
                        SettingsCaution(conflict)
                    }
                } header: {
                    Text("Shortcut Conflicts")
                } footer: {
                    SettingsFootnote("Two actions cannot share one combination — whichever registered first wins, and which that is is not something you can predict.")
                }
            }
        }
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
