import Foundation

/// Uses source activity timestamps and source-file events; snapshot generation and
/// TokenBar cache writes never extend the active polling window.
struct ActivityRefreshPolicy {
    static let idleTimeout: TimeInterval = 60
    static let idleRefreshInterval: Duration = .seconds(5 * 60)

    private(set) var lastActivityAt: Date?
    private var latestSourceTimestampMs: Int64?
    private var previousTokens: TokenBreakdown?
    private var previousRequestCount: Int?

    mutating func start(at now: Date) {
        self.lastActivityAt = now
        self.latestSourceTimestampMs = nil
        self.previousTokens = nil
        self.previousRequestCount = nil
    }

    mutating func recordSourceChange(at now: Date) {
        self.lastActivityAt = now
    }

    mutating func observe(_ snapshot: ActivitySnapshot, at now: Date) {
        if let previousTokens = self.previousTokens,
           previousTokens != snapshot.today.tokens
            || self.previousRequestCount != snapshot.today.requestCount
        {
            // Some providers update usage before publishing an end timestamp.
            self.recordSourceChange(at: now)
        }
        self.previousTokens = snapshot.today.tokens
        self.previousRequestCount = snapshot.today.requestCount
        let latest = snapshot.sessions.reduce(Int64.min) { result, session in
            session.requests.reduce(max(result, session.startedAtMs, session.endedAtMs)) {
                max($0, $1.startedAtMs, $1.endedAtMs)
            }
        }
        guard latest > 0,
              self.latestSourceTimestampMs.map({ latest > $0 }) ?? true
        else { return }
        self.latestSourceTimestampMs = latest
        // Clamp once when a source clock runs ahead. Repeated identical snapshots
        // cannot keep postponing the idle transition.
        let sourceDate = min(Date(timeIntervalSince1970: Double(latest) / 1000), now)
        self.lastActivityAt = max(self.lastActivityAt ?? .distantPast, sourceDate)
    }

    func isIdle(at now: Date) -> Bool {
        guard let lastActivityAt else { return true }
        return now.timeIntervalSince(lastActivityAt) >= Self.idleTimeout
    }

    func interval(configured: Duration, at now: Date) -> Duration {
        self.isIdle(at: now) ? max(configured, Self.idleRefreshInterval) : configured
    }
}
