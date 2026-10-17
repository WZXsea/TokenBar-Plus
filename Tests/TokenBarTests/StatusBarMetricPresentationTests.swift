import Foundation
import Testing
import TokenBarCore

struct StatusBarMetricPresentationTests {
    @Test("Live status speed becomes zero when idle while recorded averages and samples remain intact")
    func idleSpeedBecomesZero() {
        let snapshot = self.snapshot(rate: 50)
        let active = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex,
                                            now: Date(timeIntervalSince1970: 6))
        let idle = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex,
                                          now: Date(timeIntervalSince1970: 66))
        func metric(_ metric: TokenBarStatusMetric, activity: StatusBarSpeedActivity) -> StatusBarMetricPresentation {
            StatusBarMetricPresentation(metric: metric, snapshot: snapshot, quota: nil,
                                        platform: .codex, speedActivity: activity)
        }
        #expect(metric(.latestSpeed, activity: active).compactText == "100t/s")
        #expect(metric(.latestSpeed, activity: idle).compactText == "0t/s")
        #expect(metric(.latestSpeed, activity: idle).detailText?.contains("0 tok/s") == true)
        #expect(metric(.todayAverageSpeed, activity: idle).compactText == "50.0t/s")
        #expect(self.presentation(.latestSpeed, snapshot: snapshot).compactText == "100t/s")
        #expect(StatusBarMetricPresentation(metric: .latestSpeed, snapshot: nil, quota: nil,
                    platform: .codex, speedActivity: idle).compactText == "—")
    }

    private func presentation(_ metric: TokenBarStatusMetric, snapshot: ActivitySnapshot?) -> StatusBarMetricPresentation {
        StatusBarMetricPresentation(metric: metric, snapshot: snapshot, quota: nil, platform: .codex)
    }

    private func snapshot(rate: Double = 50, cost: Double = 1, input: Int64 = 1_000) -> ActivitySnapshot {
        let tokens = TokenBreakdown(input: input, output: 80, cacheRead: 0, cacheWrite: 0, reasoning: 20)
        let request = RequestSummary(
            id: "turn", sessionId: "session", physicalSessionId: "session", isSubagent: false,
            agent: nil, model: "fixture", provider: "fixture", startedAtMs: 1_000, endedAtMs: 6_000,
            durationMs: 5_000, modelDurationMs: 1_000, timeToFirstTokenMs: 750,
            tokens: tokens, costUsd: cost, costSource: .estimated,
            promptPreview: nil, outputPreview: nil, sessionPath: nil)
        return ActivitySnapshot(
            schemaVersion: 11, generatedAtMs: 6_000, timezone: "UTC",
            today: ActivityTotals(tokens: tokens, costUsd: cost, requestCount: 1, sessionCount: 1,
                                  averageGenerationTokensPerSecond: rate),
            sessions: [SessionSummary(id: "session", workspaceLabel: nil, startedAtMs: 1_000, endedAtMs: 6_000,
                                      tokens: tokens, costUsd: cost, models: ["fixture"], requests: [request])], days: [])
    }
}
