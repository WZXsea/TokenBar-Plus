import AppKit
import Observation
import SwiftUI
import TokenBarCore

@MainActor
final class TokenBarStatusItemController: NSObject, NSMenuDelegate, TokenBarMenuPersistentActionDelegate {
    private static let menuWidth: CGFloat = 384
    private static let requestDetailCacheLimit = 64
    private static let sessionHistoryCacheLimit = 16

    private struct RenderedSessionProjection: Equatable {
        let ids: [String]
        let collapsedLimit: Int
    }

    private struct SessionHistoryKey: Hashable {
        let date: String
        let statisticsTimeZone: String
    }

    private struct ResetCreditsMenuContext: Equatable {
        let platform: TokenPlatform
        let snapshot: QuotaResetCreditsSnapshot
        let sampledAt: Date
    }

    private struct SyncSettingsSignature: Equatable {
        let enabled: Bool
        let serverURL: String
        let deviceName: String
        let deviceID: String
        let credentialRevision: Int

        @MainActor
        init(_ settings: TokenBarSettings, activitySync: ActivitySyncController) {
            self.enabled = settings.syncEnabled
            self.serverURL = settings.syncServerURL
            self.deviceName = settings.syncDeviceName
            self.deviceID = settings.syncDeviceID
            self.credentialRevision = activitySync.configurationRevision
        }
    }

    private let model: DashboardModel
    private let settings: TokenBarSettings
    private let memoryTelemetry: MemoryTelemetryController
    private let activitySync: ActivitySyncController
    private let pricingStore: ModelPricingStore
    private var pricingRevision: Int
    private let requestDetailService: any RequestDetailProviding
    private let sessionLauncher: SessionLauncher
    private let unreadTasks: DesktopUnreadTaskMonitor
    private var activityFileWatcher: ActivityFileWatcher?
    private let showSettingsAction: () -> Void
    private let statusItem: NSStatusItem
    private let rootMenu = TokenBarMenu()
    private var statusLabelLayout: StatusLabelLayout?
    private var statusBarContents: [StatusBarPlatformContent] = []
    private var statusSpeedExpiryTask: Task<Void, Never>?
    private var nextMenuScopeOverride: DashboardScope?
    private var sessionItems: [NSMenuItem] = []
    private var renderedSessionProjection: RenderedSessionProjection?
    private var renderedMenuScope: DashboardScope?
    private var submenuSessions: [ObjectIdentifier: SessionSummary] = [:]
    private var requestDetailMenus: [ObjectIdentifier: RequestDetailMenuContext] = [:]
    private var requestDetailTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var requestDetailCache: [String: RequestDetail] = [:]
    private var requestDetailCacheOrder: [String] = []
    private var sessionExpansionItem: NSMenuItem?
    private var sessionEmptyItem: NSMenuItem?
    private var activityDetailItem: NSMenuItem?
    private var activitySessionMenu: TokenBarMenu?
    private var activitySessionItems: [NSMenuItem] = []
    private var renderedActivitySessionProjection: RenderedSessionProjection?
    private var activitySessionExpansionItem: NSMenuItem?
    private var activitySessionExpansionView: PersistentMenuActionRowView?
    private var activitySessionEmptyItem: NSMenuItem?
    private var selectedSessionDate: String?
    private var sessionHistory: [SessionHistoryKey: [SessionSummary]] = [:]
    private var sessionHistoryErrors: [SessionHistoryKey: String] = [:]
    private var sessionHistoryOrder: [SessionHistoryKey] = []
    private var loadingSessionHistoryKey: SessionHistoryKey?
    private var sessionHistoryTask: Task<Void, Never>?
    private var memoryItem: NSMenuItem?
    private var summaryHosts: [TokenBarDashboardSection: FixedMenuHostingView] = [:]
    private var summaryItems: [TokenBarDashboardSection: NSMenuItem] = [:]
    private var resetCreditsItem: NSMenuItem?
    private var resetCreditsHost: FixedMenuHostingView?
    private var resetCreditsContext: ResetCreditsMenuContext?
    private var highlightedRows: [ObjectIdentifier: any TokenMenuHighlighting] = [:]
    private var showsAllActivitySessions = false
    private var isRootMenuOpen = false
    private var startupTask: Task<Void, Never>?
    private var shortcutMonitor: MenuTrackingShortcutMonitor?
    private var syncSettingsSignature: SyncSettingsSignature
    private var monitorsCodexMemory: Bool

    init(
        model: DashboardModel,
        settings: TokenBarSettings = .shared,
        memoryTelemetry: MemoryTelemetryController,
        activitySync: ActivitySyncController,
        showSettings: @escaping () -> Void,
        requestDetailService: any RequestDetailProviding = CodexRequestDetailService(),
        sessionLauncher: SessionLauncher = SessionLauncher(),
        unreadTasks: DesktopUnreadTaskMonitor = DesktopUnreadTaskMonitor(),
        pricingStore: ModelPricingStore = .shared)
    {
        self.model = model
        self.settings = settings
        self.memoryTelemetry = memoryTelemetry
        self.activitySync = activitySync
        self.pricingStore = pricingStore
        self.pricingRevision = pricingStore.revision
        self.showSettingsAction = showSettings
        self.requestDetailService = requestDetailService
        self.sessionLauncher = sessionLauncher
        self.unreadTasks = unreadTasks
        self.syncSettingsSignature = SyncSettingsSignature(
            settings,
            activitySync: activitySync)
        self.monitorsCodexMemory = settings.monitorsCodexMemory
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.rootMenu.autoenablesItems = false
        self.rootMenu.minimumWidth = Self.menuWidth
        self.rootMenu.delegate = self
        self.rootMenu.persistentActionDelegate = self
        self.statusItem.menu = self.rootMenu
        self.configureStatusButton()
        self.model.updateBackgroundRefreshInterval(settings.backgroundRefreshDuration)
        self.model.updateStatisticsTimeZone(settings.statisticsTimeZone)
        self.model.updateQuotaRefreshEnabled(settings.showsClaude, for: .claude)
        self.model.updateQuotaRefreshEnabled(settings.showsGrok, for: .grok)
        self.model.updateQuotaRefreshEnabled(
            settings.showsAntigravity,
            for: .antigravity)
        self.rebuildRootMenu()
        self.observeModel()
        self.observeScope()
        self.observeSettings()
        self.observeUnreadTasks()
    }

