import Foundation
import Testing
@testable import TokenBarCore

@Suite("Recorded generation speed trend")
struct SpeedTrendPresentationTests {
    private let generatedAtMs: Int64 = 1_800_000_000_000

    @Test("missing turn observations remain empty even when a daily aggregate exists")
    func missingObservationsStayEmpty() {
        #expect(SpeedTrendPresentation(snapshot: nil, platform: .codex).points.isEmpty)
        #expect(SpeedTrendPresentation(snapshot: self.snapshot(), platform: .codex).points.isEmpty)
    }

    @Test("trend points use the same physical-request weighting as the speed summary")
    func weightsPhysicalRequests() {
        let fast = self.request(id: "fast", output: 80, reasoning: 20)
        let slow = self.request(id: "slow", duration: 3_000, output: 120, reasoning: 30)
        let unmeasured = self.request(id: "unmeasured", duration: nil, output: 20_000)
        let turn = self.request(id: "turn", duration: nil, output: 20_250, children: [fast, slow, unmeasured])
        let snapshot = self.snapshot(sessions: [self.session(requests: [turn])])
        let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)
        let summary = SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)

        #expect(trend.points.count == 1)
        #expect(trend.points.first?.tokensPerSecond == 62.5)
        #expect(trend.points.first?.tokensPerSecond == summary.latestSample?.tokensPerSecond)
        #expect(trend.points.first?.endedAtMs == turn.endedAtMs)
    }

    @Test("the default trend retains the newest thirty valid turns in ascending end-time order")
    func selectsRecentTurnsInTimeOrder() {
        let requests = (0 ..< 40).reversed().map {
            self.request(id: "turn-\($0)", end: self.generatedAtMs - Int64(40 - $0) * 1_000, output: Int64($0 + 1))
        }
        let trend = SpeedTrendPresentation(snapshot: self.snapshot(sessions: [self.session(requests: requests)]), platform: .codex)

        #expect(trend.points.count == 30)
        #expect(trend.points.map(\.tokensPerSecond) == (11 ... 40).map(Double.init))
        #expect(trend.points.map(\.endedAtMs) == trend.points.map(\.endedAtMs).sorted())
    }

    @Test("sample limits are clamped without fabricating points", arguments: [Int.min, 0, 1, 30, 120, Int.max])
    func clampsLimit(limit: Int) {
        let requests = (0 ..< 150).map { self.request(id: "turn-\($0)", end: self.generatedAtMs - Int64(150 - $0) * 1_000) }
        let trend = SpeedTrendPresentation(snapshot: self.snapshot(sessions: [self.session(requests: requests)]), platform: .codex, limit: limit)

        #expect(trend.points.count == min(120, max(1, limit)))
        let one = SpeedTrendPresentation(snapshot: self.snapshot(sessions: [self.session(requests: [requests[0]])]), platform: .codex, limit: limit)
        #expect(one.points.count == 1)
    }

    @Test("session, turn and physical-request platforms are all respected")
    func platformIsolation() {
        let codex = self.request(id: "codex", output: 90)
        let foreignTurn = self.request(id: "foreign-turn", platform: .claude)
        let mixedChildren = self.request(id: "mixed", children: [self.request(id: "foreign-child", platform: .claude)])
        let inheritedPlatform = self.request(id: "inherited", platform: nil, children: [self.request(id: "legacy-child", platform: nil)])
        let claude = self.request(id: "claude", output: 150, platform: .claude)
        let snapshot = self.snapshot(sessions: [
            self.session(requests: [codex, foreignTurn, mixedChildren, inheritedPlatform]),
            self.session(id: "claude-session", requests: [claude], platform: .claude),
        ])

        #expect(SpeedTrendPresentation(snapshot: snapshot, platform: .codex).points.count == 2)
        #expect(SpeedTrendPresentation(snapshot: snapshot, platform: .claude).points.map(\.tokensPerSecond) == [150])
        #expect(SpeedTrendPresentation(snapshot: snapshot, platform: .grok).points.isEmpty)
    }

    @Test("invalid logical times, missing generation durations and empty generation are excluded")
    func excludesInvalidTurns() {
        let requests = [
            self.request(id: "negative-time", start: -1),
            self.request(id: "reversed", start: self.generatedAtMs + 1),
            self.request(id: "zero-span", start: self.generatedAtMs),
            self.request(id: "future", end: self.generatedAtMs + 1),
            self.request(id: "missing-duration", duration: nil),
            self.request(id: "zero-duration", duration: 0),
            self.request(id: "negative-duration", duration: -1),
            self.request(id: "input-only", output: 0),
            self.request(id: "negative-output", output: -1),
        ]

        #expect(SpeedTrendPresentation(snapshot: self.snapshot(sessions: [self.session(requests: requests)]), platform: .codex).points.isEmpty)
    }

    @Test("matching turn IDs in distinct sessions retain separate stable identities")
    func identitiesIncludeSessionAndSafeSeparators() {
        let snapshot = self.snapshot(sessions: [
            self.session(id: "a:b", requests: [self.request(id: "c")]),
            self.session(id: "a", requests: [self.request(id: "b:c")]),
            self.session(id: "third", requests: [self.request(id: "c")]),
        ])
        let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)

        #expect(trend.points.count == 3)
        #expect(Set(trend.points.map(\.id)).count == 3)
    }

    @Test("duplicate observations retain the newest version of one logical turn")
    func deduplicatesLogicalTurns() {
        let older = self.request(id: "same", end: self.generatedAtMs - 1_000, output: 50)
        let newer = self.request(id: "same", output: 125)
        let snapshot = self.snapshot(sessions: [self.session(requests: [older, newer, newer])])
        let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)

        #expect(trend.points.count == 1)
        #expect(trend.points.first?.tokensPerSecond == 125)
        #expect(trend.points.first?.endedAtMs == newer.endedAtMs)
    }

    @Test("refreshing or reordering an unchanged record set creates no new sample identities")
    func refreshesKeepStablePoints() {
        let first = self.session(id: "first", requests: [self.request(id: "shared", output: 80)])
        let second = self.session(id: "second", requests: [self.request(id: "shared", output: 120)])
        let initial = self.snapshot(sessions: [first, second])
        let refreshed = self.snapshot(sessions: [second, first, first], generatedAtMs: self.generatedAtMs + 10_000)

        #expect(SpeedTrendPresentation(snapshot: initial, platform: .codex) == SpeedTrendPresentation(snapshot: refreshed, platform: .codex))
    }

    @Test("equal end times retain the later-starting turn as the trend endpoint")
    func equalEndUsesStartTimeBeforeID() {
        let olderStart = self.request(id: "z", start: self.generatedAtMs - 5_000, output: 50)
        let laterStart = self.request(id: "a", start: self.generatedAtMs - 1_000, output: 125)
        let snapshot = self.snapshot(sessions: [self.session(requests: [laterStart, olderStart])])
        let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)
        let summary = SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)

        #expect(trend.points.map(\.tokensPerSecond) == [50, 125])
        #expect(summary.latestSample?.turnID == "a")
        self.expectEndpointMatchesSummary(snapshot)
    }

    @Test("equal end and start times use raw turn ID ordering rather than the encoded point ID")
    func equalTimesUseTurnIDBeforeEncodedIdentity() {
        for firstID in ["a", "aa"] {
            let expectedLatest = self.request(id: firstID, output: 80)
            let other = self.request(id: "z", output: 120)
            let snapshot = self.snapshot(sessions: [self.session(requests: [other, expectedLatest])])
            let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)
            let summary = SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)

            #expect(trend.points.map(\.tokensPerSecond) == [120, 80])
            #expect(summary.latestSample?.turnID == firstID)
            self.expectEndpointMatchesSummary(snapshot)
        }
    }

    @Test("equal turn IDs across sessions use the same deterministic tie break in both presentations")
    func equalTimesAndTurnIDsUseSessionIdentity() {
        let first = self.session(id: "a", requests: [self.request(id: "shared", output: 80)])
        let second = self.session(id: "b", requests: [self.request(id: "shared", output: 120)])
        let snapshot = self.snapshot(sessions: [second, first])
        let reordered = self.snapshot(sessions: [first, second])
        let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)

        #expect(trend.points.map(\.tokensPerSecond) == [120, 80])
        #expect(trend == SpeedTrendPresentation(snapshot: reordered, platform: .codex))
        #expect(SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)
            == SpeedSummaryPresentation(snapshot: reordered, platform: .codex))
        self.expectEndpointMatchesSummary(snapshot)
    }

    @Test("duplicate versions with identical identities and times choose the same valid rate deterministically")
    func duplicateVersionsUseSharedFinalTieBreak() {
        let olderVersion = self.request(id: "shared", output: 80)
        let newerVersion = self.request(id: "shared", output: 120)
        let unmeasuredVersion = self.request(id: "shared", duration: nil)
        let snapshot = self.snapshot(sessions: [self.session(requests: [olderVersion, newerVersion, unmeasuredVersion])])
        let reordered = self.snapshot(sessions: [self.session(requests: [unmeasuredVersion, newerVersion, olderVersion])])
        let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex)

        #expect(trend.points.map(\.tokensPerSecond) == [120])
        #expect(trend == SpeedTrendPresentation(snapshot: reordered, platform: .codex))
        #expect(SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)
            == SpeedSummaryPresentation(snapshot: reordered, platform: .codex))
        self.expectEndpointMatchesSummary(snapshot)
    }

    @Test("model selection splits mixed turns using token and duration weighting")
    func modelSelectionSplitsMixedTurns() {
        let fast = self.request(id: "fast", output: 80, reasoning: 20, model: "alpha", ttft: 120)
        let slow = self.request(id: "slow", duration: 3_000, output: 120, reasoning: 30, model: "alpha", ttft: 150)
        let other = self.request(id: "other", duration: 10_000, output: 10, model: "beta", ttft: 500)
        let unmeasured = self.request(id: "unmeasured", duration: nil, output: 9_000, model: "alpha")
        let turn = self.request(id: "mixed", model: "summary-model", children: [fast, slow, other, unmeasured])
        let snapshot = self.snapshot(sessions: [self.session(requests: [turn])])
        let all = SpeedModelPresentation(snapshot: snapshot, platform: .codex)
        let alpha = SpeedModelPresentation(snapshot: snapshot, platform: .codex, model: "alpha")
        let beta = SpeedModelPresentation(snapshot: snapshot, platform: .codex, model: "beta")

        #expect(all.models == ["alpha", "beta"])
        #expect(Set(all.points.map(\.model)) == ["alpha", "beta"])
        #expect(alpha.points.count == 1)
        #expect(alpha.points.first?.tokensPerSecond == 62.5)
        #expect(alpha.summary.latestSample?.tokensPerSecond == 62.5)
        #expect(alpha.summary.latestSample?.timeToFirstTokenMs == 120)
        #expect(alpha.sampleTokensPerSecond == 62.5)
        #expect(alpha.summary.todayTokensPerSecond == nil)
        #expect(beta.summary.latestSample?.tokensPerSecond == 1)
        #expect(all.summary == SpeedSummaryPresentation(snapshot: snapshot, platform: .codex))
    }

    @Test("model sample averages are weighted across observations")
    func modelSampleAverageWeightsDurations() {
        let fast = self.request(id: "fast", output: 100, model: "alpha")
        let slow = self.request(id: "slow", duration: 9_000, output: 90, model: "alpha")
        let snapshot = self.snapshot(sessions: [self.session(requests: [fast, slow])])
        #expect(SpeedModelPresentation(snapshot: snapshot, platform: .codex, model: "alpha")
            .sampleTokensPerSecond == 19)
    }

    @Test("each model keeps its recent samples when another model has more observations")
    func quieterModelsRemainVisible() {
        let active = (0 ..< 40).map {
            self.request(id: "active-\($0)", end: self.generatedAtMs - Int64(40 - $0) * 1_000, model: "alpha")
        }
        let quiet = self.request(id: "quiet", end: self.generatedAtMs - 100_000, model: "beta")
        let snapshot = self.snapshot(sessions: [self.session(requests: active + [quiet])])
        let all = SpeedModelPresentation(snapshot: snapshot, platform: .codex)
        #expect(all.points.filter { $0.model == "alpha" }.count == 30)
        #expect(all.points.filter { $0.model == "beta" }.count == 1)
        #expect(all.points.map(\.endedAtMs) == all.points.map(\.endedAtMs).sorted())
    }

    @Test("model points exclude invalid physical measurements and isolate platforms")
    func modelMeasurementValidation() {
        let valid = self.request(id: "valid", model: "alpha")
        let future = self.request(id: "future", end: self.generatedAtMs + 1, model: "future")
        let negative = self.request(id: "negative", start: -1, model: "negative")
        let missing = self.request(id: "missing", duration: nil, model: "missing")
        let zero = self.request(id: "zero", duration: 0, model: "zero")
        let empty = self.request(id: "empty", output: 0, model: "empty")
        let mixed = self.request(id: "parent", children: [valid, future, negative, missing, zero, empty])
        let foreign = self.request(id: "foreign", platform: .claude, model: "claude")
        let snapshot = self.snapshot(sessions: [
            self.session(requests: [mixed]),
            self.session(id: "foreign", requests: [foreign], platform: .claude),
        ])
        let presentation = SpeedModelPresentation(snapshot: snapshot, platform: .codex)
        #expect(presentation.models == ["alpha"])
        #expect(presentation.points.count == 1)
        #expect(SpeedModelPresentation(snapshot: snapshot, platform: .claude).models == ["claude"])
        #expect(SpeedModelPresentation(snapshot: snapshot, platform: .grok).models.isEmpty)
    }

    @Test("unknown selections stay empty and identities distinguish model observations")
    func selectionAndIdentities() {
        let mixed = self.request(id: "mixed", children: [
            self.request(id: "a", model: "alpha"), self.request(id: "b", model: "beta"),
        ])
        let snapshot = self.snapshot(sessions: [self.session(requests: [mixed, mixed])])
        let all = SpeedModelPresentation(snapshot: snapshot, platform: .codex)
        #expect(all.points.count == 2)
        #expect(Set(all.points.map(\.id)).count == 2)
        let missing = SpeedModelPresentation(snapshot: snapshot, platform: .codex, model: "missing")
        #expect(missing.points.isEmpty)
        #expect(missing.summary.latestSample == nil)
        #expect(missing.sampleTokensPerSecond == nil)
        #expect(SpeedModelPresentation(snapshot: nil, platform: .codex).points.isEmpty)
    }

    private func expectEndpointMatchesSummary(_ snapshot: ActivitySnapshot) {
        let summary = SpeedSummaryPresentation(snapshot: snapshot, platform: .codex)
        for limit in [1, 2, 30] {
            let trend = SpeedTrendPresentation(snapshot: snapshot, platform: .codex, limit: limit)
            #expect(trend.points.last?.tokensPerSecond == summary.latestSample?.tokensPerSecond)
            #expect(trend.points.last?.endedAtMs == summary.latestSample?.endedAtMs)
        }
    }

    private func request(
        id: String, start: Int64? = nil, end: Int64? = nil,
        duration: Int64? = 1_000, output: Int64 = 100, reasoning: Int64 = 0,
        platform: TokenPlatform? = .codex, model: String = "fixture", ttft: Int64? = nil,
        children: [RequestSummary]? = nil) -> RequestSummary
    {
        RequestSummary(
            id: id, sessionId: "session", physicalSessionId: "physical", isSubagent: false,
            agent: nil, model: model, provider: "fixture",
            startedAtMs: start ?? self.generatedAtMs - 1_000_000,
            endedAtMs: end ?? self.generatedAtMs, durationMs: 1_000_000, modelDurationMs: duration,
            timeToFirstTokenMs: ttft,
            tokens: TokenBreakdown(input: 10_000, output: output, cacheRead: 1_000, cacheWrite: 0, reasoning: reasoning),
            costUsd: 0, costSource: .unknown, promptPreview: nil, outputPreview: nil, sessionPath: nil,
            contributions: children, platform: platform)
    }

    private func session(id: String = "session", requests: [RequestSummary], platform: TokenPlatform = .codex) -> SessionSummary {
        SessionSummary(
            id: id, workspaceLabel: nil, startedAtMs: self.generatedAtMs - 1_000_000, endedAtMs: self.generatedAtMs,
            tokens: .zero, costUsd: 0, models: [], requests: requests, platform: platform)
    }

    private func snapshot(sessions: [SessionSummary] = [], generatedAtMs: Int64? = nil) -> ActivitySnapshot {
        ActivitySnapshot(
            schemaVersion: 11, generatedAtMs: generatedAtMs ?? self.generatedAtMs, timezone: "UTC",
            today: ActivityTotals(tokens: .zero, costUsd: 0, requestCount: 0, sessionCount: 0,
                averageGenerationTokensPerSecond: 999), sessions: sessions, days: [])
    }
}
