import Foundation
import Testing
import TokenBarCore

struct StatusBarMetricPresentationTests {
    @Test("Selected metrics retain compact units, named descriptions, and estimated costs")
    func metricsAndUnits() {
        let snapshot = self.snapshot(rate: 62.5, cost: 0.42)
        let latest = self.presentation(.latestSpeed, snapshot: snapshot)
        #expect(latest.compactText == "100t/s")
        #expect(latest.detailText?.contains("100 tok/s") == true)
        #expect(self.presentation(.todayAverageSpeed, snapshot: snapshot).compactText == "62.5t/s")
        #expect(self.presentation(.timeToFirstToken, snapshot: snapshot).compactText == "750ms")
        #expect(self.presentation(.todayCost, snapshot: snapshot).compactText == "~$0.42")
        #expect(self.presentation(.todayCost, snapshot: snapshot).detailText?.contains("USD（估算）") == true)
        #expect(self.presentation(.none, snapshot: snapshot).compactText == nil)
        #expect(self.presentation(.none, snapshot: snapshot).detailText == nil)
    }

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

    @Test("Unknown quota usage and missing or invalid observations stay explicitly empty")
    func missingSamples() {
        let quota = QuotaSnapshot(
            session: QuotaWindowSnapshot(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
            weekly: QuotaWindowSnapshot(usedPercent: 0, windowMinutes: 10_080, resetsAt: nil, usageKnown: false),
            resetCredits: nil, updatedAt: Date())
        #expect(StatusBarMetricPresentation(metric: .weeklyRemaining, snapshot: nil, quota: quota, platform: .codex).compactText == "—")
        #expect(StatusBarMetricPresentation(metric: .sessionRemaining, snapshot: nil, quota: quota, platform: .codex).compactText == "80%")
        #expect(self.presentation(.latestSpeed, snapshot: nil).compactText == "—")
        #expect(self.presentation(.todayAverageSpeed, snapshot: self.snapshot(rate: .nan)).compactText == "—")
        #expect(self.presentation(.todayAverageSpeed, snapshot: self.snapshot(rate: 0)).compactText == "—")
        #expect(self.presentation(.todayCost, snapshot: self.snapshot(cost: 0)).compactText == "—")
        #expect(StatusBarMetricPresentation(metric: .todayTokens, snapshot: self.snapshot(), quota: nil, platform: .claude).compactText == "—")
    }

    @Test("Extreme rates, token counts, and prices remain bounded and keep their unit or estimate marker")
    func compactExtremes() {
        let snapshot = self.snapshot(rate: .greatestFiniteMagnitude, cost: .greatestFiniteMagnitude, input: .max)
        for metric in [TokenBarStatusMetric.todayTokens, .todayAverageSpeed, .todayCost] {
            let text = self.presentation(metric, snapshot: snapshot).compactText ?? ""
            #expect(!text.isEmpty && text.count <= 10)
        }
        #expect(self.presentation(.todayAverageSpeed, snapshot: snapshot).compactText?.hasSuffix("t/s") == true)
        #expect(self.presentation(.todayCost, snapshot: snapshot).compactText?.hasPrefix("~$") == true)
        #expect(self.presentation(.todayCost, snapshot: self.snapshot(cost: 0.001)).compactText == "~<$0.01")
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