    func start() {
        if self.activityFileWatcher == nil {
            let watcher = ActivityFileWatcher { [weak self] in
                Task { @MainActor [weak self] in
                    self?.model.notifyActivityChanged()
                }
            }
            self.activityFileWatcher = watcher
            watcher.start()
        }
        self.unreadTasks.start()
        self.startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.start()
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            let demoScope = environment["TOKENBAR_DEMO_SCOPE"]
                .flatMap(DashboardScope.init(rawValue:)) ?? .codex
            if environment["TOKENBAR_DEMO_OPEN_MENU"] == "1" {
                self.nextMenuScopeOverride = demoScope
                try? await Task.sleep(for: .milliseconds(250))
                self.statusItem.button?.performClick(nil)
            }
            #endif
        }
    }

    func tearDown() {
        self.statusSpeedExpiryTask?.cancel()
        self.statusSpeedExpiryTask = nil
        self.activityFileWatcher?.stop()
        self.activityFileWatcher = nil
        self.unreadTasks.stop()
        self.startupTask?.cancel()
        self.startupTask = nil
        self.cancelSessionHistoryLoad()
        self.removeShortcutMonitor()
        self.discardRequestDetailMenus(in: self.rootMenu)
        self.rootMenu.delegate = nil
        self.rootMenu.persistentActionDelegate = nil
        self.statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(self.statusItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.rootMenu {
            let requestedScope = self.nextMenuScopeOverride ?? self.scopeForCurrentStatusClick()
            self.nextMenuScopeOverride = nil
            if let requestedScope {
                self.model.scope = requestedScope
            }
            if !self.visibleScopes.contains(self.model.scope) {
                self.model.scope = .codex
            }
            self.rebuildRootMenu()
            return
        }

        if menu === self.resetCreditsItem?.submenu {
            self.updateResetCreditsItem(for: self.model.scope)
            return
        }

        let menuID = ObjectIdentifier(menu)
        if let context = self.requestDetailMenus[menuID] {
            self.prepareRequestDetailView(context)
            return
        }

        guard let session = self.submenuSessions[menuID] else { return }
        self.rebuildRequestMenu(menu, session: session)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.rootMenu {
            self.isRootMenuOpen = true
            self.installShortcutMonitor()
            self.unreadTasks.refresh()
            Task { @MainActor [weak self] in
                await self?.model.refreshAll(forceQuota: false)
            }
            return
        }

        let menuID = ObjectIdentifier(menu)
        if self.requestDetailMenus[menuID] != nil {
            for (otherMenuID, task) in self.requestDetailTasks where otherMenuID != menuID {
                task.cancel()
            }
        }
        self.loadRequestDetailIfNeeded(menuID: menuID)
    }

    func menuDidClose(_ menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        if self.requestDetailMenus[menuID] != nil {
            self.requestDetailTasks[menuID]?.cancel()
        }
        self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
        if menu === self.rootMenu {
            self.isRootMenuOpen = false
            self.removeShortcutMonitor()
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let menuID = ObjectIdentifier(menu)
        self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
        guard let row = item?.view as? any TokenMenuHighlighting else { return }
        row.setMenuHighlighted(true)
        self.highlightedRows[menuID] = row
    }

    nonisolated func performPersistentRefresh() {
        Task { @MainActor [weak self] in
            await self?.refreshAllIncludingSelectedSessions()
        }
    }

    private func installShortcutMonitor() {
        self.removeShortcutMonitor()
        let monitor = MenuTrackingShortcutMonitor(events: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.isRootMenuOpen else { return false }
            return self.rootMenu.handlePersistentShortcut(event)
        }
        monitor.start()
        self.shortcutMonitor = monitor
    }

    private func removeShortcutMonitor() {
        self.shortcutMonitor?.stop()
        self.shortcutMonitor = nil
    }

    private func configureStatusButton() {
        guard let button = self.statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        self.updateStatusButton()
    }

    private var visibleScopes: [DashboardScope] {
        DashboardScope.visibleScopes(
            showsClaude: self.settings.showsClaude,
            showsGrok: self.settings.showsGrok,
            showsAntigravity: self.settings.showsAntigravity,
            showsZCode: self.settings.showsZCode)
    }

    private static func isSpeedMetric(_ metric: TokenBarStatusMetric) -> Bool {
        metric == .latestSpeed || metric == .todayAverageSpeed
    }

    private func updateStatusButton() {
        guard let button = self.statusItem.button else { return }
        var toolTips: [String] = []
        let now = Date()
        var activeDeadlines: [Date] = []
        let contents = self.visibleScopes.map { scope in
            let platform = scope.platform
            let snapshot = self.model.activitySnapshot
            let quota = self.model.quotaState(for: platform).value
            let activity = StatusBarSpeedActivity(snapshot: snapshot, platform: platform, now: now)
            let top = StatusBarMetricPresentation(
                metric: self.settings.statusBarTopMetric, snapshot: snapshot, quota: quota, platform: platform, speedActivity: activity)
            let bottom = StatusBarMetricPresentation(
                metric: self.settings.statusBarBottomMetric, snapshot: snapshot, quota: quota, platform: platform, speedActivity: activity)
            let modelSpeeds = SpeedModelPresentation(snapshot: snapshot, platform: platform, limit: 30)
            let points = self.settings.showsStatusBarSpeedChart
                ? Array(modelSpeeds.points.suffix(30))
                : nil
            let chartScale = points.map { SpeedChartScale(points: $0) }
            if activity.isActive, let deadline = activity.activeUntil { activeDeadlines.append(deadline) }
            let speedTone = StatusSpeedTone(isActive: activity.isActive, tokensPerSecond: activity.tokensPerSecond)
            let unread = self.unreadTasks.count(for: platform)
            var details = [top.detailText, bottom.detailText].compactMap { $0 }
            for sample in modelSpeeds.latestModelSamples {
                let time = Date(timeIntervalSince1970: Double(sample.endedAtMs) / 1_000)
                    .formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second())
                details.append("\(sample.model)：\(SpeedSummaryPresentation.rateValueText(sample.tokensPerSecond)) tok/s · \(time)")
            }
            if let points {
                details.append("速率曲线：最近最多30轮·逐轮采样，当前 \(points.count) 个有效样本（tok/s）")
                details.append(points.isEmpty
                    ? "等待速度样本"
                    : "按轮次顺序等距连接；统计输出与推理 token，按模型请求计时")
                if let chartScale, !chartScale.overflowIndices.isEmpty {
                    let peak = points.map(\.tokensPerSecond).max() ?? 0
                    details.append("↑ \(chartScale.overflowIndices.count) 个样本超出常规显示范围，原始峰值 \(SpeedSummaryPresentation.rateValueText(peak)) tok/s")
                }
            }
            if platform == .zcode, points != nil,
               !Self.isSpeedMetric(self.settings.statusBarTopMetric),
               !Self.isSpeedMetric(self.settings.statusBarBottomMetric) {
                details.append(SpeedSummaryPresentation.helpText(for: platform))
            }
            let name = switch scope {
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .grok: "Grok Build"
            case .antigravity: "Antigravity"
            case .zcode: "ZCode"
            }
            toolTips.append(name + (details.isEmpty ? "" : " · " + details.joined(separator: " · "))
                + Self.unreadStatusText(unread).toolTip)
            return StatusBarPlatformContent(
                scope: scope, top: top.compactText, bottom: bottom.compactText,
                unreadCount: unread, trendRates: points?.map(\.tokensPerSecond),
                trendMaximum: chartScale?.maximum,
                speedTone: speedTone,
                topIsSpeed: Self.isSpeedMetric(self.settings.statusBarTopMetric),
                bottomIsSpeed: Self.isSpeedMetric(self.settings.statusBarBottomMetric))
        }
        self.scheduleStatusSpeedExpiry(at: activeDeadlines.min(), now: now)
        self.statusBarContents = contents
        var layout: StatusLabelLayout!
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            layout = StatusLabelRenderer.layout(contents: contents)
        }
        self.statusLabelLayout = layout
        button.image = layout.image
        button.toolTip = toolTips.joined(separator: "\n")
        button.setAccessibilityLabel(toolTips.joined(separator: "。"))
    }

    private func scheduleStatusSpeedExpiry(at deadline: Date?, now: Date) {
        self.statusSpeedExpiryTask?.cancel()
        self.statusSpeedExpiryTask = nil
        guard let deadline, deadline > now else { return }
        let delay = deadline.timeIntervalSince(now)
        self.statusSpeedExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.updateStatusButton()
        }
    }

    private static func unreadStatusText(_ count: Int) -> (toolTip: String, accessibility: String) {
        guard count > 0 else { return ("", "") }
        return (
            " · 待阅：\(count)",
            " 已完成待阅任务 \(count) 个。")
    }

    func celebrationOriginPoint(for platform: TokenPlatform) -> CGPoint? {
        guard let button = self.statusItem.button,
              let window = button.window,
              let image = button.image,
              let layout = self.statusLabelLayout
        else {
            return nil
        }

        let imageX = layout.centerX(for: platform) ?? image.size.width / 2
        let imageMinX = button.bounds.midX - image.size.width / 2
        let buttonPoint = CGPoint(x: imageMinX + imageX, y: button.bounds.midY)
        let windowPoint = button.convert(buttonPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func scopeForCurrentStatusClick() -> DashboardScope? {
        guard self.visibleScopes.count > 1,
              let button = self.statusItem.button,
              let window = button.window,
              let layout = self.statusLabelLayout
        else {
            return nil
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = button.convert(windowPoint, from: nil)
        return layout.scope(at: point, in: button.bounds, eventType: NSApp.currentEvent?.type)
    }

    private func observeModel() {
        withObservationTracking {
            _ = self.model.quotas
            _ = self.model.activity
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeModel()
                self.modelDidChange()
            }
        }
    }

    private func observeUnreadTasks() {
        withObservationTracking {
            _ = self.unreadTasks.counts
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeUnreadTasks()
                self.updateStatusButton()
            }
        }
    }

    private func observeScope() {
        withObservationTracking {
            _ = self.model.scope
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeScope()
                guard self.isRootMenuOpen else { return }
                self.updateMemoryVisibility(scope: self.model.scope)
                guard self.renderedMenuScope != self.model.scope else {
                    return
                }
                self.updateOverviewHeight()
                self.updateVisibleSessionItems()
            }
        }
    }

    private func observeSettings() {
        withObservationTracking {
            _ = self.settings.theme
            _ = self.settings.recentSessionCount
            _ = self.settings.refreshInterval
            _ = self.settings.statisticsTimeZone
            _ = self.settings.showsClaude
            _ = self.settings.showsGrok
            _ = self.settings.showsAntigravity
            _ = self.settings.showsZCode
            _ = self.settings.usesWeekdayWeeklyPacing
            _ = self.settings.showsFullRequestContentOnHover
            _ = self.settings.monitorsCodexMemory
            _ = self.settings.dashboardSectionOrder
            _ = self.settings.hiddenDashboardSections
            _ = self.settings.statusBarTopMetric
            _ = self.settings.statusBarBottomMetric
            _ = self.settings.showsStatusBarSpeedChart
            _ = self.settings.syncEnabled
            _ = self.settings.syncServerURL
            _ = self.settings.syncDeviceName
            _ = self.settings.syncDeviceID
            _ = self.activitySync.configurationRevision
            _ = self.pricingStore.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeSettings()
                if self.pricingRevision != self.pricingStore.revision {
                    self.pricingRevision = self.pricingStore.revision
                    self.resetSessionHistory()
                    Task { @MainActor [weak self] in
                        await self?.model.restartActivityRefresh()
                    }
                }
                let syncSettingsSignature = SyncSettingsSignature(
                    self.settings,
                    activitySync: self.activitySync)
                if syncSettingsSignature != self.syncSettingsSignature {
                    self.syncSettingsSignature = syncSettingsSignature
                    Task { @MainActor [weak self] in
                        await self?.model.restartActivityRefresh()
                    }
                }
                if self.monitorsCodexMemory != self.settings.monitorsCodexMemory {
                    self.monitorsCodexMemory = self.settings.monitorsCodexMemory
                    if self.monitorsCodexMemory {
                        self.memoryTelemetry.start()
                    } else {
                        self.memoryTelemetry.stop()
                    }
                    Task { @MainActor [weak self] in
                        await self?.model.restartActivityRefresh()
                    }
                }
                self.model.updateBackgroundRefreshInterval(self.settings.backgroundRefreshDuration)
                if self.model.updateStatisticsTimeZone(self.settings.statisticsTimeZone) {
                    self.resetSessionHistory()
                    Task { @MainActor [weak self] in
                        await self?.model.refreshActivity()
                    }
                }
                let claudeQuotaSettingChanged = self.model.updateQuotaRefreshEnabled(
                    self.settings.showsClaude,
                    for: .claude)
                if claudeQuotaSettingChanged, self.settings.showsClaude {
                    Task { @MainActor [weak self] in
                        await self?.model.refreshQuota(for: .claude)
                    }
                }
                let grokQuotaSettingChanged = self.model.updateQuotaRefreshEnabled(
                    self.settings.showsGrok,
                    for: .grok)
                if grokQuotaSettingChanged, self.settings.showsGrok {
                    Task { @MainActor [weak self] in
                        await self?.model.refreshQuota(for: .grok)
                    }
                }
                let antigravityQuotaSettingChanged = self.model.updateQuotaRefreshEnabled(
                    self.settings.showsAntigravity,
                    for: .antigravity)
                if antigravityQuotaSettingChanged, self.settings.showsAntigravity {
                    Task { @MainActor [weak self] in
                        await self?.model.refreshQuota(for: .antigravity)
                    }
                }
                if !self.visibleScopes.contains(self.model.scope) {
                    self.model.scope = .codex
                }
                self.updateStatusButton()
                if self.isRootMenuOpen {
                    self.rebuildRootMenu()
                }
            }
        }
    }

    private func modelDidChange() {
        self.updateStatusButton()
        guard self.isRootMenuOpen else { return }
        self.updateOverviewHeight()
        self.updateVisibleSessionItems()
    }

    private func updateOverviewHeight() {
        self.updateSummaryHeights(for: self.model.scope)
    }

    private var mergesWeeklyUsageIntoQuota: Bool {
        self.settings.isDashboardSectionVisible(.quota)
            && self.settings.isDashboardSectionVisible(.weeklyReset)
    }

    private func updateSummaryHeights(for scope: DashboardScope) {
        let quota = self.model.quotaState(for: scope.platform).value
        for (section, host) in self.summaryHosts {
            host.updateHeight(DashboardSectionContentView.preferredHeight(
                for: section,
                quota: quota,
                showsResetCredits: false,
                showsWeeklyUsage: section == .quota && self.mergesWeeklyUsageIntoQuota,
                providesQuota: self.model.providesQuota(for: scope.platform)))
        }
        self.summaryItems[.quota]?.isHidden = !self.model.providesQuota(for: scope.platform)
        self.summaryItems[.weeklyReset]?.isHidden = !self.model.providesQuota(for: scope.platform)
        self.updateResetCreditsItem(for: scope)
    }

    private func selectScope(_ scope: DashboardScope) {
        guard scope != self.model.scope else { return }
        let window = self.rootMenu.items.first?.view?.window
        window?.disableScreenUpdatesUntilFlush()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            self.updateSummaryHeights(for: scope)
            self.updateMemoryVisibility(scope: scope)
            self.updateSessionProjectionAndVisibility(scope: scope)
            self.updateActivitySessionProjectionAndVisibility(scope: scope)
            self.model.scope = scope
            window?.layoutIfNeeded()
        }
    }

    private func rebuildRootMenu() {
        self.discardRequestDetailMenus(in: self.rootMenu)
        for row in self.highlightedRows.values {
            row.setMenuHighlighted(false)
        }
        self.highlightedRows.removeAll()
        self.rootMenu.removeAllItems()
        self.sessionItems.removeAll()
        self.renderedSessionProjection = nil
        self.renderedMenuScope = nil
        self.sessionExpansionItem = nil
        self.sessionEmptyItem = nil
        self.activityDetailItem = nil
        self.activitySessionMenu = nil
        self.activitySessionItems.removeAll()
        self.renderedActivitySessionProjection = nil
        self.activitySessionExpansionItem = nil
        self.activitySessionExpansionView = nil
        self.activitySessionEmptyItem = nil
        self.memoryItem = nil
        self.summaryHosts.removeAll()
        self.summaryItems.removeAll()
        self.resetCreditsItem = nil
        self.resetCreditsHost = nil
        self.resetCreditsContext = nil
        self.submenuSessions.removeAll()

        let accentColor = self.settings.theme.color
        let headerHeight = DashboardLayout.headerHeight(
            showsClaude: self.settings.showsClaude,
            showsGrok: self.settings.showsGrok,
            showsAntigravity: self.settings.showsAntigravity,
            showsZCode: self.settings.showsZCode)
        let header = DashboardHeaderView(
            model: self.model,
            showsClaude: self.settings.showsClaude,
            showsGrok: self.settings.showsGrok,
            showsAntigravity: self.settings.showsAntigravity,
            showsZCode: self.settings.showsZCode,
            accentColor: accentColor,
            onSelectScope: { [weak self] scope in
                self?.selectScope(scope)
            })
            .frame(
                width: Self.menuWidth,
                height: headerHeight,
                alignment: .top)
        let headerHost = FixedMenuHostingView(
            rootView: AnyView(header),
            width: Self.menuWidth,
            height: headerHeight)
        let headerItem = NSMenuItem()
        headerItem.view = headerHost
        headerItem.isEnabled = true
        self.rootMenu.addItem(headerItem)

        for section in self.settings.visibleDashboardSections
            where section != .weeklyReset || !self.mergesWeeklyUsageIntoQuota
        {
            self.addDashboardSection(section, accentColor: accentColor)
        }
        self.updateSummaryHeights(for: self.model.scope)
        self.rootMenu.addItem(.separator())

        let refresh = NSMenuItem(title: "立即刷新", action: nil, keyEquivalent: "")
        let refreshView = PersistentMenuActionRowView(
            width: Self.menuWidth,
            title: "立即刷新",
            systemImageName: "arrow.clockwise",
            shortcut: "⌘R",
            accessibilityHelp: "在当前菜单中刷新。快捷键 ⌘R。")
        refreshView.onActivate = { [weak self] in
            self?.refreshNow()
        }
        refresh.view = refreshView
        refresh.isEnabled = true
        refresh.toolTip = "在当前菜单中刷新（⌘R）"
        self.rootMenu.addItem(refresh)

        let settings = NSMenuItem(
            title: "设置…",
            action: #selector(self.showSettings),
            keyEquivalent: ",")
        settings.target = self
        settings.keyEquivalentModifierMask = [.command]
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        self.rootMenu.addItem(settings)

        let quit = NSMenuItem(title: "退出 TokenBar", action: #selector(self.quit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        self.rootMenu.addItem(quit)
    }

    private static func sectionIdentifier(_ section: TokenBarDashboardSection) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("dashboard." + section.rawValue)
    }

    private func addDashboardSection(_ section: TokenBarDashboardSection, accentColor: Color) {
        switch section {
        case .speed, .quota, .today, .weeklyReset:
            let height = DashboardSectionContentView.preferredHeight(
                for: section,
                quota: self.model.quotaState(for: self.model.scope.platform).value,
                showsResetCredits: false,
                showsWeeklyUsage: section == .quota && self.mergesWeeklyUsageIntoQuota,
                providesQuota: self.model.providesQuota(for: self.model.scope.platform))
            let content = DashboardSectionContentView(
                section: section,
                model: self.model,
                usesWeekdayWeeklyPacing: self.settings.usesWeekdayWeeklyPacing,
                accentColor: accentColor,
                showsResetCredits: false,
                showsWeeklyUsage: section == .quota && self.mergesWeeklyUsageIntoQuota)
                .frame(width: Self.menuWidth, alignment: .top)
            let host = FixedMenuHostingView(
                rootView: AnyView(content),
                width: Self.menuWidth,
                height: height)
            let item = NSMenuItem(title: section.displayName, action: nil, keyEquivalent: "")
            item.identifier = Self.sectionIdentifier(section)
            item.view = host
            item.isEnabled = true
            self.summaryHosts[section] = host
            self.summaryItems[section] = item
            self.rootMenu.addItem(item)
            if section == .quota {
                self.addResetCreditsItem()
            }
        case .activity:
            self.addActivitySection(accentColor: accentColor)
        case .memory:
            self.addMemorySection(accentColor: accentColor)
        case .recentSessions:
            self.rootMenu.addItem(.separator())
            let header = NSMenuItem.sectionHeader(title: section.displayName)
            header.identifier = Self.sectionIdentifier(section)
            self.rootMenu.addItem(header)
            self.addSessionItems()
        }
    }

    private func addResetCreditsItem() {
        let host = FixedMenuHostingView(
            rootView: AnyView(EmptyView()),
            width: Self.menuWidth,
            height: ResetCreditsMenuRowView.preferredHeight)
        let item = NSMenuItem(title: "额外重置", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("dashboard.quota.resetCredits")
        item.view = host
        item.isEnabled = true
        item.isHidden = true
        item.toolTip = "点击或悬停查看全部额外重置记录"
        self.resetCreditsHost = host
        self.resetCreditsItem = item
        self.rootMenu.addItem(item)
    }

    private func updateResetCreditsItem(for scope: DashboardScope) {
        guard let item = self.resetCreditsItem else { return }
        guard self.model.providesQuota(for: scope.platform),
              let quota = self.model.quotaState(for: scope.platform).value,
              let snapshot = quota.resetCredits
        else {
            item.isHidden = true
            item.submenu = nil
            item.representedObject = nil
            self.resetCreditsContext = nil
            return
        }
        item.isHidden = false
        let context = ResetCreditsMenuContext(platform: scope.platform, snapshot: snapshot, sampledAt: quota.updatedAt)
        guard self.resetCreditsContext != context || item.submenu == nil else { return }
        self.resetCreditsContext = context
        item.representedObject = snapshot
        self.resetCreditsHost?.rootView = AnyView(
            ResetCreditsMenuRowView(snapshot: snapshot)
                .allowsHitTesting(false))
        item.submenu = self.makeResetCreditsDetailMenu(
            snapshot: snapshot,
            sampledAt: quota.updatedAt,
            reusing: item.submenu as? TokenBarMenu)
    }

    private func makeResetCreditsDetailMenu(
        snapshot: QuotaResetCreditsSnapshot,
        sampledAt: Date,
        reusing existing: TokenBarMenu? = nil) -> TokenBarMenu
    {
        let menu = existing ?? TokenBarMenu(title: "额外重置")
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.minimumWidth = ResetCreditsDetailView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self
        menu.addItem(self.resetCreditsDetailItem(
            title: "额外重置 · \(ResetCreditsDetailPresentation.countText(snapshot))",
            content: ResetCreditsDetailHeaderView(snapshot: snapshot),
            height: ResetCreditsDetailHeaderView.preferredHeight(for: snapshot)))
        menu.addItem(.separator())
        if snapshot.credits.isEmpty {
            menu.addItem(self.resetCreditsDetailItem(
                title: ResetCreditsDetailPresentation.emptyText(snapshot),
                content: ResetCreditsDetailEmptyView(snapshot: snapshot),
                height: ResetCreditsDetailEmptyView.preferredHeight))
        } else {
            for (index, credit) in snapshot.credits.enumerated() {
                let entry = self.resetCreditsDetailItem(
                    title: ResetCreditsDetailPresentation.title(for: credit, index: index, sampledAt: sampledAt),
                    content: ResetCreditDetailEntryView(credit: credit, index: index, sampledAt: sampledAt),
                    height: ResetCreditDetailEntryView.preferredHeight)
                entry.identifier = NSUserInterfaceItemIdentifier("resetCredit.\(index)")
                entry.representedObject = credit
                entry.toolTip = "服务端状态：\(credit.status)\n\(ResetCreditsDetailPresentation.expirationText(for: credit))"
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(self.resetCreditsDetailItem(
            title: "采样：\(ResetCreditsDetailPresentation.timestampText(sampledAt))",
            content: ResetCreditsDetailFooterView(sampledAt: sampledAt),
            height: ResetCreditsDetailFooterView.preferredHeight))
        return menu
    }

    private func resetCreditsDetailItem<Content: View>(
        title: String,
        content: Content,
        height: CGFloat) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = FixedMenuHostingView(
            rootView: AnyView(content.allowsHitTesting(false)),
            width: ResetCreditsDetailView.preferredWidth,
            height: height)
        return item
    }

    private func addActivitySection(accentColor: Color) {
        let activityHeight = ActivitySummarySection.preferredHeight + 1
        let activity = MenuActivitySummaryView(
            model: self.model,
            accentColor: accentColor)
        .frame(width: Self.menuWidth, height: activityHeight, alignment: .top)
        let activityHost = FixedMenuHostingView(
            rootView: AnyView(activity),
            width: Self.menuWidth,
            height: activityHeight)
        let activityItem = NSMenuItem(
            title: "使用记录",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        activityItem.identifier = Self.sectionIdentifier(.activity)
        activityItem.target = self
        activityItem.isEnabled = true
        activityItem.view = activityHost
        activityItem.submenu = self.makeActivityDetailMenu(accentColor: accentColor)
        self.rootMenu.addItem(activityItem)
    }

    private func addMemorySection(accentColor: Color) {
        if self.settings.monitorsCodexMemory {
            let memoryHeight = MemorySummarySection.preferredHeight + 1
            let memory = MenuMemorySummaryView(
                model: self.model,
                telemetry: self.memoryTelemetry,
                accentColor: accentColor)
                .allowsHitTesting(false)
                .frame(width: Self.menuWidth, height: memoryHeight, alignment: .top)
            let memoryHost = FixedMenuHostingView(
                rootView: AnyView(memory),
                width: Self.menuWidth,
                height: memoryHeight)
            let memoryItem = NSMenuItem(
                title: "Codex 记忆",
                action: #selector(self.activityNoOp),
                keyEquivalent: "")
            memoryItem.identifier = Self.sectionIdentifier(.memory)
            memoryItem.target = self
            memoryItem.isEnabled = true
            memoryItem.view = memoryHost
            memoryItem.submenu = self.makeMemoryDetailMenu(accentColor: accentColor)
            memoryItem.isHidden = !self.model.scope.supportsCodexMemory
            self.memoryItem = memoryItem
            self.rootMenu.addItem(memoryItem)
        }
    }

    private func addSessionItems() {
        let sessions = self.model.activitySnapshot?
            .sessionMenu(limit: nil).visibleSessions ?? []
        let empty = NSMenuItem(title: "今日会话待生成", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        empty.isHidden = !sessions.isEmpty
        self.sessionEmptyItem = empty
        self.rootMenu.addItem(empty)

        let maximumPlatformSessionCount = Dictionary(grouping: sessions, by: \.platformID)
            .values
            .map(\.count)
            .max() ?? 0
        let slotCount = max(self.settings.recentSessionLimit, maximumPlatformSessionCount)
        for _ in 0 ..< slotCount {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.sessionItems.append(item)
            self.rootMenu.addItem(item)
        }

        let expansionItem = NSMenuItem(title: "更多会话", action: nil, keyEquivalent: "")
        expansionItem.isEnabled = true
        expansionItem.isHidden = true
        let overflow = TokenBarMenu(title: "更多会话")
        overflow.autoenablesItems = false
        overflow.minimumWidth = Self.menuWidth
        overflow.delegate = self
        overflow.persistentActionDelegate = self
        expansionItem.submenu = overflow
        self.sessionExpansionItem = expansionItem
        self.rootMenu.addItem(expansionItem)
        self.updateSessionProjectionAndVisibility()
    }

    private func makeActivityDetailMenu(accentColor: Color) -> TokenBarMenu {
        self.normalizeSelectedSessionDate()
        let menu = TokenBarMenu(title: "使用记录详情")
        menu.autoenablesItems = false
        menu.minimumWidth = ActivityDetailView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detail = ActivityDetailView(
            model: self.model,
            usesWeekdayWeeklyPacing: self.settings.usesWeekdayWeeklyPacing,
            accentColor: accentColor,
            initialSelectedDate: self.selectedSessionDate,
            onSelectDate: { [weak self] date in
                self?.selectActivityDate(date)
            })
            .frame(
                width: ActivityDetailView.preferredWidth,
                height: ActivityDetailView.preferredHeight,
                alignment: .topLeading)
        let host = FixedMenuHostingView(
            rootView: AnyView(detail),
            width: ActivityDetailView.preferredWidth,
            height: ActivityDetailView.preferredHeight)
        let item = NSMenuItem(
            title: "使用记录详情",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.view = host

        let sessionMenu = TokenBarMenu(title: self.activitySessionHeaderTitle)
        sessionMenu.autoenablesItems = false
        sessionMenu.minimumWidth = Self.menuWidth
        sessionMenu.delegate = self
        sessionMenu.persistentActionDelegate = self
        item.submenu = sessionMenu
        self.activityDetailItem = item
        self.activitySessionMenu = sessionMenu
        menu.addItem(item)
        self.addActivitySessionItems(to: sessionMenu)
        return menu
    }

    private func addActivitySessionItems(to menu: TokenBarMenu) {
        let empty = NSMenuItem(title: "会话待生成", action: nil, keyEquivalent: "")
        empty.isEnabled = false
        self.activitySessionEmptyItem = empty
        menu.addItem(empty)

        let maximumDailySessionCount = self.model.activitySnapshot?
            .sourceSnapshots
            .flatMap(\.days)
            .map(\.sessionCount)
            .max()
            ?? self.model.activitySnapshot?.days.map(\.sessionCount).max()
            ?? 0
        let slotCount = max(self.settings.recentSessionLimit, maximumDailySessionCount)
        for _ in 0 ..< slotCount {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.activitySessionItems.append(item)
            menu.addItem(item)
        }

        let expansion = PersistentMenuActionRowView(
            width: Self.menuWidth,
            title: "显示更多…",
            systemImageName: "chevron.down",
            accessibilityHelp: "在当前菜单中展开或收起所选日期的会话。")
        expansion.onActivate = { [weak self] in
            self?.toggleActivitySessionExpansion()
        }
        let expansionItem = NSMenuItem(title: "显示更多…", action: nil, keyEquivalent: "")
        expansionItem.isEnabled = true
        expansionItem.isHidden = true
        expansionItem.view = expansion
        self.activitySessionExpansionItem = expansionItem
        self.activitySessionExpansionView = expansion
        menu.addItem(expansionItem)

        self.updateActivitySessionProjectionAndVisibility()
        self.loadSessionHistoryIfNeeded()
    }

    private func toggleActivitySessionExpansion() {
        guard let projection = self.renderedActivitySessionProjection else { return }
        self.showsAllActivitySessions.toggle()
        for (index, item) in self.activitySessionItems.enumerated() {
            item.isHidden = index >= projection.ids.count
                || (!self.showsAllActivitySessions && index >= projection.collapsedLimit)
        }
        let title = self.activitySessionExpansionTitle(projection: projection)
        self.activitySessionExpansionItem?.title = title
        self.activitySessionExpansionView?.configure(
            title: title,
            systemImageName: self.showsAllActivitySessions ? "chevron.up" : "chevron.down",
            accessibilityHelp: "在当前菜单中展开或收起所选日期的会话。")
    }

    private func activitySessionExpansionTitle(
        projection: RenderedSessionProjection) -> String
    {
        if self.showsAllActivitySessions {
            return "显示前 \(projection.collapsedLimit) 个"
        }
        return "再显示 \(max(0, projection.ids.count - projection.collapsedLimit)) 个…"
    }

    private func makeMemoryDetailMenu(accentColor: Color) -> TokenBarMenu {
        let menu = TokenBarMenu(title: "Codex 记忆")
        menu.autoenablesItems = false
        menu.minimumWidth = MemoryDetailView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detail = MemoryDetailView(
            model: self.model,
            telemetry: self.memoryTelemetry,
            accentColor: accentColor)
            .frame(
                width: MemoryDetailView.preferredWidth,
                height: MemoryDetailView.preferredHeight,
                alignment: .topLeading)
        let host = FixedMenuHostingView(
            rootView: AnyView(detail),
            width: MemoryDetailView.preferredWidth,
            height: MemoryDetailView.preferredHeight)
        let item = NSMenuItem(
            title: "Codex 记忆",
            action: #selector(self.activityNoOp),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.view = host
        menu.addItem(item)
        return menu
    }

    private func updateMemoryVisibility(scope: DashboardScope) {
        let isHidden = !self.settings.monitorsCodexMemory
            || !self.settings.isDashboardSectionVisible(.memory)
            || !scope.supportsCodexMemory
        if self.memoryItem?.isHidden != isHidden {
            self.memoryItem?.isHidden = isHidden
        }
    }

    private func makeSessionItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "会话",
            action: #selector(self.openSession(_:)),
            keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.view = TokenMenuRowView(width: Self.menuWidth, compact: true)
        item.submenu = self.makeSessionSubmenu(title: "会话")
        return item
    }

    private func makeSessionSubmenu(title: String) -> TokenBarMenu {
        let submenu = TokenBarMenu(title: title)
        submenu.autoenablesItems = false
        submenu.minimumWidth = Self.menuWidth
        submenu.delegate = self
        submenu.persistentActionDelegate = self
        submenu.addItem(NSMenuItem(title: "正在加载轮次…", action: nil, keyEquivalent: ""))
        return submenu
    }

    private func bindSessionSubmenu(_ item: NSMenuItem, to session: SessionSummary) {
        let sessionID = session.platformScopedID
        var submenu = item.submenu
        if let current = submenu {
            let menuID = ObjectIdentifier(current)
            if let previousSession = self.submenuSessions[menuID],
               previousSession.platformScopedID != sessionID
            {
                self.discardRequestDetailMenus(in: current)
                self.submenuSessions.removeValue(forKey: menuID)
                self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
                current.delegate = nil
                (current as? TokenBarMenu)?.persistentActionDelegate = nil
                item.submenu = nil
                submenu = nil
            }
        }
        if submenu == nil {
            let replacement = self.makeSessionSubmenu(title: session.menuDisplayTitle)
            item.submenu = replacement
            submenu = replacement
        }
        guard let submenu else { return }
        submenu.title = session.menuDisplayTitle
        self.submenuSessions[ObjectIdentifier(submenu)] = session
    }

    private func unbindSessionSubmenu(_ item: NSMenuItem) {
        guard let submenu = item.submenu else { return }
        self.discardRequestDetailMenus(in: submenu)
        let menuID = ObjectIdentifier(submenu)
        self.submenuSessions.removeValue(forKey: menuID)
        self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
        submenu.delegate = nil
        (submenu as? TokenBarMenu)?.persistentActionDelegate = nil
        item.submenu = nil
    }

    private func configureSessionItem(_ item: NSMenuItem, session: SessionSummary) {
        let title = session.menuDisplayTitle
        let detail = session.tokens.total.compactCount
        let time = Date(timeIntervalSince1970: Double(session.endedAtMs) / 1000).menuClockText
        let isRemote = session.isSynchronizedRemote
        item.representedObject = session
        item.action = isRemote ? nil : #selector(self.openSession(_:))

        let row = (item.view as? TokenMenuRowView) ?? TokenMenuRowView(width: Self.menuWidth, compact: true)
        row.configure(
            title: title,
            cost: session.menuCostText,
            detail: detail,
            trailing: time,
            showsChevron: true,
            badge: session.menuServiceTierBadge,
            rate: nil)
        row.toolTip = isRemote
            ? "\(title)\n\(session.menuDetail)\n结束于 \(time)\n同步会话（仅查看）· 悬停查看轮次"
            : "\(title)\n\(session.menuDetail)\n结束于 \(time)\n"
                + (session.platformID == .zcode ? "点击打开 ZCode 应用" : "点击在 \(session.platformID.displayName) 中打开")
                + " · 悬停查看轮次"
        row.onActivate = isRemote ? nil : { [weak self, weak item] in
            guard let self else { return }
            item?.menu?.cancelTracking()
            self.rootMenu.cancelTracking()
            self.openSessionInApp(session)
        }
        item.view = row
    }

    private func updateVisibleSessionItems() {
        self.updateSessionProjectionAndVisibility()
        self.updateActivitySessionProjectionAndVisibility()
        self.loadSessionHistoryIfNeeded()
    }

    private func updateSessionProjectionAndVisibility(scope: DashboardScope? = nil) {
        guard self.sessionExpansionItem != nil else { return }
        let scope = scope ?? self.model.scope
        self.renderedMenuScope = scope
        let visibleSessions = self.model.activitySnapshot?
            .scoped(to: scope.platform)
            .sessionMenu(limit: nil).visibleSessions ?? []
        self.ensureSessionItemCapacity(visibleSessions.count)
        let projection = RenderedSessionProjection(
            ids: visibleSessions.map(\.platformScopedID),
            collapsedLimit: self.settings.recentSessionLimit)
        let projectionChanged = self.renderedSessionProjection != projection
        self.renderedSessionProjection = projection
        if projectionChanged, let overflow = self.sessionExpansionItem?.submenu {
            for item in self.sessionItems {
                item.menu?.removeItem(item)
            }
            let insertionIndex = self.sessionExpansionItem
                .flatMap { self.rootMenu.items.firstIndex(of: $0) } ?? self.rootMenu.items.count
            for (index, item) in self.sessionItems.enumerated() {
                if index < projection.collapsedLimit {
                    self.rootMenu.insertItem(item, at: insertionIndex + index)
                } else {
                    overflow.addItem(item)
                }
            }
        }
        self.updateSessionRows(self.sessionItems, sessions: visibleSessions)

        let hasSessions = !projection.ids.isEmpty
        let emptyTitle = "今日 \(scope.displayName) 会话待生成"
        if self.sessionEmptyItem?.title != emptyTitle {
            self.sessionEmptyItem?.title = emptyTitle
        }
        self.sessionEmptyItem?.toolTip = nil
        if self.sessionEmptyItem?.isHidden != hasSessions {
            self.sessionEmptyItem?.isHidden = hasSessions
        }

        let overflowCount = max(0, projection.ids.count - projection.collapsedLimit)
        self.sessionExpansionItem?.isHidden = overflowCount == 0
        self.sessionExpansionItem?.title = "更多会话（\(overflowCount)）"
    }

    private var availableSessionDates: [String] {
        Array(Set(self.model.activitySnapshot?.days.map(\.date) ?? [])).sorted()
    }

    private var latestSessionDate: String? {
        self.availableSessionDates.last
    }

    private var selectedSessionHistoryKey: SessionHistoryKey? {
        guard let selectedSessionDate else { return nil }
        return SessionHistoryKey(
            date: selectedSessionDate,
            statisticsTimeZone: self.settings.statisticsTimeZone.rawValue)
    }

    private var selectedSessionHistoryError: String? {
        guard let key = self.selectedSessionHistoryKey else { return nil }
        return self.sessionHistoryErrors[key]
    }

    private func normalizeSelectedSessionDate() {
        let dates = self.availableSessionDates
        guard !dates.isEmpty else {
            self.selectedSessionDate = nil
            return
        }
        if let selectedSessionDate, dates.contains(selectedSessionDate) {
            return
        }
        self.selectedSessionDate = dates.last
    }

    private func activitySessionsForSelectedDate(scope: DashboardScope) -> [SessionSummary] {
        guard let selectedSessionDate else { return [] }
        let sessions: [SessionSummary]
        if selectedSessionDate == self.latestSessionDate {
            sessions = self.model.activitySnapshot?.sessions ?? []
        } else if let key = self.selectedSessionHistoryKey {
            sessions = self.sessionHistory[key] ?? []
        } else {
            sessions = []
        }
        return sessions
            .filter { $0.platformID == scope.platform }
            .sorted {
                if $0.endedAtMs != $1.endedAtMs {
                    return $0.endedAtMs > $1.endedAtMs
                }
                return $0.platformScopedID < $1.platformScopedID
            }
    }

    private var activitySessionHeaderTitle: String {
        guard let selectedSessionDate else { return "会话" }
        if selectedSessionDate == self.latestSessionDate {
            return "会话 · 今日"
        }
        return "会话 · \(selectedSessionDate)"
    }

    private func activitySessionEmptyTitle(scope: DashboardScope) -> String {
        guard let selectedSessionDate else {
            return "\(scope.displayName) 会话日期待加载"
        }
        if self.loadingSessionHistoryKey == self.selectedSessionHistoryKey {
            return "正在加载 \(selectedSessionDate) 的 \(scope.displayName) 会话…"
        }
        if self.selectedSessionHistoryError != nil {
            return "加载 \(selectedSessionDate) 的 \(scope.displayName) 会话时出错"
        }
        if selectedSessionDate == self.latestSessionDate {
            return "今日 \(scope.displayName) 会话待生成"
        }
        return "\(selectedSessionDate) 的 \(scope.displayName) 会话为空"
    }

    private func updateActivitySessionProjectionAndVisibility(
        scope: DashboardScope? = nil)
    {
        guard self.activitySessionMenu != nil else { return }
        let scope = scope ?? self.model.scope
        self.normalizeSelectedSessionDate()
        let visibleSessions = self.activitySessionsForSelectedDate(scope: scope)
        self.ensureActivitySessionItemCapacity(visibleSessions.count)
        let projection = RenderedSessionProjection(
            ids: visibleSessions.map(\.platformScopedID),
            collapsedLimit: self.settings.recentSessionLimit)
        self.renderedActivitySessionProjection = projection
        self.updateSessionRows(
            self.activitySessionItems,
            sessions: visibleSessions,
            visibleLimit: self.showsAllActivitySessions ? nil : projection.collapsedLimit)

        self.activitySessionMenu?.title = self.activitySessionHeaderTitle
        let hasSessions = !projection.ids.isEmpty
        let emptyTitle = self.activitySessionEmptyTitle(scope: scope)
        if self.activitySessionEmptyItem?.title != emptyTitle {
            self.activitySessionEmptyItem?.title = emptyTitle
        }
        self.activitySessionEmptyItem?.toolTip = self.selectedSessionHistoryError
        if self.activitySessionEmptyItem?.isHidden != hasSessions {
            self.activitySessionEmptyItem?.isHidden = hasSessions
        }

        let canExpand = projection.ids.count > projection.collapsedLimit
            && self.activitySessionItems.count > projection.collapsedLimit
        if self.activitySessionExpansionItem?.isHidden != !canExpand {
            self.activitySessionExpansionItem?.isHidden = !canExpand
        }
        guard canExpand else { return }
        let title = self.activitySessionExpansionTitle(projection: projection)
        self.activitySessionExpansionItem?.title = title
        self.activitySessionExpansionView?.configure(
            title: title,
            systemImageName: self.showsAllActivitySessions ? "chevron.up" : "chevron.down",
            accessibilityHelp: "在当前菜单中展开或收起所选日期的会话。")
    }

    /// Reconfigure only the rows whose session changed; quota updates also reach this path.
    private func updateSessionRows(
        _ items: [NSMenuItem],
        sessions: [SessionSummary],
        visibleLimit: Int? = nil)
    {
        for (index, item) in items.enumerated() {
            let session = index < sessions.count ? sessions[index] : nil
            if (item.representedObject as? SessionSummary) != session {
                if let session {
                    self.configureSessionItem(item, session: session)
                    self.bindSessionSubmenu(item, to: session)
                } else {
                    item.representedObject = nil
                    self.unbindSessionSubmenu(item)
                }
            }
            let isHidden = index >= min(sessions.count, visibleLimit ?? sessions.count)
            if item.isHidden != isHidden {
                item.isHidden = isHidden
            }
        }
    }

    private func ensureSessionItemCapacity(_ count: Int) {
        guard self.sessionItems.count < count else { return }
        let insertionIndex = self.sessionExpansionItem
            .flatMap { self.rootMenu.items.firstIndex(of: $0) }
            ?? self.rootMenu.items.count
        for offset in 0 ..< (count - self.sessionItems.count) {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.sessionItems.append(item)
            self.rootMenu.insertItem(item, at: insertionIndex + offset)
        }
    }

    private func ensureActivitySessionItemCapacity(_ count: Int) {
        guard self.activitySessionItems.count < count,
              let menu = self.activitySessionMenu
        else {
            return
        }
        let insertionIndex = self.activitySessionExpansionItem
            .flatMap { menu.items.firstIndex(of: $0) }
            ?? menu.items.count
        for offset in 0 ..< (count - self.activitySessionItems.count) {
            let item = self.makeSessionItem()
            item.isHidden = true
            self.activitySessionItems.append(item)
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    private func selectActivityDate(_ date: String) {
        guard self.availableSessionDates.contains(date) else { return }
        let didChange = self.selectedSessionDate != date
        if didChange {
            self.cancelSessionHistoryLoad()
            self.selectedSessionDate = date
            self.showsAllActivitySessions = false
        }
        self.updateActivitySessionProjectionAndVisibility()
        self.loadSessionHistoryIfNeeded(debounce: didChange)
    }

    private func loadSessionHistoryIfNeeded(
        force: Bool = false,
        debounce: Bool = false)
    {
        guard self.activitySessionMenu != nil else { return }
        self.normalizeSelectedSessionDate()
        guard let selectedSessionDate,
              selectedSessionDate != self.latestSessionDate,
              let key = self.selectedSessionHistoryKey
        else {
            self.cancelSessionHistoryLoad()
            self.updateActivitySessionProjectionAndVisibility()
            return
        }
        if force {
            self.cancelSessionHistoryLoad()
            self.sessionHistory.removeValue(forKey: key)
        } else if self.sessionHistory[key] != nil {
            self.touchSessionHistory(key)
            return
        }
        guard self.loadingSessionHistoryKey != key else { return }

        self.sessionHistoryTask?.cancel()
        self.sessionHistoryErrors.removeValue(forKey: key)
        self.loadingSessionHistoryKey = key
        self.updateActivitySessionProjectionAndVisibility()
        self.sessionHistoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(250))
                }
                let sessions = try await self.model.sessions(on: selectedSessionDate)
                try Task.checkCancellation()
                guard self.loadingSessionHistoryKey == key else { return }
                self.sessionHistory[key] = sessions
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.loadingSessionHistoryKey == key else { return }
                self.sessionHistoryErrors[key] = error.localizedDescription
            }
            guard !Task.isCancelled, self.loadingSessionHistoryKey == key else { return }
            self.touchSessionHistory(key)
            self.loadingSessionHistoryKey = nil
            self.sessionHistoryTask = nil
            self.updateActivitySessionProjectionAndVisibility()
        }
    }

    private func cancelSessionHistoryLoad() {
        self.sessionHistoryTask?.cancel()
        self.sessionHistoryTask = nil
        self.loadingSessionHistoryKey = nil
    }

    private func touchSessionHistory(_ key: SessionHistoryKey) {
        self.sessionHistoryOrder.removeAll { $0 == key }
        self.sessionHistoryOrder.append(key)
        while self.sessionHistoryOrder.count > Self.sessionHistoryCacheLimit {
            let expired = self.sessionHistoryOrder.removeFirst()
            self.sessionHistory.removeValue(forKey: expired)
            self.sessionHistoryErrors.removeValue(forKey: expired)
        }
    }

    private func resetSessionHistory() {
        self.cancelSessionHistoryLoad()
        self.sessionHistory.removeAll()
        self.sessionHistoryErrors.removeAll()
        self.sessionHistoryOrder.removeAll()
    }

    #if DEBUG
    func statusBarPresentationForTesting() -> (contents: [StatusBarPlatformContent], toolTip: String?, accessibility: String?) {
        (self.statusBarContents, self.statusItem.button?.toolTip, self.statusItem.button?.accessibilityLabel())
    }

    func rootMenuForTesting() -> NSMenu {
        self.rootMenu
    }

    func rebuildRootMenuForTesting() {
        self.rebuildRootMenu()
    }

    func visibleDashboardSectionsForTesting() -> [TokenBarDashboardSection] {
        self.rootMenu.items.compactMap { item in
            guard !item.isHidden, let identifier = item.identifier?.rawValue,
                  identifier.hasPrefix("dashboard.")
            else { return nil }
            return TokenBarDashboardSection(rawValue: String(identifier.dropFirst("dashboard.".count)))
        }
    }

    func selectScopeForTesting(_ scope: DashboardScope) {
        self.selectScope(scope)
    }

    func firstSessionSubmenuForTesting() -> NSMenu? {
        self.sessionItems.first?.submenu
    }

    func selectActivityDateForTesting(_ date: String) {
        self.selectActivityDate(date)
    }

    func selectedSessionDateForTesting() -> String? {
        self.selectedSessionDate
    }

    func renderedActivitySessionIDsForTesting() -> [String] {
        self.activitySessionItems.compactMap { ($0.representedObject as? SessionSummary)?.platformScopedID }
    }

    func activitySessionMenuForTesting() -> NSMenu? {
        self.activitySessionMenu
    }

    func activityDetailDirectSessionCountForTesting() -> Int {
        self.activityDetailItem?.menu?.items.compactMap {
            $0.representedObject as? SessionSummary
        }.count ?? 0
    }

    func activityDetailShowsSessionMenuOnHoverForTesting() -> Bool {
        self.activityDetailItem?.submenu === self.activitySessionMenu
    }

    func firstActivitySessionSubmenuForTesting() -> NSMenu? {
        self.activitySessionItems.first?.submenu
    }

    func cachedSessionHistoryDatesForTesting() -> [String] {
        self.sessionHistoryOrder.map(\.date)
    }

    func isLoadingSessionHistoryForTesting() -> Bool {
        self.loadingSessionHistoryKey != nil
    }
    #endif

    private func rebuildRequestMenu(_ menu: NSMenu, session: SessionSummary) {
        self.discardRequestDetailMenus(in: menu)
        menu.removeAllItems()

        menu.title = session.menuDisplayTitle
        menu.minimumWidth = Self.menuWidth
        menu.addItem(.sectionHeader(title: "轮次"))
        if session.isSynchronizedRemote {
            let readOnly = NSMenuItem(
                title: "同步会话 · 在本机查看",
                action: nil,
                keyEquivalent: "")
            readOnly.isEnabled = false
            menu.addItem(readOnly)
        }
        let copySession = NSMenuItem(
            title: "复制会话",
            action: #selector(self.copySession(_:)),
            keyEquivalent: "")
        copySession.target = self
        copySession.representedObject = session
        copySession.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: nil)
        menu.addItem(copySession)
        menu.addItem(.separator())

        let requests = session.requests.sorted {
            if $0.endedAtMs != $1.endedAtMs {
                return $0.endedAtMs > $1.endedAtMs
            }
            return $0.id < $1.id
        }
        if requests.isEmpty {
            let empty = NSMenuItem(title: "轮次待生成", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for request in requests {
            menu.addItem(self.makeTurnItem(request))
        }
    }

    private func makeTurnItem(_ turn: RequestSummary) -> NSMenuItem {
        let physicalRequests = turn.physicalRequests.sorted {
            if $0.isSubagent != $1.isSubagent {
                return !$0.isSubagent
            }
            if $0.startedAtMs != $1.startedAtMs {
                return $0.startedAtMs < $1.startedAtMs
            }
            return $0.id < $1.id
        }
        let item = NSMenuItem(title: "轮次", action: nil, keyEquivalent: "")
        item.isEnabled = true
        let isRemote = turn.isSynchronizedRemote

        let row = TokenMenuRowView(width: Self.menuWidth)
        row.configure(
            title: turn.menuRowTitle,
            cost: turn.menuCostText,
            detail: [turn.tokens.requestMenuDetail, turn.menuTTFTText]
                .compactMap { $0 }.joined(separator: " · "),
            trailing: "\(turn.startedAt.menuClockText) · \(turn.menuDurationText)",
            showsChevron: physicalRequests.count > 1
                || (self.settings.showsFullRequestContentOnHover && !isRemote),
            badge: turn.menuServiceTierBadge,
            rate: turn.menuAverageTPSText)
        item.view = row

        if physicalRequests.count > 1 {
            item.toolTip = isRemote
                ? "同步轮次（仅查看）· 悬停查看相关请求"
                : "悬停查看本轮相关请求"
            item.submenu = self.makeAgentRequestMenu(
                title: turn.menuTitle,
                requests: physicalRequests)
        } else if let request = physicalRequests.first {
            if isRemote {
                item.toolTip = "同步内容仅包含请求统计"
            } else {
                self.configureCopyInteraction(item: item, row: row, request: request)
            }
            if self.settings.showsFullRequestContentOnHover, !isRemote {
                item.submenu = self.makeRequestDetailMenu(for: request)
            }
        }
        return item
    }

    private func makeAgentRequestMenu(
        title: String,
        requests: [RequestSummary]) -> TokenBarMenu
    {
        let menu = TokenBarMenu(title: title)
        menu.autoenablesItems = false
        menu.minimumWidth = Self.menuWidth
        menu.delegate = self
        menu.persistentActionDelegate = self
        menu.addItem(.sectionHeader(title: "智能体请求"))

        for request in requests {
            let item = NSMenuItem(title: "智能体请求", action: nil, keyEquivalent: "")
            item.isEnabled = true
            let row = TokenMenuRowView(width: Self.menuWidth)
            row.configure(
                title: request.agentRequestMenuTitle,
                cost: request.menuCostText,
                detail: [request.tokens.requestMenuDetail, request.menuTTFTText]
                    .compactMap { $0 }.joined(separator: " · "),
                trailing: "\(request.startedAt.menuClockText) · \(request.menuDurationText)",
                showsChevron: self.settings.showsFullRequestContentOnHover
                    && !request.isSynchronizedRemote,
                badge: request.menuServiceTierBadge,
                rate: request.menuAverageTPSText)
            item.view = row
            if request.isSynchronizedRemote {
                item.toolTip = "同步内容仅包含请求统计"
            } else {
                self.configureCopyInteraction(item: item, row: row, request: request)
            }
            if self.settings.showsFullRequestContentOnHover,
               !request.isSynchronizedRemote
            {
                item.submenu = self.makeRequestDetailMenu(for: request)
            }
            menu.addItem(item)
        }
        return menu
    }

    private func configureCopyInteraction(
        item: NSMenuItem,
        row: TokenMenuRowView,
        request: RequestSummary)
    {
        item.target = self
        item.action = #selector(self.copyRequest(_:))
        item.representedObject = request
        item.toolTip = "点击复制 Tokscale 请求定位信息"
        row.onActivate = { [weak self, weak item] in
            guard let item else { return }
            self?.copyRequest(item)
            item.menu?.cancelTracking()
            self?.rootMenu.cancelTracking()
        }
    }

    private func makeRequestDetailMenu(for request: RequestSummary) -> TokenBarMenu {
        let menu = TokenBarMenu(title: "请求详情")
        menu.autoenablesItems = false
        menu.minimumWidth = RequestDetailMenuView.preferredWidth
        menu.delegate = self
        menu.persistentActionDelegate = self

        let detailView = RequestDetailMenuView()
        detailView.showLoading(
            promptPreview: request.promptPreview,
            outputPreview: request.outputPreview)
        let detailItem = NSMenuItem(
            title: "请求详情",
            action: #selector(self.requestDetailNoOp),
            keyEquivalent: "")
        detailItem.target = self
        detailItem.isEnabled = true
        detailItem.view = detailView
        menu.addItem(detailItem)

        let menuID = ObjectIdentifier(menu)
        self.requestDetailMenus[menuID] = RequestDetailMenuContext(request: request, view: detailView)
        detailView.onRetry = { [weak self, weak detailView] in
            guard let self, let context = self.requestDetailMenus[menuID],
                  self.requestDetailTasks[menuID] == nil else { return }
            self.requestDetailCache.removeValue(forKey: context.cacheKey)
            self.requestDetailCacheOrder.removeAll { $0 == context.cacheKey }
            detailView?.showLoading(promptPreview: request.promptPreview, outputPreview: request.outputPreview)
            self.loadRequestDetailIfNeeded(menuID: menuID)
        }
        return menu
    }

    private func prepareRequestDetailView(_ context: RequestDetailMenuContext) {
        if let detail = self.requestDetailCache[context.cacheKey] {
            context.view.show(
                prompt: detail.prompt ?? context.request.promptPreview,
                output: detail.output ?? context.request.outputPreview)
        } else {
            context.view.showLoading(
                promptPreview: context.request.promptPreview,
                outputPreview: context.request.outputPreview)
        }
    }

    private func loadRequestDetailIfNeeded(menuID: ObjectIdentifier) {
        guard let context = self.requestDetailMenus[menuID],
              self.requestDetailCache[context.cacheKey] == nil,
              self.requestDetailTasks[menuID] == nil
        else {
            return
        }

        let request = context.request
        let cacheKey = context.cacheKey
        let task = Task { @MainActor [weak self, weak detailView = context.view] in
            guard let self else { return }
            defer { self.requestDetailTasks[menuID] = nil }
            do {
                let detail = try await self.requestDetailService.fetchDetail(for: request)
                try Task.checkCancellation()
                self.cacheRequestDetail(detail, forKey: cacheKey)
                guard self.requestDetailMenus[menuID]?.cacheKey == cacheKey else { return }
                detailView?.show(
                    prompt: detail.prompt ?? request.promptPreview,
                    output: detail.output ?? request.outputPreview)
            } catch is CancellationError {
                // The parent menu was rebuilt or the app is terminating.
            } catch {
                guard self.requestDetailMenus[menuID]?.cacheKey == cacheKey else { return }
                detailView?.showError(
                    error.localizedDescription,
                    promptPreview: request.promptPreview,
                    outputPreview: request.outputPreview)
            }
        }
        self.requestDetailTasks[menuID] = task
    }

    private func cacheRequestDetail(_ detail: RequestDetail, forKey key: String) {
        // An empty read can become available later; keep it eligible for a new read.
        guard detail.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              detail.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        if self.requestDetailCache[key] == nil {
            self.requestDetailCacheOrder.append(key)
        }
        self.requestDetailCache[key] = detail

        while self.requestDetailCacheOrder.count > Self.requestDetailCacheLimit {
            let expiredKey = self.requestDetailCacheOrder.removeFirst()
            self.requestDetailCache.removeValue(forKey: expiredKey)
        }
    }

    private func discardRequestDetailMenus(in menu: NSMenu) {
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            self.discardRequestDetailMenus(in: submenu)

            let menuID = ObjectIdentifier(submenu)
            guard self.requestDetailMenus.removeValue(forKey: menuID) != nil else { continue }
            self.requestDetailTasks.removeValue(forKey: menuID)?.cancel()
            self.highlightedRows.removeValue(forKey: menuID)?.setMenuHighlighted(false)
            submenu.delegate = nil
            (submenu as? TokenBarMenu)?.persistentActionDelegate = nil
        }
    }

    @objc private func activityNoOp() {}

    @objc private func requestDetailNoOp() {}

    @objc private func showSettings() {
        self.showSettingsAction()
    }

    @objc private func refreshNow() {
        Task { @MainActor [weak self] in
            await self?.refreshAllIncludingSelectedSessions()
        }
    }

    private func refreshAllIncludingSelectedSessions() async {
        await self.model.refreshAll()
        guard self.selectedSessionDate != self.latestSessionDate else { return }
        self.loadSessionHistoryIfNeeded(force: true)
    }

    @objc private func copySession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionSummary else { return }
        self.copyToPasteboard(session.tokscaleCopyText)
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? SessionSummary else { return }
        self.openSessionInApp(session)
    }

    private func openSessionInApp(_ session: SessionSummary) {
        do {
            try self.sessionLauncher.open(session)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "打开会话时出错"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }

    @objc private func copyRequest(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? RequestSummary else { return }
        self.copyToPasteboard(request.tokscaleCopyText)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct RequestDetailMenuContext {
    let request: RequestSummary
    let view: RequestDetailMenuView

    var cacheKey: String {
        self.request.tokscaleCopyText
    }
}

private extension Date {
    var menuClockText: String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: self)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }
}

private final class FixedMenuHostingView: NSHostingView<AnyView> {
    private var fixedSize: NSSize

    init(rootView: AnyView, width: CGFloat, height: CGFloat) {
        self.fixedSize = NSSize(width: width, height: height)
        super.init(rootView: rootView)
        self.frame = NSRect(origin: .zero, size: self.fixedSize)
    }

    required init(rootView: AnyView) {
        self.fixedSize = .zero
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        self.fixedSize
    }

    func updateHeight(_ height: CGFloat) {
        guard self.fixedSize.height != height else { return }
        self.fixedSize.height = height
        self.setFrameSize(self.fixedSize)
        self.invalidateIntrinsicContentSize()
        self.needsLayout = true
        self.superview?.needsLayout = true
    }

}

private struct MenuActivitySummaryView: View {
    @Bindable var model: DashboardModel
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            ActivitySummarySection(
                state: self.model.visibleActivity,
                accentColor: self.accentColor,
                showsChevron: true,
                model: self.model,
                platform: self.model.scope.platform)
        }
    }
}

