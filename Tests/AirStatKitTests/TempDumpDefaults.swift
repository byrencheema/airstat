import Foundation
import Testing
@testable import AirStatKit

@Test func tempDumpDefaults() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Settings())
    try data.write(to: URL(fileURLWithPath: "/tmp/airstats-defaults.json"))
}
