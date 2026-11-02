import Foundation
import Testing
@testable import TokenBarCore

private actor ResponsiveActivityProvider: ActivityProviding {
    private(set) var calls = 0
    private(set) var startedAt: [ContinuousClock.Instant] = []
    private(set) var completedAt: [ContinuousClock.Instant] = []
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0
    private var blocked = false
    private var failsNextRequest = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    func setBlocked(_ value: Bool) {
        self.blocked = value
        if !value {
            let pending = self.pending
            self.pending.removeAll()
            for continuation in pending { continuation.resume() }
        }
    }

    func failNextRequest() { self.failsNextRequest = true }

    func fetchActivity(sinceWeeklyResetAt: Date?, statisticsTimeZone: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot {
        self.calls += 1
        self.startedAt.append(ContinuousClock().now)
        self.activeCalls += 1
        self.maximumConcurrentCalls = max(self.maximumConcurrentCalls, self.activeCalls)
        defer {
            self.activeCalls -= 1
            self.completedAt.append(ContinuousClock().now)
        }
        let fails = self.failsNextRequest
        self.failsNextRequest = false
        if self.blocked {
            await withCheckedContinuation { self.pending.append($0) }
        }
        if fails { throw CocoaError(.fileReadUnknown) }
        return TestFixtures.activity()
    }
}

private actor ResponsiveQuotaProvider: QuotaProviding {
    let platform = TokenPlatform.codex
    private(set) var calls = 0
    private var blocked: Bool
    private var usedPercent = 20.0
    private var pending: CheckedContinuation<Void, Never>?
    private let now: @Sendable () -> Date

    init(blocked: Bool = false, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) {
        self.blocked = blocked
        self.now = now
    }

    func block(usedPercent: Double) {
        self.blocked = true
        self.usedPercent = usedPercent
    }

    func release() {
        self.blocked = false
        self.pending?.resume()
        self.pending = nil
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        self.calls += 1
        if self.blocked {
            await withCheckedContinuation { self.pending = $0 }
        }
        let snapshot = TestFixtures.quota(usedPercent: self.usedPercent)
        return QuotaSnapshot(session: snapshot.session, weekly: snapshot.weekly,
            resetCredits: snapshot.resetCredits, updatedAt: self.now())
    }
}

private final class ResponsiveTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { self.lock.withLock { self.value } }
    func advance(by seconds: TimeInterval) { self.lock.withLock { self.value.addTimeInterval(seconds) } }
}

@MainActor
@Suite("Responsive local refresh")
struct ResponsiveRefreshTests {
    @Test("Active source events and a burst during a scan coalesce into one follow-up")
    func sourceEventsRefreshAndCatchUp() async {
        let activity = ResponsiveActivityProvider()
        let model = self.model(activity: activity, quota: ResponsiveQuotaProvider())
        await model.start()
        defer { model.stop() }
        #expect(await activity.calls == 1)

        model.notifyActivityChanged()
        let activeEventRefreshed = await self.eventually { await activity.calls == 2 }
        #expect(activeEventRefreshed)

        await activity.setBlocked(true)
        model.notifyActivityChanged()
        let scanStarted = await self.eventually { await activity.calls == 3 }
        #expect(scanStarted)
        model.notifyActivityChanged()
        model.notifyActivityChanged()
        model.notifyActivityChanged()
        await activity.setBlocked(false)
        let caughtUp = await self.eventually { await activity.calls == 4 && !model.activity.isRefreshing }
        #expect(caughtUp)
        #expect(await activity.calls == 4)

        await activity.setBlocked(true)
        await activity.failNextRequest()
        model.notifyActivityChanged()
        let failingScanStarted = await self.eventually { await activity.calls == 5 }
        #expect(failingScanStarted)
        model.notifyActivityChanged()
        await activity.setBlocked(false)
        let recovered = await self.eventually { await activity.calls == 6 && !model.activity.isRefreshing }
        #expect(recovered)
        #expect(model.activity.errorMessage == nil)
    }