private struct MenuMemorySummaryView: View {
    @Bindable var model: DashboardModel
    @Bindable var telemetry: MemoryTelemetryController
    let accentColor: Color

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 12)
            MemorySummarySection(
                usage: self.model.visibleActivitySnapshot?.memoryUsage,
                receiverState: self.telemetry.receiverState,
                configurationState: self.telemetry.configurationState,
                accentColor: self.accentColor)
        }
    }
}

@MainActor
struct StatusLabelLayout {
    struct Region {
        let scope: DashboardScope
        let startX: CGFloat
        let centerX: CGFloat
    }

    let image: NSImage
    let regions: [Region]

    func scope(at imageX: CGFloat) -> DashboardScope {
        self.regions.last(where: { imageX >= $0.startX })?.scope ?? .codex
    }

    func scope(at point: NSPoint, in buttonBounds: NSRect, eventType: NSEvent.EventType?) -> DashboardScope? {
        // macOS 27 can leave currentEvent as mouseMoved when the status menu opens.
        guard eventType != .keyDown, eventType != .keyUp,
              buttonBounds.contains(point)
        else { return nil }
        let imageMinX = buttonBounds.midX - self.image.size.width / 2
        return self.scope(at: point.x - imageMinX)
    }

    func centerX(for platform: TokenPlatform) -> CGFloat? {
        self.regions.first(where: { $0.scope.platform == platform })?.centerX
    }
}

