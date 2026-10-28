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

/// A display range only: every recorded rate remains available for inspection.
/// Each model establishes its own baseline so a genuinely faster model stays visible.
public struct SpeedChartScale: Equatable, Sendable {
    public let maximum: Double
    public let overflowIndices: Set<Int>

    public init(points: [SpeedTrendPoint]) {
        let valid = points.indices.filter { points[$0].tokensPerSecond.isFinite && points[$0].tokensPerSecond > 0 }
        let models = Dictionary(grouping: valid, by: { points[$0].model })
        var distant: Set<Int> = []
        for indices in models.values where indices.count >= 2 {
            let rates = indices.map { points[$0].tokensPerSecond }.sorted()
            if rates.count == 2 {
                if rates[1] > rates[0] * 10 {
                    distant.formUnion(indices.filter { points[$0].tokensPerSecond == rates[1] })
                }
                continue
            }
            let median = Self.median(rates)
            let deviation = Self.median(rates.map { abs($0 - median) }.sorted())
            // A broad floor accommodates normal model variability; MAD also
            // remains stable when several isolated spikes occur together.
            let upper = max(median * 4, median + deviation * 6)
            distant.formUnion(indices.filter { points[$0].tokensPerSecond > upper })
        }
        // A single observation keeps its value, while an established baseline
        // from other models can expose an extreme first spike at the top edge.
        let established = models.values.filter { $0.count >= 3 }.flatMap { $0 }
            .filter { !distant.contains($0) }.map { points[$0].tokensPerSecond }.sorted()
        if established.count >= 3 {
            let reference = Self.median(established)
            for indices in models.values where indices.count == 1 {
                distant.formUnion(indices.filter { points[$0].tokensPerSecond > reference * 10 })
            }
        }
        let regularPeak = valid.filter { !distant.contains($0) }.map { points[$0].tokensPerSecond }.max() ?? 0
        let maximum = Self.niceMaximum(regularPeak)
        self.maximum = maximum
        self.overflowIndices = Set(valid.filter { points[$0].tokensPerSecond > maximum })
    }

    public init(rates: [Double]) {
        self.init(points: rates.enumerated().map {
            SpeedTrendPoint(id: String($0.offset), endedAtMs: Int64($0.offset), tokensPerSecond: $0.element)
        })
    }

    public static func niceMaximum(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 1 }
        let exponent = pow(10, floor(log10(peak)))
        guard exponent.isFinite, exponent > 0 else { return peak }
        for multiplier in [1.0, 1.25, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10] {
            let bound = exponent * multiplier
            if bound.isFinite, bound >= peak { return bound }
        }
        return peak
    }

    private static func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
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
                tokensPerSecond: candidate.tokensPerSecond,
                model: candidate.turn.model))
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
