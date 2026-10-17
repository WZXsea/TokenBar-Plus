import Foundation
import Testing
@testable import TokenBarCore

@Suite("Live speed state")
struct EssentialSpeedTests {
    @Test("source observations expire at sixty seconds and slow speed is strictly below twenty")
    func activityBoundaries() {
        let active = StatusBarSpeedActivity(snapshot: self.snapshot(output: 20), platform: .codex, now: self.date(59.999))
        let expired = StatusBarSpeedActivity(snapshot: self.snapshot(output: 20), platform: .codex, now: self.date(60))
        let slow = StatusBarSpeedActivity(snapshot: self.snapshot(output: 19), platform: .codex, now: self.date(0))
        #expect(active.isActive)
        #expect(active.tokensPerSecond == 20)
        #expect(!active.isSlow)
        #expect(!expired.isActive)
        #expect(!expired.isSlow)
        #expect(slow.isActive && slow.isSlow)
    }

    @Test("cache clocks and another platform cannot reactivate idle source data")
    func sourceIsolation() {
        let old = StatusBarSpeedActivity(snapshot: self.snapshot(output: 10, generatedAtOffset: 600), platform: .codex, now: self.date(600))
        #expect(!old.isActive)
        let snapshot = self.snapshot(output: 19, platform: .claude)
        let codex = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex, now: self.date(0))
        let claude = StatusBarSpeedActivity(snapshot: snapshot, platform: .claude, now: self.date(0))
        #expect(!codex.isActive)
        #expect(codex.tokensPerSecond == nil)
        #expect(claude.isActive && claude.isSlow)
    }
    private let sampleTime: Int64 = 1_800_000_000_000

    private func date(_ offset: Double) -> Date {
        Date(timeIntervalSince1970: Double(self.sampleTime) / 1_000 + offset)
    }

    private func snapshot(output: Int64, platform: TokenPlatform = .codex, generatedAtOffset: Int64 = 0) -> ActivitySnapshot {
        let request = RequestSummary(
            id: "request", sessionId: "session", physicalSessionId: "physical", isSubagent: false,
            agent: nil, model: "fixture", provider: "fixture", startedAtMs: self.sampleTime - 1_000,
            endedAtMs: self.sampleTime, durationMs: 1_000, modelDurationMs: 1_000,
            timeToFirstTokenMs: nil,
            tokens: TokenBreakdown(input: 0, output: output, cacheRead: 0, cacheWrite: 0, reasoning: 0),
            costUsd: 0, costSource: .unknown, promptPreview: nil, outputPreview: nil, sessionPath: nil,
            platform: platform)
        let session = SessionSummary(
            id: "session", workspaceLabel: nil, startedAtMs: self.sampleTime - 1_000,
            endedAtMs: self.sampleTime, tokens: .zero, costUsd: 0, models: [], requests: [request], platform: platform)
        return ActivitySnapshot(
            schemaVersion: 4, generatedAtMs: self.sampleTime + generatedAtOffset * 1_000, timezone: "UTC",
            today: ActivityTotals(tokens: .zero, costUsd: 0, requestCount: 1, sessionCount: 1),
            sessions: [session], days: [])
    }
}
