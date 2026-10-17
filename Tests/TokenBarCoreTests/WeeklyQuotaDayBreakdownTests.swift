import Foundation
import Testing
@testable import TokenBarCore

@Suite("Weekly quota day breakdown")
struct WeeklyQuotaDayBreakdownTests {
    private let start = Date(timeIntervalSince1970: 1_786_924_800) // 2026-08-17 UTC

    @Test("groups sampled increments and preserves unattributed baseline")
    func groupsDays() throws {
        let first = snapshot(20, hour: 1)
        let yesterday = snapshot(25, hour: 25)
        let today = snapshot(32, hour: 49)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(yesterday).recording(today)
        let result = breakdown(today, history: history, hour: 50)
        #expect(result.todayUsedPercentagePoints == 7)
        #expect(result.yesterdayUsedPercentagePoints == 5)
        #expect(result.earlierUsedPercentagePoints == 20)
        #expect(result.totalUsedPercent == 32)
        #expect(!result.todayIsPartial)
        #expect(!result.yesterdayIsPartial)
    }

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

    @Test("absent or expired history leaves all usage unattributed")
    func missingAndExpired() throws {
        let last = snapshot(23, hour: 50)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: last))
        for result in [breakdown(last, history: nil, hour: 51), breakdown(last, history: history, hour: 169)] {
            #expect(result.todayUsedPercentagePoints == nil)
            #expect(result.yesterdayUsedPercentagePoints == nil)
            #expect(result.earlierUsedPercentagePoints == 23)
        }
    }

    @Test("reset excludes previous cycle even when reset happens today")
    func resetToday() throws {
        let first = snapshot(20, hour: 165)
        let old = snapshot(25, hour: 167)
        let next = snapshot(4, hour: 0.5, cycleStart: start.addingTimeInterval(168 * 3_600))
        let last = snapshot(6, hour: 1, cycleStart: start.addingTimeInterval(168 * 3_600))
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(old).recording(next).recording(last)
        let result = breakdown(last, history: history, hour: 169)
        #expect(result.todayUsedPercentagePoints == 2)
        #expect(result.yesterdayUsedPercentagePoints == nil)
        #expect(result.earlierUsedPercentagePoints == 4)
        #expect(result.todayIsPartial)
        let stale = try #require(WeeklyQuotaUsageHistory.starting(with: first)).recording(old)
        #expect(breakdown(last, history: stale, hour: 169).todayUsedPercentagePoints == nil)
    }

    @Test("correction scales observed contributions and preserves reported total")
    func correction() throws {
        let first = snapshot(40, hour: 1)
        let yesterday = snapshot(45, hour: 25)
        let high = snapshot(50, hour: 49)
        let lower = snapshot(30, hour: 50)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(yesterday).recording(high).recording(lower)
        let result = breakdown(lower, history: history, hour: 51)
        #expect(result.todayUsedPercentagePoints == 3)
        #expect(result.yesterdayUsedPercentagePoints == 3)
        #expect(result.earlierUsedPercentagePoints == 24)
        #expect(result.totalUsedPercent == 30)
        #expect(result.wasAdjustedForQuotaCorrection)
    }

    @Test("statistics timezone regroups cross-midnight samples")
    func timeZones() throws {
        let first = snapshot(20, hour: 10)
        let yesterday = snapshot(25, hour: 23.5)
        let today = snapshot(30, hour: 24.5)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(yesterday).recording(today)
        let utc = breakdown(today, history: history, hour: 25)
        let shifted = WeeklyQuotaDayBreakdown(
            snapshot: today, history: history, at: start.addingTimeInterval(25 * 3_600),
            timeZone: try #require(TimeZone(secondsFromGMT: 7_200)))
        #expect(utc.todayUsedPercentagePoints == 5)
        #expect(utc.yesterdayUsedPercentagePoints == 5)
        #expect(shifted.todayUsedPercentagePoints == 10)
        #expect(shifted.yesterdayUsedPercentagePoints == 0)
    }

    @Test("a new day without samples stays unknown")
    func noCurrentDaySample() throws {
        let last = snapshot(20, hour: 23)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: last))
        let result = breakdown(last, history: history, hour: 25)
        #expect(result.todayUsedPercentagePoints == nil)
        #expect(result.yesterdayUsedPercentagePoints == 0)
        #expect(result.yesterdayIsPartial)
        #expect(result.earlierUsedPercentagePoints == 20)
    }

    @Test("zero baseline establishes measured zero and zero correction stays nonnegative")
    func zeroUsage() throws {
        let first = snapshot(0, hour: 49)
        let high = snapshot(5, hour: 50)
        let zero = snapshot(0, hour: 51)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
        #expect(!breakdown(first, history: history, hour: 49).todayIsPartial)
        let result = breakdown(zero, history: history.recording(high).recording(zero), hour: 52)
        #expect(result.todayUsedPercentagePoints == 0)
        #expect(result.earlierUsedPercentagePoints == 0)
        #expect(result.totalUsedPercent == 0)
        #expect(result.wasAdjustedForQuotaCorrection)
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

    @Test("an unexplained increase preserves the newer tracking boundary")
    func unexplainedBaselineIncrease() throws {
        let first = snapshot(20, hour: 49)
        let current = snapshot(28, hour: 53)
        let initial = try #require(WeeklyQuotaUsageHistory.starting(with: first))
        let history = WeeklyQuotaUsageHistory(
            currentWindowStart: initial.currentWindowStart,
            currentWindowEnd: initial.currentWindowEnd,
            lastSampledAt: current.updatedAt,
            highWaterUsedPercent: 28,
            baselines: initial.baselines + [WeeklyQuotaTrackingBaseline(
                sampledAt: snapshot(25, hour: 51).updatedAt, usedPercent: 25)],
            increments: [
                WeeklyQuotaUsageIncrement(sampledAt: snapshot(23, hour: 50).updatedAt,
                                          usedPercentagePoints: 3),
                WeeklyQuotaUsageIncrement(sampledAt: current.updatedAt, usedPercentagePoints: 3),
            ])
        let result = breakdown(current, history: history, hour: 54)
        #expect(result.todayUsedPercentagePoints == 3)
        #expect(result.earlierUsedPercentagePoints == 25)
    }

    @Test("a lower baseline preserves a genuine usage restart")
    func decliningBaseline() throws {
        let first = snapshot(40, hour: 49)
        let current = snapshot(25, hour: 53)
        let initial = try #require(WeeklyQuotaUsageHistory.starting(with: first))
        let history = WeeklyQuotaUsageHistory(
            currentWindowStart: initial.currentWindowStart,
            currentWindowEnd: initial.currentWindowEnd,
            lastSampledAt: current.updatedAt,
            highWaterUsedPercent: 25,
            baselines: initial.baselines + [WeeklyQuotaTrackingBaseline(
                sampledAt: snapshot(20, hour: 51).updatedAt, usedPercent: 20)],
            increments: [WeeklyQuotaUsageIncrement(sampledAt: current.updatedAt, usedPercentagePoints: 5)])
        let result = breakdown(current, history: history, hour: 54)
        #expect(result.todayUsedPercentagePoints == 5)
        #expect(result.earlierUsedPercentagePoints == 20)
    }

    @Test("closed arithmetic cannot carry usage across a true window boundary")
    func closedArithmeticAcrossRealReset() throws {
        let first = snapshot(20, hour: 165)
        let old = snapshot(25, hour: 167)
        let nextStart = start.addingTimeInterval(168 * 3_600)
        let next = snapshot(25, hour: 0.5, cycleStart: nextStart)
        let current = snapshot(27, hour: 1, cycleStart: nextStart)
        let history = try #require(WeeklyQuotaUsageHistory.starting(with: first))
            .recording(old).recording(next).recording(current)
        let result = breakdown(current, history: history, hour: 169)
        #expect(result.todayUsedPercentagePoints == 2)
        #expect(result.yesterdayUsedPercentagePoints == nil)
        #expect(result.earlierUsedPercentagePoints == 25)
    }

    @Test("a small start adjustment preserves the sole initial baseline")
    func baselineJustBeforeRevisedStart() throws {
        let first = snapshot(20, hour: 1.0 / 3_600)
        let revised = snapshot(25, hour: 1, cycleStart: start.addingTimeInterval(2))
        let initial = try #require(WeeklyQuotaUsageHistory.starting(with: first))
        let history = WeeklyQuotaUsageHistory(
            currentWindowStart: start.addingTimeInterval(2),
            currentWindowEnd: initial.currentWindowEnd.addingTimeInterval(2),
            lastSampledAt: revised.updatedAt,
            highWaterUsedPercent: 25,
            baselines: initial.baselines,
            increments: [WeeklyQuotaUsageIncrement(sampledAt: revised.updatedAt, usedPercentagePoints: 5)])
        let result = breakdown(revised, history: history, hour: 2)
        #expect(result.todayUsedPercentagePoints == 5)
        #expect(result.earlierUsedPercentagePoints == 20)
    }

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
