import Testing
import Foundation
@testable import AirStatKit

@MainActor
@Suite("Holding updates while the panel animates")
struct MetricsEngineHoldTests {

    private func makeEngine() -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetricsEngine(settingsStore: SettingsStore(directory: dir))
    }

    private func snapshot(at date: Date) -> SystemSnapshot {
        var s = SystemSnapshot.empty
        s.capturedAt = date
        return s
    }

    /// The panel sizes its window to its content, so a sample that lands while a
    /// module is animating open retargets the window height for reasons unrelated to
    /// the disclosure. The hold is what stops that.
    @Test("a sample arriving during a hold is not published until the hold lifts")
    func heldSampleIsDeferred() async throws {
        let engine = makeEngine()
        let before = engine.lastUpdate

        engine.holdUpdates(for: .milliseconds(120))
        let held = Date(timeIntervalSince1970: 1_000)
        engine.ingest(snapshot(at: held))
        #expect(engine.lastUpdate == before, "the held sample was published anyway")

        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.lastUpdate == held, "the held sample never arrived")
    }

    /// Only the newest is kept. Flushing a backlog the instant the hold lifts would
    /// trade one late update for a burst of them.
    @Test("only the last sample taken during a hold is published")
    func onlyTheNewestHeldSampleSurvives() async throws {
        let engine = makeEngine()
        engine.holdUpdates(for: .milliseconds(120))
        engine.ingest(snapshot(at: Date(timeIntervalSince1970: 1_000)))
        let last = Date(timeIntervalSince1970: 2_000)
        engine.ingest(snapshot(at: last))

        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.lastUpdate == last)
    }

    @Test("samples outside a hold are published immediately")
    func unheldSamplesArePublishedAtOnce() {
        let engine = makeEngine()
        let now = Date(timeIntervalSince1970: 3_000)
        engine.ingest(snapshot(at: now))
        #expect(engine.lastUpdate == now)
    }
}
