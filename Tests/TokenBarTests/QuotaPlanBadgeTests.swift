import Foundation
import Testing
import TokenBarCore
@testable import TokenBar

@MainActor
@Suite("Quota plan badges")
struct QuotaPlanBadgeTests {
    @Test("Provider plan metadata gives Pro a premium text badge and Plus a standard badge")
    func recognizedPlans() {
        let pro = QuotaPlanBadgePresentation(snapshot: self.snapshot(plan: "pro"))
        #expect(pro?.title == "PRO")
        #expect(pro?.style == .premium)
        #expect(pro?.helpText.contains("pro") == true)
        let plus = QuotaPlanBadgePresentation(snapshot: self.snapshot(plan: "plus", hasSession: true))
        #expect(plus?.title == "PLUS")
        #expect(plus?.style == .standard)
    }

    @Test("Quota rows and height follow returned windows independently of the plan badge")
    func providerWindowsRemainAuthoritative() {
        let proWeekly = self.snapshot(plan: "pro")
        let plusWithSession = self.snapshot(plan: "plus", hasSession: true)
        #expect(DashboardLayout.quotaHeight(quota: proWeekly) == 71)
        #expect(DashboardLayout.quotaHeight(quota: plusWithSession) == 125)
        #expect(DashboardLayout.quotaHeight(quota: self.snapshot(plan: "plus")) == 71)
        #expect(DashboardLayout.quotaHeight(quota: self.snapshot(plan: "pro", hasSession: true)) == 125)
        #expect(DashboardLayout.quotaHeight(quota: self.snapshot(plan: nil)) == 71)
    }

    private func snapshot(plan: String?, hasSession: Bool = false) -> QuotaSnapshot {
        QuotaSnapshot(
            session: hasSession ? QuotaWindowSnapshot(usedPercent: 20, windowMinutes: 300, resetsAt: nil) : nil,
            weekly: QuotaWindowSnapshot(usedPercent: 40, windowMinutes: 10_080, resetsAt: nil),
            resetCredits: nil,
            updatedAt: Date(timeIntervalSince1970: 1_792_200_000),
            planType: plan)
    }
}
