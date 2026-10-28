import Foundation
import Observation

public struct DashboardSourceState<Value: Equatable & Sendable>: Equatable, Sendable {
    public let value: Value?
    public let isRefreshing: Bool
    public let errorMessage: String?

    public init(value: Value? = nil, isRefreshing: Bool = false, errorMessage: String? = nil) {
        self.value = value
        self.isRefreshing = isRefreshing
        self.errorMessage = errorMessage
    }
}

private enum QuotaRefreshResult: Sendable {
    case success(TokenPlatform, QuotaSnapshot)
    case cancelled(TokenPlatform)
    case failure(TokenPlatform, String)
}

@MainActor
@Observable
public final class DashboardModel {
    public static let defaultBackgroundRefreshInterval: Duration = .seconds(5 * 60)
    public static let defaultQuotaRefreshInterval = DashboardModel.defaultBackgroundRefreshInterval
    public static let defaultActivityRefreshInterval = DashboardModel.defaultBackgroundRefreshInterval
    public static let automaticQuotaRefreshMinimumAge: TimeInterval = 60

    public private(set) var quotas: [TokenPlatform: DashboardSourceState<QuotaSnapshot>]
    public private(set) var weeklyQuotaUsageHistories: [TokenPlatform: WeeklyQuotaUsageHistory] = [:]
    public private(set) var activity = DashboardSourceState<ActivitySnapshot>()
    public private(set) var history = DashboardSourceState<ActivitySnapshot>()
    public private(set) var historyRevision = 0
    public var scope: DashboardScope = .codex
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyLoadedAt: Date?
    @ObservationIgnored private var historyDayKey: String?


    public var quota: DashboardSourceState<QuotaSnapshot> {
        self.quotaState(for: .codex)
    }

    public var quotaSnapshot: QuotaSnapshot? { self.quota.value }
    public var activitySnapshot: ActivitySnapshot? { self.activity.value }
    public var visibleActivitySnapshot: ActivitySnapshot? {
        self.activity.value?.scoped(to: self.scope.platform)
    }

    public var visibleActivity: DashboardSourceState<ActivitySnapshot> {
        DashboardSourceState(
            value: self.visibleActivitySnapshot,
            isRefreshing: self.activity.isRefreshing,
            errorMessage: self.activity.errorMessage)
    }

    @ObservationIgnored public var quotaResetHandler: ((QuotaResetEvent) -> Void)?
    @ObservationIgnored private let quotaServices: [TokenPlatform: any QuotaProviding]
    @ObservationIgnored private let activityService: any ActivityProviding
    @ObservationIgnored private let cache: (any ActivitySnapshotCaching)?
    @ObservationIgnored private let quotaCache: (any QuotaSnapshotCaching)?
    @ObservationIgnored private let weeklyQuotaUsageCache: (any WeeklyQuotaUsageCaching)?
    @ObservationIgnored private var quotaRefreshInterval: Duration
    @ObservationIgnored private var activityRefreshInterval: Duration
    @ObservationIgnored private var statisticsTimeZone: TokenBarStatisticsTimeZone
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var quotaTimerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAllTask: Task<Void, Never>?
    @ObservationIgnored private var activityRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var activityRefreshGeneration = 0
    @ObservationIgnored private var activityRefreshNeedsFollowUp = false
    @ObservationIgnored private var lastQuotaRefreshAttemptAt: [TokenPlatform: Date] = [:]
    @ObservationIgnored private var quotaRefreshEnabledPlatforms: Set<TokenPlatform>
    @ObservationIgnored private var quotaResetDetector = QuotaResetDetector()
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var activityRefreshPolicy = ActivityRefreshPolicy()

