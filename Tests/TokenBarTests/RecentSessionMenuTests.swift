import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

private struct RecentSessionTestCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}

private actor HistoricalSessionActivityProvider: ActivityProviding {
    let snapshot: ActivitySnapshot
    let historicalSessions: [String: [SessionSummary]]
    private(set) var requestedDates: [String] = []

    init(snapshot: ActivitySnapshot, historicalSessions: [String: [SessionSummary]]) {
        self.snapshot = snapshot
        self.historicalSessions = historicalSessions
    }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.snapshot
    }

    func fetchSessions(
        on date: String,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
    {
        self.requestedDates.append(date)
        return self.historicalSessions[date] ?? []
    }
}

@MainActor
@Suite("Recent session menu")
struct RecentSessionMenuTests {
    @Test("recent sessions stay capped and overflow retains compact rows and turn submenus")
    func cappedRootWithOverflowSubmenu() async throws {
        let harness = try await CompactSessionHarness.make(codexCount: 6, claudeCount: 2)
        defer { harness.tearDown() }
        let menu = harness.controller.rootMenuForTesting()

        #expect(harness.settings.recentSessionLimit == 3)
        #expect(Self.visibleSessionIDs(in: menu) == ["codex-6", "codex-5", "codex-4"])
        let overflowItem = try #require(menu.items.first { $0.title == "更多会话（3）" })
        #expect(!overflowItem.isHidden)
        let overflow = try #require(overflowItem.submenu)
        #expect(Self.visibleSessionIDs(in: overflow) == ["codex-3", "codex-2", "codex-1"])

        for item in (menu.items + overflow.items) where item.representedObject is SessionSummary {
            let row = try #require(item.view as? TokenMenuRowView)
            #expect(row.frame.height == 26)
            #expect(row.intrinsicContentSize.height == 26)
            #expect(row.toolTip?.contains("结束于") == true)
            #expect(item.submenu != nil)
        }
        let sessionSubmenu = try #require(overflow.items.first?.submenu)
        harness.controller.menuNeedsUpdate(sessionSubmenu)
        #expect(sessionSubmenu.items.contains { $0.title == "轮次" })
        #expect(Self.visibleSessionIDs(in: menu).count == 3)

        harness.controller.selectScopeForTesting(.claude)
        #expect(Self.visibleSessionIDs(in: menu) == ["claude-2", "claude-1"])
        #expect(menu.items.filter { !$0.isHidden }.allSatisfy { !$0.title.hasPrefix("更多会话") })
        harness.controller.selectScopeForTesting(.codex)
        #expect(Self.visibleSessionIDs(in: menu) == ["codex-6", "codex-5", "codex-4"])
        let restoredOverflow = try #require(menu.items.first { !$0.isHidden && $0.title == "更多会话（3）" }?.submenu)
        #expect(Self.visibleSessionIDs(in: restoredOverflow) == ["codex-3", "codex-2", "codex-1"])
    }

    @Test("open menu refreshes preserve the cap and settings move rows between root and overflow")
    func refreshedSessionsAndLimitChanges() async throws {
        let harness = try await CompactSessionHarness.make(codexCount: 6)
        defer { harness.tearDown() }
        let menu = harness.controller.rootMenuForTesting()
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }
        await harness.model.refreshActivity()

        await harness.provider.replaceSessions(CompactSessionHarness.sessions(count: 8, platform: .codex))
        await harness.model.refreshActivity()
        try await Self.waitUntil {
            Self.visibleSessionIDs(in: menu) == ["codex-8", "codex-7", "codex-6"]
        }
        let updatedOverflow = try #require(menu.items.first { !$0.isHidden && $0.title == "更多会话（5）" }?.submenu)
        #expect(Self.visibleSessionIDs(in: updatedOverflow) == ["codex-5", "codex-4", "codex-3", "codex-2", "codex-1"])

        harness.settings.recentSessionCount = .five
        try await Self.waitUntil { Self.visibleSessionIDs(in: menu).count == 5 }
        #expect(Self.visibleSessionIDs(in: menu) == ["codex-8", "codex-7", "codex-6", "codex-5", "codex-4"])
        let resizedOverflow = try #require(menu.items.first { !$0.isHidden && $0.title == "更多会话（3）" }?.submenu)
        #expect(Self.visibleSessionIDs(in: resizedOverflow) == ["codex-3", "codex-2", "codex-1"])

