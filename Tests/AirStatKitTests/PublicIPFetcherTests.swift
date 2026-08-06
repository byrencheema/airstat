import Testing
import Foundation
@testable import AirStatKit

/// Everything here runs against a stub transport. The one part of this feature that
/// needs the internet is the round trip itself; the parts worth guarding are the ones
/// that decide whether the round trip happens at all.
@Suite("Public IP fetcher")
struct PublicIPFetcherTests {

    /// Counts what would have left the machine and answers on demand, so a test can
    /// assert on requests without making one.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(MetricState<String>) -> Void] = []
        private var requests = 0

        var transport: PublicIPTransport {
            { [self] completion in
                lock.lock()
                requests += 1
                pending.append(completion)
                lock.unlock()
            }
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        /// Completes every outstanding request with the same answer.
        func answer(_ state: MetricState<String>) {
            lock.lock()
            let completions = pending
            pending.removeAll()
            lock.unlock()
            for completion in completions { completion(state) }
        }
    }

    @Test("nothing is sent until the user opts in")
    func gatedOnTheSetting() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)

        for _ in 0..<5 { fetcher.refreshIfDue() }

        #expect(recorder.requestCount == 0)
        #expect(fetcher.currentState().value == nil)
        // The panel keys the row's presence off this: unsupported means "not asked for",
        // which is why the row is absent rather than empty while the toggle is down.
        #expect(fetcher.currentState().isPermanentlyUnavailable)
    }

    @Test("opting in produces exactly one lookup")
    func oneLookupOnEnable() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)

        fetcher.setEnabled(true)
        #expect(recorder.requestCount == 0)
        #expect(fetcher.currentState().failure == .pending)

        fetcher.refreshIfDue()
        #expect(recorder.requestCount == 1)

        // A second tick while the first request is still out must not open another.
        fetcher.refreshIfDue()
        #expect(recorder.requestCount == 1)

        recorder.answer(.value("198.51.100.7"))
        #expect(fetcher.currentState().value == "198.51.100.7")
    }

    @Test("a cached address is not looked up again on the next tick")
    func throttledAfterSuccess() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)
        fetcher.setEnabled(true)
        fetcher.refreshIfDue()
        recorder.answer(.value("198.51.100.7"))

        // The sampling queue calls this every second or two for the life of the app.
        for _ in 0..<200 { fetcher.refreshIfDue() }

        #expect(recorder.requestCount == 1)
        #expect(fetcher.currentState().value == "198.51.100.7")
    }

    @Test("a failed lookup is not retried on the next tick either")
    func throttledAfterFailure() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)
        fetcher.setEnabled(true)
        fetcher.refreshIfDue()
        recorder.answer(.failure(.failed("could not reach the lookup service")))

        for _ in 0..<200 { fetcher.refreshIfDue() }

        #expect(recorder.requestCount == 1)
        #expect(fetcher.currentState().failure == .failed("could not reach the lookup service"))
    }

    /// The intervals themselves, because the whole justification for talking to a third
    /// party at all is that it happens rarely. A future edit that drops either of these
    /// to seconds should fail here rather than ship.
    @Test("the throttle is measured in many minutes")
    func intervalsAreLong() {
        #expect(PublicIPFetcher.refreshInterval == 30 * 60)
        #expect(PublicIPFetcher.retryInterval == 2 * 60)
        #expect(PublicIPFetcher.retryInterval < PublicIPFetcher.refreshInterval)
    }

    @Test("turning the toggle off clears the cached address and stops lookups")
    func disablingClearsTheCache() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)
        fetcher.setEnabled(true)
        fetcher.refreshIfDue()
        recorder.answer(.value("198.51.100.7"))
        #expect(fetcher.currentState().value == "198.51.100.7")

        fetcher.setEnabled(false)

        #expect(fetcher.currentState().value == nil)
        #expect(fetcher.currentState().isPermanentlyUnavailable)
        for _ in 0..<5 { fetcher.refreshIfDue() }
        #expect(recorder.requestCount == 1)
    }

    @Test("a reply that arrives after the toggle goes off is discarded")
    func lateReplyIsDropped() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)
        fetcher.setEnabled(true)
        fetcher.refreshIfDue()

        fetcher.setEnabled(false)
        recorder.answer(.value("198.51.100.7"))

        #expect(fetcher.currentState().value == nil)
        #expect(fetcher.currentState().isPermanentlyUnavailable)
    }

    @Test("switching back on starts from pending, not from the old address")
    func reenablingDoesNotShowStaleAddress() {
        let recorder = Recorder()
        let fetcher = PublicIPFetcher(transport: recorder.transport)
        fetcher.setEnabled(true)
        fetcher.refreshIfDue()
        recorder.answer(.value("198.51.100.7"))

        fetcher.setEnabled(false)
        fetcher.setEnabled(true)

        #expect(fetcher.currentState().failure == .pending)
        fetcher.refreshIfDue()
        #expect(recorder.requestCount == 2)
    }

    @Test("only a reply that parses as an address is displayed")
    func repliesAreValidated() {
        let ok = PublicIPFetcher.interpret(data: Data("198.51.100.7\n".utf8),
                                           response: nil, error: nil)
        #expect(ok.value == "198.51.100.7")

        let v6 = PublicIPFetcher.interpret(data: Data("2001:db8::1".utf8),
                                           response: nil, error: nil)
        #expect(v6.value == "2001:db8::1")

        // What a captive portal hands back: a 200, and its login page in the body.
        let portal = PublicIPFetcher.interpret(data: Data("<html>Sign in</html>".utf8),
                                               response: nil, error: nil)
        #expect(portal.value == nil)

        let response = HTTPURLResponse(url: PublicIPFetcher.endpoint, statusCode: 503,
                                       httpVersion: nil, headerFields: nil)
        let serverError = PublicIPFetcher.interpret(data: Data("198.51.100.7".utf8),
                                                    response: response, error: nil)
        #expect(serverError.value == nil)

        let offline = PublicIPFetcher.interpret(
            data: nil, response: nil,
            error: URLError(.notConnectedToInternet))
        #expect(offline.value == nil)
        #expect(offline.failure?.isPermanent == false)
    }
}
