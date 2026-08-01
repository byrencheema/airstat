import Testing
@testable import AirStatKit

@Suite("SampleRing")
struct SampleRingTests {

    @Test("wraps and preserves oldest-to-newest order")
    func wrapping() {
        var ring = SampleRing(capacity: 3)
        for value in [1, 2, 3, 4, 5] { ring.append(Float(value)) }
        #expect(ring.count == 3)
        #expect(ring.values == [3, 4, 5])
        #expect(ring.last == 5)
    }

    @Test("non-finite samples never enter the buffer")
    func rejectsNonFinite() {
        var ring = SampleRing(capacity: 2)
        ring.append(Float.nan)
        ring.append(Float.infinity)
        #expect(ring.values == [0, 0])
    }
}
