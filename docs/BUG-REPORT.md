# AirStats manual test report

**Date:** 2026-08-05
**Build:** `Scripts/build.sh release` at working tree `bbc9088` + uncommitted rename to `AirStats`
**Machine:** MacBook Pro (14-inch, Nov 2023), Apple M3 Pro, 18 GB, macOS 26.5.2 (25F84)
**Method:** the installed `/Applications/AirStats.app` driven through the macOS
Accessibility API (`AXUIElementPerformAction`, synthetic `CGEvent` clicks and keys),
with every state change checked against
`~/Library/Application Support/AirStat/settings.json` and against the live status item.
Screen Recording is not granted in this environment, so nothing here rests on a
screenshot; layout claims are stated as accessibility frame geometry, which is what
AppKit actually laid out.

Nine issues. One is a hard crash. Five are controls that persist a preference and
change nothing. The rest are a layout break, an accessibility gap, and leftovers from
the `AirStat` to `AirStats` rename.

A tenth was raised and then withdrawn. B10 is kept in place, marked WITHDRAWN, because
the false reasoning behind it will catch the next person who tests this app.

---

## B1. Crash: `MenuBarPane` reads a stale index after the readout list shrinks

**Severity:** critical, the whole app dies
**File:** `Sources/AirStatUI/Settings/MenuBarPane.swift:224`, `:240`, `:250`
**Crash reports:** `~/Library/Logs/DiagnosticReports/AirStats-2026-08-05-224135.ips`,
`AirStats-2026-08-05-224256.ips`

### Reproduction