    public convenience init(
        quotaService: any QuotaProviding = CodexQuotaService(),
        additionalQuotaServices: [any QuotaProviding] = [],
        activityService: any ActivityProviding = ActivityService(),
        cache: (any ActivitySnapshotCaching)? = SnapshotCache(),
        quotaCache: (any QuotaSnapshotCaching)? = nil,
        weeklyQuotaUsageCache: (any WeeklyQuotaUsageCaching)? = nil,
        quotaRefreshInterval: Duration = DashboardModel.defaultQuotaRefreshInterval,
        activityRefreshInterval: Duration = DashboardModel.defaultActivityRefreshInterval,
        statisticsTimeZone: TokenBarStatisticsTimeZone = TokenBarSettings.defaultStatisticsTimeZone)
    {
        self.init(
            quotaService: quotaService,
            additionalQuotaServices: additionalQuotaServices,
            activityService: activityService,
            cache: cache,
            quotaCache: quotaCache,
            weeklyQuotaUsageCache: weeklyQuotaUsageCache,
            quotaRefreshInterval: quotaRefreshInterval,
            activityRefreshInterval: activityRefreshInterval,
            statisticsTimeZone: statisticsTimeZone,
            sleep: { try await Task.sleep(for: $0) })
    }

    init(
        quotaService: any QuotaProviding,
        additionalQuotaServices: [any QuotaProviding] = [],
        activityService: any ActivityProviding,
        cache: (any ActivitySnapshotCaching)?,
        quotaCache: (any QuotaSnapshotCaching)? = nil,
        weeklyQuotaUsageCache: (any WeeklyQuotaUsageCaching)? = nil,
        quotaRefreshInterval: Duration,
        activityRefreshInterval: Duration,
        statisticsTimeZone: TokenBarStatisticsTimeZone = TokenBarSettings.defaultStatisticsTimeZone,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current)
    {
        var quotaServices: [TokenPlatform: any QuotaProviding] = [:]
        for service in [quotaService] + additionalQuotaServices {
            quotaServices[service.platform] = service
        }
        self.quotaServices = quotaServices
        self.quotaRefreshEnabledPlatforms = Set(quotaServices.keys)
        self.quotas = quotaServices.reduce(into: [:]) { states, entry in
            states[entry.key] = DashboardSourceState()
        }
        self.activityService = activityService
        self.cache = cache
        self.quotaCache = quotaCache
        self.weeklyQuotaUsageCache = weeklyQuotaUsageCache
        self.quotaRefreshInterval = quotaRefreshInterval
        self.activityRefreshInterval = activityRefreshInterval
        self.statisticsTimeZone = statisticsTimeZone
        self.sleep = sleep
        self.now = now
        self.calendar = calendar
    }

    public func start() async {
        guard !self.isStarted else { return }
        self.isStarted = true
        self.activityRefreshPolicy.start(at: self.now())

        if self.activity.value == nil,
           let cached = try? await self.cache?.loadActivity()
        {
            self.activity = DashboardSourceState(value: cached)
        }
        if let cachedUsage = try? await self.weeklyQuotaUsageCache?.loadWeeklyQuotaUsage() {
            self.weeklyQuotaUsageHistories = cachedUsage.filter {
                self.quotaServices[$0.key] != nil
            }
        }
        var seededWeeklyQuotaUsage = false
        if let cachedQuotas = try? await self.quotaCache?.loadQuotas() {
            for (platform, snapshot) in cachedQuotas
                where self.quotaServices[platform] != nil
                    && self.quotaState(for: platform).value == nil
            {
                seededWeeklyQuotaUsage = self.recordWeeklyQuotaUsage(snapshot, for: platform)
                    || seededWeeklyQuotaUsage
                self.setQuotaState(DashboardSourceState(value: snapshot), for: platform)
                if self.quotaRefreshEnabledPlatforms.contains(platform) {
                    _ = self.quotaResetDetector.observe(snapshot, for: platform)
                }
            }
        }
        if seededWeeklyQuotaUsage {
            try? await self.weeklyQuotaUsageCache?.saveWeeklyQuotaUsage(
                self.weeklyQuotaUsageHistories)
        }

        self.startRefreshTimers()
        await self.refreshAll(forceQuota: false)
    }