enum StatusSpeedTone: Equatable, Sendable {
    case idle
    case active
    case slow

    init(isActive: Bool, tokensPerSecond: Double?) {
        guard isActive, let rate = tokensPerSecond, rate.isFinite, rate > 0 else {
            self = .idle
            return
        }
        self = rate < StatusBarSpeedActivity.slowThreshold ? .slow : .active
    }

    var color: NSColor {
        switch self {
        case .idle: .labelColor
        case .active: .systemGreen
        case .slow: .systemRed
        }
    }
}

struct StatusBarPlatformContent: Equatable, Sendable {
    let scope: DashboardScope
    let top: String?
    let bottom: String?
    let unreadCount: Int
    /// nil hides the chart; an empty array draws the explicit empty indicator.
    let trendRates: [Double]?
    let trendMaximum: Double?
    let speedTone: StatusSpeedTone
    let topIsSpeed: Bool
    let bottomIsSpeed: Bool

    init(scope: DashboardScope, top: String?, bottom: String?, unreadCount: Int = 0, trendRates: [Double]? = nil,
         trendMaximum: Double? = nil,
         speedTone: StatusSpeedTone = .idle, topIsSpeed: Bool = false, bottomIsSpeed: Bool = false) {
        self.scope = scope
        self.top = top
        self.bottom = bottom
        self.unreadCount = unreadCount
        self.trendRates = trendRates
        self.trendMaximum = trendMaximum
        self.speedTone = speedTone
        self.topIsSpeed = topIsSpeed
        self.bottomIsSpeed = bottomIsSpeed
    }
}