        await harness.provider.replaceSessions(CompactSessionHarness.sessions(count: 1, platform: .codex))
        await harness.model.refreshActivity()
        try await Self.waitUntil { Self.visibleSessionIDs(in: menu) == ["codex-1"] }
        #expect(menu.items.filter { !$0.isHidden }.allSatisfy { !$0.title.hasPrefix("更多会话") })
    }

    @Test("Refreshing one session preserves the other session's populated turn submenu")
    func refreshingOneSessionPreservesUnchangedSubmenu() async throws {
        let harness = try await CompactSessionHarness.make(codexCount: 2)
        defer { harness.tearDown() }
        let menu = harness.controller.rootMenuForTesting()
        harness.controller.menuWillOpen(menu)
        defer { harness.controller.menuDidClose(menu) }
        await harness.model.refreshActivity()

        let unchangedItem = try #require(menu.items.first {
            ($0.representedObject as? SessionSummary)?.id == "codex-1"
        })
        let unchangedRow = try #require(unchangedItem.view)
        let populatedSubmenu = try #require(unchangedItem.submenu)
        harness.controller.menuNeedsUpdate(populatedSubmenu)
        let populatedItems = populatedSubmenu.items
        #expect(populatedItems.contains { $0.title == "轮次" })
        #expect(populatedItems.contains { $0.title == "复制会话" })

        var sessions = CompactSessionHarness.sessions(count: 2, platform: .codex)
        let original = sessions[1]
        sessions[1] = SessionSummary(
            id: original.id, workspaceLabel: original.workspaceLabel,
            startedAtMs: original.startedAtMs, endedAtMs: original.endedAtMs,
            tokens: original.tokens, costUsd: original.costUsd, models: original.models,
            requests: original.requests, title: "Updated conversation", platform: original.platform)
        await harness.provider.replaceSessions(sessions)
        await harness.model.refreshActivity()
        try await Self.waitUntil {
            menu.items.contains {
                ($0.representedObject as? SessionSummary)?.title == "Updated conversation"
                    && $0.submenu?.title == "Updated conversation"
            }
        }

        let preservedItem = try #require(menu.items.first {
            ($0.representedObject as? SessionSummary)?.id == "codex-1"
        })
        #expect(preservedItem === unchangedItem)
        #expect(preservedItem.view === unchangedRow)
        #expect(preservedItem.submenu === populatedSubmenu)
        #expect(populatedSubmenu.items.count == populatedItems.count)
        #expect(zip(populatedSubmenu.items, populatedItems).allSatisfy { $0.0 === $0.1 })
        #expect(Self.visibleSessionIDs(in: menu) == ["codex-2", "codex-1"])
    }

    private static func visibleSessionIDs(in menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.compactMap { ($0.representedObject as? SessionSummary)?.id }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Recent session menu should reflect the latest model and limit")
    }

    @Test("switching platforms replaces an already-populated session submenu")
    func submenuFollowsPlatformSwitch() async throws {
        let suiteName = "RecentSessionMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")

        let model = DashboardModel(
            quotaService: DemoQuotaProvider(),
            additionalQuotaServices: [DemoClaudeQuotaProvider()],
            activityService: DemoActivityProvider(),
            cache: nil)
        await model.start()
        defer { model.stop() }

        let telemetryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentSessionMenuTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: telemetryDirectory) }
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: telemetryDirectory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: telemetryDirectory.appendingPathComponent("config.toml")))
        let activitySync = ActivitySyncController(
            settings: settings,
            credentials: RecentSessionTestCredentials())
        let controller = TokenBarStatusItemController(
            model: model,
            settings: settings,
            memoryTelemetry: telemetry,
            activitySync: activitySync,
            showSettings: {})
        defer { controller.tearDown() }

        let codexMenu = try #require(controller.firstSessionSubmenuForTesting())
        controller.menuNeedsUpdate(codexMenu)
        let codexSession = try #require(codexMenu.items.compactMap {
            $0.representedObject as? SessionSummary
        }.first)
        #expect(codexSession.platformID == .codex)

        controller.selectScopeForTesting(.claude)

        let claudeMenu = try #require(controller.firstSessionSubmenuForTesting())
        #expect(codexMenu !== claudeMenu)
        controller.menuNeedsUpdate(claudeMenu)
        let claudeSession = try #require(claudeMenu.items.compactMap {
            $0.representedObject as? SessionSummary
        }.first)
        #expect(claudeSession.platformID == .claude)
    }

    @Test("Activity Detail loads and renders the selected date's sessions")
    func loadsPreviousDate() async throws {
        let today = Self.session(id: "today", endedAtMs: 2_000)
        let yesterday = Self.session(id: "yesterday", endedAtMs: 1_000)
        let provider = HistoricalSessionActivityProvider(
            snapshot: ActivitySnapshot(
                schemaVersion: 11,
                generatedAtMs: 2_000,
                timezone: "UTC",
                today: .zero,
                sessions: [today],
                days: [
                    DailySummary(
                        date: "2026-09-01",
                        tokens: .zero,
                        costUsd: 0,
                        requestCount: 1,
                        sessionCount: 1),
                    DailySummary(
                        date: "2026-09-02",
                        tokens: .zero,
                        costUsd: 0,
                        requestCount: 1,
                        sessionCount: 1),
                ]),
            historicalSessions: ["2026-09-01": [yesterday]])
        let model = DashboardModel(
            quotaService: DemoQuotaProvider(),
            activityService: provider,
            cache: nil)
        await model.start()
        defer { model.stop() }

        let suiteName = "RecentSessionMenuTests.history.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        let telemetryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentSessionMenuHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: telemetryDirectory) }
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: telemetryDirectory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: telemetryDirectory.appendingPathComponent("config.toml")))
        let activitySync = ActivitySyncController(
            settings: settings,
            credentials: RecentSessionTestCredentials())
        let controller = TokenBarStatusItemController(
            model: model,
            settings: settings,
            memoryTelemetry: telemetry,
            activitySync: activitySync,
            showSettings: {})
        defer { controller.tearDown() }

        #expect(controller.selectedSessionDateForTesting() == "2026-09-02")
        controller.selectActivityDateForTesting("2026-09-01")
        while controller.isLoadingSessionHistoryForTesting() {
            await Task.yield()
        }

        #expect(controller.selectedSessionDateForTesting() == "2026-09-01")
        #expect(controller.renderedActivitySessionIDsForTesting() == ["codex:yesterday"])
        #expect(await provider.requestedDates == ["2026-09-01"])
        #expect(controller.firstSessionSubmenuForTesting()?.title == "today")
        let sessionMenu = try #require(controller.activitySessionMenuForTesting())
        #expect(sessionMenu.title == "会话 · 2026-09-01")
        #expect(sessionMenu.items.compactMap {
            ($0.representedObject as? SessionSummary)?.id
        } == ["yesterday"])
        #expect(controller.activityDetailDirectSessionCountForTesting() == 0)
        #expect(controller.activityDetailShowsSessionMenuOnHoverForTesting())
        let historicalMenu = try #require(controller.firstActivitySessionSubmenuForTesting())
        #expect(historicalMenu.title == "yesterday")
        controller.menuNeedsUpdate(historicalMenu)
        #expect(historicalMenu.items.contains { $0.title == "轮次" })
    }

    private static func session(id: String, endedAtMs: Int64) -> SessionSummary {
        SessionSummary(
            id: id,
            workspaceLabel: "TokenBar",
            startedAtMs: endedAtMs - 100,
            endedAtMs: endedAtMs,
            tokens: .zero,
            costUsd: 0,
            models: ["gpt-test"],
            requests: [],
            title: id,
            platform: .codex)
    }
}

