import Foundation
import Testing
@testable import TokenBarCore

enum TestFixtures {
    static func quota(usedPercent: Double) -> QuotaSnapshot {
        QuotaSnapshot(session: nil,
            weekly: QuotaWindowSnapshot(usedPercent: usedPercent, windowMinutes: 10080, resetsAt: Date(timeIntervalSince1970: 1_800_100_000)),
            resetCredits: nil, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    static func activity() -> ActivitySnapshot {
        ActivitySnapshot(schemaVersion: 3, generatedAtMs: 1_720_000_000_000, timezone: "UTC", today: .zero, sessions: [], days: [])
    }
}
