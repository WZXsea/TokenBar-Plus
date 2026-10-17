import Foundation
import Testing
@testable import TokenBarCore

@MainActor
@Suite("Fast dashboard refresh")
struct DashboardFastRefreshTests {
    @Test("One-second rounds refresh activity, throttle quota, and serialize slow scans", .timeLimit(.minutes(1)))
    func oneSecondRounds() async throws {
        let clock = FastRefreshClock()
        let sleeper = ControlledRefreshSleeper(clock: clock)
        let quota = FastRefreshQuotaProvider(clock: clock)
        let activity = FastRefreshActivityProvider(clock: clock)
        let model = DashboardModel(
            quotaService: quota,
            activityService: activity,
            cache: nil,
            quotaRefreshInterval: .seconds(300),
            activityRefreshInterval: .seconds(300),
            sleep: { try await sleeper.sleep($0) },
            now: { clock.now })
        defer {
            model.stop()
            Task {
                await sleeper.finish()
                await activity.releasePausedFetch()
            }
        }

        model.updateBackgroundRefreshInterval(TokenBarRefreshInterval.oneSecond.duration)
        await model.start()
        var sleeps = sleeper.events.makeAsyncIterator()
        var pendingSleep = try #require(await sleeps.next())
        #expect(pendingSleep.duration == .seconds(1))
        #expect(await activity.fetchCount == 1)
        #expect(await quota.fetchCount == 1)

        // Each controlled wake drives the real model timer through a complete
        // round, including the model state that the dashboard displays.
        for second in 1 ... 60 {
            model.notifyActivityChanged()
            #expect(await sleeper.wake(pendingSleep))
            pendingSleep = try #require(await sleeps.next())
            #expect(pendingSleep.duration == .seconds(1))
            #expect(await activity.fetchCount == second + 1)
            #expect(model.activitySnapshot?.generatedAtMs == clock.milliseconds)
            #expect(await quota.fetchCount == (second < 60 ? 1 : 2))
        }

        // Simulate a scan taking longer than the selected interval. The next
        // timer sleep starts after completion, and another activity refresh
        // shares the existing scan rather than starting a second one.
        await activity.pauseNextFetch()
        #expect(await sleeper.wake(pendingSleep))
        var pausedFetches = activity.pausedEvents.makeAsyncIterator()
        let pausedFetchCount = try #require(await pausedFetches.next())
        #expect(pausedFetchCount == 62)
        clock.advance(by: 2.06)
        await model.refreshActivity()
        #expect(await activity.fetchCount == 62)
        #expect(await activity.maximumConcurrentFetches == 1)
        #expect(await sleeper.pendingSleepCount == 0)

        await activity.releasePausedFetch()
        let nextSleep = try #require(await sleeps.next())
        #expect(nextSleep.duration == .seconds(1))
        #expect(await activity.fetchCount == 62)
        #expect(await activity.maximumConcurrentFetches == 1)
        #expect(await quota.fetchCount == 2)
        #expect(model.activitySnapshot?.generatedAtMs == clock.milliseconds)

        model.stop()
        await sleeper.finish()
    }

    @Test("Idle polling slows down and source events wake one serialized refresh", .timeLimit(.minutes(1)))
    func idleAndWake() async throws {
        let clock = FastRefreshClock()
        let sleeper = ControlledRefreshSleeper(clock: clock)
        let quota = FastRefreshQuotaProvider(clock: clock)
        let activity = FastRefreshActivityProvider(clock: clock)
        let model = DashboardModel(
            quotaService: quota,
            activityService: activity,
            cache: nil,
            quotaRefreshInterval: .seconds(1),
            activityRefreshInterval: .seconds(1),
            sleep: { try await sleeper.sleep($0) },
            now: { clock.now })
        defer {
            model.stop()
            Task { await sleeper.finish() }
        }
        await model.start()
        var sleeps = sleeper.events.makeAsyncIterator()
        let first = try #require(await sleeps.next())
        #expect(first.duration == .seconds(1))
        clock.advance(by: 60)
        #expect(await sleeper.wake(first))
        let idle = try #require(await sleeps.next())
        #expect(idle.duration == .seconds(300))
        #expect(await activity.fetchCount == 2)

        model.notifyActivityChanged()
        // A burst during the active window extends the window and coalesces
        // into the first wake rather than launching another provider scan.
        for _ in 0 ..< 20 { model.notifyActivityChanged() }
        let resumed = try #require(await sleeps.next())
        #expect(resumed.duration == .seconds(1))
        #expect(await activity.fetchCount == 3)
        #expect(await activity.maximumConcurrentFetches == 1)
        #expect(await sleeper.wake(idle) == false)

        model.stop()
        model.notifyActivityChanged()
        await Task.yield()
        #expect(await activity.fetchCount == 3)
        await sleeper.finish()
    }

