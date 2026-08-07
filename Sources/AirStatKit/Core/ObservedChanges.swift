import Observation

/// An async sequence that yields once every time something read inside its tracking
/// closure changes.
///
/// Several parts of the app want the same thing: suspend until an `@Observable`
/// property changes, re-read it, react, and re-arm. `withObservationTracking` is a
/// one-shot registration, so writing that loop by hand means repeating the re-arming,
/// the continuation, and one detail that is easy to get wrong:
///
/// **`onChange` fires before the new value is stored.** Reacting the instant it fires
/// reads the *old* value, which shows up as a stale render or a setting that only
/// takes effect one change late, and reads like a race. An element is therefore
/// delivered a turn after the notification, on the main actor, so the write that woke
/// the sequence has landed before the body of the loop can read it back.
///
///     for await _ in settings.changes {
///         guard let self else { return }
///         self.applySettings()
///     }
///
/// **Observation is armed when the sequence is built, not when it is first awaited.**
/// `withObservationTracking` is a one-shot registration, and the obvious place to renew
/// it is inside `next()`. That is wrong, and it is wrong in a way that only shows up in
/// optimised builds. `AsyncIteratorProtocol.next()` is not actor-isolated, so a
/// `for await` running on the main actor still hops off it and back to reach the
/// registration — and any change made during that hop is made while nothing is
/// observing, so it is lost. Since the registration was only renewed inside `next()`,
/// the same gap reopened after every element: a settings change landing in it did not
/// reach `applySettings()` until some *later* change happened to arrive, which reads as
/// a setting that silently did not take effect. In a debug build the hop happened to
/// win the race often enough to look fine. `Gate` below arms in its initialiser, on the
/// main actor, and re-arms in the same turn it delivers, so there is no moment when a
/// change can arrive unobserved.
///
/// Single consumer. One `Gate` backs one loop; iterating the same value twice has the
/// two loops stealing elements from each other. Every caller builds its own by reading
/// `store.changes` or constructing this directly.
///
/// Cancellation is noticed on the way out of a suspension rather than during one: the
/// continuation underneath is not cancellation-aware, so a cancelled loop ends at the
/// next change. That is what the hand-written copies of this did, and it is why every
/// caller keeps its reaction behind a `guard let self`.
public struct ObservedChanges: AsyncSequence {
    public typealias Element = Void

    private let gate: Gate

    /// - Parameter track: reads the properties to watch. Every `@Observable` property
    ///   read inside it arms the next element, and it is re-run for each one, so keep
    ///   it cheap. It is held for as long as the loop runs: capture the observed
    ///   objects, never the observer, or a task cancelled in a `stop()` keeps its owner
    ///   alive. Every caller here captures its store and engine and leaves `self` weak
    ///   in the loop body.
    @MainActor
    public init(tracking track: @escaping @MainActor () -> Void) {
        gate = Gate(track: track)
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(gate: gate) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let gate: Gate

        /// The isolation-inheriting entry point, and the one `for await` actually calls.
        ///
        /// Without it the plain `next()` below is used, and because that one is not
        /// isolated to anything, a loop running on the main actor leaves it to enter the
        /// iterator and comes back — a thread hop, not a main-actor turn, on every
        /// element. Nothing is lost, but the reaction to a settings change arrives a
        /// hop late for no reason, and no amount of yielding on the main actor makes it
        /// land. Taking the caller's isolation keeps a main-actor loop on the main actor
        /// from the `for await` all the way to the gate.
        public mutating func next(isolation actor: isolated (any Actor)?) async -> Void? {
            await gate.wait()
            guard !Task.isCancelled else { return nil }
            return ()
        }

        public mutating func next() async -> Void? {
            await next(isolation: nil)
        }
    }

    /// Holds the registration between elements.
    @MainActor
    fileprivate final class Gate {
        private let track: @MainActor () -> Void
        /// A change that arrived while no one was suspended. Without it, a change made
        /// between one element being delivered and the loop body coming back around for
        /// the next would be dropped.
        private var pending = false
        private var waiter: CheckedContinuation<Void, Never>?

        init(track: @escaping @MainActor () -> Void) {
            self.track = track
            arm()
        }

        private func arm() {
            withObservationTracking {
                track()
            } onChange: { [weak self] in
                // `onChange` fires from the mutating context and *before* the new value
                // is stored. Hopping to the main actor is what lets the write land
                // before anything reads it back, and is also the only place the tracking
                // closure may be re-run.
                Task { @MainActor in self?.deliver() }
            }
        }

        private func deliver() {
            // Re-armed before the waiter is resumed, so the window that started all of
            // this never opens: from here until the next change, something is watching.
            arm()
            if let waiter {
                self.waiter = nil
                waiter.resume()
            } else {
                pending = true
            }
        }

        func wait() async {
            if pending {
                pending = false
                return
            }
            await withCheckedContinuation { waiter = $0 }
        }
    }
}

extension SettingsStore {
    /// Yields once per accepted mutation, whatever part of the settings tree changed.
    ///
    /// Watching `revision` rather than `settings` is deliberate: the store bumps it
    /// only when a write actually changes something, so an assignment of an identical
    /// value wakes nobody.
    public var changes: ObservedChanges {
        ObservedChanges { [self] in _ = self.revision }
    }
}
