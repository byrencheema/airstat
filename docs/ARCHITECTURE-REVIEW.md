# AirStats architecture review

**Date:** 2026-08-06
**Tree:** `main` at `3644cee`, all nine bug-report findings fixed
**Method:** read-only. Nothing in `Sources/` was changed. Every timing figure below is
measured by the new `Performance` suite in `Tests/AirStatKitTests/`, debug build, and
can be reproduced with `swift test --filter Performance`.

The structure is sound. The module split is real, the sampling queue's confinement is
enforced by construction and documented, settings mutation has exactly one entry point,
and the collectors are honest about what they cannot measure. What follows is not a
rewrite case. It is seven specific things, ranked by what they cost.

The first four are one root cause and its consequences.

---

## A1. `SampleRing.subscript` is the per-sample bottleneck, and every aggregate goes through it

**Files:** `Sources/AirStatKit/Core/MetricHistory.swift:44`, `:52`, `:59`, `:66`

```swift
public subscript(index: Int) -> Float {
    precondition(index >= 0 && index < count, "SampleRing index out of range")
    let start = count < capacity ? 0 : head
    return storage[(start + index) % capacity]
}
```

Every element read pays a bounds precondition, a branch and an integer modulo. `maximum`,
`minimum` and `average` each walk the ring through it, and so does `ChartStats`, which
exists specifically to replace those three walks with one.

Measured over a full 1802-sample ring:

| Operation | Cost |
|---|---|
| `ring.values` (allocates, memcpys the same 1802 samples) | **583 ns** |
| `ChartStats(ring)` (one pass, no allocation) | **276 µs** |
| `ring.maximum + .minimum + .average` (three passes) | **828 µs** |

`ChartStats` is 3.0x faster than the three walks, which is what it was written to be. It
is also **474x the cost of copying the identical bytes**. The one-pass optimisation is
real and is being swamped by the per-element cost of the access it uses.

The fix does not change any signature: walk the two contiguous runs directly
(`head..<capacity` then `0..<head`) with `withUnsafeBufferPointer`, which removes the
modulo, the branch and the precondition from the inner loop. `ChartStats` is the one
caller that matters and it already takes the whole ring.

Note the figures are debug. Release inlines the subscript and closes much of the gap,
but the shape holds, and `swift test` is a debug build, which is where anyone
benchmarking this will first meet it.

## A2. `SampleRing.withValues` cannot be called in the state it was written for

**File:** `Sources/AirStatKit/Core/MetricHistory.swift:39`

```swift
/// Oldest-to-newest without allocating an intermediate array.
public func withValues<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R? {
    guard count > 0, count < capacity else { return nil }
```

`count < capacity` is false exactly when the ring is full, which is the steady state
after the first hour of uptime. The accessor whose entire purpose is to avoid the
allocation returns nil precisely when the app is doing the most work.

The guard is not wrong, it is load-bearing: a full ring wraps, so its samples are not
contiguous and no single buffer pointer can span them. But that means the API as written
can only ever serve the case that does not need it. It currently has **zero callers** in
`Sources/` and `Tests/`, which is the honest signal.

Either give it a two-run form that a full ring can actually use, which is the same
change A1 wants, or delete it. What it must not stay is a documented fast path that
silently is not one.

## A3. `MetricHistory.resize` and `clear` copy the dictionary once per series

**File:** `Sources/AirStatKit/Core/MetricHistory.swift:169`, `:178`

```swift
for key in series.keys {
    series[key] = series[key]?.resized(to: cap)
}
```

`series.keys` holds a reference to the dictionary's storage for the life of the loop, so
`series` is never uniquely referenced inside it and every assignment triggers a
copy-on-write of the whole dictionary. Twenty-one series, twenty-one full copies.

`resize` measures **3.36 ms**, and it runs on the main actor while the user drags the
retention slider. `clear` has the same shape and runs on every wake from sleep.

`for key in Array(series.keys)`, or iterating `SeriesKey.allCases`, drops the extra
copies. `SeriesKey.allCases` is the better of the two: it is what `init` already uses to
populate the dictionary, so the two would agree by construction.

## A4. The menu bar normalises an hour of history to draw about forty pixels

**File:** `Sources/AirStatUI/MenuBar/MenuBarRenderModel.swift:362`

```swift
let values = ring.values                       // allocates 1802 floats
let peak = max(ring.maximum, ...)              // full subscript walk
return values.map { min(max($0 / peak, 0), 1) } // allocates 1802 more
```

Per readout, per snapshot. With every readout enabled that is 32 array allocations and
16 full-ring walks every update interval, on the main actor, to feed graphs a few dozen
pixels wide. Then `MenuBarRenderModel ==` walks all of it again to decide whether
anything needs redrawing.

| Measured | Cost |
|---|---|
| Build model, 16 readouts, full history | **4.50 ms** |
| Build model, shipped 2 readouts | **237 µs** |
| `==` between two equal models with distinct storage | **306 µs** |