1. Settings, Menu Bar.
2. Add readouts until there are more than two (the pane's `Add Module` menu).
3. Click any readout row past index 1 so the `Editing …` section binds to it.
4. Restore Defaults, then confirm in the sheet.

The readout list resets to the two shipped items while the `Editing` section's
`Picker` still holds bindings created for the old index. `EXC_BREAKPOINT`, the status
item vanishes, the app is gone.

### Stack

```
Swift runtime failure: Index out of range
Array._checkSubscript(_:wasNativeTypeChecked:)
Array.subscript.getter
closure #1 in MenuBarPane.metricBinding(index:)
SwiftUICore  LocationBox.get()
SwiftUI      PickerStyleConfiguration.init(selection:)
SwiftUI      Picker.body.getter
```

### Cause

All three bindings guard the write and leave the read bare:

```swift
private func metricBinding(index: Int) -> Binding<MenuBarMetric> {
    Binding(get: { items[index].metric },              // <- unguarded
            set: { metric in
                settings.update { s in
                    guard s.menuBar.items.indices.contains(index) else { return }   // <- guarded
                    ...
```

`styleBinding(index:)` and `captionBinding(index:)` have the same shape, and
`itemDetail(index:)` opens with a bare `let item = items[index]` at `:173`.

### Other routes to the same crash

- About, Import…, with a settings file whose `menuBar.items` is shorter than the
  current selection index. Same mechanism, same trap.
- Any future path that replaces `menuBar.items` wholesale.

`Remove the selected readout` is **not** affected: `removeSelected()` sets
`selection = nil` at `:307`, so the detail section is gone before the list shrinks.
Verified by hand, no crash.

`NotificationsPane` is not affected. It binds by `rule.id` through
`mutate(_:_:)` at `:154` and never subscripts by a captured index. That is the
pattern `MenuBarPane` should match, or the getters need the same
`indices.contains` guard the setters already have, falling back to a safe value.

### Fix sketch

Guard every getter, or key the bindings off `MenuBarItemConfig.ID` the way
`enabledBinding(for:)` at `:212` already does.

---

## B2. "Pause sampling on Low Power Mode" does nothing

**Severity:** high, an advertised power feature is absent
**File:** `Sources/AirStatUI/Settings/GeneralPane.swift:23`

`general.pausesOnLowPower` is declared in `Settings.swift:690`, coded and decoded,
written by the toggle, and read by nothing. `grep -rn pausesOnLowPower Sources/`
returns the toggle and the model only.

Verified live: Low Power Mode was on for the whole session
(`pmset -g` reports `lowpowermode 1`), the toggle was on, and the status item kept
updating on its 2 s cadence for five consecutive samples.

Compare `general.throttlesWhenOccluded`, which is wired at
`MetricsEngine.swift:117` and does work.

---

## B3. "Look up my public IP address" does nothing, and there is nowhere to show it

**Severity:** high, a privacy-framed toggle that implies a network call it never makes
**File:** `Sources/AirStatUI/Settings/GeneralPane.swift:59`

`general.fetchesPublicIP` is never read. `NetworkCollector.swift:286` hardcodes
`publicIP: .pending` with the comment:

> A separate opt-in, heavily throttled fetcher owns this field.

That fetcher does not exist. Neither does any UI: `grep -rn publicIP Sources/AirStatUI/`
returns nothing, so `NetworkSnapshot.publicIP` is never displayed even if it were
populated. The network module's expanded detail shows Upload, Local IP and Signal
only.

Either implement the fetcher and a row to show it, or remove the toggle. A privacy
switch that claims to control an outbound request is worse than no switch when the
request is not there to control.

---

## B4. "Combine into one menu bar item" does nothing

**Severity:** high, and the UI carries a footnote describing behaviour that does not exist
**File:** `Sources/AirStatUI/Settings/MenuBarPane.swift:45`

`menuBar.usesCombinedItem` is never read outside the toggle.
`StatusItemController` holds a single `private var statusItem: NSStatusItem?`
(`:19`) and `install()` opens with `guard statusItem == nil else { return }` (`:33`).
One item is all the app can produce.

Verified live: with 16 readouts enabled, turning the switch off left a single 855 pt
status item unchanged for at least 11 s.

The footnote under it reads:

> One item keeps the readouts together and in order. Separate items can be rearranged
> among your other menu bar icons, and macOS hides them one at a time when the bar
> runs out of room.

None of that second sentence is true today.

---

## B5. Keyboard shortcuts are recorded, stored, and never registered

**Severity:** high, three visible controls with no effect
**File:** `Sources/AirStatUI/Settings/ShortcutRecorder.swift:177`

The General pane offers Show / Hide Panel, Show / Hide Overlay and Open Settings.
`ShortcutRecorder` records a key combination and writes it to
`shortcuts.bindings[action]`. Nothing reads it back.

There is no `RegisterEventHotKey`, no `CGEvent` tap, and no global key-down monitor
that dispatches a shortcut action anywhere in the source. The only global monitors
are `PanelController.swift:288` (Escape to dismiss the panel), `:297` (click outside),
and `OverlayController.swift:296`/`:326` (pointer proximity and modifier watching for
the overlay grab gesture).

---

## B6. Notification rules drive a monitor that is an empty stub

**Severity:** high, an entire settings pane is inert
**File:** `Sources/AirStatUI/Support/ThresholdMonitor.swift:19`

```swift
/// Watches metrics against the user's threshold rules and posts notifications.
///
/// Sustained-duration and cooldown handling live here so a transient spike while
/// launching an app never produces an alert.
public func start() {}
public func stop() {}
```

`AppCoordinator.start()` calls `thresholdMonitor.start()` at `:55`, so the wiring is
in place and the body is missing. There is no `UNUserNotificationCenter` reference in
the project, no authorisation request, and no delivery.

The Notifications pane is fully built on top of this: a master switch, seven rules
with metric-specific ranges and units, per-rule sustained-duration pickers and
cooldowns, plus availability badges for metrics this Mac cannot measure. All of it
persists correctly and none of it can ever fire.

---

## B7. The Menu Bar pane's preview blows the settings window layout apart

**Severity:** medium, visible corruption at a reachable configuration
**File:** `Sources/AirStatUI/Settings/SettingsSupport.swift:493` (`MenuBarPreviewStrip`)

`MenuBarPreviewStrip` lays its content out in an `HStack` with
`.frame(maxWidth: .infinity)` and no upper bound, no `.lineLimit`, and no horizontal
scroll container. Its intrinsic width grows with the number of enabled readouts, and
because the settings root is an `HStack` of sidebar plus pane, the excess pushes both
children outside the window frame.

Measured, settings window fixed at `760x616` starting at x=376 (so it spans 376 to 1136):

| Readouts | Sidebar frame | Preview frame |
|---|---|---|
| 2 (default) | `@376,173 184x560` | `@591,229 515x38` |
| 16 | `@292,173 184x560` | `@372,229 954x181` |

At 16 readouts the sidebar starts 84 pt to the left of the window's left edge and the
preview runs 190 pt past its right edge. The layout snaps back exactly when the
readout list returns to two, which isolates the preview as the cause.

The preview needs a hard width ceiling with the overflow clipped or scrolled, the way
the real menu bar truncates.

---

## B8. The settings sidebar exposes no press action to assistive technology

**Severity:** medium, VoiceOver cannot change panes
**File:** `Sources/AirStatUI/Settings/SettingsWindowController.swift:233`

Each sidebar row is a real `Button`, but the accessibility modifiers applied outside
it replace the element and drop its action:

```swift
.accessibilityElement(children: .ignore)
.accessibilityLabel(item.label)
.accessibilityAddTraits(item == tab ? [.isSelected, .isButton] : .isButton)
```

`AXUIElementCopyActionNames` on all six rows returns an empty list. They report role
`AXButton` and the `.isButton` trait, so assistive technology presents them as
buttons, and `AXPress` on them does nothing. Verified: `AXPress` on the Menu Bar row
returned success and the pane did not change; a synthetic mouse click at the same
point switched panes immediately.

Every other control in the app is fine here. The panel's module headers, the readout
checkboxes, the reorder arrows, the popups and the Restore Defaults buttons all carry
`actions=[Press]`. Those use `.accessibilityLabel` / `.accessibilityValue` /
`.accessibilityHint` without `.accessibilityElement(children: .ignore)`, which is the
difference.

The comment above the modifiers explains the intent (announce "General, selected,
button" rather than walking into the row's decoration). Keeping that announcement
while restoring the action means either dropping `children: .ignore` or adding an
explicit `.accessibilityAction`.

---

## B9. Rename leftovers: the app calls itself "AirStat" in four user-visible places

**Severity:** low, but it is on the launch surface

| Location | Text |
|---|---|
| `Sources/AirStatUI/Settings/GeneralPane.swift:52` | `Toggle("Open AirStat at login", …)` |
| `Sources/AirStatUI/Settings/AppearancePane.swift:145` | `.accessibilityHint("Returns \(label) to the colour AirStat ships with")` |
| `Sources/AirStats/DiagnosticsCLI.swift` | `--probe` header prints `AirStat metric probe` |
| `Resources/Info.plist:10` | `CFBundleIdentifier` is `com.airstat.AirStat` |

The bundle identifier is deliberate if it is being kept for continuity of
`UserDefaults` and the settings directory (`~/Library/Application Support/AirStat`).
Worth a comment in `Info.plist` saying so, otherwise someone will "fix" it and orphan
every existing user's settings.

Separately, `Scripts/build.sh:34` globs `"$BIN_DIR"/*_AirStatUI.bundle` and copies
every match. A tree that has been built under both names ships both
`AirStat_AirStatUI.bundle` and `AirStats_AirStatUI.bundle` inside
`Contents/Resources`. Confirmed in the installed bundle this session. Harmless at
runtime because `Bundle.module` looks for the current name, but it is dead weight in
the shipped app and a `rm -rf .build` masks it.

---

## B10. WITHDRAWN as unproven. Needs one retest after unlock

Kept rather than deleted, because the reasoning is a trap worth marking for whoever
tests this app next.

Late in the session the panel appeared to publish nothing to accessibility. The
app's own log showed it on screen, and every reader reported an empty tree:

```
[airstat.window] panel shown frame=(780.0, 198.0, 340.0, 743.0) key=false appActive=false
ax <pid> windows                                       -> (no windows)
System Events: count of windows of process "AirStats"  -> 0
```

I concluded the panel was invisible to VoiceOver and wrote it up as a high-severity
defect, reasoning that `PanelController.show()` deliberately avoids `makeKey()` and
that an inactive app must therefore fail to publish.

That was wrong. **macOS disables the accessibility API while the screen is locked**,
and this machine locked at 23:20. The control that settles it:

```
CGSSessionScreenIsLocked = 1
CGSSessionScreenLockedTime = 1785996012   (23:20:12)

System Events, count of windows:  Finder 0,  Safari 0,  TextEdit 0,  ghostty 0
```

Those apps all had windows on screen. Every app reports zero, so nothing about
AirStats is implicated.

The timing explains the whole confusion. Every AX tree quoted in this report was
captured between 22:24 and about 23:05, before the lock, which is why they are rich
and complete: 43 elements in the panel, correct `AXDescription` and `AXValue` on
every row, `AXPress` working throughout. Everything measured after 23:20 was empty.
Two of us independently invented app-shaped explanations for an environmental cause,
one reaching for "never activated" and one for "never made key", and both fit the
data.

**The lesson for the next person driving this app: check
`CGSSessionScreenIsLocked` before concluding anything from an empty accessibility
tree, and confirm against a control app you know has windows.** This is now recorded
in `CLAUDE.md` beside the `screencapture` note.

### Withdrawn as unproven, not as disproven

Being precise about what survives, because it would be just as sloppy to claim the
lock disproves B10 as it was to claim the empty tree proved it.

Of the three measurements above, two go through the accessibility API and are
worthless while it is switched off. The third, the app's own `appActive=false` log
line, is lock-independent but only establishes that the app was inactive; it says
nothing about whether an inactive app publishes windows. So **there is no surviving
evidence for B10, and none against it either.** It cannot be tested until the machine
is unlocked.

The one thing pointing away from it: before the lock, the panel *was* enumerable.
`ax AirStats press X/0` followed by `ax AirStats dump` returned the full 43-element
panel tree at a point in the session when only the status item had been pressed and
the Settings window had never been opened. If the app was inactive at that moment,
that is a direct counterexample. I did not record `NSApp.isActive` at the time, so I
cannot close it from the transcript.

**The retest, once unlocked:** launch the installed app clean, do not click it, press
the status item through `AXPress` only, and compare `System Events: count of windows`
against a control app in the same breath. If AirStats reports 0 while the control
reports non-zero, B10 is real and belongs to `PanelController.swift`. If both report
their windows, it is closed for good. Two minutes of work.

B8 is unaffected either way: it was measured before the lock. Its fix is written and
builds clean, but its before/after accessibility capture is still outstanding for the
same reason, so B8 is **fixed but not yet re-verified**.

---

## What was exercised and found correct

Recorded so the report is not read as a list of everything that was touched.

**Panel.** All nine modules expand and collapse, state persists across close and
reopen, and every detail row carries a correct accessibility label and value. The
panel sizes to its content, re-anchors when the status item changes width, and
centres correctly under an 855 pt status item. Footer Settings and Quit work.

**Menu bar.** All 16 metrics can be added. All four display styles (Text, Graph,
Text & Graph, Icon & Text) render and change the item's width. Reordering, enabling,
disabling and removing all behave. Metrics this Mac cannot measure are marked
"(unavailable here)" in the add menu and render as unavailable rather than as zero.
The accessibility value is a full readable sentence.

**Sampling.** The update interval is honoured end to end: at 30 s the status item held
a constant value across 18 s of polling, at 2 s it tracked. `throttlesWhenOccluded`
is wired.

**Settings.** Every popup, switch and slider outside the issues above writes through
to `settings.json` correctly. Restore Defaults is section-scoped and confirms first.
Colour wells work, the "All Metrics" master swatch writes every metric at once, and
"Use Default" clears an override. The shared `NSColorPanel` closes both when the pane
changes and when the window closes, which is the documented hazard in `CLAUDE.md` and
it is handled.

**Overlay.** Enabling shows the window, it restores on relaunch (verified through
`AIRSTAT_WINDOW_LOG=1`: `overlay shown frame=(16.0, 800.0, 220.0, 133.0) level=1000`),
and the corner setting is applied. Modules add, remove and reorder.

**CLI.** `--help`, `--probe` (all nine collectors, sane values) and `--render` (64
images across four surfaces, four scenarios, two appearances, two scales) all
succeed.

**Tests.** `swift test`: 33 tests pass in 3.0 s.

---

## Not covered

- The status item's right-click context menu. `AppCoordinator.showContextMenu()`
  builds it and `StatusItemController` configures
  `sendAction(on: [.leftMouseUp, .rightMouseUp])` correctly, but synthetic `CGEvent`
  mouse clicks do not reach the menu bar in this environment, and `AXPress` on a menu
  extra only delivers the primary action. Needs a human click.
- Anything that depends on seeing pixels: material and translucency, hover states,
  animation, the overlay's drag-to-move gesture and click-through behaviour.
- Multi-display and Space-change behaviour.
- Login item registration. Toggling it writes the preference and calls
  `LoginItem.synchronize`, but confirming registration with `launchd` was out of scope.
