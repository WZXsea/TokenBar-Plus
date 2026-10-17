import Foundation
import Testing
@testable import TokenBarCore

private func historyDate(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private func historyDay(_ date: String, tokens: Int64 = 100, cost: Double = 2, requests: Int = 3) -> DailySummary {
    DailySummary(date: date, tokens: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0), costUsd: cost, requestCount: requests, sessionCount: 1)
}
private struct HistoryQuota: QuotaProviding {
    var platform: TokenPlatform { .codex }
    func fetchQuota() async throws -> QuotaSnapshot { TestFixtures.quota(usedPercent: 20) }
}
private actor HistoryProvider: ActivityProviding {
    var calls = 0
    func fetchActivity(sinceWeeklyResetAt: Date?, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot { TestFixtures.activity() }
    func fetchHistory(days: Int, endDate: String, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot {
        self.calls += 1
        return TestFixtures.activity()
    }
}

@Suite("History aggregation and caching")
struct EssentialHistoryTests {
    @Test func yearAggregatesLeapFebruaryAndCrossesYear() {
        let data = ActivityHistoryPresentation(days: [historyDay("2024-02-28"), historyDay("2024-02-29", tokens: 200), historyDay("2024-03-01"), historyDay("2023-04-30")], range: .year, now: historyDate("2024-03-05T12:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(data.buckets.count == 12)
        #expect(data.buckets.first?.id == "2023-04")
        #expect(data.buckets.last?.id == "2024-03")
        let february = data.buckets.first { $0.id == "2024-02" }
        #expect(february?.tokens == 300)
        #expect(february?.costUsd == 4)
        #expect(february?.requestCount == 6)
    }

    @Test func localCalendarSelectsDayAcrossUTCMidnight() {
        let data = ActivityHistoryPresentation(days: [], range: .month, now: historyDate("2026-10-16T20:00:00Z"), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        #expect(data.buckets.count == 30)
        #expect(data.buckets.last?.id == "2026-10-17")
        #expect(data.buckets.first?.id == "2026-09-18")
    }

    @Test @MainActor func extendedHistoryCachesAndInvalidatesForTimezoneAndPricingRestart() async {
        let provider = HistoryProvider()
        let model = DashboardModel(quotaService: HistoryQuota(), activityService: provider, cache: nil, statisticsTimeZone: .utc)
        #expect(model.history.value == nil)
        await model.loadHistoryIfNeeded()
        await model.loadHistoryIfNeeded()
        #expect(await provider.calls == 1)
        #expect(model.history.value != nil)
        _ = model.updateStatisticsTimeZone(.local)
        #expect(model.history.value == nil)
        await model.loadHistoryIfNeeded()
        #expect(await provider.calls == 2)
        await model.restartActivityRefresh()
        #expect(model.history.value == nil)
    }

}
