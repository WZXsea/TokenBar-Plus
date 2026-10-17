import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

@MainActor
@Suite("Configurable dashboard menu")
struct DashboardMenuConfigurationTests {
    @Test("default menu leads with speed and keeps memory hidden")
    func defaultLayout() async throws {
        let harness = try await DashboardMenuHarness.make()
        defer { harness.tearDown() }

        #expect(harness.controller.visibleDashboardSectionsForTesting() == [
            .speed, .quota, .today, .recentSessions, .activity,
        ])
        #expect(harness.controller.firstSessionSubmenuForTesting() != nil)
    }

    @Test("quota merges weekly usage regardless of section order and retains its height through refreshes")
    func mergedWeeklyUsage() async throws {
        let harness = try await DashboardMenuHarness.make { settings in
            for section in TokenBarDashboardSection.allCases where section != .quota && section != .weeklyReset {
                settings.setDashboardSection(section, isVisible: false)
            }
            if let weeklyIndex = settings.dashboardSectionOrder.firstIndex(of: .weeklyReset) {
                settings.moveDashboardSection(.weeklyReset, by: -weeklyIndex)
            }
        }
        defer { harness.tearDown() }
        #expect(harness.settings.visibleDashboardSections == [.weeklyReset, .quota])
        #expect(harness.controller.visibleDashboardSectionsForTesting() == [.quota])
        let item = try #require(harness.controller.rootMenuForTesting().items.first {
            $0.identifier?.rawValue == "dashboard.quota"
        })
        let quota = try #require(harness.model.quotaSnapshot)
        let height = DashboardSectionContentView.preferredHeight(
            for: .quota, quota: quota, showsResetCredits: false, showsWeeklyUsage: true)
        #expect(height == DashboardSectionContentView.preferredHeight(
            for: .quota, quota: quota, showsResetCredits: false) + 40)
        #expect(item.view?.frame.height == height)

        harness.controller.selectScopeForTesting(.claude)
        #expect(item.view?.frame.height == DashboardSectionContentView.preferredHeight(
            for: .quota,
            quota: harness.model.quotaState(for: .claude).value,
            showsResetCredits: false,
            showsWeeklyUsage: true))
        harness.controller.selectScopeForTesting(.codex)
        #expect(item.view?.frame.height == height)

        let menu = harness.controller.rootMenuForTesting()
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }
        await harness.model.refreshQuota(for: .codex)
        for _ in 0 ..< 100 { await Task.yield() }
        #expect(item.view?.frame.height == height)
        #expect(harness.controller.visibleDashboardSectionsForTesting() == [.quota])
    }

    @Test("quota and weekly usage remain independent when only one section is visible", arguments: [
        TokenBarDashboardSection.quota, .weeklyReset,
    ])
    func standaloneQuotaSummary(section: TokenBarDashboardSection) async throws {
        let harness = try await DashboardMenuHarness.make { settings in
            for candidate in TokenBarDashboardSection.allCases {
                settings.setDashboardSection(candidate, isVisible: candidate == section)
            }
        }
        defer { harness.tearDown() }
        #expect(harness.controller.visibleDashboardSectionsForTesting() == [section])
        let item = try #require(harness.controller.rootMenuForTesting().items.first {
            $0.identifier?.rawValue == "dashboard." + section.rawValue
        })
        #expect(item.view?.frame.height == DashboardSectionContentView.preferredHeight(
            for: section, quota: harness.model.quotaSnapshot, showsResetCredits: false))
    }

    @Test("recent session rows keep concise totals while expanded turns retain performance details")
    func conciseSessionRows() async throws {
        let harness = try await DashboardMenuHarness.make()
        defer { harness.tearDown() }
        let item = try #require(harness.controller.rootMenuForTesting().items.first {
            !$0.isHidden && $0.representedObject is SessionSummary
        })
        let session = try #require(item.representedObject as? SessionSummary)
        let row = try #require(item.view as? TokenMenuRowView)
        let labels = row.subviews.compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }.map(\.stringValue)
        let cost = try #require(session.menuCostText)
        let sessionTTFT = try #require(session.menuAverageTTFTText)
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: Date(timeIntervalSince1970: Double(session.endedAtMs) / 1_000))
        let endedAt = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)

        #expect(labels.contains(session.menuDisplayTitle))
        #expect(row.accessibilityHelp()?.contains(cost) == true)
        #expect(row.accessibilityHelp()?.contains(session.tokens.total.compactCount) == true)
        #expect(row.frame.height == 26)
        #expect(labels.count <= 3)
        #expect(labels.contains(endedAt))
        #expect(labels.allSatisfy { !$0.contains("%") && !$0.contains(sessionTTFT) && !$0.contains("tok/s") })
        #expect(row.toolTip?.contains(session.menuDetail) == true)

        let submenu = try #require(item.submenu)
        harness.controller.menuNeedsUpdate(submenu)
        let turnRow = try #require(submenu.items.compactMap { $0.view as? TokenMenuRowView }.first)
        let turn = try #require(session.requests.sorted {
            if $0.endedAtMs != $1.endedAtMs { return $0.endedAtMs > $1.endedAtMs }
            return $0.id < $1.id
        }.first)
        let turnLabels = turnRow.subviews.compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden }.map(\.stringValue)
        let rate = try #require(turn.menuAverageTPSText)
        let ttft = try #require(turn.menuTTFTText)
        #expect(turnLabels.contains(rate))
        #expect(turnLabels.contains { $0.contains(turn.tokens.requestMenuDetail) && $0.contains(ttft) })
    }

    @Test("request details reread empty results, support explicit retry and reuse complete results")
    func requestDetailReloadLifecycle() async throws {
        let service = ReloadingDashboardRequestDetailService()
        let harness = try await DashboardMenuHarness.make(requestDetailService: service)
        defer { harness.tearDown() }
        let sessionMenu = try #require(harness.controller.firstSessionSubmenuForTesting())
        let (menu, view) = try #require(self.findRequestDetail(in: sessionMenu, controller: harness.controller))

        harness.controller.menuWillOpen(menu)
        try await self.waitForDetail {
            let text = self.detailText(in: view)
            return text.contains("用于验证请求详情重读的提示词") && !text.contains("正在读取请求详情")
        }
        #expect(await service.callCount == 1)
        harness.controller.menuDidClose(menu)

        harness.controller.menuNeedsUpdate(menu)
        harness.controller.menuWillOpen(menu)
        try await self.waitForDetail { self.detailText(in: view).contains("第二次读取的完整输出") }
        #expect(await service.callCount == 2)
        let retry = try #require(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "重新读取" })
        try await self.waitForDetail { !retry.isHidden }
        retry.performClick(nil)
        try await self.waitForDetail { self.detailText(in: view).contains("第三次主动重读的输出") }
        #expect(await service.callCount == 3)
        harness.controller.menuDidClose(menu)

        harness.controller.menuNeedsUpdate(menu)
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }
        #expect(self.detailText(in: view).contains("第三次主动重读的输出"))
        // Give a mistakenly scheduled reload enough time to reach the actor.
        try await Task.sleep(for: .milliseconds(25))
        #expect(await service.callCount == 3)
    }

    private func findRequestDetail(
        in menu: NSMenu,
        controller: TokenBarStatusItemController,
        depth: Int = 0) -> (NSMenu, RequestDetailMenuView)?
    {
        guard depth < 5 else { return nil }
        controller.menuNeedsUpdate(menu)
        if let view = menu.items.compactMap({ $0.view as? RequestDetailMenuView }).first {
            return (menu, view)
        }
        for submenu in menu.items.compactMap(\.submenu) {
            if let result = self.findRequestDetail(in: submenu, controller: controller, depth: depth + 1) {
                return result
            }
        }
        return nil
    }

    private func detailText(in view: NSView) -> String {
        if let textView = view as? NSTextView { return textView.string }
        return view.subviews.map { self.detailText(in: $0) }.joined()
    }

    private func waitForDetail(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Request detail state did not settle within one second")
    }

    @Test("saved section ordering controls the native menu")
    func customLayout() async throws {
        let harness = try await DashboardMenuHarness.make { settings in
            settings.moveDashboardSection(.recentSessions, by: -3)
            for section in [TokenBarDashboardSection.speed, .weeklyReset, .activity] {
                settings.setDashboardSection(section, isVisible: false)
            }
        }
        defer { harness.tearDown() }

        #expect(harness.controller.visibleDashboardSectionsForTesting() == [.recentSessions, .quota, .today])
        #expect(harness.controller.activitySessionMenuForTesting() == nil)
    }

    @Test("hidden sessions stay hidden after platform changes, even with all sections hidden")
    func emptyDashboardStaysEmpty() async throws {
        let harness = try await DashboardMenuHarness.make { settings in
            for section in TokenBarDashboardSection.allCases {
                settings.setDashboardSection(section, isVisible: false)
            }
        }
        defer { harness.tearDown() }

        harness.controller.selectScopeForTesting(.claude)
        let menu = harness.controller.rootMenuForTesting()
        #expect(harness.controller.visibleDashboardSectionsForTesting().isEmpty)
        #expect(harness.controller.firstSessionSubmenuForTesting() == nil)
        #expect(menu.items.allSatisfy { !($0.representedObject is SessionSummary) })
        #expect(menu.items.contains { $0.title == "设置…" })
        #expect(menu.items.contains { $0.title == "退出 TokenBar" })
    }

    @Test("memory opt-in preserves its position when changing platforms")
    func memoryScopeAndOrder() async throws {
        let harness = try await DashboardMenuHarness.make { settings in
            settings.setDashboardSection(.memory, isVisible: true)
            settings.moveDashboardSection(.memory, by: -4)
        }
        defer { harness.tearDown() }
        let order = harness.settings.visibleDashboardSections.filter { $0 != .weeklyReset }

        #expect(harness.controller.visibleDashboardSectionsForTesting() == order)
        harness.controller.selectScopeForTesting(.claude)
        #expect(harness.controller.visibleDashboardSectionsForTesting() == order.filter { $0 != .memory })
        harness.controller.selectScopeForTesting(.codex)
        #expect(harness.controller.visibleDashboardSectionsForTesting() == order)
        #expect(harness.settings.isDashboardSectionVisible(.memory))
    }

    @Test("memory display preference is retained while collection is disabled")
    func memoryCollectionGate() async throws {
        let harness = try await DashboardMenuHarness.make { settings in
            settings.monitorsCodexMemory = false
            settings.setDashboardSection(.memory, isVisible: true)
        }
        defer { harness.tearDown() }

        #expect(harness.settings.isDashboardSectionVisible(.memory))
        #expect(!harness.controller.visibleDashboardSectionsForTesting().contains(.memory))
    }

    @Test("an open menu observes display and order changes immediately")
    func liveConfiguration() async throws {
        let harness = try await DashboardMenuHarness.make()
        defer { harness.tearDown() }
        let menu = harness.controller.rootMenuForTesting()
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }

        harness.settings.setDashboardSection(.activity, isVisible: false)
        harness.settings.setDashboardSection(.recentSessions, isVisible: false)
        harness.settings.moveDashboardSection(.today, by: -2)
        let expected = harness.settings.visibleDashboardSections.filter { $0 != .weeklyReset }
        for _ in 0 ..< 100 {
            if harness.controller.visibleDashboardSectionsForTesting() == expected { break }
            await Task.yield()
        }
        #expect(harness.controller.visibleDashboardSectionsForTesting() == expected)
        #expect(harness.controller.firstSessionSubmenuForTesting() == nil)
        #expect(harness.controller.activitySessionMenuForTesting() == nil)
    }
}

