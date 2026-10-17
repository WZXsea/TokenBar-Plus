import Foundation

public enum ActivityHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, year
    public var id: Self { self }
    public var title: String { switch self { case .week: "周"; case .month: "月"; case .year: "年" } }
    public var subtitle: String { switch self { case .week: "近 7 天"; case .month: "近 30 天"; case .year: "近 12 个月" } }
}

public struct ActivityHistoryBucket: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let tokens: Int64
    public let costUsd: Double
    public let requestCount: Int
}

/// Calendar boundaries use the statistics timezone, matching the helper's daily summaries.
public struct ActivityHistoryPresentation: Sendable {
    public let buckets: [ActivityHistoryBucket]
    public let range: ActivityHistoryRange
    public let timeZone: TimeZone
    public var totalTokens: Int64 { self.buckets.reduce(0) { historySaturatingAdd($0, $1.tokens) } }
    public var maximumTokens: Int64 { self.buckets.map(\.tokens).max() ?? 0 }

    public init(days: [DailySummary], range: ActivityHistoryRange, now: Date, timeZone: TimeZone) {
        self.range = range
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let monthly = range == .year
        let end = monthly ? calendar.date(from: calendar.dateComponents([.year, .month], from: today))! : today
        let count = monthly ? 12 : range == .week ? 7 : 30
        let component: Calendar.Component = monthly ? .month : .day
        let starts = (0..<count).map { calendar.date(byAdding: component, value: $0 - count + 1, to: end)! }
        var values: [String: (Int64, Double, Int)] = [:]
        for day in days {
            guard let date = formatter.date(from: day.date), formatter.string(from: date) == day.date,
                  date <= today, date >= starts[0] else { continue }
            let key = monthly ? String(day.date.prefix(7)) : day.date
            let old = values[key] ?? (0, 0, 0)
            let (requests, overflow) = old.2.addingReportingOverflow(max(0, day.requestCount))
            values[key] = (historySaturatingAdd(old.0, max(0, day.tokens.total)),
                           old.1 + (day.costUsd.isFinite ? day.costUsd : 0), overflow ? Int.max : requests)
        }
        self.buckets = starts.map { start in
            let dayKey = formatter.string(from: start)
            let key = monthly ? String(dayKey.prefix(7)) : dayKey
            let value = values[key] ?? (0, 0, 0)
            return ActivityHistoryBucket(id: key, date: start, tokens: value.0, costUsd: value.1, requestCount: value.2)
        }
    }
}

private func historySaturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? (rhs >= 0 ? Int64.max : Int64.min) : value
}
