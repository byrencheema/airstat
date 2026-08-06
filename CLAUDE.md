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
