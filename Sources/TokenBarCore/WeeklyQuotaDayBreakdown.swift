import Foundation

/// Observed changes in the current quota window, grouped by the day of each sample.
/// Usage preceding the first observation stays in `earlierUsedPercentagePoints`.
public struct WeeklyQuotaDayBreakdown: Equatable, Sendable {
    public let todayUsedPercentagePoints: Double?
    public let yesterdayUsedPercentagePoints: Double?
    public let earlierUsedPercentagePoints: Double
    public let totalUsedPercent: Double
    public let todayIsPartial: Bool
    public let yesterdayIsPartial: Bool
    public let wasAdjustedForQuotaCorrection: Bool

    public init(
        snapshot: QuotaSnapshot?,
        history: WeeklyQuotaUsageHistory?,
        at now: Date = Date(),
        statisticsTimeZone: TokenBarStatisticsTimeZone)
    {
        self.init(
            snapshot: snapshot,
            history: history,
            at: now,
            timeZone: statisticsTimeZone == .utc ? .gmt : .autoupdatingCurrent)
    }

    init(
        snapshot: QuotaSnapshot?,
        history: WeeklyQuotaUsageHistory?,
        at now: Date,
        timeZone: TimeZone)
    {
        let reported = snapshot?.weekly
        let total = reported?.usageKnown == true && reported?.usedPercent.isFinite == true
            ? min(100, max(0, reported?.usedPercent ?? 0)) : 0
        self.totalUsedPercent = total

        guard let snapshot,
              let weekly = reported,
              weekly.usageKnown,
              weekly.usedPercent.isFinite,
              let minutes = weekly.windowMinutes,
              minutes > 0,
              let end = weekly.resetsAt,
              end.timeIntervalSinceReferenceDate.isFinite,
              let history,
              history.validated() != nil
        else {
            self.todayUsedPercentagePoints = nil
            self.yesterdayUsedPercentagePoints = nil
            self.earlierUsedPercentagePoints = total
            self.todayIsPartial = false
            self.yesterdayIsPartial = false
            self.wasAdjustedForQuotaCorrection = false
            return
        }

        let start = end.addingTimeInterval(-Double(minutes) * 60)
        guard now >= start, now < end,
              snapshot.updatedAt >= start, snapshot.updatedAt < end,
              snapshot.updatedAt <= now,
              history.matches(windowStart: start, windowEnd: end),
              let baseline = Self.continuousBaseline(
                  history: history, start: start, end: end, through: snapshot.updatedAt)
        else {
            self.todayUsedPercentagePoints = nil
            self.yesterdayUsedPercentagePoints = nil
            self.earlierUsedPercentagePoints = total
            self.todayIsPartial = false
            self.yesterdayIsPartial = false
            self.wasAdjustedForQuotaCorrection = false
            return
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let latestObservation = min(history.lastSampledAt, snapshot.updatedAt)
        let firstDay = calendar.startOfDay(for: baseline.sampledAt)
        let latestDay = calendar.startOfDay(for: latestObservation)
        let todayKnown = firstDay <= today && latestDay >= today
        let yesterdayKnown = firstDay <= yesterday && latestDay >= yesterday
        let increments = history.increments.filter {
            $0.sampledAt > baseline.sampledAt && $0.sampledAt >= start
                && $0.sampledAt < end && $0.sampledAt <= snapshot.updatedAt
                && $0.sampledAt <= now
        }
        let todayObserved = increments.filter { calendar.isDate($0.sampledAt, inSameDayAs: today) }
            .reduce(0) { $0 + $1.usedPercentagePoints }
        let yesterdayObserved = increments.filter { calendar.isDate($0.sampledAt, inSameDayAs: yesterday) }
            .reduce(0) { $0 + $1.usedPercentagePoints }

        // A provider correction may lower the current total below the history high-water mark.
        // Apply the same factor to observed day contributions and leave the remainder unattributed.
        let observedTotal = baseline.usedPercent + increments.reduce(0) { $0 + $1.usedPercentagePoints }
        let denominator = max(total, observedTotal)
        let adjusted = observedTotal > total + 1e-9
        let factor = adjusted && denominator > 0 ? total / denominator : 1
        let todayValue = todayObserved * factor
        let yesterdayValue = min(max(0, total - todayValue), yesterdayObserved * factor)
        self.todayUsedPercentagePoints = todayKnown ? todayValue : nil
        self.yesterdayUsedPercentagePoints = yesterdayKnown ? yesterdayValue : nil
        self.earlierUsedPercentagePoints = max(0, total - todayValue - yesterdayValue)
        self.todayIsPartial = todayKnown && baseline.usedPercent > 0
            && calendar.isDate(baseline.sampledAt, inSameDayAs: today)
        self.yesterdayIsPartial = yesterdayKnown && baseline.usedPercent > 0
            && calendar.isDate(baseline.sampledAt, inSameDayAs: yesterday)
        self.wasAdjustedForQuotaCorrection = adjusted
    }

    /// Older caches may contain extra baselines caused by small reset-time changes.
    /// Recover only chains whose recorded increments fully explain every later baseline.
    /// A real reset changes the window boundary or breaks this arithmetic continuity.
    private static func continuousBaseline(
        history: WeeklyQuotaUsageHistory, start: Date, end: Date, through sampledAt: Date)
        -> WeeklyQuotaTrackingBaseline?
    {
        let candidates = history.baselines.filter {
            $0.sampledAt >= start && $0.sampledAt < end && $0.sampledAt <= sampledAt
        }
        guard var baseline = candidates.last else {
            // A sole baseline can sit just before a slightly revised window start.
            // Once a baseline exists inside this window, recovery stays strictly inside it.
            return history.baselines.last(where: {
                $0.sampledAt < start && $0.sampledAt >= start.addingTimeInterval(-300)
                    && $0.sampledAt <= sampledAt
            })
        }
        for preceding in candidates.dropLast().reversed() {
            let increment = history.increments.lazy.filter {
                $0.sampledAt > preceding.sampledAt && $0.sampledAt <= baseline.sampledAt
            }.reduce(0) { $0 + $1.usedPercentagePoints }
            guard baseline.usedPercent >= preceding.usedPercent,
                  abs(preceding.usedPercent + increment - baseline.usedPercent) < 1e-7
            else { break }
            baseline = preceding
        }
        return baseline
    }

}
