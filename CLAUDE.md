# AirStats

Things that cost time to learn and are not visible in the code.

## Build

- **Every piece of work ends with the app rebuilt and installed.** The copy running on
  the machine is the one being judged, so leaving it a build behind means the next
  thing said about the app is about code that is no longer there:

      pkill -x AirStats; Scripts/build.sh release
      rm -rf /Applications/AirStats.app
      cp -R .build/arm64-apple-macosx/release/AirStats.app /Applications/
      open /Applications/AirStats.app

  Not only when asked, and not only for visible changes.
- `swift build` reports success while linking stale objects. If an edit does not show
  up in the binary (`strings .build/debug/AirStats | grep '<removed text>'`), the
  incremental state is corrupt: `rm -rf .build`. Verify renders against a clean build.
- The app is AirStats; the modules are still `AirStatKit` and `AirStatUI`, and the
  bundle id, the settings directory and the window autosave names all still say
  AirStat. That is deliberate — renaming any of them discards the user's settings,
  their notification grant, or their saved window positions.
- SwiftPM emits AirStatUI's resources as `AirStats_AirStatUI.bundle` beside the binary,
  and `Bundle.module` looks for it inside `Contents/Resources`. `build.sh` copies it;
  a bundle assembled by hand without that step launches with no logo and no error.
- The artwork is checked in, not generated at build time. `Resources/AppIcon.icns` is
  opaque (an app icon composites over the Dock, so black-on-transparent disappears)
  and `Sources/AirStatUI/Resources/Logo.png` is a black-on-transparent template AppKit
  re-tints per appearance. Neither can stand in for the other.
  `Resources/logo-source.png` is the master art to redraw either from.

## Verification

- `AirStats --render <surface>` writes PNGs offscreen from fixtures. It shows layout
  and SwiftUI drawing only: `NSVisualEffectView` renders nothing offscreen, so
  materials and translucency cannot be judged there. `OffscreenRenderer` substitutes
  `.regularMaterial` for the panel's real backdrop.
- `screencapture` has no Screen Recording grant in this environment, so live windows
  cannot be checked without the user looking.
- The Accessibility API is the way to drive the running app: `AXUIElementPerformAction`
  presses real controls, and the whole UI is well labelled, so a dump reads like the
  screen. Two limits are worth knowing before trusting an empty result.
  - **A locked screen empties `AXWindows` for every app on the machine**, and it looks
    exactly like the app failing to publish anything. It is not the whole API that
    goes: menu bar extras keep answering, and the status item's live value can be read
    minutes after the lock in the same process that enumerates no windows. So a
    successful AX read is not evidence the screen is unlocked, and window enumeration
    coming back empty is not evidence of a bug. Check `CGSSessionScreenIsLocked` from
    `CGSessionCopyCurrentDictionary` and confirm against a control app you know has
    windows. Two of us independently invented app-shaped explanations for this, one
    blaming `makeKey()` and one blaming activation state, and both fit the poisoned
    data perfectly. `AXIsProcessTrusted()` keeps answering true throughout, so the
    permission being granted says nothing about whether the API will return anything.
  - An app with **no window open** reports an `AXWindows` array holding the
    application element itself. Walking it naively never terminates.
- Synthesised input does not cover everything. `CGEvent` mouse clicks reach ordinary
  windows but not the menu bar, so the status item's left and right click paths need a
  human. Synthesised key events do not trigger Carbon hot keys at all, whatever the tap
  or event-source state, so a recorded global shortcut can only be confirmed by a real
  key press.
- `swift build --scratch-path <dir>` gives a trustworthy build without `rm -rf .build`,
  which matters when the stale-object problem above bites and something else is using
  the shared build directory.
- `HOME` does not redirect `applicationSupportDirectory`, so launching with a fake home
  does not isolate a test instance from the real settings file. `SettingsStore(directory:)`
  is the only thing that does.
- Contract tests read real sensors. The fan minimum-RPM test flakes during spin-down
  (1 RPM tolerance against the SMC's stated minimum). Re-run before investigating.

## macOS

- SwiftUI `Canvas` brings up the Metal renderer: a fixed ~93 MB process-global
  allocation, never returned, paid the first time any Canvas renders. Draw charts as
  shapes.
- A titled window's corner radius is the system's (12 on macOS 26; readable via KVC
  `cornerRadius` on `contentView.superview`) and cannot be set. Clearing
  `backgroundColor` or setting `titlebarAppearsTransparent` takes the content out of
  the frame view's mask and squares the corners off.
- `ColorPicker` opens the process-wide `NSColorPanel` and never closes it. Close it
  when the pane or window that owns the swatch goes away.
- The status item redraws only when `MenuBarRenderModel` changes, so anything that
  affects its drawing must travel in the model as data, not be read from a global by
  the view.
- Assigning an `@Observable` property the value it already holds does not reliably
  notify: measured firing `onChange` in a debug build and not in a release one. Never
  write a test that wakes an observer by re-assigning an unchanged value.
- `AsyncIteratorProtocol.next()` is not isolated to anything, so a `for await` on the
  main actor still leaves it and comes back on every element. Anything the iterator
  does to arm itself therefore happens after a thread hop, not in the caller's turn.
  Implement `next(isolation:)` to inherit the caller's actor, and never let a one-shot
  registration be renewed inside `next()` — see `ObservedChanges`.
- A template `NSImage` is tinted by AppKit only when a *control* draws it. Setting a
  fill colour and calling `image.draw(in:)` from a view's own `draw` paints the
  symbol's black ink, which is invisible on a dark menu bar and looks like a colour
  bug rather than a drawing-path one. Tint the image instead: rasterise into an
  `NSBitmapImageRep` and fill `.sourceIn`. That pass composites against everything
  already in the context, so it cannot run in the destination context, and the
  resulting image has to have `isTemplate = false` or AppKit paints over it again.
  Cache on the *resolved* colour — `labelColor` is one object meaning two colours.
