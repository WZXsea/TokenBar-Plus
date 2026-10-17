import Foundation
import Testing
@testable import TokenBarCore

@Suite("Quota reset credit details")
struct QuotaResetCreditsTests {
    @Test("effective availability includes future or unspecified expiry and excludes the exact expiry boundary")
    func effectiveAvailability() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = QuotaResetCredit(status: "available", expiresAt: now.addingTimeInterval(1))
        let unspecified = QuotaResetCredit(status: "available", expiresAt: nil)
        let boundary = QuotaResetCredit(status: "available", expiresAt: now)
        let past = QuotaResetCredit(status: "available", expiresAt: now.addingTimeInterval(-1))

        #expect(future.isAvailable(at: now))
        #expect(unspecified.isAvailable(at: now))
        #expect(!boundary.isAvailable(at: now))
        #expect(!past.isAvailable(at: now))
        #expect(future.effectiveStatus(at: now) == "available")
        #expect(unspecified.effectiveStatus(at: now) == "available")
        #expect(boundary.effectiveStatus(at: now) == "expired")
        #expect(past.effectiveStatus(at: now) == "expired")
        #expect(boundary.status == "available")
    }

    @Test("server statuses and unknown raw values are preserved", arguments: ["redeemed", "used", "expired", "future-status", "Available"])
    func rawStatusIsPreserved(status: String) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let credit = QuotaResetCredit(status: status, expiresAt: now.addingTimeInterval(-1))

        #expect(!credit.isAvailable(at: now))
        #expect(credit.effectiveStatus(at: now) == status)
        #expect(credit.status == status)
    }

    @Test("legacy summaries decode with empty details and keep the saved count")
    func legacySummaryCompatibility() throws {
        let data = Data("{\"availableCount\":3,\"nextExpiresAt\":1000}".utf8)
        let snapshot = try JSONDecoder().decode(QuotaResetCreditsSnapshot.self, from: data)

        #expect(snapshot.availableCount == 3)
        #expect(snapshot.nextExpiresAt == Date(timeIntervalSinceReferenceDate: 1000))
        #expect(snapshot.credits.isEmpty)
        #expect(snapshot.serverAvailableCount == nil)
        let restored = try JSONDecoder().decode(QuotaResetCreditsSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored == snapshot)
    }

    @Test("credit details round-trip with original order and independent server count")
    func detailsRoundTrip() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let credits = [
            QuotaResetCredit(status: "redeemed", expiresAt: expiry),
            QuotaResetCredit(status: "future-status", expiresAt: nil),
            QuotaResetCredit(status: "available", expiresAt: expiry.addingTimeInterval(100)),
        ]
        let snapshot = QuotaResetCreditsSnapshot(
            availableCount: 1,
            nextExpiresAt: expiry.addingTimeInterval(100),
            credits: credits,
            serverAvailableCount: 2)

        let restored = try JSONDecoder().decode(QuotaResetCreditsSnapshot.self, from: JSONEncoder().encode(snapshot))

        #expect(restored == snapshot)
        #expect(restored.credits == credits)
        #expect(restored.availableCount == 1)
        #expect(restored.serverAvailableCount == 2)
    }
}
