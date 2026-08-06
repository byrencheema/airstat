import AppKit
import Carbon.HIToolbox

/// Turns a recorded `KeyboardShortcut` into the two values `RegisterEventHotKey` takes.
///
/// The recorder stores the modifiers as an `NSEvent.ModifierFlags` bitmask. Carbon
/// predates that type and carries a bitmask of its own with entirely different bit
/// positions, so the two share nothing but their meaning and have to be mapped by hand.
extension KeyboardShortcut {

    /// Carbon's virtual key codes are the same `kVK_` values `NSEvent` reports, so the
    /// key code needs a width change and nothing more.
    public var carbonKeyCode: UInt32 { UInt32(keyCode) }

    /// Caps Lock, Fn and the numeric-keypad bit are dropped. They describe the state
    /// the keyboard happened to be in, not part of the chord, and carrying them
    /// through would produce a hot key that only fires while Caps Lock is on.
    public var carbonModifierFlags: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Whether this combination is safe to claim system-wide.
    ///
    /// A bare key, or Shift plus a key, would swallow that keystroke everywhere the
    /// user types. The recorder refuses to record one, but a hand-edited or imported
    /// settings file can still contain one and must not be registered.
    public var isGloballyRegisterable: Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        return !flags.intersection([.command, .option, .control]).isEmpty
    }
}

extension ShortcutAction {

    /// Carbon identifies a registered hot key by a number, and hands that number back
    /// when the chord is pressed. Derived from the case's position so that adding an
    /// action cannot collide with an existing one, and so there is no hand-kept table
    /// to drift out of step with the enum.
    public var hotKeyIdentifier: UInt32 {
        UInt32((ShortcutAction.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    public static func action(forHotKeyIdentifier identifier: UInt32) -> ShortcutAction? {
        allCases.first { $0.hotKeyIdentifier == identifier }
    }
}