    @Test("Manual refresh discovering activity replaces an outstanding idle sleep", .timeLimit(.minutes(1)))
    func manualRefreshResumesActiveTimer() async throws {
        let clock = FastRefreshClock()
        let sleeper = ControlledRefreshSleeper(clock: clock)
        let activity = FastRefreshActivityProvider(clock: clock)
        let model = DashboardModel(
            quotaService: FastRefreshQuotaProvider(clock: clock),
            activityService: activity,
            cache: nil,
            quotaRefreshInterval: .seconds(1),
            activityRefreshInterval: .seconds(1),
            sleep: { try await sleeper.sleep($0) },
            now: { clock.now })
        defer {
            model.stop()
            Task { await sleeper.finish() }
        }
        await model.start()
        var sleeps = sleeper.events.makeAsyncIterator()
        let first = try #require(await sleeps.next())
        clock.advance(by: 60)
        #expect(await sleeper.wake(first))
        let idle = try #require(await sleeps.next())
        #expect(idle.duration == .seconds(300))

        await activity.recordSourceActivity()
        await model.refreshActivity()
        let active = try #require(await sleeps.next())
        #expect(active.duration == .seconds(1))
        #expect(await activity.fetchCount == 3)
        // Events following a manual refresh remain coalesced, and the formerly
        // outstanding five-minute sleep has already been replaced.
        model.notifyActivityChanged()
        #expect(await sleeper.wake(active))
        let next = try #require(await sleeps.next())
        #expect(next.duration == .seconds(1))
        #expect(await activity.fetchCount == 4)
        #expect(await activity.maximumConcurrentFetches == 1)
        #expect(await sleeper.wake(idle) == false)
        await sleeper.finish()
    }

}

private final class FastRefreshClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { self.lock.withLock { self.instant } }
    var milliseconds: Int64 { Int64((self.now.timeIntervalSince1970 * 1_000).rounded()) }

    func advance(by seconds: TimeInterval) {
        self.lock.withLock { self.instant = self.instant.addingTimeInterval(seconds) }
    }
}

private struct ControlledRefreshSleep: Sendable {
    let id: UUID
    let duration: Duration
}

private actor ControlledRefreshSleeper {
    nonisolated let events: AsyncStream<ControlledRefreshSleep>
    private let continuation: AsyncStream<ControlledRefreshSleep>.Continuation
    private let clock: FastRefreshClock
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var isFinished = false

    var pendingSleepCount: Int { self.pending.count }

    init(clock: FastRefreshClock) {
        let stream = AsyncStream<ControlledRefreshSleep>.makeStream()
        self.events = stream.stream
        self.continuation = stream.continuation
        self.clock = clock
    }

    func sleep(_ duration: Duration) async throws {
        let request = ControlledRefreshSleep(id: UUID(), duration: duration)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || self.isFinished {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.pending[request.id] = continuation
                self.continuation.yield(request)
            }
        } onCancel: {
            Task { await self.cancel(request.id) }
        }
    }

    func wake(_ request: ControlledRefreshSleep) -> Bool {
        guard let continuation = self.pending.removeValue(forKey: request.id) else { return false }
        let components = request.duration.components
        self.clock.advance(by: Double(components.seconds) + Double(components.attoseconds) / 1e18)
        continuation.resume()
        return true
    }

    func finish() {
        self.isFinished = true
        let continuations = Array(self.pending.values)
        self.pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
        self.continuation.finish()
    }

    private func cancel(_ id: UUID) {
        self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private actor FastRefreshQuotaProvider: QuotaProviding {
    let platform = TokenPlatform.codex
    private let clock: FastRefreshClock
    private(set) var fetchCount = 0

    init(clock: FastRefreshClock) {
        self.clock = clock
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        self.fetchCount += 1
        return QuotaSnapshot(
            session: nil,
            weekly: QuotaWindowSnapshot(
                usedPercent: 25,
                windowMinutes: 10_080,
                resetsAt: self.clock.now.addingTimeInterval(7 * 86_400)),
            resetCredits: nil,
            updatedAt: self.clock.now)
    }
}

private actor FastRefreshActivityProvider: ActivityProviding {
    nonisolated let pausedEvents: AsyncStream<Int>
    private let pauseContinuation: AsyncStream<Int>.Continuation
    private let clock: FastRefreshClock
    private var shouldPauseNextFetch = false
    private var sourceActivityTimestampMs: Int64?
    private var pausedFetch: CheckedContinuation<Void, Never>?
    private var concurrentFetches = 0
    private(set) var maximumConcurrentFetches = 0
    private(set) var fetchCount = 0

    init(clock: FastRefreshClock) {
        let stream = AsyncStream<Int>.makeStream()
        self.pausedEvents = stream.stream
        self.pauseContinuation = stream.continuation
        self.clock = clock
    }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.fetchCount += 1
        self.concurrentFetches += 1
        self.maximumConcurrentFetches = max(self.maximumConcurrentFetches, self.concurrentFetches)
        defer { self.concurrentFetches -= 1 }
        if self.shouldPauseNextFetch {
            self.shouldPauseNextFetch = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.pausedFetch = continuation
                self.pauseContinuation.yield(self.fetchCount)
            }
        }
        if let sourceActivityTimestampMs {
            return TestFixtures.activity(generatedAtMs: sourceActivityTimestampMs)
        }
        return ActivitySnapshot(
            schemaVersion: 4,
            generatedAtMs: self.clock.milliseconds,
            timezone: "UTC",
            today: .zero,
            sessions: [],
            days: [])
    }

    func recordSourceActivity() {
        self.sourceActivityTimestampMs = self.clock.milliseconds
    }

    func pauseNextFetch() {
        self.shouldPauseNextFetch = true
    }

    func releasePausedFetch() {
        self.pausedFetch?.resume()
        self.pausedFetch = nil
    }
}
