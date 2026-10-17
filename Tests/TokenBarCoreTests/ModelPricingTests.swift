import Foundation
import Observation
import Testing
@testable import TokenBarCore

@MainActor
@Suite("Custom model pricing")
struct ModelPricingTests {
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

    @Test("Restoring automatic prices writes an empty versioned rules file and leaves neighboring data intact")
    func restoresAutomaticPricing() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let history = directory.appendingPathComponent("activity-snapshot.json")
            let historicalBytes = Data("historical-token-records".utf8)
            try historicalBytes.write(to: history)
            let store = ModelPricingStore(fileURL: url)
            try store.upsert(self.rule())
            let revision = store.revision
            try store.removeAll()
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])

            #expect(store.overrides.isEmpty)
            #expect(store.activeFileURL == nil)
            #expect(store.revision == revision + 1)
            #expect(payload["schemaVersion"] as? Int == 1)
            #expect((payload["overrides"] as? [Any])?.isEmpty == true)
            #expect(try Data(contentsOf: history) == historicalBytes)
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
                for value in [-1.0, Double.nan, .infinity, -.infinity, 1_000_000.01] {
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

    @Test("Model IDs trim whitespace, enforce length and controls, and support four platforms")
    func validatesTargets() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("nested/pricing.json")
            let store = ModelPricingStore(fileURL: url)
            for model in ["", "   ", "fixture\nmodel", "fixture\0model", String(repeating: "x", count: 201)] {
                #expect(throws: ModelPricingError.invalidModelID) { try store.upsert(self.rule(model: model)) }
            }
            #expect(throws: ModelPricingError.invalidPlatform) {
                try store.upsert(self.rule(platform: TokenPlatform(rawValue: "unsupported")))
            }
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
            #expect(store.revision == 0)
            try store.upsert(self.rule(model: "\n  fixture  \n"))
            #expect(store.overrides.first?.modelID == "fixture")
            for platform in [TokenPlatform.claude, .grok, .antigravity] {
                try store.upsert(self.rule(platform: platform))
            }
            #expect(store.overrides.count == 4)
        }
    }

    @Test("Targets are unique after trimming and case folding while modes and platforms remain distinct")
    func validatesUniqueTargets() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let store = ModelPricingStore(fileURL: url)
            let baseline = self.rule(model: "GPT-Fixture")
            try store.upsert(baseline)
            let bytes = try Data(contentsOf: url)
            #expect(throws: ModelPricingError.duplicateTarget) {
                try store.upsert(self.rule(model: " gpt-fixture "))
            }
            #expect(store.overrides == [baseline])
            #expect(try Data(contentsOf: url) == bytes)
            try store.upsert(self.rule(model: "gpt-fixture", tier: .standard))
            try store.upsert(self.rule(model: "gpt-fixture", tier: .fast))
            try store.upsert(self.rule(model: "gpt-fixture", platform: .claude))
            #expect(store.overrides.count == 4)
        }
    }

    @Test("Duplicate UUIDs and duplicate targets in files are rejected as a whole")
    func rejectsDuplicateFiles() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let first = self.rule()
            let duplicateID = ModelPriceOverride(id: first.id, platform: .codex, modelID: "other-model")
            for rules in [[first, duplicateID], [first, self.rule(model: " FIXTURE ")]] {
                let bytes = try self.payload(rules)
                try bytes.write(to: url)
                let store = ModelPricingStore(fileURL: url)
                #expect(store.overrides.isEmpty)
                #expect(store.errorMessage != nil)
                #expect(store.activeFileURL == nil)
                #expect(try Data(contentsOf: url) == bytes)
            }
        }
    }

    @Test("Unreadable payloads remain intact until an explicit restore")
    func protectsDamagedFiles() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let malformed = Data("{broken json".utf8)
            let unsupported = try self.payload([], version: 2)
            let oversized = Data(repeating: 32, count: 1_048_577)
            for bytes in [malformed, unsupported, oversized] {
                try bytes.write(to: url)
                let store = ModelPricingStore(fileURL: url)
                let message = store.errorMessage
                #expect(message != nil)
                #expect(store.overrides.isEmpty)
                #expect(store.activeFileURL == nil)
                #expect(throws: ModelPricingError.recoveryRequired) { try store.upsert(self.rule()) }
                #expect(throws: ModelPricingError.recoveryRequired) { try store.remove(UUID()) }
                #expect(throws: ModelPricingError.recoveryRequired) { try store.setEnabled(UUID(), isEnabled: true) }
                #expect(store.errorMessage == message)
                #expect(store.revision == 0)
                #expect(try Data(contentsOf: url) == bytes)
                try store.removeAll()
                #expect(store.errorMessage == nil)
                #expect(store.revision == 1)
                try store.upsert(self.rule())
                #expect(store.activeFileURL == url)
            }
        }
    }

    @Test("Version one decoding supplies optional legacy defaults without rewriting the file")
    func readsOptionalDefaults() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            var record = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(self.rule())) as? [String: Any])
            record.removeValue(forKey: "enabled")
            record.removeValue(forKey: "serviceTier")
            let bytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "overrides": [record]])
            try bytes.write(to: url)
            let store = ModelPricingStore(fileURL: url)
            #expect(store.overrides.first?.serviceTier == .any)
            #expect(store.overrides.first?.enabled == true)
            #expect(store.errorMessage == nil)
            #expect(store.revision == 0)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test("Oversized serialized updates leave loaded compact rules and bytes intact")
    func rejectsOversizedSaves() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let rules = (0 ..< 4_000).map { self.rule(model: "model-\($0)") }
            let bytes = try self.payload(rules)
            #expect(bytes.count <= 1_048_576)
            try bytes.write(to: url)
            let store = ModelPricingStore(fileURL: url)
            #expect(store.errorMessage == nil)
            #expect(store.overrides.count == rules.count)
            #expect(throws: ModelPricingError.fileTooLarge) { try store.upsert(self.rule(model: "new-model")) }
            #expect(store.overrides == rules)
            #expect(store.revision == 0)
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test("Atomic publication uses owner-only permissions and leaves no staging file")
    func privatePermissions() throws {
        try self.withDirectory { directory in
            let url = directory.appendingPathComponent("pricing.json")
            let store = ModelPricingStore(fileURL: url)
            let rule = self.rule()
            try store.upsert(rule)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try store.setEnabled(rule.id, isEnabled: false)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["pricing.json"])
            let payload = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let record = try #require((payload["overrides"] as? [[String: Any]])?.first)
            #expect(record["modelID"] as? String == rule.modelID)
            #expect(record["modelId"] == nil)
            #expect(record["serviceTier"] as? String == "any")
        }
    }

    @Test("Filesystem failures and symbolic links preserve existing bytes and state")
    func protectsOtherFiles() throws {
        try self.withDirectory { directory in
            let blocker = directory.appendingPathComponent("blocker")
            let marker = Data("preserved".utf8)
            try marker.write(to: blocker)
            let store = ModelPricingStore(fileURL: blocker.appendingPathComponent("pricing.json"))
            #expect(throws: (any Error).self) { try store.upsert(self.rule()) }
            #expect(store.overrides.isEmpty)
            #expect(store.revision == 0)
            #expect(try Data(contentsOf: blocker) == marker)

            let link = directory.appendingPathComponent("pricing.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blocker)
            let linkedStore = ModelPricingStore(fileURL: link)
            #expect(linkedStore.errorMessage != nil)
            #expect(linkedStore.activeFileURL == nil)
            #expect(throws: ModelPricingError.regularFileRequired) { try linkedStore.removeAll() }
            #expect(try Data(contentsOf: blocker) == marker)
        }
    }

    @Test("Revisions and active file availability participate in Observation after successful mutations")
    func observesSuccessfulUpdates() throws {
        try self.withDirectory { directory in
            let store = ModelPricingStore(fileURL: directory.appendingPathComponent("pricing.json"))
            let changed = PricingObservationFlag()
            withObservationTracking { _ = store.revision } onChange: { changed.mark() }
            let activeChanged = PricingObservationFlag()
            withObservationTracking { _ = store.activeFileURL } onChange: { activeChanged.mark() }
            let rule = self.rule()
            try store.upsert(rule)
            #expect(changed.isSet)
            #expect(activeChanged.isSet)
            #expect(store.revision == 1)
            let unchanged = PricingObservationFlag()
            withObservationTracking { _ = store.revision } onChange: { unchanged.mark() }
            var invalid = rule
            invalid.outputPerMillion = -1
            #expect(throws: ModelPricingError.invalidRate) { try store.upsert(invalid) }
            #expect(!unchanged.isSet)
            #expect(store.revision == 1)
        }
    }

    @Test("Observed model IDs and automatic quotes retain platform, tier, and unknown cache-write prices")
    func quoteContracts() throws {
        let observed = ObservedPricingModel(platform: .claude, modelID: "claude-fixture")
        #expect(observed.id == "claude:claude-fixture")
        let quote = AutomaticModelPriceQuote(
            platform: .codex, modelID: "gpt-fixture", serviceTier: .fast,
            rates: AutomaticModelPriceRates(inputPerMillion: 2, cachedInputPerMillion: 0.2, outputPerMillion: 12))
        let decoded = try JSONDecoder().decode(AutomaticModelPriceQuote.self, from: JSONEncoder().encode(quote))
        #expect(decoded == quote)
        #expect(decoded.rates?.cacheWritePerMillion == nil)
        #expect(ModelPriceTier.any.displayName == "所有模式")
        #expect(ModelPriceTier.standard.displayName == "标准／未标注")
        #expect(ModelPriceTier.fast.displayName == "Fast")
        #expect(ModelPricingStore.defaultURL().lastPathComponent == "custom-pricing.json")
        #expect(ModelPricingStore.defaultURL().deletingLastPathComponent().lastPathComponent == "TokenBar")
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

private final class PricingObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { self.lock.withLock { self.value } }
    func mark() { self.lock.withLock { self.value = true } }
}
