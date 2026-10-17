import SwiftUI
import Testing
import TokenBarCore
@testable import TokenBar

private actor MenuHistoryProvider: ActivityProviding {
    var requests: [Int] = []

    func fetchActivity(sinceWeeklyResetAt: Date?, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot {
        try await DemoActivityProvider().fetchActivity(sinceWeeklyResetAt: sinceWeeklyResetAt, statisticsTimeZone: statisticsTimeZone)
    }

    func fetchHistory(days: Int, endDate: String, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot {
        self.requests.append(days)
        return try await DemoActivityProvider().fetchHistory(days: days, endDate: endDate, statisticsTimeZone: statisticsTimeZone)
    }
}

@MainActor
@Suite("History selection in menu hosts")
struct ActivityHistorySelectionTests {
    @Test("Selecting year starts loading without an appearance or SwiftUI task lifecycle")
    func selectingYearStartsHistoryImmediately() async throws {
        let provider = MenuHistoryProvider()
        let model = DashboardModel(quotaService: DemoQuotaProvider(), activityService: provider, cache: nil)
        var range = ActivityHistoryRange.month
        let selection = ActivitySummarySection.historySelection(Binding(get: { range }, set: { range = $0 }), model: model)

        selection.wrappedValue = .year
        #expect(range == .year)
        // This binding has no hosting view, window, onAppear, or view task to drive the load.
        try await self.waitForHistory(model)
        #expect(await provider.requests == [366])
        #expect(model.history.value != nil)
        #expect(!model.history.isRefreshing)
    }

    @Test("Week and month remain on the existing snapshot; year reuses the loaded window")
    func shorterRangesStayLocalAndYearUsesCache() async throws {
        let provider = MenuHistoryProvider()
        let model = DashboardModel(quotaService: DemoQuotaProvider(), activityService: provider, cache: nil)
        var range = ActivityHistoryRange.month
        let selection = ActivitySummarySection.historySelection(Binding(get: { range }, set: { range = $0 }), model: model)

        selection.wrappedValue = .week
        selection.wrappedValue = .month
        #expect(await provider.requests.isEmpty)
        #expect(model.history.value == nil)
        selection.wrappedValue = .year
        try await self.waitForHistory(model)
        selection.wrappedValue = .month
        selection.wrappedValue = .year
        for _ in 0..<10 { await Task.yield() }
        #expect(range == .year)
        #expect(await provider.requests == [366])
    }

    private func waitForHistory(_ model: DashboardModel) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while model.history.value == nil && model.history.errorMessage == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.history.errorMessage == nil)
        #expect(model.history.value != nil)
    }
}
