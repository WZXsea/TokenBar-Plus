import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

@MainActor
@Suite("Model pricing refresh integration")
struct ModelPricingRefreshTests {
    @Test("Saving, enabling, disabling, removing, and restoring prices refresh the dashboard and session cost help")
    func pricingRevisionsRefreshVisibleCosts() async throws {
        let harness = try await PricingRefreshHarness.make()
        let initialFetchCount = await harness.provider.fetchCount
        let menu = harness.controller.rootMenuForTesting()
        harness.controller.menuWillOpen(menu)
        defer {
            harness.controller.menuDidClose(menu)
            harness.tearDown()
        }

        // Opening the menu performs its normal refresh. Settle it before pricing
        // mutations so each subsequent fetch is attributable to a store revision.
        var fetchCount = try await self.waitForCost(2, after: initialFetchCount, harness: harness)
        var rule = ModelPriceOverride(
            platform: .codex, modelID: PricingRefreshActivityProvider.modelID,
            outputPerMillion: 8)
        try harness.store.upsert(rule)
        fetchCount = try await self.waitForCost(8, after: fetchCount, harness: harness)

        rule.outputPerMillion = 11
        try harness.store.upsert(rule)
        fetchCount = try await self.waitForCost(11, after: fetchCount, harness: harness)

        try harness.store.setEnabled(rule.id, isEnabled: false)
        fetchCount = try await self.waitForCost(2, after: fetchCount, harness: harness)
        #expect(harness.store.overrides.count == 1)
        #expect(harness.store.activeFileURL == nil)

        try harness.store.setEnabled(rule.id, isEnabled: true)
        fetchCount = try await self.waitForCost(11, after: fetchCount, harness: harness)

        try harness.store.remove(rule.id)
        fetchCount = try await self.waitForCost(2, after: fetchCount, harness: harness)
        #expect(harness.store.overrides.isEmpty)

        rule.outputPerMillion = 6
        try harness.store.upsert(rule)
        fetchCount = try await self.waitForCost(6, after: fetchCount, harness: harness)
        try harness.store.removeAll()
        _ = try await self.waitForCost(2, after: fetchCount, harness: harness)
        #expect(harness.store.revision == 7)
        #expect(harness.store.activeFileURL == nil)
        #expect(harness.model.activitySnapshot?.today.tokens.output == 1_000_000)
    }

    private func waitForCost(
        _ expected: Double, after previousFetchCount: Int,
        harness: PricingRefreshHarness) async throws -> Int
    {
        let expectedText = String(format: "~$%.2f", locale: Locale(identifier: "en_US_POSIX"), expected)
        for _ in 0 ..< 400 {
            let count = await harness.provider.fetchCount
            if count > previousFetchCount,
               !harness.model.activity.isRefreshing,
               harness.model.activitySnapshot?.today.costUsd == expected,
               self.sessionCostHelp(in: harness.controller).contains(expectedText)
            {
                #expect(count == previousFetchCount + 1)
                return count
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await harness.provider.fetchCount
        try #require(count > previousFetchCount, "价格规则修订后应触发使用记录刷新")
        try #require(harness.model.activitySnapshot?.today.costUsd == expected, "今日费用应采用修订后的价格")
        try #require(self.sessionCostHelp(in: harness.controller).contains(expectedText), "会话提示应显示修订后的费用")
        return count
    }

    private func sessionCostHelp(in controller: TokenBarStatusItemController) -> [String] {
        controller.rootMenuForTesting().items
            .filter { $0.representedObject is SessionSummary && !$0.isHidden }
            .compactMap { $0.view as? TokenMenuRowView }
            .flatMap { row in
                (row.accessibilityHelp() ?? "").components(separatedBy: ". ")
            }
    }
}

private actor PricingRefreshActivityProvider: ActivityProviding {
    nonisolated static let modelID = "pricing-refresh-fixture"
    private let store: ModelPricingStore
    private(set) var fetchCount = 0

    init(store: ModelPricingStore) {
        self.store = store
    }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.fetchCount += 1
        let cost = await MainActor.run {
            self.store.overrides.first {
                $0.enabled && $0.platform == .codex && $0.modelID == Self.modelID
            }?.outputPerMillion ?? 2
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let tokens = TokenBreakdown(input: 0, output: 1_000_000, cacheRead: 0, cacheWrite: 0, reasoning: 0)
        let request = RequestSummary(
            id: "pricing-request", sessionId: "pricing-session", physicalSessionId: "pricing-session",
            isSubagent: false, agent: nil, model: Self.modelID, provider: "fixture-provider",
            startedAtMs: now - 1_000, endedAtMs: now, durationMs: 1_000, modelDurationMs: 1_000,
            tokens: tokens, costUsd: cost, costSource: .estimated,
            promptPreview: "Pricing refresh fixture", outputPreview: nil, sessionPath: nil, platform: .codex)
        let session = SessionSummary(
            id: "pricing-session", workspaceLabel: "Pricing refresh fixture",
            startedAtMs: now - 1_000, endedAtMs: now,
            tokens: tokens, costUsd: cost, models: [Self.modelID], requests: [request], platform: .codex)
        return ActivitySnapshot(
            schemaVersion: 11, generatedAtMs: now, timezone: "UTC",
            today: ActivityTotals(tokens: tokens, costUsd: cost, requestCount: 1, sessionCount: 1),
            sessions: [session], days: [])
    }
}

private struct PricingRefreshCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}

@MainActor
private struct PricingRefreshHarness {
    let store: ModelPricingStore
    let provider: PricingRefreshActivityProvider
    let model: DashboardModel
    let controller: TokenBarStatusItemController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    static func make() async throws -> Self {
        let suite = "ModelPricingRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        settings.monitorsCodexMemory = false
        settings.showsClaude = false
        settings.showsGrok = false
        settings.showsAntigravity = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelPricingRefreshTests-\(UUID().uuidString)")
        let store = ModelPricingStore(fileURL: directory.appendingPathComponent("custom-pricing.json"))
        let provider = PricingRefreshActivityProvider(store: store)
        let model = DashboardModel(quotaService: DemoQuotaProvider(), activityService: provider, cache: nil)
        await model.start()
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: directory),
            configurationService: CodexMemoryConfigurationService(
                configurationURL: directory.appendingPathComponent("config.toml")))
        let sync = ActivitySyncController(settings: settings, credentials: PricingRefreshCredentials())
        let controller = TokenBarStatusItemController(
            model: model, settings: settings, memoryTelemetry: telemetry,
            activitySync: sync, showSettings: {}, pricingStore: store)
        return Self(store: store, provider: provider, model: model, controller: controller,
                    defaults: defaults, suite: suite, directory: directory)
    }

    func tearDown() {
        self.controller.tearDown()
        self.model.stop()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}
