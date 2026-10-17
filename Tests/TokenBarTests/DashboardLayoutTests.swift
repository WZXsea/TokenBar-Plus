import Testing
import TokenBarCore
@testable import TokenBar

@MainActor
@Suite("Dashboard layout")
struct DashboardLayoutTests {
    @Test("standalone summary heights include exactly one menu divider")
    func standaloneSummaryHeights() {
        #expect(DashboardSectionContentView.preferredHeight(for: .speed, quota: nil) == 165)
        #expect(DashboardSectionContentView.preferredHeight(for: .today, quota: nil) == 113)
        #expect(DashboardSectionContentView.preferredHeight(for: .weeklyReset, quota: nil) == 65)
        let standaloneQuotaHeight = DashboardSectionContentView.preferredHeight(for: .quota, quota: nil)
        let expectedQuotaHeight = DashboardOverviewView.quotaHeight(quota: nil) + 1
        #expect(abs(Double(standaloneQuotaHeight) - Double(expectedQuotaHeight)) < 0.001)
        for section in [TokenBarDashboardSection.activity, .memory, .recentSessions] {
            #expect(DashboardSectionContentView.preferredHeight(for: section, quota: nil) == 0)
        }
    }

    @Test("summary preview preserves section order and removes duplicate or separately hosted sections")
    func previewSectionOrder() {
        #expect(DashboardSummaryView.summarySections(
            [.today, .memory, .speed, .recentSessions, .activity, .quota, .weeklyReset, .today],
            providesQuota: true) == [.today, .speed, .activity, .quota])
        #expect(DashboardSummaryView.summarySections(
            [.quota, .weeklyReset, .speed, .today, .activity],
            providesQuota: false) == [.speed, .today, .activity])
    }

    @Test("summary preview height follows only the selected sections")
    func previewHeightFollowsSelection() {
        let empty = DashboardSummaryView.preferredHeight(
            quota: nil, showsClaude: false, showsGrok: false, showsAntigravity: false, sections: [])
        let speedOnly = DashboardSummaryView.preferredHeight(
            quota: nil, showsClaude: false, showsGrok: false, showsAntigravity: false, sections: [.speed])
        let speedAndToday = DashboardSummaryView.preferredHeight(
            quota: nil, showsClaude: false, showsGrok: false, showsAntigravity: false, sections: [.today, .speed])
        #expect(empty == DashboardOverviewView.compactHeaderHeight)
        #expect(speedOnly - empty == 165)
        #expect(speedAndToday - speedOnly == 113)
    }

    @Test("quota height follows the rows returned by the provider")
    func quotaHeightFollowsAvailableRows() {
        let weeklyOnly = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: false,
            hasResetCredits: false)
        let weeklyAndFiveHour = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: true,
            hasResetCredits: false)
        let weeklyAndResetCredits = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: false,
            hasResetCredits: true)
        let allRows = DashboardOverviewView.quotaHeight(
            hasWeekly: true,
            hasFiveHour: true,
            hasResetCredits: true)

        #expect(weeklyOnly == 71)
        #expect(weeklyAndFiveHour - weeklyOnly == 54)
        #expect(weeklyOnly < weeklyAndFiveHour)
        #expect(weeklyOnly < weeklyAndResetCredits)
        #expect(weeklyAndFiveHour < allRows)
        #expect(weeklyAndResetCredits < allRows)
    }

    @Test("single-platform header omits the selector height")
    func compactSinglePlatformHeader() {
        #expect(
            DashboardOverviewView.headerHeight(
                showsClaude: false,
                showsGrok: false,
                showsAntigravity: false)
                == DashboardOverviewView.compactHeaderHeight)
        #expect(
            DashboardOverviewView.headerHeight(
                showsClaude: false,
                showsGrok: false,
                showsAntigravity: false)
                < DashboardOverviewView.headerHeight(
                    showsClaude: true,
                    showsGrok: false,
                    showsAntigravity: false))
        #expect(
            DashboardOverviewView.headerHeight(
                showsClaude: false,
                showsGrok: false,
                showsAntigravity: false)
                < DashboardOverviewView.headerHeight(
                    showsClaude: false,
                    showsGrok: false,
                    showsAntigravity: true))
    }
}
