import Foundation
import Testing
@testable import TokenBarCore

@Suite("Speed summary presentation")
struct SpeedSummaryPresentationTests {
    private let generatedAtMs: Int64 = 1_800_000_000_000

    @Test("Missing observations stay empty instead of becoming zero")
    func emptySamples() {
        let empty = SpeedSummaryPresentation(snapshot: nil, platform: .codex)
        let snapshot = SpeedSummaryPresentation(snapshot: self.snapshot(), platform: .codex)

        for presentation in [empty, snapshot] {
            #expect(presentation.latestSample == nil)
            #expect(presentation.todayTokensPerSecond == nil)
            #expect(presentation.latestSpeedValueText == "—")
            #expect(presentation.todaySpeedText == "—")
            #expect(presentation.latestFirstTokenText == "—")
        }
    }

    @Test("Newest valid turn wins by request time rather than session order")
    func latestValidTurn() {
        let old = self.request(id: "old", endedAtMs: self.generatedAtMs - 10_000)
        let newest = self.request(id: "new", endedAtMs: self.generatedAtMs - 1_000, firstTokenMs: 750)
        let invalidNewer = self.request(id: "no-duration", modelDurationMs: nil)
        let future = self.request(id: "future", endedAtMs: self.generatedAtMs + 10_000)
        let snapshot = self.snapshot(sessions: [
            self.session(id: "first", requests: [invalidNewer, old, future]),
            self.session(id: "last", requests: [newest]),
        ])

        let presentation = SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)

