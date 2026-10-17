import Foundation
import Testing
@testable import TokenBarCore

@MainActor
@Suite("Custom price persistence and validation")
struct EssentialPricingTests {
    @Test("Rules persist independently, edits keep their UUID, and disabled rows remain on disk")
    func persistsAndEditsRules() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let isolatedURL = directory.appendingPathComponent("isolated.json")
            let store = ModelPricingStore(fileURL: url)
            let isolated = ModelPricingStore(fileURL: isolatedURL)
            var rule = self.rule(model: "  GPT-Fixture  ")
            #expect(store.activeFileURL == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            try store.upsert(rule)
            #expect(store.overrides.first?.modelID == "GPT-Fixture")
            #expect(store.revision == 1)
            #expect(store.activeFileURL == url)
            #expect(isolated.overrides.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: isolatedURL.path))

            rule.outputPerMillion = 12
            try store.upsert(rule)
            #expect(store.overrides.count == 1)
            #expect(store.overrides.first?.id == rule.id)
            #expect(store.overrides.first?.outputPerMillion == 12)
            #expect(store.revision == 2)
            try store.setEnabled(rule.id, isEnabled: false)
            #expect(store.activeFileURL == nil)
            #expect(store.overrides.count == 1)
            #expect(store.overrides.first?.enabled == false)
            #expect(FileManager.default.fileExists(atPath: url.path))

            let reloaded = ModelPricingStore(fileURL: url)
            #expect(reloaded.overrides == store.overrides)
            #expect(reloaded.activeFileURL == nil)
            #expect(reloaded.errorMessage == nil)
            try reloaded.setEnabled(rule.id, isEnabled: true)
            #expect(reloaded.activeFileURL == url)
            try reloaded.remove(rule.id)
            #expect(reloaded.overrides.isEmpty)
            #expect(reloaded.activeFileURL == nil)
        }
    }

    @Test("Rates require finite values in the supported range without changing memory or disk")
    func validatesRatesWithoutSideEffects() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let store = ModelPricingStore(fileURL: url)
            let baseline = self.rule()
            try store.upsert(baseline)
            let bytes = try Data(contentsOf: url)
            let revision = store.revision
            let paths: [WritableKeyPath<ModelPriceOverride, Double>] = [
                \.inputPerMillion, \.cachedInputPerMillion, \.cacheWritePerMillion, \.outputPerMillion,
            ]
            for path in paths {
                for value in [-1.0, Double.nan] {
                    var invalid = baseline
                    invalid[keyPath: path] = value
                    #expect(throws: ModelPricingError.invalidRate) { try store.upsert(invalid) }
                    #expect(store.overrides == [baseline])
                    #expect(store.revision == revision)
                    #expect(store.errorMessage == nil)
                    #expect(try Data(contentsOf: url) == bytes)
                }
            }
            var boundary = baseline
            boundary.inputPerMillion = 0
            boundary.outputPerMillion = 1_000_000
            try store.upsert(boundary)
            #expect(store.overrides == [boundary])
        }
    }
    private func rule(
        model: String = "fixture", platform: TokenPlatform = .codex,
        tier: ModelPriceTier = .any) -> ModelPriceOverride
    {
        ModelPriceOverride(platform: platform, modelID: model, serviceTier: tier,
                           inputPerMillion: 1, cachedInputPerMillion: 0.1,
                           cacheWritePerMillion: 1.2, outputPerMillion: 2.3)
    }

    private func payload(_ rules: [ModelPriceOverride], version: Int = 1) throws -> Data {
        let records = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rules))
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "overrides": records], options: [.sortedKeys])
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ModelPricingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
