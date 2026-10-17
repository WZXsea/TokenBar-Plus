import Foundation
import Testing
import TokenBarCore
@testable import TokenBar

@Suite("Weekly reset usage period matching")
struct WeeklyResetUsagePresentationTests {
    private let startMs: Int64 = 1_800_000_000_000
    private var start: Date { Date(timeIntervalSince1970: Double(self.startMs) / 1_000) }
    private var now: Date { self.start.addingTimeInterval(86_400) }
    private var reset: Date { self.start.addingTimeInterval(7 * 86_400) }
    private var usage: ActivityRangeSummary { ActivityRangeSummary(startedAtMs: self.startMs, totals: .zero) }

    @Test("matching current periods retain the original usage summary")
    func matchesCurrentPeriod() {
        #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(), usage: self.usage, at: self.now) == self.usage)
        #expect(WeeklyResetUsagePresentation.summary(
            quota: self.quota(updatedAt: self.start), usage: self.usage, at: self.start) == self.usage)
    }

    @Test("usage remains available for known periods regardless of percentage availability")
    func percentageDoesNotGateUsage() {
        for known in [true, false] {
            for percent in [0.0, -1, 125, .nan, .infinity] {
                let quota = self.quota(percent: percent, usageKnown: known)
                #expect(WeeklyResetUsagePresentation.summary(quota: quota, usage: self.usage, at: self.now) == self.usage)
            }
        }
    }

    @Test("expired and future periods are excluded at their precise boundaries")
    func excludesInactivePeriods() {
        for now in [self.reset, self.reset.addingTimeInterval(1), self.start.addingTimeInterval(-1)] {
            #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(), usage: self.usage, at: now) == nil)
        }
    }

    @Test("usage start permits sub-second rounding while requiring a difference strictly below one second")
    func startTolerance() {
        let acceptedOffsets: [Int64] = [-999, 0, 999]
        for offset in acceptedOffsets {
            let usage = ActivityRangeSummary(startedAtMs: self.startMs + offset, totals: .zero)
            #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(), usage: usage, at: self.now) == usage)
        }
        let rejectedOffsets: [Int64] = [-604_800_000, -1_000, 1_000, 604_800_000]
        for offset in rejectedOffsets {
            let usage = ActivityRangeSummary(startedAtMs: self.startMs + offset, totals: .zero)
            #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(), usage: usage, at: self.now) == nil)
        }
    }

    @Test("quota samples must belong to the same period and precede the reference time")
    func excludesInvalidQuotaSampleTimes() {
        for updated in [self.start.addingTimeInterval(-1), self.reset, self.now.addingTimeInterval(1),
                        Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)] {
            #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(updatedAt: updated), usage: self.usage, at: self.now) == nil)
        }
    }

    @Test("missing data, invalid window lengths and non-finite dates stay unmatched")
    func excludesInvalidWindowMetadata() {
        #expect(WeeklyResetUsagePresentation.summary(quota: nil, usage: self.usage, at: self.now) == nil)
        #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(), usage: nil, at: self.now) == nil)
        let noWeekly = QuotaSnapshot(session: nil, weekly: nil, resetCredits: nil, updatedAt: self.now)
        #expect(WeeklyResetUsagePresentation.summary(quota: noWeekly, usage: self.usage, at: self.now) == nil)
        let invalidMinutes: [Int?] = [nil, 0, -1]
        for minutes in invalidMinutes {
            #expect(WeeklyResetUsagePresentation.summary(quota: self.quota(minutes: minutes), usage: self.usage, at: self.now) == nil)
        }
        let invalidResets: [Date?] = [nil, Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)]
        for reset in invalidResets {
            let quota = QuotaSnapshot(
                session: nil,
                weekly: QuotaWindowSnapshot(usedPercent: 25, windowMinutes: 10_080, resetsAt: reset),
                resetCredits: nil, updatedAt: self.now)
            #expect(WeeklyResetUsagePresentation.summary(quota: quota, usage: self.usage, at: self.now) == nil)
        }
        #expect(WeeklyResetUsagePresentation.summary(
            quota: self.quota(), usage: self.usage, at: Date(timeIntervalSinceReferenceDate: .nan)) == nil)
    }

    private func quota(
        minutes: Int? = 10_080,
        updatedAt: Date? = nil,
        percent: Double = 25,
        usageKnown: Bool = true) -> QuotaSnapshot
    {
        QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(usedPercent: percent, windowMinutes: minutes,
                resetsAt: self.reset, usageKnown: usageKnown),
            resetCredits: nil, updatedAt: updatedAt ?? self.now)
    }
}