        #expect(presentation.latestSample?.turnID == "new")
        #expect(presentation.latestSample?.endedAtMs == newest.endedAtMs)
        #expect(presentation.latestSample?.tokensPerSecond == 100)
        #expect(presentation.latestSpeedValueText == "100")
        #expect(presentation.latestFirstTokenText == "750 ms")
        #expect(presentation.todayTokensPerSecond == nil)
    }

    @Test("Latest turn preserves physical-request weighting and excludes wall-clock tool time")
    func weightedGenerationSpeed() {
        let fast = self.request(id: "fast", output: 80, reasoning: 20, firstTokenMs: 800)
        let slow = self.request(id: "slow", modelDurationMs: 3_000, output: 120, reasoning: 30)
        let unknown = self.request(id: "unknown", modelDurationMs: nil, output: 10_000)
        let turn = self.request(
            id: "aggregate", modelDurationMs: nil, output: 10_200,
            firstTokenMs: 800, contributions: [fast, slow, unknown])
        let presentation = SpeedSummaryPresentation(
            snapshot: self.snapshot(sessions: [self.session(requests: [turn])], todayRate: 62.5),
            platform: .codex)

        #expect(presentation.latestSample?.tokensPerSecond == 62.5)
        #expect(presentation.latestSpeedValueText == "62.5")
        #expect(presentation.todaySpeedText == "62.5 tok/s")
        #expect(presentation.latestFirstTokenText == "800 ms")
    }

    @Test("Platform selection isolates both samples and today's source totals")
    func platformIsolation() {
        let codex = self.request(id: "same-id", endedAtMs: self.generatedAtMs - 1_000, output: 75)
        let claude = self.request(id: "same-id", output: 200, platform: .claude)
        let snapshot = self.snapshot(
            sessions: [
                self.session(requests: [codex]),
                self.session(requests: [claude], platform: .claude),
            ],
            todayRate: 999,
            sources: [self.source(.codex, rate: 55), self.source(.claude, rate: 120)])

        let codexPresentation = SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)
        let claudePresentation = SpeedSummaryPresentation(snapshot: snapshot, platform: .claude)
        let grokPresentation = SpeedSummaryPresentation(snapshot: snapshot, platform: .grok)

        #expect(codexPresentation.latestSample?.tokensPerSecond == 75)
        #expect(codexPresentation.todayTokensPerSecond == 55)
        #expect(claudePresentation.latestSample?.tokensPerSecond == 200)
        #expect(claudePresentation.todayTokensPerSecond == 120)
        #expect(grokPresentation.latestSample == nil)
        #expect(grokPresentation.todayTokensPerSecond == nil)
    }

    @Test("Mixed legacy snapshots retain per-platform samples while leaving combined totals empty")
    func legacyTotalsStayScoped() {
        let snapshot = self.snapshot(
            sessions: [
                self.session(requests: [self.request(id: "codex")]),
                self.session(requests: [self.request(id: "claude", platform: .claude)], platform: .claude),
            ],
            todayRate: 900)

        #expect(SpeedSummaryPresentation(snapshot: snapshot, platform: .codex).latestSample != nil)
        #expect(SpeedSummaryPresentation(snapshot: snapshot, platform: .codex).todayTokensPerSecond == nil)
        #expect(SpeedSummaryPresentation(snapshot: snapshot, platform: .claude).todayTokensPerSecond == nil)
    }

    @Test("Invalid durations, token counts, timestamps, and foreign contributions are skipped")
    func rejectsInvalidSamples() {
        let requests = [
            self.request(id: "missing-duration", modelDurationMs: nil),
            self.request(id: "zero-duration", modelDurationMs: 0),
            self.request(id: "negative-duration", modelDurationMs: -1),
            self.request(id: "input-only", output: 0),
            self.request(id: "negative-output", output: -1),
            self.request(id: "negative-time", startedAtMs: -1),
            self.request(id: "reversed-time", startedAtMs: self.generatedAtMs + 1),
            self.request(id: "zero-span", startedAtMs: self.generatedAtMs),
            self.request(id: "future", endedAtMs: self.generatedAtMs + 1),
            self.request(id: "foreign-turn", platform: .claude),
            self.request(id: "foreign-child", contributions: [self.request(id: "child", platform: .claude)]),
        ]
        let presentation = SpeedSummaryPresentation(
            snapshot: self.snapshot(sessions: [self.session(requests: requests)]), platform: .codex)

        #expect(presentation.latestSample == nil)
        #expect(presentation.latestSpeedValueText == "—")
    }

    @Test("Today's zero, negative, and non-finite speeds stay empty", arguments: [0.0, -1, .nan, .infinity, -.infinity])
    func rejectsInvalidAggregateRates(rate: Double) {
        let presentation = SpeedSummaryPresentation(snapshot: self.snapshot(todayRate: rate), platform: .codex)

        #expect(presentation.todayTokensPerSecond == nil)
        #expect(presentation.todaySpeedText == "—")
    }

    @Test("First-token latency belongs to the selected speed sample")
    func firstTokenBelongsToSelectedSample() {
        let older = self.request(id: "older", endedAtMs: self.generatedAtMs - 1_000, firstTokenMs: 500)
        let latest = self.request(id: "latest", firstTokenMs: -1)
        let presentation = SpeedSummaryPresentation(
            snapshot: self.snapshot(sessions: [self.session(requests: [older, latest])]), platform: .codex)

        #expect(presentation.latestSample?.turnID == "latest")
        #expect(presentation.latestFirstTokenText == "—")

        let zeroLatency = SpeedSummaryPresentation(
            snapshot: self.snapshot(sessions: [self.session(requests: [self.request(firstTokenMs: 0)])]),
            platform: .codex)
        #expect(zeroLatency.latestFirstTokenText == "0 ms")
    }

    @Test("Positive sub-centitoken rates retain a positive display bound")
    func tinyPositiveSpeed() {
        let presentation = SpeedSummaryPresentation(
            snapshot: self.snapshot(
                sessions: [self.session(requests: [self.request(modelDurationMs: 1_000_000, output: 1)])]),
            platform: .codex)

        #expect(presentation.latestSample?.tokensPerSecond == 0.001)
        #expect(presentation.latestSpeedValueText == "<0.01")
    }

    @Test("shared speed formatting retains tiny positive rates and empty invalid values")
    func sharedRateFormatting() {
        #expect(SpeedSummaryPresentation.rateValueText(0.001) == "<0.01")
        #expect(SpeedSummaryPresentation.rateValueText(0.000_001) == "<0.01")
        #expect(SpeedSummaryPresentation.rateValueText(62.5) == "62.5")
        let invalid: [Double?] = [nil, 0, -1, .nan, .infinity, -.infinity]
        for rate in invalid {
            #expect(SpeedSummaryPresentation.rateValueText(rate) == "—")
        }
    }

    @Test("otherwise-identical observations retain a deterministic recorded first-token latency")
    func duplicateLatencyIsDeterministic() {
        let measured = self.request(id: "same", firstTokenMs: 750)
        let missing = self.request(id: "same", firstTokenMs: nil)
        let first = self.snapshot(sessions: [self.session(requests: [missing, measured])])
        let reordered = self.snapshot(sessions: [self.session(requests: [measured, missing])])
        let presentation = SpeedSummaryPresentation(snapshot: first, platform: .codex)

        #expect(presentation == SpeedSummaryPresentation(snapshot: reordered, platform: .codex))
        #expect(presentation.latestFirstTokenText == "750 ms")
        #expect(SpeedTrendPresentation(snapshot: first, platform: .codex).points.last?.tokensPerSecond
            == presentation.latestSample?.tokensPerSecond)
    }

    private func request(
        id: String = "request", startedAtMs: Int64? = nil, endedAtMs: Int64? = nil,
        modelDurationMs: Int64? = 1_000, output: Int64 = 100, reasoning: Int64 = 0,
        firstTokenMs: Int64? = nil, contributions: [RequestSummary]? = nil,
        platform: TokenPlatform = .codex) -> RequestSummary
    {
        RequestSummary(
            id: id, sessionId: "session", physicalSessionId: "physical", isSubagent: false,
            agent: nil, model: "fixture-model", provider: "fixture-provider",
            startedAtMs: startedAtMs ?? self.generatedAtMs - 1_000_000,
            endedAtMs: endedAtMs ?? self.generatedAtMs,
            durationMs: 1_000_000, modelDurationMs: modelDurationMs, timeToFirstTokenMs: firstTokenMs,
            tokens: TokenBreakdown(input: 10_000, output: output, cacheRead: 5_000, cacheWrite: 0, reasoning: reasoning),
            costUsd: 0, costSource: .unknown, promptPreview: nil, outputPreview: nil, sessionPath: nil,
            contributions: contributions, platform: platform)
    }

    private func session(
        id: String = "session", requests: [RequestSummary], platform: TokenPlatform = .codex) -> SessionSummary
    {
        SessionSummary(
            id: id, workspaceLabel: nil, startedAtMs: self.generatedAtMs - 1_000_000,
            endedAtMs: self.generatedAtMs, tokens: .zero, costUsd: 0,
            models: [], requests: requests, platform: platform)
    }

    private func snapshot(
        sessions: [SessionSummary] = [], todayRate: Double? = nil,
        sources: [ActivitySourceSnapshot]? = nil) -> ActivitySnapshot
    {
        ActivitySnapshot(
            schemaVersion: 4, generatedAtMs: self.generatedAtMs, timezone: "UTC",
            today: self.totals(rate: todayRate), sessions: sessions, days: [], sources: sources)
    }

    private func source(_ platform: TokenPlatform, rate: Double) -> ActivitySourceSnapshot {
        ActivitySourceSnapshot(platform: platform, today: self.totals(rate: rate), weeklySinceReset: nil, days: [])
    }

    private func totals(rate: Double?) -> ActivityTotals {
        ActivityTotals(tokens: .zero, costUsd: 0, requestCount: 0, sessionCount: 0,
                       averageGenerationTokensPerSecond: rate)
    }
}
