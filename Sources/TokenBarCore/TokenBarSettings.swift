import Foundation
import Observation

public enum TokenBarTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case blue
    case purple
    case green
    case orange
    case pink

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .green: "绿色"
        case .orange: "橙色"
        case .pink: "粉色"
        }
    }
}

public enum TokenBarRecentSessionCount: Int, CaseIterable, Codable, Identifiable, Sendable {
    case three = 3
    case five = 5
    case ten = 10

    public var id: Self { self }
}

public enum TokenBarRefreshInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    // Negative raw values encode seconds; legacy positive values retain minutes.
    case oneSecond = -1
    case twoSeconds = -2
    case fiveSeconds = -5
    case tenSeconds = -10
    case thirtySeconds = -30

    // Keep these persisted minute values compatible with existing installations.
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case fifteenMinutes = 15

    public var id: Self { self }
    public var duration: Duration {
        .seconds(self.rawValue < 0 ? -self.rawValue : self.rawValue * 60)
    }

    public var displayName: String {
        self.rawValue < 0 ? "\(-self.rawValue) 秒" : "\(self.rawValue) 分钟"
    }
}

public enum TokenBarResetCelebration: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case session
    case weekly
    case both

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .off: "关闭"
        case .session: "5 小时额度重置"
        case .weekly: "每周额度重置"
        case .both: "5 小时及每周额度重置"
        }
    }

    public func includes(_ window: QuotaResetWindow) -> Bool {
        switch (self, window) {
        case (.session, .session), (.weekly, .weekly), (.both, _):
            true
        default:
            false
        }
    }
}

public enum TokenBarStatisticsTimeZone: String, CaseIterable, Codable, Identifiable, Sendable {
    case utc
    case local

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .utc: "UTC（与 Codex 一致）"
        case .local: "本地时间"
        }
    }

    var processEnvironmentValue: String {
        switch self {
        case .utc: "UTC"
        case .local: TimeZone.autoupdatingCurrent.identifier
        }
    }
}

public enum TokenBarDashboardSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case speed
    case quota
    case today
    case weeklyReset
    case activity
    case memory
    case recentSessions

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .speed: "Token 速率"
        case .quota: "额度"
        case .today: "今日用量"
        case .weeklyReset: "每周重置以来"
        case .activity: "使用记录"
        case .memory: "Codex 记忆"
        case .recentSessions: "最近会话"
        }
    }
}

public enum TokenBarStatusMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case todayTokens
    case latestSpeed
    case todayAverageSpeed
    case weeklyRemaining
    case sessionRemaining
    case todayCost
    case timeToFirstToken
    case none

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .todayTokens: "今日 Token 数"
        case .latestSpeed: "最近生成速率"
        case .todayAverageSpeed: "今日平均速率"
        case .weeklyRemaining: "每周剩余额度"
        case .sessionRemaining: "5 小时剩余额度"
        case .todayCost: "今日费用"
        case .timeToFirstToken: "首 token 延迟"
        case .none: "隐藏"
        }
    }
}

@MainActor
@Observable
public final class TokenBarSettings {
    public static let shared = TokenBarSettings()
    public static let defaultTheme = TokenBarTheme.system
    public static let defaultRecentSessionCount = TokenBarRecentSessionCount.three
    public static let defaultRefreshInterval = TokenBarRefreshInterval.fiveMinutes
    public static let defaultStatisticsTimeZone = TokenBarStatisticsTimeZone.utc
    public static let defaultShowsClaude = true
    public static let defaultShowsGrok = true
    public static let defaultShowsAntigravity = true
    public static let defaultUsesWeekdayWeeklyPacing = false
    public static let defaultShowsFullRequestContentOnHover = true
    public static let defaultMonitorsCodexMemory = true
    public static let defaultResetCelebration = TokenBarResetCelebration.off
    public static let defaultSyncEnabled = false
    public static let defaultSyncServerURL = ""
    public static let defaultStatusBarTopMetric = TokenBarStatusMetric.todayTokens
    public static let defaultStatusBarBottomMetric = TokenBarStatusMetric.weeklyRemaining
    public static let defaultShowsStatusBarSpeedChart = true
    public static let defaultDashboardSectionOrder: [TokenBarDashboardSection] = [
        .speed, .quota, .today, .recentSessions, .weeklyReset, .activity, .memory,
    ]
    public static let defaultHiddenDashboardSections: Set<TokenBarDashboardSection> = [.memory]
    public static var defaultSyncDeviceName: String {
        let name = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mac" : name
    }

