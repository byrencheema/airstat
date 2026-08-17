import Testing
import Foundation
@testable import AirStatUI

/// A scheduled update says two things: a row in the panel, which stands for as long as
/// the update is outstanding, and one notification, which is an event. Only the second
/// can go wrong quietly, and only a release later: announce on the wrong predicate and
/// every launch posts a banner for an update the user already declined, or a release
/// ships and nobody is told. So the predicate is pure and it is tested.
@Suite("An update is announced once per release")
struct UpdateAnnouncerTests {

    @Test("a release nobody has been told about is announced")
    func announcesFirstTime() {
        #expect(UpdateAnnouncer.shouldAnnounce(pending: "1.2", announced: nil))
    }

    @Test("the same release is never announced twice")
    func doesNotNag() {
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: "1.2", announced: "1.2"))
    }

    @Test("the release after an announced one still speaks")
    func announcesNextRelease() {
        #expect(UpdateAnnouncer.shouldAnnounce(pending: "1.3", announced: "1.2"))
    }

    /// Sparkle reports no pending update whenever the session ends, including when the
    /// user installed the thing, and an empty display version is a release that arrived
    /// without one.
    @Test("nothing is announced with nothing pending")
    func staysQuietWithoutAnUpdate() {
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: nil, announced: "1.2"))
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: "", announced: nil))
    }
}
