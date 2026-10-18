import AppKit
import Foundation
import Testing
import TokenBarCore
@testable import TokenBar

@MainActor
@Suite("ZCode platform integration")
struct ZCodeIntegrationTests {
    @Test("Platform visibility persists independently and keeps Codex available")
    func platformVisibility() throws {
        let suite = "TokenBar.ZCodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TokenBarSettings(defaults: defaults)
        #expect(settings.showsZCode)
        settings.showsZCode = false
        #expect(!TokenBarSettings(defaults: defaults).showsZCode)
        #expect(DashboardScope.visibleScopes(showsClaude: false, showsGrok: false,
                    showsAntigravity: false, showsZCode: true) == [.codex, .zcode])
        #expect(DashboardScope.visibleScopes(showsClaude: false, showsGrok: false,
                    showsAntigravity: false, showsZCode: false) == [.codex])
        #expect(PlatformStatusIcon.image(for: .zcode)?.isTemplate == true)
        #expect(SpeedSummaryPresentation.title(for: .zcode) == "响应速率")
        #expect(SpeedSummaryPresentation.title(for: .codex) == "生成速度")
        let metric = StatusBarMetricPresentation(metric: .todayAverageSpeed,
            snapshot: nil, quota: nil, platform: .zcode)
        #expect(metric.detailText?.contains("今日平均响应速率") == true)
        #expect(metric.detailText?.contains("含首 Token 等待") == true)
    }

    @Test("Local session opens the ZCode application and quota sections remain conditional")
    func localApplicationLaunch() throws {
        let session = SessionSummary(id: "zcode-session", workspaceLabel: nil,
            startedAtMs: 1_000, endedAtMs: 2_000, tokens: .zero, costUsd: 0,
            models: [], requests: [], platform: .zcode)
        var launches = 0
        let launcher = SessionLauncher(openURL: { _ in
            Issue.record("ZCode uses its installed application launcher")
            return false
        }, launchZCodeApplication: { launches += 1; return true })
        try launcher.open(session)
        #expect(launches == 1)
        #expect(DashboardSummaryView.summarySections([.speed, .quota, .today, .weeklyReset, .activity],
                    providesQuota: false) == [.speed, .today, .activity])
        let withQuota = DashboardSectionContentView.preferredHeight(for: .today, quota: nil)
        let withoutQuota = DashboardSectionContentView.preferredHeight(for: .today, quota: nil, providesQuota: false)
        #expect(withQuota - withoutQuota == 18)
        let fullHeight = DashboardSummaryView.preferredHeight(quota: nil, providesQuota: true,
            showsClaude: false, showsGrok: false, showsAntigravity: false, showsZCode: true,
            sections: [.speed, .today, .activity])
        let compactHeight = DashboardSummaryView.preferredHeight(quota: nil, providesQuota: false,
            showsClaude: false, showsGrok: false, showsAntigravity: false, showsZCode: true,
            sections: [.speed, .today, .activity])
        #expect(fullHeight - compactHeight == 18)
        let unavailable = SessionLauncher(launchZCodeApplication: { false })
        #expect(throws: SessionLauncherError.self) { try unavailable.open(session) }
    }
}
