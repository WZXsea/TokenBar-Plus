import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

@MainActor
@Suite("Reset credits menu")
struct ResetCreditsMenuTests {
    private let sampledAt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The dedicated native row has a submenu and preserves the quota module's full height")
    func nativeSubmenuAndHeight() async throws {
        let snapshot = self.inventory()
        let harness = try await ResetCreditsMenuHarness.make(credits: snapshot, sampledAt: self.sampledAt)
        defer { harness.tearDown() }
        let menu = harness.controller.rootMenuForTesting()
        let quotaIndex = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "dashboard.quota" })
        let row = try #require(menu.items.first { $0.identifier?.rawValue == "dashboard.quota.resetCredits" })
        let submenu = try #require(row.submenu)

        #expect(menu.items[quotaIndex + 1] === row)
        #expect(row.title == "额外重置")
        #expect(row.hasSubmenu)
        #expect(row.isEnabled)
        #expect(!row.isHidden)
        #expect(row.view?.frame.height == DashboardLayout.resetCreditsIncrement)
        let quota = try #require(harness.model.quotaSnapshot)
        let fullHeight = DashboardSectionContentView.preferredHeight(
            for: .quota, quota: quota, showsWeeklyUsage: true)
        #expect((menu.items[quotaIndex].view?.frame.height ?? 0) + (row.view?.frame.height ?? 0) == fullHeight)
        #expect(DashboardSectionContentView.preferredHeight(for: .quota, quota: nil, showsResetCredits: false)
            == DashboardSectionContentView.preferredHeight(for: .quota, quota: nil))

        let requestCount = await harness.provider.fetchCount
        harness.controller.menuNeedsUpdate(submenu)
        #expect(await harness.provider.fetchCount == requestCount)
        #expect(submenu.items.allSatisfy { $0.action == nil })
    }

    @Test("The submenu keeps every returned record in order, including unknown and expired-available statuses")
    func fullInventory() async throws {
        let snapshot = self.inventory()
        let harness = try await ResetCreditsMenuHarness.make(credits: snapshot, sampledAt: self.sampledAt)
        defer { harness.tearDown() }
        let submenu = try #require(self.resetRow(in: harness.controller)?.submenu)
        let entries = submenu.items.filter { $0.representedObject is QuotaResetCredit }
        #expect(entries.compactMap { $0.representedObject as? QuotaResetCredit } == snapshot.credits)
        #expect(entries.map(\.title) == [
            "记录 1 · 可用", "记录 2 · 已使用", "记录 3 · 已到期", "记录 4 · future_status", "记录 5 · 可用",
        ])
        #expect(submenu.items.first?.title == "额外重置 · 可用 2 次 / 共 5 次")
        #expect(ResetCreditsDetailHeaderView.showsServerCount(snapshot))
        #expect(entries[2].toolTip?.contains("服务端状态：available") == true)
        #expect(entries[3].toolTip?.contains("future_status") == true)
        #expect(entries[0].toolTip?.contains(ResetCreditsDetailPresentation.timestampText(snapshot.credits[0].expiresAt!)) == true)
        #expect(entries[4].toolTip?.contains("服务端留空") == true)
        #expect(entries.allSatisfy { !$0.isEnabled && $0.action == nil })
    }

    @Test("Legacy summaries retain their available count and show a refresh hint instead of invented records")
    func legacySummary() async throws {
        let legacy = QuotaResetCreditsSnapshot(availableCount: 2, nextExpiresAt: self.sampledAt.addingTimeInterval(3600))
        let harness = try await ResetCreditsMenuHarness.make(credits: legacy, sampledAt: self.sampledAt)
        defer { harness.tearDown() }
        let submenu = try #require(self.resetRow(in: harness.controller)?.submenu)
        #expect(submenu.items.first?.title == "额外重置 · 可用 2 次")
        #expect(submenu.items.contains { $0.title == "当前缓存保留可用次数；刷新后获取全部条目。" })
        #expect(submenu.items.allSatisfy { !($0.representedObject is QuotaResetCredit) })
        #expect(!ResetCreditsDetailPresentation.hasInventory(legacy))
    }

    @Test("An explicitly empty inventory displays zero total records")
    func emptyInventory() async throws {
        let empty = QuotaResetCreditsSnapshot(availableCount: 0, nextExpiresAt: nil, serverAvailableCount: 0)
        let harness = try await ResetCreditsMenuHarness.make(credits: empty, sampledAt: self.sampledAt)
        defer { harness.tearDown() }
        let submenu = try #require(self.resetRow(in: harness.controller)?.submenu)
        #expect(submenu.items.first?.title == "额外重置 · 可用 0 次 / 共 0 次")
        #expect(submenu.items.contains { $0.title == "服务端本次返回 0 条重置记录。" })
    }

    @Test("Quota sorting and visibility move or hide the reset row together with its owning section")
    func followsQuotaConfiguration() async throws {
        let harness = try await ResetCreditsMenuHarness.make(credits: self.inventory(), sampledAt: self.sampledAt) {
            $0.moveDashboardSection(.quota, by: 2)
        }
        defer { harness.tearDown() }
        let menu = harness.controller.rootMenuForTesting()
        let quotaIndex = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "dashboard.quota" })
        #expect(menu.items[quotaIndex + 1].identifier?.rawValue == "dashboard.quota.resetCredits")
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }
        harness.settings.setDashboardSection(.quota, isVisible: false)
        try await self.waitUntil { self.resetRow(in: harness.controller) == nil }
        #expect(menu.items.allSatisfy { $0.identifier?.rawValue != "dashboard.quota" })
        harness.settings.setDashboardSection(.quota, isVisible: true)
        try await self.waitUntil { self.resetRow(in: harness.controller)?.hasSubmenu == true }
        let restoredIndex = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "dashboard.quota" })
        #expect(menu.items[restoredIndex + 1].identifier?.rawValue == "dashboard.quota.resetCredits")
    }

    @Test("Platform changes and refreshed quota inventory update the submenu without stale records")
    func refreshesAndScopesInventory() async throws {
        let harness = try await ResetCreditsMenuHarness.make(credits: self.inventory(), sampledAt: self.sampledAt)
        defer { harness.tearDown() }
        harness.controller.selectScopeForTesting(.claude)
        #expect(self.resetRow(in: harness.controller)?.isHidden == true)
        #expect(self.resetRow(in: harness.controller)?.submenu == nil)
        harness.controller.selectScopeForTesting(.codex)
        #expect(self.resetRow(in: harness.controller)?.isHidden == false)
        #expect(self.resetRow(in: harness.controller)?.submenu != nil)
        let menu = harness.controller.rootMenuForTesting()
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }
        let replacement = QuotaResetCreditsSnapshot(
            availableCount: 0, nextExpiresAt: nil,
            credits: [QuotaResetCredit(status: "revoked", expiresAt: nil)], serverAvailableCount: 0)
        await harness.provider.replaceCredits(replacement, sampledAt: self.sampledAt.addingTimeInterval(60))
        await harness.model.refreshQuota(for: .codex)
        try await self.waitUntil {
            self.resetRow(in: harness.controller)?.submenu?.items.contains { $0.title == "记录 1 · 已撤销" } == true
        }
        let records = self.resetRow(in: harness.controller)?.submenu?.items.compactMap { $0.representedObject as? QuotaResetCredit }
        #expect(records == replacement.credits)
    }

    private func resetRow(in controller: TokenBarStatusItemController) -> NSMenuItem? {
        controller.rootMenuForTesting().items.first { $0.identifier?.rawValue == "dashboard.quota.resetCredits" }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "原生重置详情菜单应同步当前额度与显示配置")
    }

    private func inventory() -> QuotaResetCreditsSnapshot {
        let future = self.sampledAt.addingTimeInterval(86_400)
        return QuotaResetCreditsSnapshot(
            availableCount: 2,
            nextExpiresAt: future,
            credits: [
                QuotaResetCredit(status: "available", expiresAt: future),
                QuotaResetCredit(status: "redeemed", expiresAt: future),
                QuotaResetCredit(status: "available", expiresAt: self.sampledAt.addingTimeInterval(-1)),
                QuotaResetCredit(status: "future_status", expiresAt: nil),
                QuotaResetCredit(status: "available", expiresAt: nil),
            ],
            serverAvailableCount: 3)
    }
}

