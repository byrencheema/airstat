import Testing
import Foundation
@testable import AirStatKit

/// The comparison is the whole feature: everything else the checker does is in service
/// of putting one version beside another and deciding whether to say anything.
@Suite("Version comparison")
struct AppVersionTests {

    @Test("a later release is newer")
    func ordering() {
        #expect(AppVersion.isNewer("1.1", than: "1.0"))
        #expect(AppVersion.isNewer("2.0", than: "1.9"))
        #expect(AppVersion.isNewer("1.0.1", than: "1.0"))
        #expect(!AppVersion.isNewer("1.0", than: "1.1"))
        #expect(!AppVersion.isNewer("1.0", than: "1.0.1"))
    }

    /// The reason this is not `<` on strings. As text "1.10" sorts below "1.9", so a
    /// string comparison ships the wrong answer from the tenth release onwards and
    /// looks perfectly correct for the nine before it.
    @Test("the tenth release beats the ninth")
    func numericComponentsNotText() {
        #expect(AppVersion.isNewer("1.10", than: "1.9"))
        #expect(!AppVersion.isNewer("1.9", than: "1.10"))
        #expect(AppVersion.isNewer("1.0.10", than: "1.0.9"))
        #expect("1.10" < "1.9")
    }

    @Test("the same release is not newer than itself")
    func equalIsNotNewer() {
        #expect(!AppVersion.isNewer("1.1", than: "1.1"))
        #expect(!AppVersion.isNewer("1.1.0", than: "1.1"))
        #expect(!AppVersion.isNewer("1.1", than: "1.1.0"))
        #expect(!AppVersion.isNewer("1.0.0.0", than: "1"))
    }

    /// Nothing unparseable is ever newer than anything. This function is the only thing
    /// that can put an update notice on screen, so junk from the endpoint has to fail
    /// towards silence rather than towards an alert.
    @Test("malformed input is never newer")
    func malformedIsNeverNewer() {
        for junk in ["", " ", "abc", "v1.2", "1.2.3-beta", "1..2", "1.", ".1", "1,2",
                     "1.2.3.4.5", "9999999", "1.٢", "<html>", "-1.0", "1.-2"] {
            #expect(!AppVersion.isNewer(junk, than: "1.0"), "\(junk) was treated as a release")
            #expect(!AppVersion.isNewer("2.0", than: junk), "\(junk) was treated as a release")
        }
    }

    @Test("whitespace around a version is tolerated")
    func trimming() {
        #expect(AppVersion.isNewer(" 1.2\n", than: "1.1"))
        #expect(AppVersion.components("1.2") == [1, 2])
    }
}

/// Everything here runs against a stub transport and a settings store in a temporary
/// directory. The round trip is the one part of this feature that needs the internet;
/// the parts worth guarding are the ones that decide whether it happens at all.
@MainActor
@Suite("Update checker")
struct UpdateCheckerTests {

    /// Counts what would have left the machine and answers with whatever the test set.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var answer: UpdateCheckResult = .unavailable("no answer configured")

        var transport: UpdateTransport {
            // Through a synchronous method rather than inline: the closure is an async
            // function type, and a lock taken directly in one is a Swift 6 error even
            // when, as here, nothing suspends while it is held.
            { [self] url in record(url) }
        }

        private func record(_ url: URL) -> UpdateCheckResult {
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
            return answer
        }

        func set(_ result: UpdateCheckResult) {
            lock.lock()
            answer = result
            lock.unlock()
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return urls.count
        }

