import Foundation
import Observation

// MARK: - Versions

/// Comparison for the dotted release numbers this app is versioned with.
///
/// Component-wise and numeric, because the obvious alternative is not: `"1.10" < "1.9"`
/// as strings, so a string comparison starts shipping the wrong answer at the tenth
/// release of a minor series and looks correct until then.
public enum AppVersion {

    /// True when `candidate` is a strictly higher release than `current`.
    ///
    /// Anything that is not a plain dotted number — a build tag, an empty string, a
    /// value the endpoint invented — is not newer than anything. The result of this
    /// function is the only thing that can put an update notice on screen, so the
    /// unparseable case has to fail towards silence.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateParts = components(candidate),
              let currentParts = components(current) else { return false }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let left = index < candidateParts.count ? candidateParts[index] : 0
            let right = index < currentParts.count ? currentParts[index] : 0
            if left != right { return left > right }
        }
        // Missing components count as zero, so "1.1" and "1.1.0" are the same release.
        return false
    }

    /// The numeric components of a version string, or nil if it is not one.
    static func components(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 32 else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // `isNumber` is true of Devanagari digits and circled numerals too, and
            // `Int(_:)` accepts several of them, so ASCII is asserted separately.
            guard !part.isEmpty, part.count <= 6,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

// MARK: - Wire types

/// A release the endpoint says exists.
public struct UpdateRelease: Sendable, Equatable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// What one round trip produced.
///
/// Every way of failing collapses into `unavailable`: no route, a 404, a captive
/// portal's login page, a body that is not the agreed JSON. The automatic path treats
/// all of them the same way — by doing nothing — and the sentence exists only for the
/// user who pressed the button and is owed an answer.
public enum UpdateCheckResult: Sendable, Equatable {
    case release(UpdateRelease)
    case unavailable(String)
}

/// How the checker reaches the network. The shipping implementation is one URLSession
/// round trip; tests substitute a closure so the gate, the toggle and the comparison
/// can be exercised without an endpoint.
public typealias UpdateTransport = @Sendable (URL) async -> UpdateCheckResult

// MARK: - Checker

/// Asks airstats.app whether there is a newer release, and says so if there is.
///
/// It notifies and nothing else. Nothing is downloaded, nothing is installed, and no
/// framework is linked to do either: the whole feature is one GET, a version
/// comparison and a row in the About pane pointing at the download page. That is also
/// why it can afford to fail completely silently, which it does — a check that cannot
/// reach the endpoint leaves no alert, no log spam and no second attempt until the
/// gate reopens.
///
/// The request carries the running version and the macOS version so the endpoint can
/// answer with a build that will actually run on this Mac. It carries nothing else,
/// and the session is ephemeral, for the reasons spelled out on `PublicIPFetcher`.
@MainActor
@Observable
public final class UpdateChecker {

    /// What the last check did, for the About pane. Only the manual check displays
    /// this; the automatic one is meant to be invisible unless it finds something.
    ///
    /// `updateAvailable` carries no release because the release itself is stored in
    /// settings, which is what lets the notice survive a relaunch. `availableRelease`
    /// is the property to read for it.
    public enum Status: Sendable, Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable
        case unavailable(String)
    }

    /// Seven days. The endpoint learns that this Mac is running AirStats every time it
    /// is asked, so the interval is the whole privacy story of the feature: 52 requests
    /// a year says a copy is still in use and nothing more.
    public nonisolated static let checkInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Long enough after launch that the check is never competing with the app coming
    /// up, and long enough after a login that a laptop has usually associated with
    /// something by the time it fires.
    public nonisolated static let launchDelay: Duration = .seconds(20)

    /// How often a running app re-tests the gate. Not how often it checks: a Mac that
    /// stays up for a month would otherwise never check at all, because the only check
    /// this app would ever run is the one at launch.
    public nonisolated static let pollInterval: Duration = .seconds(6 * 60 * 60)

    public nonisolated static let endpoint = URL(string: "https://airstats.app/api/version")!

    public private(set) var status: Status = .idle

    private let settings: SettingsStore
    private let transport: UpdateTransport
    /// Nil when running the bare SwiftPM binary rather than the assembled `.app`,
    /// which has no version to compare against and so cannot check at all.
    private let currentVersion: String?
    private let osVersion: String
    private var schedule: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    public init(settings: SettingsStore,
                currentVersion: String? = UpdateChecker.bundleVersion,
                osVersion: String = UpdateChecker.systemVersion,
                transport: @escaping UpdateTransport = UpdateChecker.httpTransport()) {
        self.settings = settings
        self.currentVersion = currentVersion
        self.osVersion = osVersion
        self.transport = transport
    }

    // MARK: Lifecycle

    /// Arms the automatic path. Returns immediately; the first check happens a `launchDelay`
    /// later and only if the user has left the setting on and the gate has reopened.
    public func start() {
        guard schedule == nil else { return }
        schedule = Task { @MainActor [weak self] in
            try? await Task.sleep(for: UpdateChecker.launchDelay)
            while !Task.isCancelled {
                guard let self else { return }
                self.checkIfDue()
                try? await Task.sleep(for: UpdateChecker.pollInterval)
            }
        }
    }

    public func stop() {
        schedule?.cancel()
        schedule = nil
        inFlight?.cancel()
        inFlight = nil
    }

    // MARK: Checking

    /// The automatic path: honours both the user's setting and the seven-day gate.
    public func checkIfDue(now: Date = Date()) {
        guard settings.settings.general.checksForUpdates else { return }
        guard UpdateChecker.isDue(lastCheck: settings.settings.updates.lastCheckedAt, now: now) else { return }
        check(now: now)
    }

    /// The manual path: the gate does not apply, because the user pressing a button is
    /// a better reason to ask than a timer is. The setting does not apply either — the
    /// press is the consent, and a disabled button beside a switch the user just turned
    /// off would be answering a question they did not ask.
    public func checkNow(now: Date = Date()) {
        check(now: now)
    }

    /// True while a round trip is out. The pane disables its button on this rather than
    /// letting an impatient user queue requests the throttle exists to prevent.
    public var isChecking: Bool { inFlight != nil }

    /// The round trip currently out, so a test can wait for the answer. Nothing in the
    /// app awaits a check: the feature is fire and forget by design, which is also why
    /// this is not public.
    var currentCheck: Task<Void, Never>? { inFlight }

    /// The release worth telling the user about, or nil.
    ///
    /// Read from stored settings rather than from `status`, so the notice is still
    /// there after a relaunch and the user is not told about the same release only in
    /// the ten minutes after it was found. Nothing older than or equal to the running
    /// version ever comes back from here.
    public var availableRelease: UpdateRelease? {
        UpdateChecker.availableRelease(in: settings.settings, currentVersion: currentVersion)
    }

    public nonisolated static func availableRelease(in settings: Settings,
                                                    currentVersion: String? = UpdateChecker.bundleVersion)
        -> UpdateRelease? {
        guard let currentVersion,
              let version = settings.updates.latestVersion,
              let url = settings.updates.latestURL,
              AppVersion.isNewer(version, than: currentVersion) else { return nil }
        return UpdateRelease(version: version, url: url)
    }

    /// Whether the gate has reopened. A stored date in the future is treated as due:
    /// the clock moving backwards is the user's business, and the alternative is an app
    /// that quietly stops checking until the date it wrote catches up.
    public nonisolated static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        if elapsed < 0 { return true }
        return elapsed >= checkInterval
    }

    private func check(now: Date) {
        guard inFlight == nil else { return }
        guard let currentVersion else {
            status = .unavailable("This is a development build, so there is nothing to compare against.")
            return
        }

        // Written before the answer, not after it. The interval is measured from the
        // attempt so that an endpoint which is missing, slow or answering rubbish costs
        // one request per gate period rather than one per launch forever.
        settings.update { $0.updates.lastCheckedAt = now }
        status = .checking

        let url = UpdateChecker.requestURL(version: currentVersion, os: osVersion)
        let transport = self.transport
        inFlight = Task { @MainActor [weak self] in
            let result = await transport(url)
            guard let self, !Task.isCancelled else { return }
            self.inFlight = nil
            self.apply(result, currentVersion: currentVersion)
        }
    }

    private func apply(_ result: UpdateCheckResult, currentVersion: String) {
        switch result {
        case .unavailable(let message):
            // The stored release is left alone: a check that could not complete has not
            // learned that a version the user was told about has gone away.
            status = .unavailable(message)
        case .release(let release):
            settings.update {
                $0.updates.latestVersion = release.version
                $0.updates.latestURL = release.url
            }
            status = AppVersion.isNewer(release.version, than: currentVersion) ? .updateAvailable : .upToDate
        }
    }

    // MARK: Request

    nonisolated static func requestURL(endpoint: URL = UpdateChecker.endpoint, version: String, os: String) -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.queryItems = [URLQueryItem(name: "v", value: version),
                                 URLQueryItem(name: "os", value: os)]
        return components.url ?? endpoint
    }

    public nonisolated static var bundleVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Two components, which is how Apple names a release: "26.0", not "26.0.1".
    public nonisolated static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    // MARK: Transport

    /// The shipping transport. Ephemeral session, no cookies and no cache, so a check
    /// leaves nothing behind on this machine; `waitsForConnectivity` off, so an offline
    /// Mac fails now instead of holding a request open until the network returns.
    public nonisolated static func httpTransport() -> UpdateTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)

        return { url in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            // CFNetwork's default agent string spells out the OS build and the app
            // version; the query already says both, in the form that was agreed.
            request.setValue("AirStats", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                return interpret(data: data, response: response)
            } catch {
                return .unavailable("AirStats could not reach the update service.")
            }
        }
    }

    /// The reply, checked hard enough that nothing but the agreed shape can reach the
    /// user. A missing endpoint answers 404 with an HTML error page, and a captive
    /// portal answers 200 with a login page, so neither the status nor the body can be
    /// taken on trust.
    nonisolated static func interpret(data: Data, response: URLResponse?) -> UpdateCheckResult {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .unavailable("The update service answered HTTP \(http.statusCode).")
        }
        guard data.count <= 8192, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .unavailable("The update service sent a reply AirStats could not read.")
        }
        guard AppVersion.components(payload.version) != nil else {
            return .unavailable("The update service named a version AirStats could not read.")
        }
        // The URL becomes a link the user clicks, so it has to be one this app would
        // have been willing to write down itself.
        guard let url = URL(string: payload.url), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return .unavailable("The update service sent a download address AirStats will not open.")
        }
        return .release(UpdateRelease(version: payload.version, url: url))
    }

    private struct Payload: Decodable {
        let version: String
        let url: String
    }
}
