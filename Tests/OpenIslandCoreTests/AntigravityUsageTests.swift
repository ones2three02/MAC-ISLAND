import Foundation
import Testing
@testable import OpenIslandCore

struct AntigravityUsageTests {
    @Test
    func antigravityUsageLoaderParsesCachedRateLimits() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-antigravity-usage-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("open-island-antigravity-rl.json")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = """
        {
          "five_hour": {
            "used_percentage": 35.5,
            "resets_at": 1760000000
          },
          "seven_day": {
            "used_percentage": 20.0,
            "resets_at": 1760500000
          }
        }
        """
        try payload.write(to: cacheURL, atomically: true, encoding: .utf8)

        let snapshot = try AntigravityUsageLoader.load(from: cacheURL)

        #expect(snapshot?.fiveHour?.roundedUsedPercentage == 36)
        #expect(snapshot?.sevenDay?.roundedUsedPercentage == 20)
        #expect(snapshot?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(snapshot?.cachedAt != nil)
    }

    @Test
    func antigravityUsageLoaderParsesISO8601ResetDates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-antigravity-usage-iso-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = rootURL.appendingPathComponent("open-island-antigravity-rl.json")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let payload = """
        {
          "five_hour": {
            "utilization": 5,
            "resets_at": null
          },
          "seven_day": {
            "utilization": 45,
            "resets_at": "2026-02-09T12:00:00.462679+00:00"
          }
        }
        """
        try payload.write(to: cacheURL, atomically: true, encoding: .utf8)

        let snapshot = try AntigravityUsageLoader.load(from: cacheURL)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        #expect(snapshot?.fiveHour?.roundedUsedPercentage == 5)
        #expect(snapshot?.fiveHour?.resetsAt == nil)
        #expect(snapshot?.sevenDay?.roundedUsedPercentage == 45)
        #expect(snapshot?.sevenDay?.resetsAt == formatter.date(from: "2026-02-09T12:00:00.462679+00:00"))
    }
}