        var lastURL: URL? {
            lock.lock()
            defer { lock.unlock() }
            return urls.last
        }
    }

    private func makeStore() -> SettingsStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SettingsStore(directory: dir)
    }

    private func makeChecker(_ store: SettingsStore, _ recorder: Recorder,
                             version: String? = "1.0") -> UpdateChecker {
        UpdateChecker(settings: store, currentVersion: version, osVersion: "26.0",
                      transport: recorder.transport)
    }

    private let release = UpdateCheckResult.release(
        UpdateRelease(version: "1.1", url: URL(string: "https://airstats.app/download")!))

    // MARK: The seven-day gate

    @Test("a Mac that has never checked is due")
    func neverCheckedIsDue() {
        #expect(UpdateChecker.isDue(lastCheck: nil, now: Date()))
    }

    @Test("the gate stays shut for seven days and then opens")
    func gateInterval() {
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        #expect(!UpdateChecker.isDue(lastCheck: now, now: now))
        #expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-day), now: now))
        #expect(!UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-6.9 * day), now: now))
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-7 * day), now: now))
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(-40 * day), now: now))
        #expect(UpdateChecker.checkInterval == 7 * day)
    }

    /// A stored date in the future is what a clock correction leaves behind. Waiting it
    /// out would stop the app checking until that date arrived, which for a machine set
    /// a year forward is a year of silence.
    @Test("a date in the future does not disable checking")
    func futureDateIsDue() {
        let now = Date()
        #expect(UpdateChecker.isDue(lastCheck: now.addingTimeInterval(60 * 60), now: now))
    }

    @Test("a check that has already happened this week does not happen again")
    func gateBlocksTheSecondCheck() async {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder)

        let now = Date()
        checker.checkIfDue(now: now)
        await checker.currentCheck?.value
        #expect(recorder.requestCount == 1)

        for hours in [1, 6, 24, 24 * 6] {
            checker.checkIfDue(now: now.addingTimeInterval(TimeInterval(hours) * 60 * 60))
            await checker.currentCheck?.value
        }
        #expect(recorder.requestCount == 1)

        checker.checkIfDue(now: now.addingTimeInterval(UpdateChecker.checkInterval))
        await checker.currentCheck?.value
        #expect(recorder.requestCount == 2)
    }

    /// The gate is written before the answer comes back, so a service that is missing
    /// or hanging costs one request per week rather than one per launch forever.
    @Test("a failed check still closes the gate")
    func failureClosesTheGate() async {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(.unavailable("The update service answered HTTP 404."))
        let checker = makeChecker(store, recorder)

        let now = Date()
        checker.checkIfDue(now: now)
        await checker.currentCheck?.value
        #expect(recorder.requestCount == 1)
        #expect(store.settings.updates.lastCheckedAt != nil)

        checker.checkIfDue(now: now.addingTimeInterval(24 * 60 * 60))
        await checker.currentCheck?.value
        #expect(recorder.requestCount == 1)
        #expect(checker.status == .unavailable("The update service answered HTTP 404."))
        #expect(checker.availableRelease == nil)
    }

    @Test("the stored check date is what a relaunch reads, so it does not re-check")
    func gateSurvivesRelaunch() async {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(release)
        let now = Date()

        let first = makeChecker(store, recorder)
        first.checkIfDue(now: now)
        await first.currentCheck?.value

        // A second checker over the same store is what the next launch amounts to.
        let relaunched = makeChecker(store, recorder)
        relaunched.checkIfDue(now: now.addingTimeInterval(60))
        await relaunched.currentCheck?.value

        #expect(recorder.requestCount == 1)
    }

    // MARK: The setting

    @Test("nothing is sent while the setting is off")
    func gatedOnTheSetting() async {
        let store = makeStore()
        store.update { $0.general.checksForUpdates = false }
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder)

        for day in 0..<40 {
            checker.checkIfDue(now: Date().addingTimeInterval(TimeInterval(day) * 24 * 60 * 60))
            await checker.currentCheck?.value
        }

        #expect(recorder.requestCount == 0)
        #expect(store.settings.updates.lastCheckedAt == nil)
    }

    @Test("the setting ships on")
    func defaultsToOn() {
        #expect(GeneralSettings().checksForUpdates)
        #expect(Settings().general.checksForUpdates)
    }

    /// The button is the user asking, which outranks both the gate and the switch.
    @Test("Check Now ignores the gate")
    func manualCheckBypassesTheGate() async {
        let store = makeStore()
        store.update { $0.general.checksForUpdates = false }
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder)

        checker.checkNow()
        await checker.currentCheck?.value
        checker.checkNow()
        await checker.currentCheck?.value

        #expect(recorder.requestCount == 2)
    }

    // MARK: What the answer does

    @Test("a newer version is remembered and offered")
    func newerVersionIsOffered() async {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder)

        checker.checkNow()
        await checker.currentCheck?.value

        #expect(checker.status == .updateAvailable)
        #expect(store.settings.updates.latestVersion == "1.1")
        #expect(store.settings.updates.latestURL == URL(string: "https://airstats.app/download"))
        #expect(checker.availableRelease?.version == "1.1")
        // And it is still offered on the next launch, from stored settings alone.
        #expect(UpdateChecker.availableRelease(in: store.settings, currentVersion: "1.0")?.version == "1.1")
    }

    @Test("the running version and an older one are never announced")
    func sameOrOlderIsSilent() async {
        for served in ["1.0", "0.9", "1.0.0"] {
            let store = makeStore()
            let recorder = Recorder()
            recorder.set(.release(UpdateRelease(version: served,
                                                url: URL(string: "https://airstats.app/download")!)))
            let checker = makeChecker(store, recorder)

            checker.checkNow()
            await checker.currentCheck?.value

            #expect(checker.status == .upToDate, "\(served) was treated as an update")
            #expect(checker.availableRelease == nil, "\(served) was offered over 1.0")
        }
    }

    @Test("a failed check leaves a release the user was already told about alone")
    func failureKeepsTheKnownRelease() async {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder)
        checker.checkNow()
        await checker.currentCheck?.value

        recorder.set(.unavailable("AirStats could not reach the update service."))
        checker.checkNow()
        await checker.currentCheck?.value

        #expect(checker.availableRelease?.version == "1.1")
    }

    @Test("a development build with no version checks nothing")
    func developmentBuildDoesNotCheck() async {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder, version: nil)

        checker.checkIfDue()
        await checker.currentCheck?.value
        checker.checkNow()
        await checker.currentCheck?.value

        #expect(recorder.requestCount == 0)
        #expect(checker.availableRelease == nil)
    }

    // MARK: The request

    @Test("the request carries the running version and the macOS version")
    func requestCarriesTheAgreedQuery() async throws {
        let store = makeStore()
        let recorder = Recorder()
        recorder.set(release)
        let checker = makeChecker(store, recorder)

        checker.checkNow()
        await checker.currentCheck?.value

        let url = try #require(recorder.lastURL)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(url.scheme == "https")
        #expect(url.host == "airstats.app")
        #expect(url.path == "/api/version")
        #expect(components?.queryItems?.first { $0.name == "v" }?.value == "1.0")
        #expect(components?.queryItems?.first { $0.name == "os" }?.value == "26.0")
    }

    // MARK: The reply

    /// The endpoint does not exist yet, so every one of these is a shape the app will
    /// meet before it meets the agreed one.
    @Test("only the agreed reply is believed")
    func repliesAreValidated() {
        let good = UpdateChecker.interpret(
            data: Data(#"{"version": "1.1", "url": "https://airstats.app/download"}"#.utf8),
            response: nil)
        #expect(good == .release(UpdateRelease(version: "1.1",
                                               url: URL(string: "https://airstats.app/download")!)))

        let missing = HTTPURLResponse(url: UpdateChecker.endpoint, statusCode: 404,
                                      httpVersion: nil, headerFields: nil)
        #expect(UpdateChecker.interpret(data: Data("<html>Not found</html>".utf8),
                                        response: missing) == .unavailable("The update service answered HTTP 404."))

        // A captive portal's login page, served with a 200.
        #expect(isUnavailable(UpdateChecker.interpret(data: Data("<html>Sign in</html>".utf8),
                                                      response: nil)))
        #expect(isUnavailable(UpdateChecker.interpret(data: Data(), response: nil)))
        #expect(isUnavailable(UpdateChecker.interpret(data: Data("{}".utf8), response: nil)))
        // A version that is not a version, and an address this app will not open.
        #expect(isUnavailable(UpdateChecker.interpret(
            data: Data(#"{"version": "latest", "url": "https://airstats.app/download"}"#.utf8),
            response: nil)))
        #expect(isUnavailable(UpdateChecker.interpret(
            data: Data(#"{"version": "1.1", "url": "http://airstats.app/download"}"#.utf8),
            response: nil)))
        #expect(isUnavailable(UpdateChecker.interpret(
            data: Data(#"{"version": "1.1", "url": "javascript:alert(1)"}"#.utf8),
            response: nil)))
        // A body far larger than the agreed one is not parsed at all.
        let flood = #"{"version": "1.1", "url": "https://airstats.app/download", "pad": ""#
            + String(repeating: "x", count: 9000) + #""}"#
        #expect(isUnavailable(UpdateChecker.interpret(data: Data(flood.utf8), response: nil)))
    }

    private func isUnavailable(_ result: UpdateCheckResult) -> Bool {
        if case .unavailable = result { return true }
        return false
    }

    // MARK: Persistence

    @Test("what the check learned survives a settings round trip")
    func storedStateRoundTrips() throws {
        var settings = Settings()
        let checked = Date(timeIntervalSince1970: 1_760_000_000)
        settings.updates = UpdateSettings(lastCheckedAt: checked, latestVersion: "1.1",
                                          latestURL: URL(string: "https://airstats.app/download"))
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded.updates.lastCheckedAt == checked)
        #expect(decoded.updates.latestVersion == "1.1")
        #expect(decoded.updates.latestURL == settings.updates.latestURL)
    }

    @Test("a settings file written before this feature existed still loads")
    func absentKeyIsNotAnError() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"general":{}}"#.utf8))
        #expect(decoded.updates.lastCheckedAt == nil)
        #expect(decoded.updates.latestVersion == nil)
        #expect(decoded.general.checksForUpdates)
    }

    @Test("a malformed stored record falls back instead of failing the whole file")
    func malformedRecordIsIsolated() throws {
        let decoded = try JSONDecoder().decode(
            Settings.self,
            from: Data(#"{"updates":{"lastCheckedAt":"soon","latestVersion":7},"general":{"launchAtLogin":true}}"#.utf8))
        #expect(decoded.updates.lastCheckedAt == nil)
        #expect(decoded.updates.latestVersion == nil)
        #expect(decoded.general.launchAtLogin)
    }
}
