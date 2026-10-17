import Foundation
import Testing
@testable import TokenBarCore

private struct StubRateLimitsRequester: CodexRateLimitsRequesting {
    let result: Result<Data, any Error & Sendable>
    func fetchRateLimitsResult() async throws -> Data { try self.result.get() }
}

@Suite("Quota source and cache contracts")
struct EssentialQuotaTests {
    @Test("classifies reversed app-server windows by duration")
    func classifiesReversedWindows() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800597600
                },
                "secondary": {
                  "usedPercent": 40,
                  "windowDurationMins": 300,
                  "resetsAt": 1800000300
                }
              }
            }
            """.utf8)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session?.usedPercent == 40)
        #expect(snapshot.session?.windowMinutes == 300)
        #expect(snapshot.weekly?.usedPercent == 3)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
    }

    @Test("classifies a lone primary seven-day window as weekly")
    func classifiesPrimaryWeeklyOnly() async throws {
        let requester = StubRateLimitsRequester(result: .success(Data(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1800597600
                },
                "secondary": null
              }
            }
            """.utf8)))

        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 3)
        #expect(snapshot.weekly?.remainingPercent == 97)
        #expect(snapshot.weekly?.windowMinutes == 10_080)
        #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_800_597_600))
    }

    @Test("recovers plan metadata from quota error bodies")
    func recoversPlanType() async throws {
        let message = """
        decode error; body={"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":35,"limit_window_seconds":604800}}}
        """
        let requester = StubRateLimitsRequester(result: .failure(CodexAppServerError.requestFailed(message)))
        let snapshot = try await CodexAppServerQuotaClient(requester: requester).fetchQuota()
        #expect(snapshot.planType == "pro")
        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.usedPercent == 35)
    }

    @Test("legacy quota caches decode without a plan")
    func legacyCache() throws {
        let data = Data(#"{"updatedAt":0,"weekly":{"usedPercent":35,"windowMinutes":10080}}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
        #expect(decoded.planType == nil)
        #expect(decoded.planDisplayName == nil)
        #expect(decoded.weekly?.usedPercent == 35)
    }

    @Test("plan metadata survives cache encoding")
    func roundTrip() throws {
        let snapshot = QuotaSnapshot(session: nil, weekly: nil, resetCredits: nil,
                                     updatedAt: Date(), planType: "pro")
        let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored == snapshot)
    }

}

@Suite("Weekly reset tracking")
struct EssentialWeeklyUsageTests {
    @Test("small reset timestamp drift preserves the cycle and observed daily usage")
    func preservesCycleAcrossResetTimestampDrift() throws {
        let first = self.snapshot(usedPercent: 30, offset: 86_400)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(self.snapshot(usedPercent: 51, offset: 86_700))
            .recording(self.snapshot(
                usedPercent: 51,
                offset: 86_800,
                windowStart: self.windowStart.addingTimeInterval(2)))
            .recording(self.snapshot(
                usedPercent: 52,
                offset: 86_900,
                windowStart: self.windowStart.addingTimeInterval(-3)))

        #expect(history.baselines.count == 1)
        #expect(history.increments.map(\.usedPercentagePoints) == [21, 1])
        #expect(history.highWaterUsedPercent == 52)
        #expect(history.usage(on: "2026-08-18", statisticsTimeZone: .utc)?.usedPercentagePoints == 22)
        #expect(history.validated() != nil)
    }

    @Test("an early real reset starts a new baseline")
    func earlyResetCreatesBaseline() throws {
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: self.snapshot(
            usedPercent: 40,
            offset: 86_400)))
            .recording(self.snapshot(usedPercent: 50, offset: 86_500))
        let reset = history.recording(self.snapshot(
            usedPercent: 2,
            offset: 60,
            windowStart: self.windowStart.addingTimeInterval(86_600)))

        #expect(reset.baselines.map(\.usedPercent) == [40, 2])
        #expect(reset.highWaterUsedPercent == 2)
        #expect(reset.increments.map(\.usedPercentagePoints) == [10])
        #expect(reset.validated() != nil)
    }
    private let windowStart: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: 17))!
    }()


    private func snapshot(
        usedPercent: Double,
        offset: TimeInterval,
        windowStart: Date? = nil) -> QuotaSnapshot
    {
        let windowStart = windowStart ?? self.windowStart
        return QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: usedPercent,
                windowMinutes: 10_080,
                resetsAt: windowStart.addingTimeInterval(7 * 86_400)),
            resetCredits: nil,
            updatedAt: windowStart.addingTimeInterval(offset))
    }
}

@Suite("Daily quota attribution")
struct EssentialQuotaDayTests {
    @Test("first observation day is partial and baseline stays unattributed")
    func partialFirstDay() throws {
        let first = snapshot(20, hour: 49)
        let last = snapshot(23, hour: 50)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first)).recording(last)
        let result = breakdown(last, history: history, hour: 51)
        #expect(result.todayUsedPercentagePoints == 3)
        #expect(result.todayIsPartial)
        #expect(result.yesterdayUsedPercentagePoints == nil)
        #expect(result.earlierUsedPercentagePoints == 20)
    }

    @Test("legacy duplicate baselines preserve today's observed usage")
    func recoversContinuousLegacyBaselines() throws {
        let first = snapshot(30, hour: 49)
        let current = snapshot(51, hour: 52)
        let initial = try #require(WeeklyQuotaUsageHistory.starting(with: first))
        let history = WeeklyQuotaUsageHistory(
            currentWindowStart: initial.currentWindowStart,
            currentWindowEnd: initial.currentWindowEnd,
            lastSampledAt: current.updatedAt,
            highWaterUsedPercent: 51,
            baselines: initial.baselines + [
                WeeklyQuotaTrackingBaseline(sampledAt: snapshot(51, hour: 51).updatedAt, usedPercent: 51),
                WeeklyQuotaTrackingBaseline(sampledAt: current.updatedAt, usedPercent: 51),
            ],
            increments: [WeeklyQuotaUsageIncrement(
                sampledAt: snapshot(51, hour: 50).updatedAt, usedPercentagePoints: 21)])
        let result = breakdown(current, history: history, hour: 53)
        #expect(result.todayUsedPercentagePoints == 21)
        #expect(result.earlierUsedPercentagePoints == 30)
        #expect(result.todayIsPartial)
        #expect(!result.wasAdjustedForQuotaCorrection)
        // Recovery is a presentation operation; the stored evidence remains intact.
        #expect(history.baselines.count == 3)
        let later = snapshot(53, hour: 53)
        #expect(breakdown(later, history: history.recording(later), hour: 54)
            .todayUsedPercentagePoints == 23)
    }
    private let start = Date(timeIntervalSince1970: 1_786_924_800)

    private func snapshot(_ used: Double, hour: Double, cycleStart: Date? = nil) -> QuotaSnapshot {
        let base = cycleStart ?? start
        return QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: used, windowMinutes: 10_080,
                resetsAt: base.addingTimeInterval(168 * 3_600)),
            resetCredits: nil, updatedAt: base.addingTimeInterval(hour * 3_600))
    }

    private func breakdown(
        _ snapshot: QuotaSnapshot, history: WeeklyQuotaUsageHistory?, hour: Double) -> WeeklyQuotaDayBreakdown
    {
        WeeklyQuotaDayBreakdown(
            snapshot: snapshot, history: history, at: start.addingTimeInterval(hour * 3_600),
            statisticsTimeZone: .utc)
    }
}