    public func stop() {
        self.invalidateHistory()
        self.isStarted = false
        self.quotaTimerTask?.cancel()
        self.quotaTimerTask = nil
        self.refreshAllTask?.cancel()
        self.refreshAllTask = nil
        self.activityRefreshGeneration += 1
        self.activityRefreshTask?.cancel()
        self.activityRefreshTask = nil
        self.activityRefreshNeedsFollowUp = false
    }

    /// Source writes refresh local usage immediately. Writes arriving during a
    /// scan coalesce into one follow-up so the latest append is not left waiting.
    public func notifyActivityChanged() {
        guard self.isStarted else { return }
        let now = self.now()
        let wasIdle = self.activityRefreshPolicy.isIdle(at: now)
        self.activityRefreshPolicy.recordSourceChange(at: now)
        if wasIdle {
            self.startRefreshTimers()
        }
        self.activityRefreshNeedsFollowUp = true
        Task { @MainActor [weak self] in
            guard let self, self.isStarted else { return }
            await self.refreshActivity()
        }
    }

    var effectiveBackgroundRefreshInterval: Duration {
        self.activityRefreshPolicy.interval(
            configured: min(self.quotaRefreshInterval, self.activityRefreshInterval),
            at: self.now())
    }

    public func updateBackgroundRefreshInterval(_ interval: Duration) {
        guard interval > .zero,
              self.quotaRefreshInterval != interval || self.activityRefreshInterval != interval
        else {
            return
        }
        self.quotaRefreshInterval = interval
        self.activityRefreshInterval = interval
        if self.isStarted {
            self.startRefreshTimers()
        }
    }

    @discardableResult
    public func updateStatisticsTimeZone(_ timeZone: TokenBarStatisticsTimeZone) -> Bool {
        guard self.statisticsTimeZone != timeZone else { return false }
        self.statisticsTimeZone = timeZone
        self.invalidateHistory()
        return true
    }

    @discardableResult
    public func updateQuotaRefreshEnabled(
        _ isEnabled: Bool,
        for platform: TokenPlatform) -> Bool
    {
        guard self.quotaServices[platform] != nil else { return false }
        if isEnabled {
            return self.quotaRefreshEnabledPlatforms.insert(platform).inserted
        }
        guard self.quotaRefreshEnabledPlatforms.remove(platform) != nil else { return false }
        self.lastQuotaRefreshAttemptAt.removeValue(forKey: platform)
        self.quotaResetDetector.reset(for: platform)
        let state = self.quotaState(for: platform)
        if state.isRefreshing {
            self.setQuotaState(
                DashboardSourceState(
                    value: state.value,
                    errorMessage: state.errorMessage),
                for: platform)
        }
        return true
    }

