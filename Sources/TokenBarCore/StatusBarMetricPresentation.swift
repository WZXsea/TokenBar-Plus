import Foundation

/// Short status-bar values plus named, unit-bearing descriptions for tooltips
/// and accessibility. An explicitly hidden metric has no value or description.
public struct StatusBarMetricPresentation: Equatable, Sendable {
    public let compactText: String?
    public let detailText: String?

    public init(
        metric: TokenBarStatusMetric,
        snapshot: ActivitySnapshot?,
        quota: QuotaSnapshot?,
        platform: TokenPlatform,
        speedActivity: StatusBarSpeedActivity? = nil)
    {
        let metricName: String
        if platform == .zcode, metric == .latestSpeed || metric == .todayAverageSpeed {
            metricName = metric == .latestSpeed ? "最近响应速率" : "今日平均响应速率"
        } else {
            metricName = metric.displayName
        }
        let speedMethod = platform == .zcode && (metric == .latestSpeed || metric == .todayAverageSpeed)
            ? "；" + SpeedSummaryPresentation.helpText(for: platform) : ""
        if metric == .none {
            self.compactText = nil
            self.detailText = nil
            return
        }
        let totals = Self.totals(snapshot: snapshot, platform: platform)
        var compact: String?
        var detail: String?
        switch metric {
        case .todayTokens:
            if let total = totals?.tokens.total, total >= 0 {
                compact = Self.compactCount(total)
                detail = "\(total.formatted()) token"
            }
        case .latestSpeed, .todayAverageSpeed:
            let speed = SpeedSummaryPresentation(snapshot: snapshot, platform: platform)
            let rate = metric == .latestSpeed ? speed.latestSample?.tokensPerSecond : speed.todayTokensPerSecond
            if let rate, rate.isFinite, rate > 0 {
                compact = Self.compactRate(rate) + "t/s"
                detail = Self.compactRate(rate) + " tok/s"
            }
        case .weeklyRemaining, .sessionRemaining:
            let window = metric == .weeklyRemaining ? quota?.weekly : quota?.session
            if let window, window.usageKnown, window.usedPercent.isFinite {
                compact = "\(Int(min(100, max(0, window.remainingPercent)).rounded()))%"
                detail = compact
            }
        case .todayCost:
            if let totals, totals.costUsd.isFinite, totals.costUsd >= 0,
               totals.costUsd > 0 || totals.tokens.total == 0
            {
                compact = Self.compactEstimatedCost(totals.costUsd)
                detail = compact.map { "\($0) USD（估算）" }
            }
        case .timeToFirstToken:
            let speed = SpeedSummaryPresentation(snapshot: snapshot, platform: platform)
            if let milliseconds = speed.latestSample?.timeToFirstTokenMs {
                compact = milliseconds < 1_000
                    ? "\(milliseconds)ms"
                    : Self.compactDuration(Double(milliseconds) / 1_000) + "s"
                detail = "\(milliseconds.formatted()) ms（最近一轮）"
            }
        case .none:
            break
        }
        self.compactText = compact ?? "—"
        let missingUnit = switch metric {
        case .todayTokens: "token"
        case .latestSpeed, .todayAverageSpeed: "tok/s"
        case .weeklyRemaining, .sessionRemaining: "%"
        case .todayCost: "USD，估算"
        case .timeToFirstToken: "ms"
        case .none: ""
        }
        let activityNote = metric == .latestSpeed && compact != nil && speedActivity?.isActive == false
            ? "（上次记录，当前空闲）" : ""
        self.detailText = "\(metricName)：\(detail ?? "待获取（\(missingUnit)）")\(activityNote)\(speedMethod)"
    }

    private static func totals(snapshot: ActivitySnapshot?, platform: TokenPlatform) -> ActivityTotals? {
        guard let snapshot else { return nil }
        if let source = snapshot.sourceSnapshots.first(where: { $0.platform == platform }) { return source.today }
        if platform == .codex, snapshot.sourceSnapshots.isEmpty,
           snapshot.sessions.allSatisfy({ $0.platformID == .codex })
        {
            return snapshot.today
        }
        return nil
    }

    private static func scientific(_ value: Double) -> String {
        String(format: "%.0e", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: "e+", with: "e")
            .replacingOccurrences(of: "e0", with: "e")
    }

    private static func compactCount(_ value: Int64) -> String {
        value >= 1_000_000_000_000 ? self.scientific(Double(value)) : value.statusBarCompactCount
    }

    private static func compactRate(_ value: Double) -> String {
        if value >= 1_000_000_000 { return self.scientific(value) }
        if value >= 1_000_000 { return self.decimal(value / 1_000_000, digits: 1) + "M" }
        if value >= 1_000 { return self.decimal(value / 1_000, digits: 1) + "K" }
        if value >= 100 { return self.decimal(value, digits: 0) }
        if value >= 10 { return self.decimal(value, digits: 1) }
        return value >= 0.01 ? self.decimal(value, digits: 2) : "<0.01"
    }

    private static func compactDuration(_ seconds: Double) -> String {
        seconds >= 1_000_000 ? self.scientific(seconds) : self.decimal(seconds, digits: 1)
    }

    private static func compactEstimatedCost(_ value: Double) -> String {
        if value > 0, value < 0.01 { return "~<$0.01" }
        if value >= 1_000_000_000 { return "~$" + self.scientific(value) }
        if value >= 1_000_000 { return "~$" + self.decimal(value / 1_000_000, digits: 1) + "M" }
        if value >= 1_000 { return "~$" + self.decimal(value / 1_000, digits: 1) + "K" }
        return "~$" + self.decimal(value, digits: 2)
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
    }
}
