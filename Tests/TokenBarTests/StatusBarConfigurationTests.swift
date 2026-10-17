import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

@MainActor
struct StatusBarConfigurationTests {
    @Test("Status metric and chart preferences immediately update the closed-menu image, tooltip, and accessibility")
    func liveStatusPreferences() async throws {
        let suite = "StatusBarConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        settings.showsClaude = false
        settings.showsGrok = false
        settings.showsAntigravity = false
        settings.monitorsCodexMemory = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StatusBarConfigurationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DashboardModel(quotaService: DemoQuotaProvider(), activityService: DemoActivityProvider(), cache: nil)
        await model.start()
        defer { model.stop() }
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: directory),
            configurationService: CodexMemoryConfigurationService(configurationURL: directory.appendingPathComponent("config.toml")))
        let sync = ActivitySyncController(settings: settings, credentials: StatusConfigurationCredentials())
        let controller = TokenBarStatusItemController(
            model: model, settings: settings, memoryTelemetry: telemetry, activitySync: sync,
            showSettings: {}, pricingStore: ModelPricingStore(fileURL: directory.appendingPathComponent("pricing.json")))
        defer { controller.tearDown() }
        #expect(controller.statusBarPresentationForTesting().contents.count == 1)
        #expect(controller.statusBarPresentationForTesting().contents.first?.trendRates != nil)

        settings.statusBarTopMetric = .latestSpeed
        settings.statusBarBottomMetric = .none
        settings.showsStatusBarSpeedChart = false
        try await self.waitUntil {
            let state = controller.statusBarPresentationForTesting()
            return state.contents.first?.bottom == nil && state.contents.first?.trendRates == nil
                && state.toolTip?.contains("最近生成速率") == true
        }
        #expect(controller.statusBarPresentationForTesting().accessibility?.contains("tok/s") == true)

        settings.statusBarTopMetric = .none
        settings.statusBarBottomMetric = .todayCost
        settings.showsStatusBarSpeedChart = true
        try await self.waitUntil {
            let state = controller.statusBarPresentationForTesting()
            return state.contents.first?.top == nil && state.contents.first?.bottom != nil
                && state.contents.first?.trendRates != nil && state.toolTip?.contains("今日费用") == true
        }
        #expect(controller.statusBarPresentationForTesting().toolTip?.contains("最近最多30轮·逐轮采样") == true)

        settings.statusBarBottomMetric = .none
        settings.showsStatusBarSpeedChart = false
        try await self.waitUntil {
            let content = controller.statusBarPresentationForTesting().contents.first
            return content?.top == nil && content?.bottom == nil && content?.trendRates == nil
        }
        let layout = StatusLabelRenderer.layout(contents: controller.statusBarPresentationForTesting().contents)
        #expect(layout.image.size.width > 0)
        #expect(layout.regions.map(\.scope) == [.codex])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "状态栏应立即应用当前指标和图表设置")
    }
}

private struct StatusConfigurationCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}