    public func refreshAll(forceQuota: Bool = true) async {
        if let refreshAllTask = self.refreshAllTask {
            await refreshAllTask.value
            return
        }

        let refreshAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Remote quota latency must not postpone local token and speed data.
            async let quotas: Void = self.refreshQuotas(force: forceQuota)
            await self.refreshActivity()
            await quotas
        }
        self.refreshAllTask = refreshAllTask
        await refreshAllTask.value
        self.refreshAllTask = nil
    }

    public func refreshQuota() async {
        await self.refreshQuota(for: .codex)
    }

    public func refreshQuotas(force: Bool = true) async {
        await self.refreshQuotas(for: self.quotaRefreshEnabledPlatforms, force: force)
    }

    public func refreshQuota(for platform: TokenPlatform) async {
        await self.refreshQuotas(for: [platform], force: true)
    }

    private func refreshQuotas(for platforms: Set<TokenPlatform>, force: Bool) async {
        let pending = self.quotaServices.filter { platform, _ in
            platforms.contains(platform)
                && self.quotaRefreshEnabledPlatforms.contains(platform)
                && !self.quotaState(for: platform).isRefreshing
                && (force || self.shouldAutomaticallyRefreshQuota(for: platform))
        }
        guard !pending.isEmpty else { return }
        let attemptedAt = self.now()
        let previous = self.quotas
        for platform in pending.keys {
            self.lastQuotaRefreshAttemptAt[platform] = attemptedAt
            let state = self.quotaState(for: platform)
            self.setQuotaState(
                DashboardSourceState(
                    value: state.value,
                    isRefreshing: true,
                    errorMessage: nil),
                for: platform)
        }

        var savedSnapshot = false
        await withTaskGroup(of: QuotaRefreshResult.self) { group in
            for (platform, service) in pending {
                group.addTask {
                    do {
                        let snapshot = try await service.fetchQuota()
                        try Task.checkCancellation()
                        return .success(platform, snapshot)
                    } catch is CancellationError {
                        return .cancelled(platform)
                    } catch {
                        return .failure(platform, error.localizedDescription)
                    }
                }
            }
            for await result in group {
                switch result {
                case let .success(platform, snapshot):
                    self.acceptQuotaSnapshot(
                        snapshot,
                        mergingFrom: previous[platform]?.value,
                        for: platform)
                    savedSnapshot = true
                case let .cancelled(platform):
                    let state = previous[platform] ?? DashboardSourceState()
                    self.setQuotaState(state, for: platform)
                case let .failure(platform, message):
                    self.setQuotaState(
                        DashboardSourceState(
                            value: previous[platform]?.value,
                            errorMessage: message),
                        for: platform)
                }
            }
        }
        if savedSnapshot {
            try? await self.quotaCache?.saveQuotas(self.quotaSnapshots())
            try? await self.weeklyQuotaUsageCache?.saveWeeklyQuotaUsage(
                self.weeklyQuotaUsageHistories)
        }
    }

    public func quotaState(for platform: TokenPlatform) -> DashboardSourceState<QuotaSnapshot> {
        self.quotas[platform] ?? DashboardSourceState()
    }

    /// Antigravity publishes no local quota window, so its tab drops the quota
    /// card instead of showing a row that can never fill in.
    public func providesQuota(for platform: TokenPlatform) -> Bool {
        self.quotaServices[platform] != nil
    }

    public func weeklyQuotaUsage(for platform: TokenPlatform) -> WeeklyQuotaUsageHistory? {
        self.weeklyQuotaUsageHistories[platform]
    }

    public func weeklyQuotaDayBreakdown(for platform: TokenPlatform) -> WeeklyQuotaDayBreakdown {
        WeeklyQuotaDayBreakdown(snapshot: self.quotaState(for: platform).value,
            history: self.weeklyQuotaUsageHistories[platform], at: self.now(),
            statisticsTimeZone: self.statisticsTimeZone)
    }

    public func weeklyQuotaUsageToday(for platform: TokenPlatform) -> WeeklyQuotaDailyUsage? {
        self.weeklyQuotaUsageHistories[platform]?.usage(
            at: self.now(),
            statisticsTimeZone: self.statisticsTimeZone)
    }

    public func weeklyQuotaUsage(
        for platform: TokenPlatform,
        on date: String) -> WeeklyQuotaDailyUsage?
    {
        self.weeklyQuotaUsageHistories[platform]?.usage(
            on: date,
            statisticsTimeZone: self.statisticsTimeZone)
    }

    private func setQuotaState(
        _ state: DashboardSourceState<QuotaSnapshot>,
        for platform: TokenPlatform)
    {
        guard self.quotas[platform] != state else { return }
        self.quotas[platform] = state
    }

    private func quotaSnapshots() -> [TokenPlatform: QuotaSnapshot] {
        self.quotas.reduce(into: [:]) { snapshots, entry in
            snapshots[entry.key] = entry.value.value
        }
    }

    private func acceptQuotaSnapshot(
        _ snapshot: QuotaSnapshot,
        mergingFrom previous: QuotaSnapshot?,
        for platform: TokenPlatform)
    {
        let snapshot = Self.mergingMissingResetDates(
            in: snapshot,
            from: previous,
            for: platform,
            now: self.now(),
            calendar: self.calendar)
        _ = self.recordWeeklyQuotaUsage(snapshot, for: platform)
        self.setQuotaState(DashboardSourceState(value: snapshot), for: platform)
        let events = self.quotaResetDetector.observe(snapshot, for: platform)
        for event in events {
            self.quotaResetHandler?(event)
        }
    }

    @discardableResult
    private func recordWeeklyQuotaUsage(
        _ snapshot: QuotaSnapshot,
        for platform: TokenPlatform) -> Bool
    {
        let previous = self.weeklyQuotaUsageHistories[platform]
        let history = previous?.recording(snapshot)
            ?? WeeklyQuotaUsageHistory.starting(with: snapshot)
        guard let history, history != previous else { return false }
        var histories = self.weeklyQuotaUsageHistories
        histories[platform] = history
        self.weeklyQuotaUsageHistories = histories
        return true
    }

    private func shouldAutomaticallyRefreshQuota(for platform: TokenPlatform) -> Bool {
        let now = self.now()
        if let lastAttempt = self.lastQuotaRefreshAttemptAt[platform],
           now.timeIntervalSince(lastAttempt) < Self.automaticQuotaRefreshMinimumAge
        {
            return false
        }
        guard let updatedAt = self.quotaState(for: platform).value?.updatedAt else {
            return true
        }
        return now.timeIntervalSince(updatedAt) >= Self.automaticQuotaRefreshMinimumAge
    }

    private static func mergingMissingResetDates(
        in snapshot: QuotaSnapshot,
        from previous: QuotaSnapshot?,
        for platform: TokenPlatform,
        now: Date,
        calendar: Calendar) -> QuotaSnapshot
    {
        let previousSnapshotUpdatedAt = previous?.updatedAt ?? .distantPast
        func merge(
            _ window: QuotaWindowSnapshot?,
            previous: QuotaWindowSnapshot?) -> QuotaWindowSnapshot?
        {
            guard let window else { return nil }
            let windowMinutes = window.windowMinutes ?? previous?.windowMinutes
            let inferredReset: Date? = {
                guard platform == .claude,
                      window.resetsAt == nil,
                      let previous,
                      previous.usedPercent > QuotaResetDetector.resetUsageThreshold,
                      window.usedPercent <= QuotaResetDetector.resetUsageThreshold,
                      snapshot.updatedAt > previousSnapshotUpdatedAt,
                      let windowMinutes,
                      windowMinutes > 0
                else {
                    return nil
                }
                return snapshot.updatedAt.addingTimeInterval(
                    TimeInterval(windowMinutes) * 60)
            }()
            let inheritedReset: Date? = {
                guard window.resetsAt == nil,
                      inferredReset == nil,
                      let reset = previous?.resetsAt,
                      let windowMinutes,
                      windowMinutes > 0
                else {
                    return nil
                }
                if let currentMinutes = window.windowMinutes,
                   let previousMinutes = previous?.windowMinutes,
                   currentMinutes != previousMinutes
                {
                    return nil
                }
                let duration = TimeInterval(windowMinutes) * 60
                if reset > now,
                   reset > snapshot.updatedAt,
                   reset.timeIntervalSince(snapshot.updatedAt) <= duration
                {
                    return reset
                }
                guard platform == .claude else { return nil }
                return Self.nextPeriodicReset(
                    from: reset,
                    every: duration,
                    after: now)
            }()
            let scheduledWeeklyReset: Date? = {
                guard platform == .claude,
                      window.resetsAt == nil,
                      inferredReset == nil,
                      inheritedReset == nil,
                      windowMinutes == 7 * 24 * 60
                else {
                    return nil
                }
                return Self.nextSundayAtEightPM(after: now, calendar: calendar)
            }()
            let resetsAt = window.resetsAt
                ?? inferredReset
                ?? inheritedReset
                ?? scheduledWeeklyReset
            let inheritedUsage = Self.inheritedUsage(
                for: window,
                from: previous,
                resetsAt: resetsAt)
            return QuotaWindowSnapshot(
                usedPercent: inheritedUsage ?? window.usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: resetsAt,
                usageKnown: inheritedUsage == nil ? window.usageKnown : true)
        }
        return QuotaSnapshot(
            session: merge(snapshot.session, previous: previous?.session),
            weekly: merge(snapshot.weekly, previous: previous?.weekly),
            resetCredits: snapshot.resetCredits,
            updatedAt: snapshot.updatedAt,
            origin: snapshot.origin,
            planType: snapshot.planType)
    }

    /// Keeps a percentage sampled in the same quota window when a newer provider
    /// payload repeats the reset time but omits usage.
    private static func inheritedUsage(
        for window: QuotaWindowSnapshot,
        from previous: QuotaWindowSnapshot?,
        resetsAt: Date?) -> Double?
    {
        guard !window.usageKnown,
              let previous,
              previous.usageKnown,
              previous.usedPercent.isFinite,
              let resetsAt,
              let previousReset = previous.resetsAt,
              abs(previousReset.timeIntervalSince(resetsAt)) <= 1
        else {
            return nil
        }
        return previous.usedPercent
    }

    private static func nextPeriodicReset(
        from reset: Date,
        every duration: TimeInterval,
        after referenceDate: Date) -> Date?
    {
        guard reset.timeIntervalSinceReferenceDate.isFinite,
              referenceDate.timeIntervalSinceReferenceDate.isFinite,
              duration.isFinite,
              duration > 0
        else {
            return nil
        }
        if reset > referenceDate { return reset }
        let elapsed = referenceDate.timeIntervalSince(reset)
        let intervals = floor(elapsed / duration) + 1
        let candidate = reset.addingTimeInterval(intervals * duration)
        return candidate.timeIntervalSinceReferenceDate.isFinite ? candidate : nil
    }

    private static func nextSundayAtEightPM(
        after referenceDate: Date,
        calendar: Calendar) -> Date?
    {
        var components = DateComponents()
        components.weekday = 1
        components.hour = 20
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: referenceDate,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward)
    }

    public var isRefreshing: Bool {
        self.activity.isRefreshing || self.quotas.values.contains(where: \.isRefreshing)
    }

    private func weeklyResetDates() -> [TokenPlatform: Date] {
        self.quotas.reduce(into: [:]) { result, entry in
            guard self.quotaRefreshEnabledPlatforms.contains(entry.key),
                  let windowStart = entry.value.value?.weekly?
                .weeklyPacing(at: self.now(), weekdaysOnly: false)?.windowStart
            else {
                return
            }
            result[entry.key] = windowStart
        }
    }

    public func sessions(on date: String) async throws -> [SessionSummary] {
        if self.activitySnapshot?.days.map(\.date).max() == date {
            return self.activitySnapshot?.sessions ?? []
        }
        return try await self.activityService.fetchSessions(
            on: date,
            statisticsTimeZone: self.statisticsTimeZone)
    }

    public var historyTimeZone: TimeZone {
        self.statisticsTimeZone == .utc ? TimeZone(secondsFromGMT: 0)! : .autoupdatingCurrent
    }

    public func invalidateHistory() {
        self.historyRevision += 1
        self.historyTask?.cancel()
        self.historyTask = nil
        self.historyLoadedAt = nil
        self.historyDayKey = nil
        self.history = DashboardSourceState()
    }

    /// Fetches the extended window only on demand; normal activity polling remains a 30-day scan.
    public func loadHistoryIfNeeded() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = self.historyTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let dayKey = formatter.string(from: self.now())
        if let loadedAt = self.historyLoadedAt,
           self.historyDayKey == dayKey,
           Int(self.now().timeIntervalSince1970 / 300) == Int(loadedAt.timeIntervalSince1970 / 300) { return }
        if let task = self.historyTask { await task.value; return }
        let revision = self.historyRevision
        let previous = self.history.value
        let zone = self.statisticsTimeZone
        let historyTimeZone = self.historyTimeZone
        let requestedAt = self.now()
        self.history = DashboardSourceState(value: self.history.value, isRefreshing: true)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.activityService.fetchHistory(days: previous == nil ? 366 : 30, endDate: dayKey, statisticsTimeZone: zone)
                try Task.checkCancellation()
                guard revision == self.historyRevision, zone == self.statisticsTimeZone else { return }
                let combined = previous.map { Self.mergingHistory(previous: $0, recent: snapshot, at: requestedAt, timeZone: historyTimeZone) } ?? snapshot
                self.history = DashboardSourceState(value: combined)
                self.historyLoadedAt = self.now()
                self.historyDayKey = dayKey
            } catch {
                guard revision == self.historyRevision else { return }
                self.history = DashboardSourceState(value: self.history.value, errorMessage: error.localizedDescription)
            }
        }
        self.historyTask = task
        await task.value
        if revision == self.historyRevision { self.historyTask = nil }
    }

    /// Replaces the complete recent window, including missing/removed days, while retaining older local months.
    private static func mergingHistory(previous: ActivitySnapshot, recent: ActivitySnapshot, at date: Date, timeZone: TimeZone) -> ActivitySnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let end = formatter.string(from: today)
        let lower = formatter.string(from: calendar.date(byAdding: .day, value: -365, to: today)!)
        let recentLower = formatter.string(from: calendar.date(byAdding: .day, value: -29, to: today)!)
        func mergedDays(_ old: [DailySummary], _ new: [DailySummary]) -> [DailySummary] {
            var days: [String: DailySummary] = [:]
            for day in old where day.date >= lower && day.date < recentLower { days[day.date] = day }
            for day in new where day.date >= recentLower && day.date <= end { days[day.date] = day }
            return days.values.sorted { $0.date < $1.date }
        }
        func platformSources(_ snapshot: ActivitySnapshot) -> [TokenPlatform: ActivitySourceSnapshot] {
            let sources = snapshot.sourceSnapshots.isEmpty
                ? [ActivitySourceSnapshot(platform: .codex, today: snapshot.today, weeklySinceReset: snapshot.weeklySinceReset, days: snapshot.days)]
                : snapshot.sourceSnapshots
            return Dictionary(sources.map { ($0.platform, $0) }, uniquingKeysWith: { _, last in last })
        }
        let oldSources = platformSources(previous)
        let newSources = platformSources(recent)
        let platforms = Set(oldSources.keys).union(newSources.keys).sorted { $0.rawValue < $1.rawValue }
        let sources = platforms.map { platform in
            ActivitySourceSnapshot(
                platform: platform, today: newSources[platform]?.today ?? .zero,
                weeklySinceReset: newSources[platform]?.weeklySinceReset,
                days: mergedDays(oldSources[platform]?.days ?? [], newSources[platform]?.days ?? []), rangeTotals: nil)
        }
        return ActivitySnapshot(
            schemaVersion: recent.schemaVersion, generatedAtMs: recent.generatedAtMs, timezone: recent.timezone,
            today: recent.today, sessions: recent.sessions, days: mergedDays(previous.days, recent.days),
            weeklySinceReset: recent.weeklySinceReset, sources: sources.isEmpty ? nil : sources,
            rangeTotals: nil, memoryUsage: recent.memoryUsage, pricingModels: recent.pricingModels)
    }

    /// Extended history is local-only, matching the extended provider contract.
    /// Normal activity may contain synchronized devices and is deliberately kept separate.
    public func historyDays(for platform: TokenPlatform?) -> [DailySummary] {
        (self.history.value?.scoped(to: platform).days ?? []).sorted { $0.date < $1.date }
    }

    public func refreshActivity() async {
        await self.startActivityRefresh(restarting: false)
    }

    public func restartActivityRefresh() async {
        self.invalidateHistory()
        await self.startActivityRefresh(restarting: true)
    }

    private func startActivityRefresh(restarting: Bool) async {
        if restarting {
            self.activityRefreshGeneration += 1
            self.activityRefreshTask?.cancel()
            self.activityRefreshTask = nil
        } else if self.activityRefreshTask != nil {
            return
        }
        let generation = self.activityRefreshGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performActivityRefresh(generation: generation)
        }
        self.activityRefreshTask = task
        await task.value
        if generation == self.activityRefreshGeneration {
            self.activityRefreshTask = nil
        }
    }

    private func performActivityRefresh(generation: Int) async {
        guard generation == self.activityRefreshGeneration else { return }
        while generation == self.activityRefreshGeneration {
            self.activityRefreshNeedsFollowUp = false
            self.activity = DashboardSourceState(
                value: self.activity.value,
                isRefreshing: true,
                errorMessage: nil)
            let statisticsTimeZone = self.statisticsTimeZone
            do {
                let snapshot = try await self.activityService.fetchActivity(
                    sinceWeeklyResetAtByPlatform: self.weeklyResetDates(),
                    statisticsTimeZone: statisticsTimeZone)
                try Task.checkCancellation()
                guard generation == self.activityRefreshGeneration else { return }
                guard statisticsTimeZone == self.statisticsTimeZone else { continue }
                let observedAt = self.now()
                let wasIdle = self.activityRefreshPolicy.isIdle(at: observedAt)
                self.activityRefreshPolicy.observe(snapshot, at: observedAt)
                if self.isStarted, wasIdle,
                   !self.activityRefreshPolicy.isIdle(at: observedAt)
                {
                    // A manual refresh can discover activity while the timer is
                    // still sleeping at the idle cadence. Schedule its next
                    // poll at the active cadence without launching another scan.
                    self.startRefreshTimers()
                }
                self.activity = DashboardSourceState(value: snapshot)
                try? await self.cache?.saveActivity(snapshot)
                guard generation == self.activityRefreshGeneration else { return }
                if self.activityRefreshNeedsFollowUp { continue }
                return
            } catch is CancellationError {
                guard generation == self.activityRefreshGeneration else { return }
                self.activity = DashboardSourceState(
                    value: self.activity.value,
                    errorMessage: self.activity.errorMessage)
                return
            } catch {
                guard generation == self.activityRefreshGeneration else { return }
                guard statisticsTimeZone == self.statisticsTimeZone else { continue }
                self.activity = DashboardSourceState(
                    value: self.activity.value,
                    errorMessage: error.localizedDescription)
                if self.activityRefreshNeedsFollowUp { continue }
                return
            }
        }
    }

    private func startRefreshTimers(refreshImmediately: Bool = false) {
        self.quotaTimerTask?.cancel()
        self.quotaTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            var delay = refreshImmediately ? Duration.zero : self.effectiveBackgroundRefreshInterval
            while !Task.isCancelled {
                do {
                    try await self.sleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isStarted else { return }
                let started = clock.now
                await self.refreshAll(forceQuota: false)
                guard !Task.isCancelled, self.isStarted else { return }
                // The chosen interval is start-to-start, with scans kept serial.
                // A two-second scan at a one-second setting starts its next scan
                // when ready instead of adding another full second of sleep.
                delay = max(.zero, self.effectiveBackgroundRefreshInterval - started.duration(to: clock.now))
            }
        }
    }
}
