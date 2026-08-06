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
/// Cancellation is noticed on the way out of a suspension rather than during one: the
/// continuation underneath is not cancellation-aware, so a cancelled loop ends at the
/// next change. That is what the hand-written copies of this did, and it is why every
/// caller keeps its reaction behind a `guard let self`.
public struct ObservedChanges: AsyncSequence {
    public typealias Element = Void

    private let track: @MainActor () -> Void

    /// - Parameter track: reads the properties to watch. Every `@Observable` property
    ///   read inside it arms the next element, and it is re-run for each one, so keep
    ///   it cheap. It is held for as long as the loop runs: capture the observed
    ///   objects, never the observer, or a task cancelled in a `stop()` keeps its owner
    ///   alive. Every caller here captures its store and engine and leaves `self` weak
    ///   in the loop body.
    public init(tracking track: @escaping @MainActor () -> Void) {
        self.track = track
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(track: track) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate let track: @MainActor () -> Void

        public mutating func next() async -> Void? {
            await ObservedChanges.awaitChange(track)
            guard !Task.isCancelled else { return nil }
            return ()
        }
    }

    /// Suspends until any property read inside `track` changes, then lets the write land.
    ///
    /// `withObservationTracking` guarantees `onChange` runs at most once, which is
    /// exactly the once-only resume a continuation requires.
    @MainActor
    private static func awaitChange(_ track: @MainActor () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                track()
            } onChange: {
                continuation.resume()
            }
        }
        // `onChange` fires *before* the new value is stored, so yield a turn on the main
        // actor to let the write land before the loop body re-reads it. This is the one
        // place in the app that has to get this right; see the type's documentation.
        await Task.yield()
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