    @Test("A delayed remote quota request leaves local usage free to publish")
    func slowQuotaDoesNotBlockActivity() async {
        let activity = ResponsiveActivityProvider()
        let quota = ResponsiveQuotaProvider(blocked: true)
        let model = self.model(activity: activity, quota: quota)
        let refresh = Task { await model.refreshAll() }
        let published = await self.eventually { model.activitySnapshot != nil }
        #expect(published)
        await quota.release()
        await refresh.value
        #expect(await activity.calls == 1)
    }

    @Test("A slow scan and simultaneous timer/source events retain a full pause before the next scan")
    func slowScansPauseAndCoalesceTimerEvents() async throws {
        let activity = ResponsiveActivityProvider()
        let interval: Duration = .milliseconds(80)
        let model = DashboardModel(quotaService: ResponsiveQuotaProvider(), activityService: activity, cache: nil,
            quotaRefreshInterval: interval, activityRefreshInterval: interval)
        await model.start()
        defer { model.stop() }

        await activity.setBlocked(true)
        model.notifyActivityChanged()
        #expect(await self.eventually { await activity.calls == 2 })
        model.notifyActivityChanged()
        model.notifyActivityChanged()
        try await Task.sleep(for: .milliseconds(160))
        await activity.setBlocked(false)
        #expect(await self.eventually { await activity.calls >= 3 })

        let ended = await activity.completedAt
        let started = await activity.startedAt
        let secondEnded = try #require(ended.dropFirst().first)
        let thirdStarted = try #require(started.dropFirst(2).first)
        #expect(secondEnded.duration(to: thirdStarted) >= interval)
        #expect(await activity.maximumConcurrentCalls == 1)
    }

    @Test("Manual refresh covers queued source events and stopping cancels a deferred follow-up")
    func manualRefreshAndStopHandleDeferredEvents() async throws {
        let activity = ResponsiveActivityProvider()
        let model = self.model(activity: activity, quota: ResponsiveQuotaProvider())
        await model.start()
        model.notifyActivityChanged()
        await model.refreshActivity()
        #expect(await activity.calls == 2)
        model.notifyActivityChanged()
        model.stop()
        try await Task.sleep(for: .milliseconds(1100))
        #expect(await activity.calls == 2)
    }

    @Test("Rescheduling or waking a timer preserves an in-flight quota request, while stopping cancels it")
    func quotaSurvivesTimerRescheduling() async {
        let activity = ResponsiveActivityProvider()
        let clock = ResponsiveTestClock()
        let quota = ResponsiveQuotaProvider(now: { clock.now })
        let model = DashboardModel(quotaService: quota, activityService: activity, cache: nil,
            quotaRefreshInterval: .milliseconds(40), activityRefreshInterval: .milliseconds(40),
            sleep: { try await Task.sleep(for: $0) }, now: { clock.now })
        await model.start()
        await quota.block(usedPercent: 70)
        clock.advance(by: 61)
        model.notifyActivityChanged()
        #expect(await self.eventually { await quota.calls == 2 })

        model.updateBackgroundRefreshInterval(.milliseconds(80))
        clock.advance(by: 61)
        model.notifyActivityChanged()
        await quota.release()
        #expect(await self.eventually { model.quotaSnapshot?.weekly?.usedPercent == 70 })
        #expect(await quota.calls == 2)

        await quota.block(usedPercent: 85)
        clock.advance(by: 61)
        model.notifyActivityChanged()
        #expect(await self.eventually { await quota.calls == 3 })
        model.stop()
        await quota.release()
        #expect(await self.eventually { !model.quota.isRefreshing })
        #expect(model.quotaSnapshot?.weekly?.usedPercent == 70)
    }

    private func model(activity: ResponsiveActivityProvider, quota: ResponsiveQuotaProvider) -> DashboardModel {
        DashboardModel(quotaService: quota, activityService: activity, cache: nil,
            quotaRefreshInterval: .seconds(86_400), activityRefreshInterval: .seconds(86_400))
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}
