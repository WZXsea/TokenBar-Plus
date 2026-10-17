import Foundation

/// Activity refers to recorded provider work, scoped to the selected platform.
/// Cache generation timestamps and unrelated platforms cannot renew its lifetime.
public struct StatusBarSpeedActivity: Equatable, Sendable {
    public static let idleTimeout: TimeInterval = 60
    public static let slowThreshold: Double = 20

    public let isActive: Bool
    public let tokensPerSecond: Double?
    public let activeUntil: Date?

    public init(snapshot: ActivitySnapshot?, platform: TokenPlatform, now: Date = Date()) {
        let speed = SpeedSummaryPresentation(snapshot: snapshot, platform: platform)
        self.tokensPerSecond = speed.latestSample?.tokensPerSecond
        guard let snapshot, self.tokensPerSecond != nil else {
            self.isActive = false
            self.activeUntil = nil
            return
        }
        let nowMs = now.timeIntervalSince1970 * 1_000
        var latest: Int64?
        func observe(_ timestamp: Int64) {
            guard timestamp > 0, Double(timestamp) <= nowMs else { return }
            latest = max(latest ?? timestamp, timestamp)
        }
        for session in snapshot.sessions where session.platformID == platform {
            observe(session.startedAtMs)
            observe(session.endedAtMs)
            for request in session.requests where request.platformID == platform {
                observe(request.startedAtMs)
                observe(request.endedAtMs)
            }
        }
        guard let latest else {
            self.isActive = false
            self.activeUntil = nil
            return
        }
        let expiresAt = Date(timeIntervalSince1970: Double(latest) / 1_000 + Self.idleTimeout)
        self.isActive = now < expiresAt
        self.activeUntil = self.isActive ? expiresAt : nil
    }

    public var isSlow: Bool {
        self.isActive && (self.tokensPerSecond.map { $0 < Self.slowThreshold } ?? false)
    }
}
