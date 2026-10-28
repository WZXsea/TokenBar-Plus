import Foundation
import Testing
@testable import TokenBarCore

private actor ResponsiveActivityProvider: ActivityProviding {
    private(set) var calls = 0
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
    private var blocked: Bool
    private var pending: CheckedContinuation<Void, Never>?

    init(blocked: Bool = false) { self.blocked = blocked }

    func release() {
        self.blocked = false
        self.pending?.resume()
        self.pending = nil
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        if self.blocked {
            await withCheckedContinuation { self.pending = $0 }
        }
        return TestFixtures.quota(usedPercent: 20)
    }
}

@MainActor
@Suite("Responsive local refresh")
struct ResponsiveRefreshTests {
    @Test("Active source events refresh immediately and a burst during a scan coalesces into one follow-up")
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
