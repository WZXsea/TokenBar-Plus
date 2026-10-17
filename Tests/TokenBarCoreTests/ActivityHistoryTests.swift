import Foundation
import Testing
@testable import TokenBarCore

private func historyDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
private func historyDay(_ date: String, tokens: Int64 = 100, cost: Double = 2, requests: Int = 3) -> DailySummary {
    DailySummary(date: date, tokens: TokenBreakdown(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0, reasoning: 0), costUsd: cost, requestCount: requests, sessionCount: 1)
}
private struct HistoryQuota: QuotaProviding {
    var platform: TokenPlatform { .codex }
    func fetchQuota() async throws -> QuotaSnapshot { TestFixtures.quota(usedPercent: 20) }
}
private actor HistoryProvider: ActivityProviding {
    var calls = 0
    var pending: CheckedContinuation<ActivitySnapshot, Never>?
    var shouldPause = false
    func pauseNext() { self.shouldPause = true }
    func release() { self.pending?.resume(returning: TestFixtures.activity(generatedAtMs: 1)); self.pending = nil }
    func fetchActivity(sinceWeeklyResetAt: Date?, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot { TestFixtures.activity() }
    func fetchHistory(days: Int, endDate: String, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot {
        self.calls += 1
        if self.shouldPause {
            self.shouldPause = false
            return await withCheckedContinuation { self.pending = $0 }
        }
        return TestFixtures.activity(generatedAtMs: 2)
    }
}

private struct UnsupportedHistoryProvider: ActivityProviding {
    func fetchActivity(sinceWeeklyResetAt: Date?, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot { TestFixtures.activity() }
}
private actor HistoryRunner: ActivityHelperRunning {
    var arguments: [String] = []
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        self.arguments = arguments
        return try JSONEncoder().encode(TestFixtures.activity())
    }
}

private final class HistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { self.lock.lock(); defer { self.lock.unlock() }; return self.value }
    func advance(_ seconds: TimeInterval) { self.lock.lock(); defer { self.lock.unlock() }; self.value.addTimeInterval(seconds) }
}
private actor IncrementalHistoryProvider: ActivityProviding {
    private var snapshots: [ActivitySnapshot]
    var requestedDays: [Int] = []
    init(_ snapshots: [ActivitySnapshot]) { self.snapshots = snapshots }
    func fetchActivity(sinceWeeklyResetAt: Date?, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot { TestFixtures.activity() }
    func fetchHistory(days: Int, endDate: String, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot {
        self.requestedDays.append(days)
        return self.snapshots.count > 1 ? self.snapshots.removeFirst() : self.snapshots[0]
    }
}
private func incrementalHistorySnapshot(days: [DailySummary], sources: [ActivitySourceSnapshot]) -> ActivitySnapshot {
    ActivitySnapshot(schemaVersion: 1, generatedAtMs: 1_792_195_200_000, timezone: "UTC", today: .zero, sessions: [], days: days, sources: sources)
}

@Suite("Usage history periods")
struct ActivityHistoryTests {
    @Test func weekFillsMissingDatesAndExcludesFuture() {
        let data = ActivityHistoryPresentation(days: [historyDay("2026-01-01"), historyDay("2026-01-05"), historyDay("2026-01-06")], range: .week, now: historyDate("2026-01-05T12:00:00Z"), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(data.buckets.count == 7)
        #expect(data.buckets.first?.id == "2025-12-30")
        #expect(data.buckets.last?.id == "2026-01-05")
        #expect(data.totalTokens == 200)
        #expect(data.buckets.filter { $0.tokens == 0 }.count == 5)
    }
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
    @Test @MainActor func supersededHistoryResultCannotReplaceCurrentState() async {
        let provider = HistoryProvider()
        await provider.pauseNext()
        let model = DashboardModel(quotaService: HistoryQuota(), activityService: provider, cache: nil, statisticsTimeZone: .utc)
        let stale = Task { await model.loadHistoryIfNeeded() }
        while await provider.pending == nil { await Task.yield() }
        model.invalidateHistory()
        await model.loadHistoryIfNeeded()
        await provider.release()
        await stale.value
        #expect(model.history.value?.generatedAtMs == 2)
        #expect(model.history.isRefreshing == false)
    }
    @Test @MainActor func unsupportedExtendedHistoryRemainsUnknownWithError() async {
        let model = DashboardModel(quotaService: HistoryQuota(), activityService: UnsupportedHistoryProvider(), cache: nil)
        await model.loadHistoryIfNeeded()
        #expect(model.history.value == nil)
        #expect(model.history.errorMessage != nil)
        #expect(model.history.isRefreshing == false)
    }
    @Test func historyHelperUsesExplicitWindowAndCustomPrices() async throws {
        let runner = HistoryRunner()
        let service = ActivityService(
            customPricingURLProvider: { URL(fileURLWithPath: "/tmp/history-prices.json") },
            resolveHelper: { URL(fileURLWithPath: "/tmp/tokenbar-helper") }, runner: runner)
        _ = try await service.fetchHistory(days: 366, endDate: "2026-10-17", statisticsTimeZone: .utc)
        let args = await runner.arguments
        #expect(args.contains("366"))
        #expect(args.contains("2026-10-17"))
        #expect(args.contains("--statistics-timezone"))
        #expect(args.contains("/tmp/history-prices.json"))
    }

    @Test @MainActor func expiryRefreshesThirtyLocalDaysAndRetainsOlderMonthsByPlatform() async {
        let oldCodex = [historyDay("2026-01-01"), historyDay("2026-09-20", tokens: 50), historyDay("2026-10-17", tokens: 10)]
        let oldGrok = [historyDay("2026-01-01", tokens: 700), historyDay("2026-09-23", tokens: 900)]
        let initial = incrementalHistorySnapshot(
            days: [historyDay("2025-01-01"), historyDay("2026-01-01", tokens: 800), historyDay("2026-09-20", tokens: 50)],
            sources: [
                ActivitySourceSnapshot(platform: .codex, today: .zero, weeklySinceReset: nil, days: oldCodex),
                ActivitySourceSnapshot(platform: .grok, today: TestFixtures.activity().today, weeklySinceReset: nil, days: oldGrok),
            ])
        let current = [historyDay("2026-10-17", tokens: 120)]
        let recent = incrementalHistorySnapshot(days: current, sources: [
            ActivitySourceSnapshot(platform: .codex, today: .zero, weeklySinceReset: nil, days: current),
        ])
        let provider = IncrementalHistoryProvider([initial, recent, initial])
        let clock = HistoryClock(historyDate("2026-10-17T12:00:00Z"))
        let model = DashboardModel(
            quotaService: HistoryQuota(), activityService: provider, cache: nil,
            quotaRefreshInterval: .seconds(300), activityRefreshInterval: .seconds(300), statisticsTimeZone: .utc,
            sleep: { _ in }, now: { clock.now() })
        await model.loadHistoryIfNeeded()
        clock.advance(301)
        await model.loadHistoryIfNeeded()
        #expect(await provider.requestedDays == [366, 30])
        #expect(model.historyDays(for: nil).map(\.date) == ["2026-01-01", "2026-10-17"])
        #expect(model.historyDays(for: .codex).map(\.tokens.total) == [100, 120])
        #expect(model.historyDays(for: .grok).map(\.tokens.total) == [700])
        #expect(model.history.value?.scoped(to: .grok).today == .zero)
        #expect(model.history.value?.rangeTotals == nil)
        #expect(model.history.value?.sourceSnapshots.allSatisfy { $0.rangeTotals == nil } == true)
        await model.restartActivityRefresh()
        await model.loadHistoryIfNeeded()
        #expect(await provider.requestedDays == [366, 30, 366])
    }

}
