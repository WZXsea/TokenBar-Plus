import Foundation
import Testing
@testable import TokenBarCore

@Suite("Quota plan metadata")
struct QuotaPlanMetadataTests {
    @Test("legacy quota caches decode without a plan")
    func legacyCache() throws {
        let data = Data(#"{"updatedAt":0,"weekly":{"usedPercent":35,"windowMinutes":10080}}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
        #expect(decoded.planType == nil)
        #expect(decoded.planDisplayName == nil)
        #expect(decoded.weekly?.usedPercent == 35)
    }

    @Test("plan metadata survives cache encoding")
    func roundTrip() throws {
        let snapshot = QuotaSnapshot(session: nil, weekly: nil, resetCredits: nil,
                                     updatedAt: Date(), planType: "pro")
        let restored = try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(restored == snapshot)
    }

    @Test("formats known plans and safely preserves unknown identifiers")
    func displayNames() {
        let cases: [(String?, String?)] = [
            (nil, nil), ("  ", nil), ("free", "Free"), ("PLUS", "Plus"),
            ("pro", "Pro"), ("prolite", "Pro"), ("pro_lite", "Pro"),
            ("business", "Business"), ("team", "Team"), ("enterprise", "Enterprise"),
            ("edu", "Edu"), (" new\nplan ", "new plan"),
        ]
        for (raw, expected) in cases {
            let snapshot = QuotaSnapshot(session: nil, weekly: nil, resetCredits: nil,
                                         updatedAt: Date(), planType: raw)
            #expect(snapshot.planDisplayName == expected)
            #expect(snapshot.planType == raw)
        }
    }
}
