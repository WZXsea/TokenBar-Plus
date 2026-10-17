import Foundation
import Observation
@testable import TokenBarCore
import Testing

@MainActor
struct TokenBarSettingsTests {
    @Test("Settings use product defaults in a new store")
    func defaults() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)

            #expect(settings.theme == .system)
            #expect(settings.recentSessionCount == .three)
            #expect(settings.recentSessionLimit == 3)
            #expect(settings.refreshInterval == .fiveMinutes)
            #expect(settings.backgroundRefreshDuration == .seconds(5 * 60))
            #expect(settings.statusBarTopMetric == .todayTokens)
            #expect(settings.statusBarBottomMetric == .weeklyRemaining)
            #expect(settings.showsStatusBarSpeedChart)
            #expect(settings.statisticsTimeZone == .utc)
            #expect(settings.showsClaude)
            #expect(settings.showsGrok)
            #expect(settings.showsAntigravity)
            #expect(!settings.usesWeekdayWeeklyPacing)
            #expect(settings.showsFullRequestContentOnHover)
            #expect(settings.monitorsCodexMemory)
            #expect(settings.resetCelebration == .off)
            #expect(!settings.syncEnabled)
            #expect(settings.syncServerURL.isEmpty)
            #expect(!settings.syncDeviceName.isEmpty)
            #expect(UUID(uuidString: settings.syncDeviceID) != nil)
            #expect(settings.dashboardSectionOrder == [
                .speed, .quota, .today, .recentSessions, .weeklyReset, .activity, .memory,
            ])
            #expect(settings.hiddenDashboardSections == [.memory])
            #expect(settings.visibleDashboardSections == [
                .speed, .quota, .today, .recentSessions, .weeklyReset, .activity,
            ])
        }
    }

    @Test("Settings changes persist for the next model instance")
    func persistence() {
        self.withDefaults { defaults, prefix in
            var settings: TokenBarSettings? = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings?.theme = .purple
            settings?.recentSessionCount = .five
            settings?.refreshInterval = .fifteenMinutes
            settings?.statusBarTopMetric = .latestSpeed
            settings?.statusBarBottomMetric = .timeToFirstToken
            settings?.showsStatusBarSpeedChart = false
            settings?.statisticsTimeZone = .local
            settings?.showsClaude = false
            settings?.showsGrok = false
            settings?.showsAntigravity = false
            settings?.usesWeekdayWeeklyPacing = true
            settings?.showsFullRequestContentOnHover = false
            settings?.monitorsCodexMemory = false
            settings?.resetCelebration = .both
            settings?.syncEnabled = true
            settings?.syncServerURL = "https://sync.example.com"
            settings?.syncDeviceName = "Studio"
            let deviceID = settings?.syncDeviceID
            settings = nil

            let restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.theme == .purple)
            #expect(restored.recentSessionLimit == 5)
            #expect(restored.refreshInterval == .fifteenMinutes)
            #expect(restored.statusBarTopMetric == .latestSpeed)
            #expect(restored.statusBarBottomMetric == .timeToFirstToken)
            #expect(!restored.showsStatusBarSpeedChart)
            #expect(restored.statisticsTimeZone == .local)
            #expect(!restored.showsClaude)
            #expect(!restored.showsGrok)
            #expect(!restored.showsAntigravity)
            #expect(restored.usesWeekdayWeeklyPacing)
            #expect(!restored.showsFullRequestContentOnHover)
            #expect(!restored.monitorsCodexMemory)
            #expect(restored.resetCelebration == .both)
            #expect(restored.syncEnabled)
            #expect(restored.syncServerURL == "https://sync.example.com")
            #expect(restored.syncDeviceName == "Studio")
            #expect(restored.syncDeviceID == deviceID)
        }
    }

    @Test("Unsupported stored values fall back safely")
    func invalidValues() {
        self.withDefaults { defaults, prefix in
            defaults.set("ultraviolet", forKey: "\(prefix).theme")
            defaults.set(7, forKey: "\(prefix).recentSessionCount")
            defaults.set(3, forKey: "\(prefix).refreshInterval")
            defaults.set("mars", forKey: "\(prefix).statisticsTimeZone")
            defaults.set("fireworks", forKey: "\(prefix).resetCelebration")
            defaults.set("future-top", forKey: "\(prefix).statusBarTopMetric")
            defaults.set("future-bottom", forKey: "\(prefix).statusBarBottomMetric")
            defaults.set("invalid-boolean", forKey: "\(prefix).showsStatusBarSpeedChart")

            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(settings.theme == .system)
            #expect(settings.recentSessionCount == .three)
            #expect(settings.refreshInterval == .fiveMinutes)
            #expect(settings.statisticsTimeZone == .utc)
            #expect(settings.resetCelebration == .off)
            #expect(settings.statusBarTopMetric == .todayTokens)
            #expect(settings.statusBarBottomMetric == .weeklyRemaining)
            #expect(settings.showsStatusBarSpeedChart)
        }
    }

    @Test("Second-based refresh options persist their seconds and round-trip through Codable", arguments: [
        TokenBarRefreshInterval.oneSecond, .twoSeconds, .fiveSeconds, .tenSeconds, .thirtySeconds,
    ])
    func secondRefreshIntervalPersistence(interval: TokenBarRefreshInterval) throws {
        try self.withDefaults { defaults, prefix in
            defaults.set(1, forKey: "\(prefix).refreshInterval")
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(settings.refreshInterval == .oneMinute)

            settings.refreshInterval = interval

            let seconds = -interval.rawValue
            #expect(defaults.integer(forKey: "\(prefix).refreshInterval") == interval.rawValue)
            #expect(settings.backgroundRefreshDuration == .seconds(seconds))
            #expect(interval.displayName == "\(seconds) 秒")
            let restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.refreshInterval == interval)
            #expect(restored.backgroundRefreshDuration == .seconds(seconds))
            let encoded = try JSONEncoder().encode(interval)
            #expect(try JSONDecoder().decode(Int.self, from: encoded) == interval.rawValue)
            #expect(try JSONDecoder().decode(TokenBarRefreshInterval.self, from: encoded) == interval)
        }
    }

    @Test("Every status metric, including hidden rows, persists independently", arguments: TokenBarStatusMetric.allCases)
    func statusMetricPersistence(metric: TokenBarStatusMetric) throws {
        try self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings.statusBarTopMetric = metric
            var restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.statusBarTopMetric == metric)
            #expect(restored.statusBarBottomMetric == .weeklyRemaining)
            #expect(defaults.string(forKey: "\(prefix).statusBarTopMetric") == metric.rawValue)

            settings.statusBarBottomMetric = metric
            restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.statusBarTopMetric == metric)
            #expect(restored.statusBarBottomMetric == metric)
            #expect(defaults.string(forKey: "\(prefix).statusBarBottomMetric") == metric.rawValue)
            #expect(restored.showsStatusBarSpeedChart)
            let data = try JSONEncoder().encode(metric)
            #expect(try JSONDecoder().decode(TokenBarStatusMetric.self, from: data) == metric)
            #expect(!metric.displayName.isEmpty)
        }
    }

    @Test("Status display defaults preserve existing refresh, theme, platform, and layout preferences")
    func statusDisplayMigration() {
        self.withDefaults { defaults, prefix in
            let order: [TokenBarDashboardSection] = [
                .recentSessions, .speed, .quota, .today, .weeklyReset, .activity, .memory,
            ]
            defaults.set(TokenBarRefreshInterval.oneSecond.rawValue, forKey: "\(prefix).refreshInterval")
            defaults.set("pink", forKey: "\(prefix).theme")
            defaults.set(false, forKey: "\(prefix).showsGrok")
            defaults.set(order.map(\.rawValue), forKey: "\(prefix).dashboardSectionOrder")
            defaults.set(["quota", "memory"], forKey: "\(prefix).hiddenDashboardSections")

            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(settings.statusBarTopMetric == .todayTokens)
            #expect(settings.statusBarBottomMetric == .weeklyRemaining)
            #expect(settings.showsStatusBarSpeedChart)
            #expect(settings.refreshInterval == .oneSecond)
            #expect(settings.theme == .pink)
            #expect(!settings.showsGrok)
            #expect(settings.dashboardSectionOrder == order)
            #expect(settings.hiddenDashboardSections == [.quota, .memory])
            #expect(defaults.integer(forKey: "\(prefix).refreshInterval") == -1)
            #expect(defaults.stringArray(forKey: "\(prefix).dashboardSectionOrder") == order.map(\.rawValue))
        }
    }

    @Test("Legacy minute refresh values keep their raw values and durations")
    func legacyRefreshIntervalPersistence() {
        self.withDefaults { defaults, prefix in
            let legacy: [(Int, TokenBarRefreshInterval)] = [
                (1, .oneMinute), (5, .fiveMinutes), (10, .tenMinutes), (15, .fifteenMinutes),
            ]
            for (minutes, interval) in legacy {
                defaults.set(minutes, forKey: "\(prefix).refreshInterval")
                let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
                #expect(settings.refreshInterval == interval)
                #expect(settings.backgroundRefreshDuration == .seconds(minutes * 60))
                #expect(interval.rawValue == minutes)
                #expect(interval.displayName == "\(minutes) 分钟")
                #expect(defaults.integer(forKey: "\(prefix).refreshInterval") == minutes)
            }
        }
    }

    @Test("Refresh options lead with seconds and retain all minute options")
    func refreshIntervalOptionOrder() {
        #expect(TokenBarRefreshInterval.allCases == [
            .oneSecond, .twoSeconds, .fiveSeconds, .tenSeconds, .thirtySeconds,
            .oneMinute, .fiveMinutes, .tenMinutes, .fifteenMinutes,
        ])
    }

    @Test("Restore defaults updates values and persistence")
    func reset() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings.theme = .pink
            settings.recentSessionCount = .five
            settings.refreshInterval = .oneSecond
            settings.statusBarTopMetric = .none
            settings.statusBarBottomMetric = .none
            settings.showsStatusBarSpeedChart = false
            settings.statisticsTimeZone = .local
            settings.showsClaude = false
            settings.showsGrok = false
            settings.showsAntigravity = false
            settings.usesWeekdayWeeklyPacing = true
            settings.showsFullRequestContentOnHover = false
            settings.monitorsCodexMemory = false
            settings.resetCelebration = .session
            settings.syncEnabled = true
            settings.syncServerURL = "https://sync.example.com"
            settings.syncDeviceName = "Custom name"
            settings.moveDashboardSection(.activity, by: -4)
            settings.setDashboardSection(.speed, isVisible: false)
            settings.setDashboardSection(.memory, isVisible: true)

            settings.resetToDefaults()

            let restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.theme == .system)
            #expect(restored.recentSessionCount == .three)
            #expect(restored.refreshInterval == .fiveMinutes)
            #expect(settings.statusBarTopMetric == .todayTokens)
            #expect(settings.statusBarBottomMetric == .weeklyRemaining)
            #expect(settings.showsStatusBarSpeedChart)
            #expect(restored.statusBarTopMetric == .todayTokens)
            #expect(restored.statusBarBottomMetric == .weeklyRemaining)
            #expect(restored.showsStatusBarSpeedChart)
            #expect(restored.statisticsTimeZone == .utc)
            #expect(restored.showsClaude)
            #expect(restored.showsGrok)
            #expect(restored.showsAntigravity)
            #expect(!restored.usesWeekdayWeeklyPacing)
            #expect(restored.showsFullRequestContentOnHover)
            #expect(restored.monitorsCodexMemory)
            #expect(restored.resetCelebration == .off)
            #expect(!restored.syncEnabled)
            #expect(restored.syncServerURL.isEmpty)
            #expect(restored.syncDeviceName == TokenBarSettings.defaultSyncDeviceName)
            #expect(settings.dashboardSectionOrder == TokenBarSettings.defaultDashboardSectionOrder)
            #expect(settings.hiddenDashboardSections == TokenBarSettings.defaultHiddenDashboardSections)
            #expect(restored.dashboardSectionOrder == TokenBarSettings.defaultDashboardSectionOrder)
            #expect(restored.hiddenDashboardSections == TokenBarSettings.defaultHiddenDashboardSections)
        }
    }

    @Test("Existing settings receive layout defaults while preserving collection preferences")
    func layoutMigration() {
        self.withDefaults { defaults, prefix in
            defaults.set("purple", forKey: "\(prefix).theme")
            defaults.set(false, forKey: "\(prefix).monitorsCodexMemory")

            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(settings.dashboardSectionOrder == TokenBarSettings.defaultDashboardSectionOrder)
            #expect(settings.hiddenDashboardSections == [.memory])
            #expect(settings.theme == .purple)
            #expect(!settings.monitorsCodexMemory)

            settings.setDashboardSection(.memory, isVisible: true)
            #expect(settings.isDashboardSectionVisible(.memory))
            #expect(!settings.monitorsCodexMemory)
        }
    }

    @Test("Layout order and visibility persist as raw-value arrays")
    func layoutPersistence() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings.moveDashboardSection(.activity, by: -4)
            settings.setDashboardSection(.quota, isVisible: false)
            settings.setDashboardSection(.memory, isVisible: true)

            let expectedOrder: [TokenBarDashboardSection] = [
                .speed, .activity, .quota, .today, .recentSessions, .weeklyReset, .memory,
            ]
            #expect(defaults.stringArray(forKey: "\(prefix).dashboardSectionOrder")
                == expectedOrder.map(\.rawValue))
            #expect(defaults.stringArray(forKey: "\(prefix).hiddenDashboardSections") == ["quota"])

            let restored = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(restored.dashboardSectionOrder == expectedOrder)
            #expect(restored.hiddenDashboardSections == [.quota])
            #expect(restored.visibleDashboardSections == [
                .speed, .activity, .today, .recentSessions, .weeklyReset, .memory,
            ])
        }
    }

    @Test("Stored layout removes unknown values and duplicates, then appends missing sections")
    func normalizesStoredLayout() {
        self.withDefaults { defaults, prefix in
            defaults.set(["quota", "futureSection", 42, "quota", "speed"] as [Any],
                         forKey: "\(prefix).dashboardSectionOrder")
            defaults.set(["activity", "futureSection", 42, "activity"] as [Any],
                         forKey: "\(prefix).hiddenDashboardSections")

            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            let expectedOrder: [TokenBarDashboardSection] = [
                .quota, .speed, .today, .recentSessions, .weeklyReset, .activity, .memory,
            ]
            #expect(settings.dashboardSectionOrder == expectedOrder)
            #expect(settings.hiddenDashboardSections == [.activity])
            #expect(defaults.stringArray(forKey: "\(prefix).dashboardSectionOrder")
                == expectedOrder.map(\.rawValue))
            #expect(defaults.stringArray(forKey: "\(prefix).hiddenDashboardSections") == ["activity"])
        }
    }

    @Test("Malformed layout values use defaults while explicit empty visibility remains visible")
    func malformedLayoutValues() {
        self.withDefaults { defaults, prefix in
            defaults.set("quota", forKey: "\(prefix).dashboardSectionOrder")
            defaults.set(42, forKey: "\(prefix).hiddenDashboardSections")
            let recovered = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(recovered.dashboardSectionOrder == TokenBarSettings.defaultDashboardSectionOrder)
            #expect(recovered.hiddenDashboardSections == [.memory])

            defaults.set([String](), forKey: "\(prefix).dashboardSectionOrder")
            defaults.set([String](), forKey: "\(prefix).hiddenDashboardSections")
            let explicitEmpty = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            #expect(explicitEmpty.dashboardSectionOrder == TokenBarSettings.defaultDashboardSectionOrder)
            #expect(explicitEmpty.hiddenDashboardSections.isEmpty)
            #expect(explicitEmpty.visibleDashboardSections == explicitEmpty.dashboardSectionOrder)
        }
    }

    @Test("Out-of-range and overflowing layout moves preserve the full order")
    func layoutMoveBoundaries() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            let original = settings.dashboardSectionOrder
            settings.moveDashboardSection(.speed, by: -1)
            settings.moveDashboardSection(.memory, by: 1)
            settings.moveDashboardSection(.quota, by: Int.max)
            settings.moveDashboardSection(.speed, by: Int.min)
            settings.moveDashboardSection(.today, by: 0)
            #expect(settings.dashboardSectionOrder == original)

            settings.moveDashboardSection(.memory, by: -6)
            #expect(settings.dashboardSectionOrder.first == .memory)
            settings.moveDashboardSection(.memory, by: 6)
            #expect(settings.dashboardSectionOrder == original)
        }
    }

    @Test("Hidden sections keep their saved position and reappear in that order")
    func hiddenLayoutOrder() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            settings.setDashboardSection(.quota, isVisible: false)
            settings.moveDashboardSection(.quota, by: 2)
            #expect(settings.visibleDashboardSections == [
                .speed, .today, .recentSessions, .weeklyReset, .activity,
            ])

            settings.setDashboardSection(.quota, isVisible: true)
            #expect(settings.visibleDashboardSections == [
                .speed, .today, .recentSessions, .quota, .weeklyReset, .activity,
            ])
            #expect(!settings.isDashboardSectionVisible(.memory))
            #expect(settings.monitorsCodexMemory)
        }
    }

    @Test("Visible layout participates in observation for visibility and order changes")
    func layoutObservation() {
        self.withDefaults { defaults, prefix in
            let settings = TokenBarSettings(defaults: defaults, keyPrefix: prefix)
            let visibilityChanged = SettingsObservationFlag()
            withObservationTracking {
                _ = settings.visibleDashboardSections
            } onChange: {
                visibilityChanged.mark()
            }
            settings.setDashboardSection(.quota, isVisible: false)
            #expect(visibilityChanged.isSet)

            let orderChanged = SettingsObservationFlag()
            withObservationTracking {
                _ = settings.visibleDashboardSections
            } onChange: {
                orderChanged.mark()
            }
            settings.moveDashboardSection(.today, by: -2)
            #expect(orderChanged.isSet)

            let unchanged = SettingsObservationFlag()
            withObservationTracking {
                _ = settings.visibleDashboardSections
            } onChange: {
                unchanged.mark()
            }
            settings.setDashboardSection(.quota, isVisible: false)
            #expect(!unchanged.isSet)
        }
    }

    private func withDefaults(
        _ body: (UserDefaults, String) throws -> Void) rethrows
    {
        let suiteName = "TokenBarSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, "test.settings")
    }
}

private final class SettingsObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { self.lock.withLock { self.value } }

    func mark() {
        self.lock.withLock { self.value = true }
    }
}
