import Darwin
import Foundation

/// How the fetcher reaches the network. The shipping implementation is one URLSession
/// round trip; tests substitute a closure so the throttle, the opt-in gate and the
/// clearing behaviour can be exercised on a machine that is offline.
public typealias PublicIPTransport =
    @Sendable (@escaping @Sendable (MetricState<String>) -> Void) -> Void

/// Looks up the machine's public IP address, off the sampling queue and only when the
/// user has asked for it.
///
/// This is the only code in the app that opens a connection to anything, so it holds
/// itself to rules the other collectors do not need:
///
/// - Nothing is sent until `setEnabled(true)` arrives from `general.fetchesPublicIP`,
///   which ships off. A fetcher nobody enabled never builds a session.
/// - `refreshIfDue()` is called from `NetworkCollector.collect()` on `SamplingCore`'s
///   serial queue and never waits for a reply: it either returns immediately or hands
///   the round trip to URLSession's own queues. `currentState()` reads a cached answer,
///   so the sampling tick costs a lock and nothing else.
/// - Turning the toggle back off drops the cached address. A withdrawn permission that
///   leaves the last answer on screen has not really been withdrawn.
///
/// State is guarded by a lock rather than confined to a queue: it is written from
/// URLSession's delegate queue and read from the sampling queue, which is exactly the
/// case `SamplingCore`'s confinement-by-construction does not cover.
public final class PublicIPFetcher: @unchecked Sendable {

    /// Half an hour. A public address is a lease from an ISP that turns over in days on
    /// a home line and in hours at worst, so unlike a rate it does not go stale between
    /// samples. Thirty minutes is 48 requests a day, few enough that the pattern tells
    /// the other end nothing beyond that the Mac is awake, and short enough that
    /// someone who moves onto a hotspot sees the new address without relaunching.
    public static let refreshInterval: TimeInterval = 30 * 60

    /// Two minutes after a failed attempt rather than the full interval. The ordinary
    /// failure is having no route at all, and a laptop that has just opened its lid
    /// should not sit on "unavailable" for half an hour once the Wi-Fi associates.
    public static let retryInterval: TimeInterval = 2 * 60

    /// api.ipify.org answers with the bare address as `text/plain`: no JSON envelope,
    /// no cookies, no redirect chain, no query string and no geolocation record that
    /// nobody asked for. The request therefore carries nothing the TCP connection would
    /// not already reveal, which is the least this app can ask of the one third party
    /// it talks to.
    public static let endpoint = URL(string: "https://api.ipify.org")!

    /// Said in place of an address while the feature is off, so the panel can leave the
    /// row out entirely instead of drawing an empty field.
    public static let disabledMessage = "Public IP lookup is off"

    private let transport: PublicIPTransport
    private let lock = NSLock()
    private var isEnabled = false
    private var state: MetricState<String> = .failure(.unsupported(PublicIPFetcher.disabledMessage))
    private var lastAttempt: ContinuousClock.Instant?
    private var isFetching = false

    /// Bumped every time the toggle moves. A reply that arrives after the user turned
    /// the feature off carries the old generation and is discarded: the request is
    /// already out and cannot be unsent, but its answer never reaches the screen.
    private var generation: UInt64 = 0

    public init(transport: @escaping PublicIPTransport = PublicIPFetcher.httpTransport()) {
        self.transport = transport
    }

    /// Safe from any thread. Called on `SamplingCore`'s queue when the setting changes.
    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        generation &+= 1
        lastAttempt = nil
        isFetching = false
        state = enabled ? .pending : .failure(.unsupported(Self.disabledMessage))
    }

    public func currentState() -> MetricState<String> {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Starts a lookup if the feature is on and the cached answer is old enough.
    /// Returns without waiting for the reply, so the caller may be the sampling queue.
    public func refreshIfDue() {
        lock.lock()
        guard isEnabled, !isFetching, isDueLocked() else {
            lock.unlock()
            return
        }
        isFetching = true
        lastAttempt = Monotonic.now
        let generation = self.generation
        lock.unlock()

        transport { [weak self] result in
            self?.finish(result, generation: generation)
        }
    }

    /// Timed from the start of the last attempt, not from the answer: a request that
    /// hangs until its timeout must not earn a second one the moment it gives up.
    private func isDueLocked() -> Bool {
        guard let lastAttempt else { return true }
        let interval = state.isAvailable ? Self.refreshInterval : Self.retryInterval
        return Monotonic.seconds(since: lastAttempt) >= interval
    }

    private func finish(_ result: MetricState<String>, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, isEnabled else { return }
        isFetching = false
        state = result
    }

    // MARK: Transport

    /// The shipping transport.
    ///
    /// The session is ephemeral: no cookie jar, no credential store and no disk cache
    /// outlive the request, so the lookup leaves nothing behind on this machine either.
    /// `waitsForConnectivity` is off on purpose, because an offline Mac should say it
    /// could not reach the endpoint rather than hold a request open until the network
    /// comes back and then report an address minutes late.
    public static func httpTransport(endpoint: URL = PublicIPFetcher.endpoint) -> PublicIPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)

        return { completion in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            // CFNetwork's default agent string spells out the OS build and the app
            // version. A fixed name says who is asking without describing the machine.
            request.setValue("AirStats", forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            session.dataTask(with: request) { data, response, error in
                completion(interpret(data: data, response: response, error: error))
            }.resume()
        }
    }

    static func interpret(data: Data?, response: URLResponse?, error: Error?) -> MetricState<String> {
        if let error {
            return .failure(.failed("could not reach the lookup service: \(error.localizedDescription)"))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failure(.failed("the lookup service answered HTTP \(http.statusCode)"))
        }
        guard let data, let text = String(data: data, encoding: .utf8) else {
            return .failure(.failed("the lookup service returned no address"))
        }
        // A captive portal answers every request with its own login page, and a 200 of
        // HTML is the usual shape of that. Nothing reaches the panel unless it parses
        // as an address.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIPAddress(trimmed) else {
            return .failure(.failed("the reply was not an IP address"))
        }
        return .value(trimmed)
    }

    static func isIPAddress(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count < 64 else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, text, &v6) == 1
    }
}
