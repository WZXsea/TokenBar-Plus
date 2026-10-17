import Foundation
import Testing
@testable import TokenBarCore

@Suite("Status bar speed activity")
struct StatusBarSpeedActivityTests {
    private let sampleTime: Int64 = 1_800_000_000_000

    @Test("fresh observations are active and become ordinary at sixty seconds")
    func expiresBySourceTime() {
        let snapshot = self.snapshot(output: 67)
        let active = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex, now: self.date(59.999))
        let idle = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex, now: self.date(60))
        #expect(active.isActive)
        #expect(active.activeUntil == self.date(60))
        #expect(active.tokensPerSecond == 67)
        #expect(!active.isSlow)
        #expect(!idle.isActive)
        #expect(!idle.isSlow)
        #expect(idle.tokensPerSecond == 67)
    }

    @Test("only active valid speeds below twenty are slow")
    func slowBoundary() {
        let slow = StatusBarSpeedActivity(snapshot: self.snapshot(output: 19), platform: .codex, now: self.date(0))
        let boundary = StatusBarSpeedActivity(snapshot: self.snapshot(output: 20), platform: .codex, now: self.date(0))
        #expect(slow.isActive)
        #expect(slow.isSlow)
        #expect(boundary.isActive)
        #expect(!boundary.isSlow)
        for output in [Int64(0), -1] {
            let unknown = StatusBarSpeedActivity(snapshot: self.snapshot(output: output), platform: .codex, now: self.date(0))
            #expect(!unknown.isActive)
            #expect(!unknown.isSlow)
            #expect(unknown.tokensPerSecond == nil)
        }
    }

    @Test("fresh cache timestamps cannot reactivate old source observations")
    func ignoresCacheClock() {
        let snapshot = self.snapshot(output: 10, generatedAtOffset: 600)
        let presentation = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex, now: self.date(600))
        #expect(!presentation.isActive)
        #expect(!presentation.isSlow)
    }

    @Test("another platform's recent work cannot activate this platform")
    func platformIsolation() {
        let snapshot = self.snapshot(output: 19, platform: .claude)
        let codex = StatusBarSpeedActivity(snapshot: snapshot, platform: .codex, now: self.date(0))
        let claude = StatusBarSpeedActivity(snapshot: snapshot, platform: .claude, now: self.date(0))
        #expect(!codex.isActive)
        #expect(codex.tokensPerSecond == nil)
        #expect(claude.isActive)
        #expect(claude.isSlow)
        #expect(!StatusBarSpeedActivity(snapshot: nil, platform: .codex, now: self.date(0)).isActive)
    }

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
