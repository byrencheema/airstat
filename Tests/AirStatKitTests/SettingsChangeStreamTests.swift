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

    /// Waits for something the observer does, rather than for a number of turns.
    ///
    /// The turn count used to be the wait, and it was a claim about scheduling that no
    /// part of the contract makes: delivery goes through an enqueued main-actor turn so
    /// the write has landed before the loop body reads it, and how many yields that
    /// takes is the runtime's business and differs between debug and release. Counting
    /// turns produced a suite that passed in one configuration, failed in the other, and
    /// was measuring the scheduler either way. What the stream actually promises is that
    /// the change arrives, so that is what is waited for.
    @discardableResult
    private func settle(until condition: @MainActor () -> Bool,
                        within timeout: Duration = .milliseconds(500)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// Gives anything that was going to happen time to happen, for the assertions that
    /// nothing did. There is no edge to wait for when the expected outcome is silence.
    private func settleQuietly() async {
        try? await Task.sleep(for: .milliseconds(50))
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
        await settle { seen.revisions.count == 1 }
        // 1, not 0: the bump that woke the loop has landed by the time the body runs.
        #expect(seen.revisions == [1])
        #expect(seen.intervals == [5])

        store.update { $0.general.updateInterval = 7 }
        await settle { seen.revisions.count == 2 }
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
        await settleQuietly()
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

        // A snapshot that differs from the one the engine already holds. Ingesting
        // `.empty` into a fresh engine assigns the value it is already on, and an
        // assignment that changes nothing does not reliably notify: it woke this loop in
        // a debug build and did not in a release one. The test means "the engine
        // changed", so it has to actually change it.
        engine.ingest(SnapshotFixtures.nominal)
        await settle { wakeups == 1 }
        #expect(wakeups == 1)

        store.update { $0.general.updateInterval = 9 }
        await settle { wakeups == 2 }
        #expect(wakeups == 2)

        task.cancel()
    }

    /// The bug this suite was rewritten around. Observation is a one-shot registration,
    /// and renewing it inside `next()` leaves the loop unobserved for as long as the
    /// iterator takes to get back there — `next()` is not actor-isolated, so even a loop
    /// running on the main actor hops off it and back to reach the registration. A
    /// change made in that gap reached nobody, and because the gap reopened after every
    /// element, the effect in the app was a setting that quietly did not take effect
    /// until some later change happened along. Optimised builds lost this race almost
    /// every time and debug builds almost never, so it was invisible until the release
    /// suite ran.
    ///
    /// Time-based on purpose: a body that is slow is the thing that makes the gap wide
    /// enough to aim at. Yields cannot express "while the body is still running".
    @Test("a change made while the loop body is still running is not dropped")
    func changeDuringTheBodyIsKept() async {
        let store = makeStore()
        let seen = Sightings()
        let changes = store.changes
        let task = Task { @MainActor in
            for await _ in changes {
                seen.revisions.append(store.revision)
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        await pump()

        store.update { $0.general.updateInterval = 5 }
        // The body is in its sleep once the first element has been recorded.
        await settle { seen.revisions.count == 1 }
        #expect(seen.revisions == [1])

        // Nothing is suspended on the stream right now. This has to be held, not lost.
        store.update { $0.general.updateInterval = 7 }
        await settle { seen.revisions.count == 2 }
        #expect(seen.revisions == [1, 2])

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
