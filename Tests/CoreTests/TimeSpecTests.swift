import Foundation
import Testing

@testable import Core

@Suite struct TimeSpecTests {
    let now = Date(timeIntervalSince1970: 1_756_710_000)  // 2025-09-01T07:00:00Z
    let utc = TimeZone(identifier: "UTC")!

    static let parseCases: [(String, Double)] = [
        ("30s", 1_756_710_000.0 - 30),
        ("30m", 1_756_710_000.0 - 1800),
        ("2h", 1_756_710_000.0 - 7200),
        ("1d", 1_756_710_000.0 - 86400),
        ("1.5h", 1_756_710_000.0 - 5400),
        ("1756700000", 1_756_700_000.0),
        ("1756700000.5", 1_756_700_000.5),
        ("2025-09-01T07:00:00Z", 1_756_710_000.0),
        ("2025-09-01T07:00:00.250Z", 1_756_710_000.25),
        ("2025-09-01T09:00:00+02:00", 1_756_710_000.0),
        ("2025-09-01T07:00:00", 1_756_710_000.0),  // local, and local == UTC here
        ("2025-09-01 07:00", 1_756_710_000.0),
        ("2025-09-01", 1_756_684_800.0),
    ]

    @Test(arguments: parseCases)
    func parses(input: String, expected: Double) throws {
        let parsed = try TimeSpec.parse(input, now: now, timeZone: utc)
        #expect(abs(parsed - expected) < 0.001, "\(input)")
    }

    @Test(arguments: ["", "yesterday", "2h30m", "1e5", "2025-13-01", "5w"])
    func rejects(input: String) {
        #expect(throws: TimeSpecError.self) {
            try TimeSpec.parse(input, now: now, timeZone: utc)
        }
    }

    @Test func localTimeUsesGivenZone() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let parsed = try TimeSpec.parse("2025-09-01T16:00:00", now: now, timeZone: tokyo)
        #expect(parsed == 1_756_710_000.0)  // 16:00 JST == 07:00 UTC
    }
}
