import Foundation
import Testing
@testable import TokenBarCore

@Suite("Exact observed pricing model metadata")
struct PricingModelMetadataTests {
    private let models = [
        ObservedPricingModel(platform: .codex, modelID: "openai_codex/gpt-5.4-2026-03-05(high)"),
        ObservedPricingModel(platform: .claude, modelID: "claude-sonnet-4-5"),
    ]

    @Test("metadata preserves exact model IDs and the modelID JSON key")
    func exactMetadataRoundTrip() throws {
        let snapshot = self.snapshot(sources: [])
        let data = try JSONEncoder().encode(snapshot)
        let encoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(encoded["pricingModels"] as? [[String: String]])
        #expect(entries[0]["modelID"] == self.models[0].modelID)
        #expect(entries[0]["modelId"] == nil)
        let decoded = try JSONDecoder().decode(ActivitySnapshot.self, from: data)
        #expect(decoded.pricingModels == self.models)
        #expect(decoded.redactedForCache().pricingModels == self.models)
    }

    @Test("old snapshots retain absent metadata for the legacy observation fallback")
    func legacySnapshotCompatibility() throws {
        let fixture = TestFixtures.activity()
        let decoded = try JSONDecoder().decode(ActivitySnapshot.self, from: JSONEncoder().encode(fixture))
        #expect(decoded.pricingModels == nil)
        #expect(decoded.sessions == fixture.sessions)
        #expect(decoded.days == fixture.days)
    }

    @Test("platform scoping filters metadata for source and legacy snapshots")
    func scopesMetadata() {
        let source = ActivitySourceSnapshot(platform: .claude, today: .zero, weeklySinceReset: nil, days: [])
        let snapshot = self.snapshot(sources: [source])
        #expect(snapshot.scoped(to: .claude).pricingModels == [self.models[1]])
        #expect(snapshot.scoped(to: .grok).pricingModels == [])
        #expect(snapshot.scoped(to: nil).pricingModels == self.models)
        #expect(self.snapshot(sources: []).scoped(to: .codex).pricingModels == [self.models[0]])
    }

    @Test("activity cache redaction retains exact pricing observations")
    func cacheRetainsMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBarPricingMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(fileURL: directory.appendingPathComponent("activity.json"))
        try await cache.saveActivity(self.snapshot(sources: []))
        let decoded = try await cache.loadActivity()
        #expect(decoded?.pricingModels == self.models)
    }

    private func snapshot(sources: [ActivitySourceSnapshot]) -> ActivitySnapshot {
        ActivitySnapshot(
            schemaVersion: 11, generatedAtMs: 1_800_000_000_000, timezone: "UTC", today: .zero,
            sessions: [], days: [], sources: sources, pricingModels: self.models)
    }
}
