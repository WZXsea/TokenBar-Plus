import Foundation

/// One recorded logical turn, using measured physical-request generation time.
/// A point is an observation of a turn, rather than a per-second live sample.
public struct SpeedTrendPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let endedAtMs: Int64
    public let tokensPerSecond: Double
    public let model: String

    public init(id: String, endedAtMs: Int64, tokensPerSecond: Double, model: String = "") {
        self.id = id
        self.endedAtMs = endedAtMs
        self.tokensPerSecond = tokensPerSecond
        self.model = model
    }
}

public struct SpeedTrendPresentation: Equatable, Sendable {
    public let points: [SpeedTrendPoint]

    public init(snapshot: ActivitySnapshot?, platform: TokenPlatform, limit: Int = 30) {
        guard let snapshot else {
            self.points = []
            return
        }
        let limit = min(120, max(1, limit))
        var seen: Set<String> = []
        var recent: [SpeedTrendPoint] = []
        for candidate in RecordedSpeedTurns.newestFirst(snapshot: snapshot, platform: platform) {
            // Length prefixes preserve identities even when source IDs
            // themselves contain separators, as synchronized IDs do.
            let id = [platform.rawValue, candidate.sessionID, candidate.turn.id]
                .map { "\($0.utf8.count):\($0)" }
                .joined()
            guard seen.insert(id).inserted else { continue }
            recent.append(SpeedTrendPoint(
                id: id,
                endedAtMs: candidate.turn.endedAtMs,
                tokensPerSecond: candidate.tokensPerSecond))
            if recent.count == limit { break }
        }
        self.points = Array(recent.reversed())
    }
}

struct RecordedSpeedTurn {
    let sessionID: String
    let turn: RequestSummary
    let tokensPerSecond: Double
}

/// Shared with the latest-speed summary so both presentations accept the same
/// platform, logical-turn time bounds, and physical-request platform lineage.
enum RecordedSpeedTurns {
    static func newestFirst(snapshot: ActivitySnapshot, platform: TokenPlatform) -> [RecordedSpeedTurn] {
        snapshot.sessions
            .filter { $0.platformID == platform }
            .flatMap { session in
                session.requests.compactMap { turn -> RecordedSpeedTurn? in
                    guard (turn.platform ?? session.platformID) == platform,
                          turn.startedAtMs >= 0,
                          turn.endedAtMs > turn.startedAtMs,
                          turn.endedAtMs <= snapshot.generatedAtMs,
                          turn.physicalRequests.allSatisfy({
                              ($0.platform ?? turn.platform ?? session.platformID) == platform
                          }),
                          let rate = turn.averageGenerationTokensPerSecond,
                          rate.isFinite, rate > 0
                    else { return nil }
                    return RecordedSpeedTurn(sessionID: session.id, turn: turn, tokensPerSecond: rate)
                }
            }
            .sorted { left, right in
                if left.turn.endedAtMs != right.turn.endedAtMs {
                    return left.turn.endedAtMs > right.turn.endedAtMs
                }
                if left.turn.startedAtMs != right.turn.startedAtMs {
                    return left.turn.startedAtMs > right.turn.startedAtMs
                }
                if left.turn.id != right.turn.id {
                    return left.turn.id < right.turn.id
                }
                if left.sessionID != right.sessionID {
                    return left.sessionID < right.sessionID
                }
                if left.tokensPerSecond != right.tokensPerSecond {
                    return left.tokensPerSecond > right.tokensPerSecond
                }
                let leftLatency = left.turn.timeToFirstTokenMs.flatMap { $0 >= 0 ? $0 : nil }
                let rightLatency = right.turn.timeToFirstTokenMs.flatMap { $0 >= 0 ? $0 : nil }
                switch (leftLatency, rightLatency) {
                case let (.some(left), .some(right)): return left < right
                case (.some, .none): return true
                default: return false
                }
            }
    }
}
