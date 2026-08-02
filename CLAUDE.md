# AirStat

Things that cost time to learn and are not visible in the code.

## Build

- `swift build` reports success while linking stale objects. If an edit does not show
  up in the binary (`strings .build/debug/AirStat | grep '<removed text>'`), the
  incremental state is corrupt: `rm -rf .build`. Verify renders against a clean build.
- `Scripts/build.sh release` assembles the .app. Install by replacing
  `/Applications/AirStat.app` and relaunching.

## Verification

- `AirStat --render <surface>` writes PNGs offscreen from fixtures. It shows layout
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