private actor CompactSessionActivityProvider: ActivityProviding {
    private var sessions: [SessionSummary]

    init(sessions: [SessionSummary]) { self.sessions = sessions }

    func replaceSessions(_ sessions: [SessionSummary]) { self.sessions = sessions }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        ActivitySnapshot(
            schemaVersion: 11,
            generatedAtMs: 10_000,
            timezone: "UTC",
            today: .zero,
            sessions: self.sessions,
            days: [],
            sources: [TokenPlatform.codex, .claude].map {
                ActivitySourceSnapshot(platform: $0, today: .zero, weeklySinceReset: nil, days: [])
            })
    }
}

@MainActor
private struct CompactSessionHarness {
    let settings: TokenBarSettings
    let model: DashboardModel
    let provider: CompactSessionActivityProvider
    let controller: TokenBarStatusItemController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    static func make(codexCount: Int, claudeCount: Int = 0) async throws -> Self {
        let suite = "CompactSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        let provider = CompactSessionActivityProvider(sessions:
            Self.sessions(count: codexCount, platform: .codex)
                + Self.sessions(count: claudeCount, platform: .claude))
        let model = DashboardModel(
            quotaService: DemoQuotaProvider(),
            additionalQuotaServices: [DemoClaudeQuotaProvider()],
            activityService: provider,
            cache: nil)
        await model.start()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactSessionTests-\(UUID().uuidString)")
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: directory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: directory.appendingPathComponent("config.toml")))
        let sync = ActivitySyncController(settings: settings, credentials: RecentSessionTestCredentials())
        let controller = TokenBarStatusItemController(
            model: model, settings: settings, memoryTelemetry: telemetry, activitySync: sync,
            showSettings: {})
        return Self(settings: settings, model: model, provider: provider, controller: controller,
                    defaults: defaults, suite: suite, directory: directory)
    }

    static func sessions(count: Int, platform: TokenPlatform) -> [SessionSummary] {
        (0 ..< count).map { index in
            let id = "\(platform.rawValue)-\(index + 1)"
            return SessionSummary(
                id: id, workspaceLabel: "TokenBar", startedAtMs: Int64(index * 1_000),
                endedAtMs: Int64((index + 1) * 1_000), tokens: .zero, costUsd: 0,
                models: ["test-model"], requests: [], title: id, platform: platform)
        }
    }

    func tearDown() {
        self.controller.tearDown()
        self.model.stop()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}
