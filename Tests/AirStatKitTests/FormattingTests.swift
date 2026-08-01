import Testing
import Foundation
@testable import AirStatKit

@Suite("Byte units follow Apple's own conventions")
struct ByteUnitTests {

    /// This Mac: hw.memsize = 19_327_352_832, which Apple calls "18 GB".
    @Test("memory is binary regardless of the storage preference")
    func memoryIsAlwaysBinary() {
        for style in ByteUnitStyle.allCases {
            let f = MetricFormatter(byteStyle: style)
            #expect(f.memory(UInt64(19_327_352_832)) == "18 GB")
        }
    }

    /// This Mac's APFS container: 494_384_795_648 bytes, which Finder calls "494 GB".
    @Test("storage is decimal by default, matching Finder")
    func storageIsDecimalByDefault() {
        let f = MetricFormatter()
        #expect(f.storage(UInt64(494_384_795_648)) == "494 GB")
    }

    @Test("storage honours an explicit binary preference")
    func storageBinaryOptIn() {
        let f = MetricFormatter(byteStyle: .binary)
        #expect(f.storage(UInt64(494_384_795_648)) == "460 GB")
    }

    @Test("unavailable values never render as zero")
    func unavailableIsNotZero() {
        let f = MetricFormatter()
        #expect(f.temperature(nil) == MetricFormatter.unavailable)
        #expect(f.duration(nil) == MetricFormatter.unavailable)
        #expect(f.watts(nil) == MetricFormatter.unavailable)
        #expect(f.percent(.nan) == MetricFormatter.unavailable)
        #expect(f.rpm(nil) == MetricFormatter.unavailable)
    }

    @Test("percent clamps but per-process CPU does not")
    func clampingRules() {
        let f = MetricFormatter()
        #expect(f.percent(1.5) == "100%")
        #expect(f.unclampedPercent(347.2) == "347.2%")
    }
}
