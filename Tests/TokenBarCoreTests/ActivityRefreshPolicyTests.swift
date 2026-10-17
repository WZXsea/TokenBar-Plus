import Foundation
import Testing
@testable import TokenBarCore

@Suite("Activity refresh policy")
struct ActivityRefreshPolicyTests {
    @Test("Snapshot generation leaves the idle deadline unchanged")
    func snapshotGeneration() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = ActivityRefreshPolicy()
        policy.start(at: start)
        let snapshot = TestFixtures.activity(generatedAtMs: 1_700_000_000_000)
        policy.observe(snapshot, at: start.addingTimeInterval(30))
        let regenerated = ActivitySnapshot(
            schemaVersion: snapshot.schemaVersion,
            generatedAtMs: 1_800_000_059_000,
            timezone: snapshot.timezone,
            today: snapshot.today,
            sessions: snapshot.sessions,
            days: snapshot.days)
        policy.observe(regenerated, at: start.addingTimeInterval(59))
        #expect(policy.interval(configured: .seconds(1), at: start.addingTimeInterval(60)) == .seconds(300))
        #expect(policy.interval(configured: .seconds(600), at: start.addingTimeInterval(60)) == .seconds(600))
    }

    @Test("Real activity and source events extend the active window")
    func activityChanges() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = ActivityRefreshPolicy()
        policy.start(at: start)
        policy.observe(TestFixtures.activity(generatedAtMs: 1_800_000_030_000), at: start.addingTimeInterval(31))
        #expect(!policy.isIdle(at: start.addingTimeInterval(90)))
        #expect(policy.isIdle(at: start.addingTimeInterval(91)))
        policy.recordSourceChange(at: start.addingTimeInterval(92))
        #expect(!policy.isIdle(at: start.addingTimeInterval(100)))
    }

    @Test("Repeated future source timestamps cannot keep polling active")
    func futureTimestamp() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var policy = ActivityRefreshPolicy()
        policy.start(at: start)
        let future = TestFixtures.activity(generatedAtMs: 1_900_000_000_000)
        policy.observe(future, at: start)
        policy.observe(future, at: start.addingTimeInterval(59))
        #expect(policy.isIdle(at: start.addingTimeInterval(60)))
    }

    @Test("Token and request-count changes count as activity with unchanged source timestamps")
    func usageChanges() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let original = TestFixtures.activity(generatedAtMs: 1_700_000_000_000)
        let tokens = TokenBreakdown(input: 11, output: 5, cacheRead: 3, cacheWrite: 2, reasoning: 1)
        for (changedTokens, changedRequests) in [(tokens, 1), (original.today.tokens, 2)] {
            var policy = ActivityRefreshPolicy()
            policy.start(at: start)
            policy.observe(original, at: start)
            let changed = ActivitySnapshot(
                schemaVersion: original.schemaVersion,
                generatedAtMs: original.generatedAtMs,
                timezone: original.timezone,
                today: ActivityTotals(
                    tokens: changedTokens,
                    costUsd: original.today.costUsd,
                    requestCount: changedRequests,
                    sessionCount: original.today.sessionCount),
                sessions: original.sessions,
                days: original.days)
            policy.observe(changed, at: start.addingTimeInterval(70))
            #expect(!policy.isIdle(at: start.addingTimeInterval(100)))
            // An unchanged usage sample keeps the original activity deadline.
            policy.observe(changed, at: start.addingTimeInterval(129))
            #expect(policy.isIdle(at: start.addingTimeInterval(130)))
        }
    }

}
