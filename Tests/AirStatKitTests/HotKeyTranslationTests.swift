import Testing
import AppKit
import Carbon.HIToolbox
@testable import AirStatKit

@Suite("Recorded shortcuts translate into what RegisterEventHotKey takes")
struct HotKeyTranslationTests {

    private func shortcut(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> KeyboardShortcut {
        KeyboardShortcut(keyCode: keyCode, modifierFlags: flags.rawValue, characters: "")
    }

    @Test("each modifier maps onto its Carbon bit")
    func modifiersMapIndividually() {
        #expect(shortcut(35, .command).carbonModifierFlags == UInt32(cmdKey))
        #expect(shortcut(35, .option).carbonModifierFlags == UInt32(optionKey))
        #expect(shortcut(35, .control).carbonModifierFlags == UInt32(controlKey))
        #expect(shortcut(35, .shift).carbonModifierFlags == UInt32(shiftKey))
    }

    @Test("a chord combines the bits rather than picking one")
    func modifiersCombine() {
        let combined = shortcut(35, [.command, .shift, .option]).carbonModifierFlags
        #expect(combined == UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey))
    }

    @Test("no modifiers means no Carbon bits")
    func bareKeyHasNoModifiers() {
        #expect(shortcut(35, []).carbonModifierFlags == 0)
    }

    @Test("keyboard state that is not part of the chord is dropped")
    func stateFlagsAreDropped() {
        // Caps Lock on while recording ⌘P must not produce a hot key that needs Caps
        // Lock to fire.
        let recorded = shortcut(35, [.command, .capsLock, .function, .numericPad])
        #expect(recorded.carbonModifierFlags == UInt32(cmdKey))
    }

    @Test("the key code passes through unchanged")
    func keyCodePassesThrough() {
        #expect(shortcut(35, .command).carbonKeyCode == 35)
        #expect(shortcut(UInt16(kVK_Escape), .command).carbonKeyCode == UInt32(kVK_Escape))
    }

    @Test("only chords with ⌘, ⌥ or ⌃ may be claimed system-wide")
    func registerabilityMatchesTheRecorder() {
        #expect(shortcut(35, .command).isGloballyRegisterable)
        #expect(shortcut(35, .option).isGloballyRegisterable)
        #expect(shortcut(35, .control).isGloballyRegisterable)
        // Shift plus a key is how you type a capital letter; claiming it would eat the
        // keystroke everywhere.
        #expect(!shortcut(35, .shift).isGloballyRegisterable)
        #expect(!shortcut(35, []).isGloballyRegisterable)
        #expect(!shortcut(35, .capsLock).isGloballyRegisterable)
    }

    @Test("every action has its own hot key identifier")
    func identifiersAreUnique() {
        let identifiers = ShortcutAction.allCases.map(\.hotKeyIdentifier)
        #expect(Set(identifiers).count == ShortcutAction.allCases.count)
        // Zero is what an uninitialised `EventHotKeyID` carries, so no action may use it.
        #expect(!identifiers.contains(0))
    }

    @Test("the identifier Carbon hands back resolves to the action that was registered")
    func identifiersRoundTrip() {
        for action in ShortcutAction.allCases {
            #expect(ShortcutAction.action(forHotKeyIdentifier: action.hotKeyIdentifier) == action)
        }
        #expect(ShortcutAction.action(forHotKeyIdentifier: 0) == nil)
        #expect(ShortcutAction.action(forHotKeyIdentifier: 99) == nil)
    }

    @Test("a hand-edited settings file cannot smuggle in an unregisterable binding")
    func decodedBindingsAreChecked() throws {
        // A dictionary keyed by an enum encodes as a flat key, value array, which is
        // also the shape on disk.
        let json = """
        {"shortcuts":{"bindings":["togglePanel",{"keyCode":35,"modifierFlags":0,"characters":"p"}]}}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        let binding = try #require(settings.shortcuts.bindings[.togglePanel])
        #expect(!binding.isGloballyRegisterable)
    }
}