enum StatusSpeedChartGeometry {
    static func points(rates: [Double], in rect: NSRect, maximum: Double? = nil) -> [NSPoint] {
        let values = Array(rates.filter { $0.isFinite && $0 > 0 }.suffix(30))
        guard !values.isEmpty else { return [] }
        let peak = maximum ?? SpeedChartScale(rates: values).maximum
        return values.enumerated().map { index, rate in
            NSPoint(
                x: values.count == 1 ? rect.midX : rect.minX + CGFloat(index) / CGFloat(values.count - 1) * rect.width,
                y: rect.minY + CGFloat(min(1, rate / peak)) * rect.height)
        }
    }
}

@MainActor
enum StatusLabelRenderer {
    struct Geometry {
        let size: NSSize
        let iconRect: NSRect?
        let chartRect: NSRect?
        let topRect: NSRect?
        let bottomRect: NSRect?
    }

    static func layout(
        codexToday: String,
        codexWeekly: String,
        codexUnreadCount: Int = 0,
        claudeToday: String? = nil,
        claudeWeekly: String? = nil,
        claudeUnreadCount: Int = 0,
        grokToday: String? = nil,
        grokWeekly: String? = nil,
        antigravityToday: String? = nil,
        antigravityWeekly: String? = nil) -> StatusLabelLayout
    {
        var contents = [StatusBarPlatformContent(
            scope: .codex, top: codexToday, bottom: codexWeekly, unreadCount: codexUnreadCount)]
        if let claudeToday, let claudeWeekly {
            contents.append(StatusBarPlatformContent(
                scope: .claude, top: claudeToday, bottom: claudeWeekly, unreadCount: claudeUnreadCount))
        }
        if let grokToday, let grokWeekly {
            contents.append(StatusBarPlatformContent(scope: .grok, top: grokToday, bottom: grokWeekly))
        }
        if let antigravityToday, let antigravityWeekly {
            contents.append(StatusBarPlatformContent(scope: .antigravity, top: antigravityToday, bottom: antigravityWeekly))
        }
        return self.layout(contents: contents)
    }