private struct DashboardMenuCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}

@MainActor
private struct DashboardMenuHarness {
    let settings: TokenBarSettings
    let model: DashboardModel
    let controller: TokenBarStatusItemController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    static func make(
        requestDetailService: any RequestDetailProviding = CodexRequestDetailService(),
        configure: (TokenBarSettings) -> Void = { _ in }) async throws -> Self
    {
        let suite = "DashboardMenuConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        configure(settings)
        let model = DashboardModel(
            quotaService: DemoQuotaProvider(),
            additionalQuotaServices: [DemoClaudeQuotaProvider()],
            activityService: DemoActivityProvider(),
            cache: nil)
        await model.start()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashboardMenuConfigurationTests-\(UUID().uuidString)")
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: directory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: directory.appendingPathComponent("config.toml")))
        let sync = ActivitySyncController(settings: settings, credentials: DashboardMenuCredentials())
        let controller = TokenBarStatusItemController(
            model: model,
            settings: settings,
            memoryTelemetry: telemetry,
            activitySync: sync,
            showSettings: {},
            requestDetailService: requestDetailService)
        return Self(
            settings: settings,
            model: model,
            controller: controller,
            defaults: defaults,
            suite: suite,
            directory: directory)
    }

    func tearDown() {
        self.controller.tearDown()
        self.model.stop()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}

private actor ReloadingDashboardRequestDetailService: RequestDetailProviding {
    private(set) var callCount = 0

    func fetchDetail(for _: RequestSummary) async throws -> RequestDetail {
        self.callCount += 1
        let output: String?
        switch self.callCount {
        case 1: output = nil
        case 2: output = "第二次读取的完整输出"
        default: output = "第三次主动重读的输出"
        }
        return RequestDetail(prompt: "用于验证请求详情重读的提示词", output: output)
    }
}