private actor ResetCreditsTestQuotaProvider: QuotaProviding {
    nonisolated let platform = TokenPlatform.codex
    private var credits: QuotaResetCreditsSnapshot?
    private var sampledAt: Date
    private(set) var fetchCount = 0

    init(credits: QuotaResetCreditsSnapshot?, sampledAt: Date) {
        self.credits = credits
        self.sampledAt = sampledAt
    }

    func replaceCredits(_ credits: QuotaResetCreditsSnapshot?, sampledAt: Date) {
        self.credits = credits
        self.sampledAt = sampledAt
    }

    func fetchQuota() async throws -> QuotaSnapshot {
        self.fetchCount += 1
        return QuotaSnapshot(
            session: QuotaWindowSnapshot(usedPercent: 10, windowMinutes: 300, resetsAt: self.sampledAt.addingTimeInterval(3600)),
            weekly: QuotaWindowSnapshot(usedPercent: 20, windowMinutes: 10_080, resetsAt: self.sampledAt.addingTimeInterval(86_400)),
            resetCredits: self.credits, updatedAt: self.sampledAt)
    }
}

private struct ResetCreditsMenuCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}

@MainActor
private struct ResetCreditsMenuHarness {
    let settings: TokenBarSettings
    let model: DashboardModel
    let provider: ResetCreditsTestQuotaProvider
    let controller: TokenBarStatusItemController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    static func make(
        credits: QuotaResetCreditsSnapshot?, sampledAt: Date,
        configure: (TokenBarSettings) -> Void = { _ in }) async throws -> Self
    {
        let suite = "ResetCreditsMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        settings.monitorsCodexMemory = false
        configure(settings)
        let provider = ResetCreditsTestQuotaProvider(credits: credits, sampledAt: sampledAt)
        let model = DashboardModel(
            quotaService: provider, additionalQuotaServices: [DemoClaudeQuotaProvider()],
            activityService: DemoActivityProvider(), cache: nil)
        await model.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResetCreditsMenuTests-\(UUID().uuidString)")
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: directory),
            configurationService: CodexMemoryConfigurationService(configurationURL: directory.appendingPathComponent("config.toml")))
        let sync = ActivitySyncController(settings: settings, credentials: ResetCreditsMenuCredentials())
        let controller = TokenBarStatusItemController(
            model: model, settings: settings, memoryTelemetry: telemetry,
            activitySync: sync, showSettings: {},
            pricingStore: ModelPricingStore(fileURL: directory.appendingPathComponent("pricing.json")))
        return Self(settings: settings, model: model, provider: provider, controller: controller,
                    defaults: defaults, suite: suite, directory: directory)
    }

    func tearDown() {
        self.controller.tearDown()
        self.model.stop()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}