    static func layout(contents: [StatusBarPlatformContent]) -> StatusLabelLayout {
        let contents = contents.isEmpty ? [StatusBarPlatformContent(scope: .codex, top: nil, bottom: nil)] : contents
        let images = contents.map { content in
            self.image(platform: content.scope.platform, top: content.top, bottom: content.bottom,
                       unreadCount: content.unreadCount, trendRates: content.trendRates,
                       trendMaximum: content.trendMaximum,
                       speedTone: content.speedTone, topIsSpeed: content.topIsSpeed, bottomIsSpeed: content.bottomIsSpeed)
        }
        let gap: CGFloat = 7
        let size = NSSize(width: images.map(\.size.width).reduce(0, +) + gap * CGFloat(max(0, images.count - 1)), height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for providerImage in images {
                providerImage.draw(in: NSRect(x: x, y: 0, width: providerImage.size.width, height: 20),
                                   from: .zero, operation: .sourceOver, fraction: 1)
                x += providerImage.size.width + gap
            }
            return true
        }
        image.isTemplate = contents.allSatisfy { $0.speedTone == .idle }
        var regions: [StatusLabelLayout.Region] = []
        var x: CGFloat = 0
        for (index, content) in contents.enumerated() {
            regions.append(StatusLabelLayout.Region(
                scope: content.scope, startX: index == 0 ? 0 : x - gap / 2,
                centerX: x + images[index].size.width / 2))
            x += images[index].size.width + gap
        }
        // Bake colored labels under the status button appearance; template labels
        // continue to let AppKit supply the menu bar foreground.
        if !image.isTemplate,
           let bitmap = NSBitmapImageRep(
               bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)),
               pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8,
               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: bitmap)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            image.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = size
            let coloredImage = NSImage(size: size)
            coloredImage.addRepresentation(bitmap)
            coloredImage.isTemplate = false
            return StatusLabelLayout(image: coloredImage, regions: regions)
        }
        return StatusLabelLayout(image: image, regions: regions)
    }

    static func image(platform: TokenPlatform? = nil, today: String, weekly: String, unreadCount: Int = 0) -> NSImage {
        self.image(platform: platform, top: today, bottom: weekly, unreadCount: unreadCount)
    }

    static func geometry(platform: TokenPlatform?, top: String?, bottom: String?, showsTrend: Bool) -> Geometry {
        let top = self.visibleText(top)
        let bottom = self.visibleText(bottom)
        let attributes = self.textAttributes
        let width = min(54, ceil(max(
            top.map { ($0 as NSString).size(withAttributes: attributes).width } ?? 0,
            bottom.map { ($0 as NSString).size(withAttributes: attributes).width } ?? 0)))
        let hasIcon = platform.flatMap { PlatformStatusIcon.image(for: $0) } != nil
        let widths: [CGFloat] = [hasIcon ? 15 : 0, showsTrend ? 34 : 0, width].filter { $0 > 0 }
        let contentWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * 4
        let size = NSSize(width: max(30, contentWidth + 4), height: 20)
        let start = floor((size.width - contentWidth) / 2)
        var x = start
        let iconRect: NSRect? = hasIcon ? NSRect(x: x, y: 2, width: 15, height: 15) : nil
        if hasIcon { x += 15 }
        var chartRect: NSRect?
        if showsTrend {
            if x > start { x += 4 }
            chartRect = NSRect(x: x, y: 3, width: 34, height: 14)
            x += 34
        }
        if width > 0, x > start { x += 4 }
        let singleRow = top == nil || bottom == nil
        return Geometry(
            size: size, iconRect: iconRect, chartRect: chartRect,
            topRect: top == nil ? nil : NSRect(x: x, y: singleRow ? 5 : 10, width: width, height: 10),
            bottomRect: bottom == nil ? nil : NSRect(x: x, y: singleRow ? 5 : 0, width: width, height: 10))
    }

    static func image(
        platform: TokenPlatform? = nil, top: String?, bottom: String?, unreadCount: Int = 0,
        trendRates: [Double]? = nil, trendMaximum: Double? = nil, speedTone: StatusSpeedTone = .idle,
        topIsSpeed: Bool = false, bottomIsSpeed: Bool = false) -> NSImage
    {
        let geometry = self.geometry(platform: platform, top: top, bottom: bottom, showsTrend: trendRates != nil)
        let icon = platform.flatMap { PlatformStatusIcon.image(for: $0) }
        let badge = icon != nil && unreadCount > 0 ? StatusUnreadBadge(count: unreadCount) : nil
        let top = self.visibleText(top)
        let bottom = self.visibleText(bottom)
        let attributes = self.textAttributes
        let image = NSImage(size: geometry.size, flipped: false) { _ in
            if let icon, let rect = geometry.iconRect {
                let tinted = NSImage(size: icon.size, flipped: false) { _ in
                    let bounds = NSRect(origin: .zero, size: icon.size)
                    icon.draw(in: bounds)
                    NSColor.labelColor.setFill()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                if let badge {
                    badge.draw(in: NSRect(
                        x: rect.maxX + StatusUnreadBadge.iconOverhang - badge.width,
                        y: geometry.size.height - StatusUnreadBadge.height,
                        width: badge.width, height: StatusUnreadBadge.height))
                }
            }
            if let rates = trendRates, let rect = geometry.chartRect {
                self.drawTrend(rates: rates, in: rect, color: speedTone.color, maximum: trendMaximum)
            }
            if let top, let rect = geometry.topRect {
                var textAttributes = attributes
                if topIsSpeed { textAttributes[.foregroundColor] = speedTone.color }
                (top as NSString).draw(in: rect, withAttributes: textAttributes)
            }
            if let bottom, let rect = geometry.bottomRect {
                var textAttributes = attributes
                if bottomIsSpeed { textAttributes[.foregroundColor] = speedTone.color }
                (bottom as NSString).draw(in: rect, withAttributes: textAttributes)
            }
            return true
        }
        image.isTemplate = speedTone == .idle
        return image
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static func visibleText(_ value: String?) -> String? {
        value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    private static func drawTrend(rates: [Double], in rect: NSRect, color: NSColor, maximum: Double?) {
        let values = Array(rates.filter { $0.isFinite && $0 > 0 }.suffix(30))
        let maximum = maximum ?? SpeedChartScale(rates: values).maximum
        let points = StatusSpeedChartGeometry.points(rates: values, in: rect.insetBy(dx: 1.5, dy: 1.5), maximum: maximum)
        guard let first = points.first else {
            let dash = "—" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.45)]
            let size = dash.size(withAttributes: attributes)
            dash.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return
        }
        color.setStroke()
        color.setFill()
        if points.count > 1 {
            let line = NSBezierPath()
            line.lineWidth = 1.1
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            line.move(to: first)
            for point in points.dropFirst() { line.line(to: point) }
            line.stroke()
        }
        let last = points.last ?? first
        let diameter: CGFloat = points.count == 1 ? 2.6 : 2.2
        NSBezierPath(ovalIn: NSRect(x: last.x - diameter / 2, y: last.y - diameter / 2,
                                  width: diameter, height: diameter)).fill()
        for index in values.indices where values[index] > maximum {
            let point = points[index]
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: point.x - 1.8, y: point.y - 1.5))
            marker.line(to: NSPoint(x: point.x, y: point.y + 1))
            marker.line(to: NSPoint(x: point.x + 1.8, y: point.y - 1.5))
            marker.lineWidth = 0.8
            marker.stroke()
        }
    }
}

