import Testing
import Foundation
@testable import AirStatKit

/// Covers `ObservedChanges`, the one helper every observation loop in the app now
/// iterates.
///
/// The assertion that matters is on `revision`. Observation's `onChange` fires from
/// the property's `willSet`, so a loop that reacted the instant it was notified would
/// read the *previous* value of whatever woke it. `ObservedChanges` yields a turn
/// before delivering an element, and the expectations below are written against the
/// value the change installed rather than the one it replaced: reading back `0` after
/// the first accepted mutation is the failure this suite exists to catch.
@MainActor
@Suite("Observed change stream")
struct SettingsChangeStreamTests {

    /// Values read from inside a loop body, in the order the loop saw them.
    @MainActor
    private final class Sightings {
        var revisions: [UInt64] = []
        var intervals: [TimeInterval] = []
    }

    private func makeStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SettingsStore(directory: dir)
    }

    /// Hands the main actor to the observing task long enough for it to reach, or come
    /// back from, a suspension. Everything here is main-actor confined, so a handful of
    /// turns is the whole of the scheduling involved.
    private func pump(_ turns: Int = 8) async {
        for _ in 0..<turns { await Task.yield() }
    }

    @Test("a change wakes the loop, and the body reads the value that woke it")
    func deliversTheLandedWrite() async {
        let store = makeStore()
        let seen = Sightings()
        let changes = store.changes
        let task = Task { @MainActor in
            for await _ in changes {
                seen.revisions.append(store.revision)
                seen.intervals.append(store.settings.general.updateInterval)
            }
        }
        await pump()

        store.update { $0.general.updateInterval = 5 }
        await pump()
        // 1, not 0: the bump that woke the loop has landed by the time the body runs.
        #expect(seen.revisions == [1])
        #expect(seen.intervals == [5])

        store.update { $0.general.updateInterval = 7 }
        await pump()
        #expect(seen.revisions == [1, 2])
        #expect(seen.intervals == [5, 7])

        task.cancel()
    }

    @Test("a write that changes nothing wakes nobody")
    func identicalWriteIsNotAChange() async {
        let store = makeStore()
        let seen = Sightings()
        let changes = store.changes
        let task = Task { @MainActor in
            for await _ in changes { seen.revisions.append(store.revision) }
        }
        await pump()

        store.update { $0.general.updateInterval = store.settings.general.updateInterval }
        await pump()
        #expect(seen.revisions.isEmpty)

        task.cancel()
    }

    @Test("the tracking closure can span two observable objects")
    func tracksSeveralSources() async {
        let store = makeStore()
        let engine = MetricsEngine(settingsStore: store)
        var wakeups = 0
        let changes = ObservedChanges {
            _ = engine.snapshot
            _ = store.revision
        }
        let task = Task { @MainActor in
            for await _ in changes { wakeups += 1 }
        }
        await pump()

        engine.ingest(.empty)
        await pump()
        #expect(wakeups == 1)

        store.update { $0.general.updateInterval = 9 }
        await pump()
        #expect(wakeups == 2)

        task.cancel()
    }

    @Test("a cancelled loop finishes at the next change instead of reacting to it")
    func cancellationEndsTheLoop() async {
        let store = makeStore()
        let seen = Sightings()
        let changes = store.changes
        let task = Task { @MainActor in
            for await _ in changes { seen.revisions.append(store.revision) }
        }
        await pump()

        task.cancel()
        store.update { $0.general.updateInterval = 4 }
        // The loop ends rather than running its body, and this returns rather than
        // hanging: a cancelled observer must not outlive the thing that cancelled it.
        await task.value
        #expect(seen.revisions.isEmpty)
    }
}