    public var theme: TokenBarTheme {
        didSet { self.defaults.set(self.theme.rawValue, forKey: self.keys.theme) }
    }

    public var recentSessionCount: TokenBarRecentSessionCount {
        didSet { self.defaults.set(self.recentSessionCount.rawValue, forKey: self.keys.recentSessionCount) }
    }

    public var refreshInterval: TokenBarRefreshInterval {
        didSet { self.defaults.set(self.refreshInterval.rawValue, forKey: self.keys.refreshInterval) }
    }

    public var statusBarTopMetric: TokenBarStatusMetric {
        didSet { self.defaults.set(self.statusBarTopMetric.rawValue, forKey: self.keys.statusBarTopMetric) }
    }

    public var statusBarBottomMetric: TokenBarStatusMetric {
        didSet { self.defaults.set(self.statusBarBottomMetric.rawValue, forKey: self.keys.statusBarBottomMetric) }
    }

    public var showsStatusBarSpeedChart: Bool {
        didSet { self.defaults.set(self.showsStatusBarSpeedChart, forKey: self.keys.showsStatusBarSpeedChart) }
    }

    public var statisticsTimeZone: TokenBarStatisticsTimeZone {
        didSet {
            self.defaults.set(
                self.statisticsTimeZone.rawValue,
                forKey: self.keys.statisticsTimeZone)
        }
    }

    public var showsClaude: Bool {
        didSet {
            self.defaults.set(
                self.showsClaude,
                forKey: self.keys.showsClaude)
        }
    }

    public var showsGrok: Bool {
        didSet {
            self.defaults.set(
                self.showsGrok,
                forKey: self.keys.showsGrok)
        }
    }

    public var showsAntigravity: Bool {
        didSet {
            self.defaults.set(
                self.showsAntigravity,
                forKey: self.keys.showsAntigravity)
        }
    }

    public var usesWeekdayWeeklyPacing: Bool {
        didSet {
            self.defaults.set(
                self.usesWeekdayWeeklyPacing,
                forKey: self.keys.usesWeekdayWeeklyPacing)
        }
    }

    public var showsFullRequestContentOnHover: Bool {
        didSet {
            self.defaults.set(
                self.showsFullRequestContentOnHover,
                forKey: self.keys.showsFullRequestContentOnHover)
        }
    }

    public var monitorsCodexMemory: Bool {
        didSet {
            self.defaults.set(
                self.monitorsCodexMemory,
                forKey: self.keys.monitorsCodexMemory)
        }
    }

    public var resetCelebration: TokenBarResetCelebration {
        didSet {
            self.defaults.set(
                self.resetCelebration.rawValue,
                forKey: self.keys.resetCelebration)
        }
    }

    public var syncEnabled: Bool {
        didSet { self.defaults.set(self.syncEnabled, forKey: self.keys.syncEnabled) }
    }

    public var syncServerURL: String {
        didSet { self.defaults.set(self.syncServerURL, forKey: self.keys.syncServerURL) }
    }

    public var syncDeviceName: String {
        didSet { self.defaults.set(self.syncDeviceName, forKey: self.keys.syncDeviceName) }
    }

    public private(set) var syncDeviceID: String

    public private(set) var dashboardSectionOrder: [TokenBarDashboardSection] {
        didSet {
            self.defaults.set(
                self.dashboardSectionOrder.map(\.rawValue),
                forKey: self.keys.dashboardSectionOrder)
        }
    }

    public private(set) var hiddenDashboardSections: Set<TokenBarDashboardSection> {
        didSet {
            self.defaults.set(
                TokenBarDashboardSection.allCases
                    .filter { self.hiddenDashboardSections.contains($0) }
                    .map(\.rawValue),
                forKey: self.keys.hiddenDashboardSections)
        }
    }

    public var visibleDashboardSections: [TokenBarDashboardSection] {
        self.dashboardSectionOrder.filter { self.isDashboardSectionVisible($0) }
    }

