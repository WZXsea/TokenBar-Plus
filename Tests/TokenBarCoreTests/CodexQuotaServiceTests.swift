import Foundation
import Testing
@testable import TokenBarCore

@Suite("CodexQuotaService")
struct CodexQuotaServiceTests {
    @Test("supports an offline injected quota loader")
    func injectedLoader() async throws {
        let expected = TestFixtures.quota(usedPercent: 35)
        let service = CodexQuotaService(loadQuota: { expected })

        let actual = try await service.fetchQuota()

        #expect(actual == expected)
    }

    @Test("adds effective reset credit inventory to the quota snapshot")
    func resetCredits() async throws {
        let fixture = TestFixtures.quota(usedPercent: 35)
        let base = QuotaSnapshot(
            session: fixture.session, weekly: fixture.weekly, resetCredits: nil,
            updatedAt: fixture.updatedAt, origin: .liveProvider, planType: "pro")
        let expectedCredits = QuotaResetCreditsSnapshot(
            availableCount: 2,
            nextExpiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        let service = CodexQuotaService(
            loadQuota: { base },
            loadResetCredits: { expectedCredits })

        let actual = try await service.fetchQuota()

        #expect(actual.session == base.session)
        #expect(actual.weekly == base.weekly)
        #expect(actual.resetCredits == expectedCredits)
        #expect(actual.planType == "pro")
        #expect(actual.origin == .liveProvider)
    }

    @Test("reset credit failures do not hide quota windows")
    func resetCreditFailureIsBestEffort() async throws {
        struct ResetFailure: Error {}
        let fixture = TestFixtures.quota(usedPercent: 35)
        let base = QuotaSnapshot(
            session: fixture.session, weekly: fixture.weekly, resetCredits: nil,
            updatedAt: fixture.updatedAt, origin: .liveProvider, planType: "pro")
        let service = CodexQuotaService(
            loadQuota: { base },
            loadResetCredits: { throw ResetFailure() })

        let actual = try await service.fetchQuota()

        #expect(actual == base)
    }
}