/// Unread count follows the menu bar foreground in template and colored images.
/// The ring and digits are knocked out to retain contrast against the background.
/// Longer counts growward over the icon, so the status label keeps its width.
private struct StatusUnreadBadge {
    static let height: CGFloat = 9
    /// How far the pill reaches past the icon into the 4pt gap; its 1pt ring still
    /// leaves 1pt before the values.
    static let iconOverhang: CGFloat = 2

    private let label: NSString
    private let font: NSFont
    let width: CGFloat

    init(count: Int) {
        let label = (count > 99 ? "99+" : "\(count)") as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .heavy)
        self.label = label
        self.font = font
        self.width = max(Self.height, ceil(label.size(withAttributes: [.font: font]).width) + 4)
    }

    func draw(in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: self.font,
            .foregroundColor: NSColor.labelColor,
        ]
        let radius = rect.height / 2
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        NSColor.labelColor.setFill()
        context.compositingOperation = .clear
        NSBezierPath(
            roundedRect: rect.insetBy(dx: -1, dy: -1),
            xRadius: radius + 1,
            yRadius: radius + 1).fill()
        context.compositingOperation = .sourceOver
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        context.compositingOperation = .destinationOut
        let labelWidth = self.label.size(withAttributes: attributes).width
        self.label.draw(
            at: NSPoint(
                x: rect.midX - labelWidth / 2,
                y: rect.midY - self.font.capHeight / 2 + self.font.descender),
            withAttributes: attributes)
    }
}