    public var recentSessionLimit: Int { self.recentSessionCount.rawValue }
    public var backgroundRefreshDuration: Duration { self.refreshInterval.duration }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: Keys

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "TokenBar.settings")
    {
        self.defaults = defaults
        self.keys = Keys(prefix: keyPrefix)
        self.theme = defaults.string(forKey: self.keys.theme)
            .flatMap(TokenBarTheme.init(rawValue:)) ?? Self.defaultTheme
        self.recentSessionCount = TokenBarRecentSessionCount(
            rawValue: defaults.integer(forKey: self.keys.recentSessionCount)) ?? Self.defaultRecentSessionCount
        self.refreshInterval = TokenBarRefreshInterval(
            rawValue: defaults.integer(forKey: self.keys.refreshInterval)) ?? Self.defaultRefreshInterval
        self.statusBarTopMetric = defaults.string(forKey: self.keys.statusBarTopMetric)
            .flatMap(TokenBarStatusMetric.init(rawValue:)) ?? Self.defaultStatusBarTopMetric
        self.statusBarBottomMetric = defaults.string(forKey: self.keys.statusBarBottomMetric)
            .flatMap(TokenBarStatusMetric.init(rawValue:)) ?? Self.defaultStatusBarBottomMetric
        self.showsStatusBarSpeedChart = defaults.object(
            forKey: self.keys.showsStatusBarSpeedChart) as? Bool
            ?? Self.defaultShowsStatusBarSpeedChart
        self.statisticsTimeZone = defaults.string(forKey: self.keys.statisticsTimeZone)
            .flatMap(TokenBarStatisticsTimeZone.init(rawValue:)) ?? Self.defaultStatisticsTimeZone
        self.showsClaude = defaults.object(
            forKey: self.keys.showsClaude) as? Bool
            ?? Self.defaultShowsClaude
        self.showsGrok = defaults.object(
            forKey: self.keys.showsGrok) as? Bool
            ?? Self.defaultShowsGrok
        self.showsAntigravity = defaults.object(
            forKey: self.keys.showsAntigravity) as? Bool
            ?? Self.defaultShowsAntigravity
        self.usesWeekdayWeeklyPacing = defaults.object(
            forKey: self.keys.usesWeekdayWeeklyPacing) as? Bool
            ?? Self.defaultUsesWeekdayWeeklyPacing
        self.showsFullRequestContentOnHover = defaults.object(
            forKey: self.keys.showsFullRequestContentOnHover) as? Bool
            ?? Self.defaultShowsFullRequestContentOnHover
        self.monitorsCodexMemory = defaults.object(
            forKey: self.keys.monitorsCodexMemory) as? Bool
            ?? Self.defaultMonitorsCodexMemory
        self.resetCelebration = defaults.string(forKey: self.keys.resetCelebration)
            .flatMap(TokenBarResetCelebration.init(rawValue:)) ?? Self.defaultResetCelebration
        self.syncEnabled = defaults.object(forKey: self.keys.syncEnabled) as? Bool
            ?? Self.defaultSyncEnabled
        self.syncServerURL = defaults.string(forKey: self.keys.syncServerURL)
            ?? Self.defaultSyncServerURL
        self.syncDeviceName = defaults.string(forKey: self.keys.syncDeviceName)
            ?? Self.defaultSyncDeviceName
        let storedDeviceID = defaults.string(forKey: self.keys.syncDeviceID)
        self.syncDeviceID = storedDeviceID.flatMap { UUID(uuidString: $0) }?
            .uuidString.lowercased() ?? UUID().uuidString.lowercased()
        let storedOrder = defaults.array(forKey: self.keys.dashboardSectionOrder)?
            .compactMap { $0 as? String }
        self.dashboardSectionOrder = Self.normalizedDashboardSectionOrder(storedOrder)
        if let storedHidden = defaults.array(forKey: self.keys.hiddenDashboardSections) {
            self.hiddenDashboardSections = Set(storedHidden
                .compactMap { $0 as? String }
                .compactMap(TokenBarDashboardSection.init(rawValue:)))
        } else {
            self.hiddenDashboardSections = Self.defaultHiddenDashboardSections
        }
        defaults.set(self.syncDeviceID, forKey: self.keys.syncDeviceID)
        defaults.set(
            self.dashboardSectionOrder.map(\.rawValue),
            forKey: self.keys.dashboardSectionOrder)
        defaults.set(
            TokenBarDashboardSection.allCases
                .filter { self.hiddenDashboardSections.contains($0) }
                .map(\.rawValue),
            forKey: self.keys.hiddenDashboardSections)
    }

    public func isDashboardSectionVisible(_ section: TokenBarDashboardSection) -> Bool {
        !self.hiddenDashboardSections.contains(section)
    }

    public func setDashboardSection(_ section: TokenBarDashboardSection, isVisible: Bool) {
        guard self.isDashboardSectionVisible(section) != isVisible else { return }
        var hidden = self.hiddenDashboardSections
        if isVisible {
            hidden.remove(section)
        } else {
            hidden.insert(section)
        }
        self.hiddenDashboardSections = hidden
    }

    public func moveDashboardSection(_ section: TokenBarDashboardSection, by offset: Int) {
        guard let sourceIndex = self.dashboardSectionOrder.firstIndex(of: section) else { return }
        let (destinationIndex, overflow) = sourceIndex.addingReportingOverflow(offset)
        guard !overflow,
              self.dashboardSectionOrder.indices.contains(destinationIndex),
              destinationIndex != sourceIndex
        else { return }
        var order = self.dashboardSectionOrder
        order.remove(at: sourceIndex)
        order.insert(section, at: destinationIndex)
        self.dashboardSectionOrder = order
    }

    public func resetToDefaults() {
        self.theme = Self.defaultTheme
        self.recentSessionCount = Self.defaultRecentSessionCount
        self.refreshInterval = Self.defaultRefreshInterval
        self.statusBarTopMetric = Self.defaultStatusBarTopMetric
        self.statusBarBottomMetric = Self.defaultStatusBarBottomMetric
        self.showsStatusBarSpeedChart = Self.defaultShowsStatusBarSpeedChart
        self.statisticsTimeZone = Self.defaultStatisticsTimeZone
        self.showsClaude = Self.defaultShowsClaude
        self.showsGrok = Self.defaultShowsGrok
        self.showsAntigravity = Self.defaultShowsAntigravity
        self.usesWeekdayWeeklyPacing = Self.defaultUsesWeekdayWeeklyPacing
        self.showsFullRequestContentOnHover = Self.defaultShowsFullRequestContentOnHover
        self.monitorsCodexMemory = Self.defaultMonitorsCodexMemory
        self.resetCelebration = Self.defaultResetCelebration
        self.syncEnabled = Self.defaultSyncEnabled
        self.syncServerURL = Self.defaultSyncServerURL
        self.syncDeviceName = Self.defaultSyncDeviceName
        self.dashboardSectionOrder = Self.defaultDashboardSectionOrder
        self.hiddenDashboardSections = Self.defaultHiddenDashboardSections
    }

    private static func normalizedDashboardSectionOrder(_ storedValues: [String]?) -> [TokenBarDashboardSection] {
        let storedSections = storedValues?.compactMap(TokenBarDashboardSection.init(rawValue:)) ?? []
        var seen: Set<TokenBarDashboardSection> = []
        return (storedSections + Self.defaultDashboardSectionOrder).filter { seen.insert($0).inserted }
    }

    private struct Keys {
        let theme: String
        let recentSessionCount: String
        let refreshInterval: String
        let statusBarTopMetric: String
        let statusBarBottomMetric: String
        let showsStatusBarSpeedChart: String
        let statisticsTimeZone: String
        let showsClaude: String
        let showsGrok: String
        let showsAntigravity: String
        let usesWeekdayWeeklyPacing: String
        let showsFullRequestContentOnHover: String
        let monitorsCodexMemory: String
        let resetCelebration: String
        let syncEnabled: String
        let syncServerURL: String
        let syncDeviceName: String
        let syncDeviceID: String
        let dashboardSectionOrder: String
        let hiddenDashboardSections: String

        init(prefix: String) {
            self.theme = "\(prefix).theme"
            self.recentSessionCount = "\(prefix).recentSessionCount"
            self.refreshInterval = "\(prefix).refreshInterval"
            self.statusBarTopMetric = "\(prefix).statusBarTopMetric"
            self.statusBarBottomMetric = "\(prefix).statusBarBottomMetric"
            self.showsStatusBarSpeedChart = "\(prefix).showsStatusBarSpeedChart"
            self.statisticsTimeZone = "\(prefix).statisticsTimeZone"
            self.showsClaude = "\(prefix).showsClaude"
            self.showsGrok = "\(prefix).showsGrok"
            self.showsAntigravity = "\(prefix).showsAntigravity"
            self.usesWeekdayWeeklyPacing = "\(prefix).usesWeekdayWeeklyPacing"
            self.showsFullRequestContentOnHover = "\(prefix).showsFullRequestContentOnHover"
            self.monitorsCodexMemory = "\(prefix).monitorsCodexMemory"
            self.resetCelebration = "\(prefix).resetCelebration"
            self.syncEnabled = "\(prefix).syncEnabled"
            self.syncServerURL = "\(prefix).syncServerURL"
            self.syncDeviceName = "\(prefix).syncDeviceName"
            self.syncDeviceID = "\(prefix).syncDeviceID"
            self.dashboardSectionOrder = "\(prefix).dashboardSectionOrder"
            self.hiddenDashboardSections = "\(prefix).hiddenDashboardSections"
        }
    }
}
