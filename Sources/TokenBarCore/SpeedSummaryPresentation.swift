import Foundation

/// A platform-specific view of recorded generation speeds. Durations retain the
/// existing physical-request weighting used by the activity and session menus.
public struct SpeedSummaryPresentation: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public let turnID: String
        public let endedAtMs: Int64
        public let tokensPerSecond: Double
        public let timeToFirstTokenMs: Int64?

        public var endedAt: Date {
            Date(timeIntervalSince1970: Double(self.endedAtMs) / 1_000)
        }
    }

    public let latestSample: Sample?
    public let todayTokensPerSecond: Double?

    public init(snapshot: ActivitySnapshot?, platform: TokenPlatform) {
        guard let snapshot else {
            self.latestSample = nil
            self.todayTokensPerSecond = nil
            return
        }

        self.latestSample = RecordedSpeedTurns.newestFirst(snapshot: snapshot, platform: platform).first.map { observation in
            let turn = observation.turn
            return Sample(
                turnID: turn.id,
                endedAtMs: turn.endedAtMs,
                tokensPerSecond: observation.tokensPerSecond,
                timeToFirstTokenMs: turn.timeToFirstTokenMs.flatMap { $0 >= 0 ? $0 : nil })
        }

        // Source totals cover all of today's observations, including sessions
        // outside the recent-session list. Never substitute an all-time rate.
        let totals: ActivityTotals?
        if let source = snapshot.sourceSnapshots.first(where: { $0.platform == platform }) {
            totals = source.today
        } else if platform == .codex,
                  snapshot.sourceSnapshots.isEmpty,
                  snapshot.sessions.allSatisfy({ $0.platformID == .codex })
        {
            totals = snapshot.today
        } else {
            totals = nil
        }
        self.todayTokensPerSecond = Self.validRate(totals?.averageGenerationTokensPerSecond)
    }

    init(latestSample: Sample?, todayTokensPerSecond: Double?) {
        self.latestSample = latestSample
        self.todayTokensPerSecond = todayTokensPerSecond
    }

    public var latestSpeedValueText: String {
        Self.rateValueText(self.latestSample?.tokensPerSecond)
    }

    public var todaySpeedText: String {
        self.todayTokensPerSecond.map { "\(Self.rateValueText($0)) tok/s" } ?? "—"
    }

    public var latestFirstTokenText: String {
        guard let milliseconds = self.latestSample?.timeToFirstTokenMs else { return "—" }
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }
        return String(
            format: "%.1f s",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(milliseconds) / 1_000)
    }

    private static func validRate(_ rate: Double?) -> Double? {
        guard let rate, rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    public static func rateValueText(_ rate: Double?) -> String {
        guard let rate = Self.validRate(rate) else { return "—" }
        let value: Double
        let format: String
        switch rate {
        case 1_000_000...:
            value = rate / 1_000_000
            format = "%.1fM"
        case 1_000...:
            value = rate / 1_000
            format = "%.1fK"
        case 100...:
            value = rate
            format = "%.0f"
        case 10...:
            value = rate
            format = "%.1f"
        case 0.01...:
            value = rate
            format = "%.2f"
        default:
            return "<0.01"
        }
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