@MainActor
enum PlatformStatusIcon {
    private static let size = NSSize(width: 16, height: 16)
    private static var cache: [TokenPlatform: NSImage] = [:]

    private static let resourceBundle: Bundle = {
        if let bundleURL = Bundle.main.url(
            forResource: "TokenBar_TokenBar",
            withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL)
        {
            return bundle
        }
        return Bundle.module
    }()

    static func image(for platform: TokenPlatform) -> NSImage? {
        if let cached = self.cache[platform] {
            return cached
        }
        if platform == .zcode {
            let image = NSImage(size: self.size, flipped: false) { rect in
                let path = NSBezierPath()
                path.lineWidth = 2.1
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3))
                path.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
                path.line(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
                path.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3))
                NSColor.labelColor.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            self.cache[platform] = image
            return image
        }
        if let symbolName = self.symbolName(for: platform),
           let symbol = NSImage(
               systemSymbolName: symbolName,
               accessibilityDescription: platform.displayName)?
               .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
        {
            symbol.size = self.size
            symbol.isTemplate = true
            self.cache[platform] = symbol
            return symbol
        }
        guard let resourceName = self.resourceName(for: platform),
              let url = self.resourceBundle.url(
                  forResource: resourceName,
                  withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.size = self.size
        image.isTemplate = true
        self.cache[platform] = image
        return image
    }

    private static func symbolName(for platform: TokenPlatform) -> String? {
        switch platform {
        case .grok: "xmark"
        default: nil
        }
    }

    private static func resourceName(for platform: TokenPlatform) -> String? {
        switch platform {
        case .codex: "ProviderIcon-codex"
        case .claude: "ProviderIcon-claude"
        case .antigravity: "ProviderIcon-antigravity"
        default: nil
        }
    }
}
