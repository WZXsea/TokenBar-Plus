import Foundation
import TokenBarCore

enum WeeklyResetUsagePresentation {
    static func summary(
        quota: QuotaSnapshot?,
        usage: ActivityRangeSummary?,
        at now: Date = Date()) -> ActivityRangeSummary?
    {
        guard let quota, let usage, let window = quota.weekly,
              let minutes = window.windowMinutes, minutes > 0,
              let reset = window.resetsAt,
              reset.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              quota.updatedAt.timeIntervalSinceReferenceDate.isFinite
        else { return nil }

        let duration = TimeInterval(minutes) * 60
        guard duration.isFinite, duration > 0 else { return nil }
        let start = reset.addingTimeInterval(-duration)
        guard start.timeIntervalSinceReferenceDate.isFinite, start < reset,
              now >= start, now < reset,
              quota.updatedAt >= start, quota.updatedAt < reset, quota.updatedAt <= now,
              abs(usage.startedAt.timeIntervalSince(start)) < 1
        else { return nil }

        return usage
    }
}
