import Foundation

/// Recorded generation observations split by the physical request's model.
/// Each model retains its own recent observations, including quieter models.
public struct SpeedModelPresentation: Equatable, Sendable {
    public let models: [String]
    public let points: [SpeedTrendPoint]
    public let summary: SpeedSummaryPresentation
    public let sampleTokensPerSecond: Double?

    public var latestModelSamples: [SpeedTrendPoint] {
        var seen: Set<String> = []
        return self.points.reversed().filter { seen.insert($0.model).inserted }
    }

    public init(snapshot: ActivitySnapshot?, platform: TokenPlatform, model: String? = nil, limit: Int = 30) {
        let observations = snapshot.map { Self.observations(snapshot: $0, platform: platform) } ?? []
        self.models = Array(Set(observations.map(\.model))).sorted()
        let limit = min(120, max(1, limit))
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        let selected = observations.filter { observation in
            guard model == nil || observation.model == model,
                  counts[observation.model, default: 0] < limit,
                  seen.insert(observation.id).inserted else { return false }
            counts[observation.model, default: 0] += 1
            return true
        }
        self.points = selected.reversed().map {
            SpeedTrendPoint(id: $0.id, endedAtMs: $0.endedAtMs, tokensPerSecond: $0.rate, model: $0.model)
        }
        let tokens = selected.reduce(0.0) { $0 + $1.tokens }
        let duration = selected.reduce(0.0) { $0 + $1.durationMs }
        self.sampleTokensPerSecond = tokens > 0 && duration > 0 ? tokens * 1_000 / duration : nil
        if model == nil {
            self.summary = SpeedSummaryPresentation(snapshot: snapshot, platform: platform)
        } else {
            self.summary = SpeedSummaryPresentation(
                latestSample: selected.first.map {
                    SpeedSummaryPresentation.Sample(
                        turnID: $0.turnID, endedAtMs: $0.endedAtMs,
                        tokensPerSecond: $0.rate, timeToFirstTokenMs: $0.timeToFirstTokenMs)
                }, todayTokensPerSecond: nil)
        }
    }

    private struct Observation {
        let id: String
        let turnID: String
        let model: String
        let endedAtMs: Int64
        let tokens: Double
        let durationMs: Double
        let timeToFirstTokenMs: Int64?
        var rate: Double { self.tokens * 1_000 / self.durationMs }
    }

    private static func observations(snapshot: ActivitySnapshot, platform: TokenPlatform) -> [Observation] {
        var observations: [Observation] = []
        for candidate in RecordedSpeedTurns.newestFirst(snapshot: snapshot, platform: platform) {
            let measured = candidate.turn.physicalRequests.filter { request in
                request.startedAtMs >= 0 && request.endedAtMs > request.startedAtMs
                    && request.endedAtMs <= snapshot.generatedAtMs
                    && (request.modelDurationMs ?? 0) > 0
                    && (request.tokens.output > 0 || request.tokens.reasoning > 0)
            }
            let groups = Dictionary(grouping: measured) { request in
                let name = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "未知模型" : name
            }
            for (model, requests) in groups {
                let tokens = requests.reduce(0.0) {
                    $0 + Double(max(0, $1.tokens.output)) + Double(max(0, $1.tokens.reasoning))
                }
                let duration = requests.reduce(0.0) { $0 + Double($1.modelDurationMs ?? 0) }
                guard tokens.isFinite, duration.isFinite, tokens > 0, duration > 0 else { continue }
                let latest = requests.sorted {
                    if $0.endedAtMs != $1.endedAtMs { return $0.endedAtMs > $1.endedAtMs }
                    if $0.startedAtMs != $1.startedAtMs { return $0.startedAtMs > $1.startedAtMs }
                    return $0.id < $1.id
                }.first!
                let id = [platform.rawValue, candidate.sessionID, candidate.turn.id, model]
                    .map { "\($0.utf8.count):\($0)" }.joined()
                observations.append(Observation(
                    id: id, turnID: candidate.turn.id, model: model,
                    endedAtMs: latest.endedAtMs, tokens: tokens, durationMs: duration,
                    timeToFirstTokenMs: latest.timeToFirstTokenMs.flatMap { $0 >= 0 ? $0 : nil }))
            }
        }
        return observations.sorted {
            if $0.endedAtMs != $1.endedAtMs { return $0.endedAtMs > $1.endedAtMs }
            // The parent ordering already resolves duplicate versions by rate.
            // Identical model observations use that ordering's deterministic tie break.
            if $0.turnID != $1.turnID { return $0.turnID < $1.turnID }
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.rate != $1.rate { return $0.rate > $1.rate }
            return ($0.timeToFirstTokenMs ?? Int64.max) < ($1.timeToFirstTokenMs ?? Int64.max)
        }
    }
}