At the default 2 s cadence the 16-readout case is roughly 0.2 % of a core, which is not
an emergency. It is disproportionate: the graph resolves to about forty points, and
decimating to the drawn width before normalising would cut both the allocations and the
comparison by more than an order of magnitude. A1 would make the walks themselves
cheaper without changing the amount of work being done.

Worth stating plainly: the shipped default is 237 µs and most users will never leave it.
This is a worst-case-configuration finding, not a shipping-defect one.

---

## A5. Adding one metric means editing eight files

The per-metric fan-out, all of them switches over the same conceptual thing:

| File | What it decides |
|---|---|
| `Core/Snapshots.swift` | the field |
| `Core/MetricHistory.swift` | `SeriesKey`, `.label`, `.isNormalized` |
| `Core/MetricsEngine.swift:260` | `record(_:)`, snapshot field to series key |
| `Settings/Settings.swift` | `MenuBarMetric`, `ThresholdMetric`, supported styles |
| `Support/Formatting.swift` | `widestSample(for:)` |
| `MenuBar/MenuBarRenderModel.swift` | `render`, `captionText`, `symbolName` |
| `Charts/ChartData.swift` | `ChartValueFormat.standard(for:)` |
| `Support/ThresholdEvaluator.swift` | `readings(from:)`, `isBreached` |

Nothing here is wrong, and Swift's exhaustive switching means the compiler names most of
the places you missed. But `record(_:)` and `readings(from:)` are hand-written mappings
from snapshot fields to keys, and neither is exhaustive over anything: forget a line and
it compiles clean and silently retains no history for the new metric.

The cheapest improvement is not a redesign. It is a test that asserts every `SeriesKey`
receives a value when a fully-populated fixture snapshot is recorded, which turns the
one non-exhaustive step into a caught error. That is a small addition and it removes the
only part of this fan-out that can fail quietly.

## A6. `awaitChange` is copied verbatim in five files

`MetricsEngine.swift:195`, `StatusItemController.swift:249`, `ThresholdMonitor.swift:85`,
`GlobalHotKeyCenter.swift:211`, `OverlayController.swift:378`.

All five are character-for-character the same `withObservationTracking` plus
`withCheckedContinuation` pairing, and four of the five sit under the same
`while !Task.isCancelled` loop with the same `await Task.yield()` and the same comment
explaining why the yield is needed. The subtlety being duplicated is real: `onChange`
fires before the new value is stored, and getting that wrong gives you a stale read that
looks like a race.

One `AsyncStream`-shaped helper in `AirStatKit`, something like
`for await _ in settings.changes { ... }`, would leave each observer with only its own
reaction. Five copies of a subtle concurrency pattern is four chances to fix a bug in one
place and not the others.

## A7. `applySettings()` re-pushes the world on any settings change

**File:** `Sources/AirStatKit/Core/MetricsEngine.swift:230`

The engine wakes on `settingsStore.revision`, which bumps for every accepted mutation.
Changing an overlay colour re-pushes the base interval, the enabled-source set, the
public IP lookup flag and re-runs `updateActivity()`.

This is currently harmless: `SamplingCore`'s setters all early-return on an unchanged
value, so the redundant pushes cost a few queue hops. It is worth recording as the
reason that guard has to stay. Anything added to `applySettings` that is not idempotent
becomes a bug the moment a user drags a colour picker, and `SettingsStore.update`
measures 4.3 µs, so a drag runs this at display rate.

---

## Deliberately not on this list

Things that look like findings and are not, so nobody re-raises them:

- **`Settings.swift` at 914 lines.** It is one type per settings subtree with their
  fault-tolerant decoders, in reading order. Splitting it by subtree would scatter the
  `Codable` conventions that currently sit next to each other and are worth comparing.
- **`MetricFormatter` constructed per render.** It is a four-field value type; the one
  `NumberFormatter` behind it is a shared static. Six formatted values cost 5.6 µs.
- **`MetricHistory` keyed by dictionary rather than a dense array.** 21 hashes per
  ingest, and the whole ingest measures 15.6 µs. Not where the time goes.
- **`SamplingCore`'s nine hand-written slots and `forEachSlot`.** The generic slots are
  what keep each collector's output strongly typed to the snapshot with no boxing on the
  sampling path. An array of existentials would read better and undo that.

---

## Suggested order

1. **A3** is a few lines and removes 21 dictionary copies from two main-actor paths.
2. **A1** and **A2** are the same change and unblock the largest measured factor.
3. **A5**'s coverage test is small and closes the one silent failure in the fan-out.
4. **A6** is a genuine refactor and should be its own piece of work.
5. **A4** is worth doing only if the 16-readout configuration is one you care about.

Every one of these is guarded by the `Performance` suite: budgets are set above today's
measurements, so the improvements will show up as headroom rather than as failures, and
the tests will catch anything that goes the other way.
