# Contributing

Thanks for looking. AirStat is a small codebase with a few opinions, and this file
covers them so a pull request does not have to discover them in review.

## Getting set up

You need macOS 14 or later and the Swift 6 toolchain that ships with Xcode 16.

```sh
git clone <your fork>
cd airstat
swift build
swift test
Scripts/build.sh          # debug .app bundle
Scripts/build.sh release  # optimised .app bundle
```

To run your build, replace `/Applications/AirStat.app` with the one the script prints
and launch it again. Two copies of a menu bar app running at once will confuse you about
which status item you are looking at.

## Before you open a pull request

Run these four:

```sh
swift build
swift test
.build/debug/AirStat --probe            # sanity check the collectors on your Mac
.build/debug/AirStat --render           # PNGs of every surface, in ./render
```

If you touched anything that draws, attach the relevant render. If you touched a
collector, say what you diffed its output against.

Two known rough edges. The fan minimum-RPM contract test can fail for a second while a
fan spins down, so re-run before you investigate. `swift build` sometimes reports
success while linking stale objects, so if an edit does not show up in the binary, delete
`.build` and build again.

## House rules

**Never show a number the machine did not report.** A missing sensor renders as a dash
and an unsupported metric is greyed out with the reason attached. Do not substitute a
zero, a guess or a last-known value. The same rule covers charts: a sparkline with fewer
than two samples draws nothing, because a flat line reads as a metric pinned at zero.

**Comments explain why, not what.** The code says what it does. A comment earns its place
by recording the measurement, the platform bug or the rejected alternative that made the
code look like this. If you removed a comment's reason, remove the comment.

**Keep AirStatKit free of UI.** It imports Foundation, IOKit and the rest of the system,
never SwiftUI or AppKit. The tests and `--probe` run in a windowless process and depend
on that.

**Match the design system.** Spacing, type and colour come from `Design` in
`Sources/AirStatUI/Design/DesignSystem.swift`. Add a token there rather than a literal at
the call site.

**Read CLAUDE.md.** It records the platform behaviour that is expensive to rediscover,
including how the Metal renderer inflates memory the first time a SwiftUI `Canvas` draws,
and why a titled window loses its rounded corners when you clear its background.

## Commits

One change per commit. Conventional Commits, on one line:

```
feat: colour menu bar readouts from the metric palette
fix: keep the panel on screen when the status item is hidden
perf: draw charts as shapes instead of Canvas
```

## Reporting a bug

Include your Mac model, your macOS version, and the output of `AirStat --probe` for the
metric that misbehaved. Sensor coverage varies across Macs more than anything else in
this app, so that output is often the whole bug report.
