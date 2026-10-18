import Foundation
import Testing
@testable import TokenBarCore

@Suite("ZCode local inputs")
struct ZCodeSupportTests {
    @Test func watchesDatabaseAndRolloutsWithoutCacheFeedback() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zcode/v2"), withIntermediateDirectories: true)
        try Data("{\"dataBaseDir\":\"/tmp/zcode-custom-base\"}".utf8).write(to: home.appendingPathComponent(".zcode/v2/setting.json"))
        let paths = ActivityFilePaths(environment: [:], homeDirectory: home)
        #expect(paths.matches(home.path + "/.zcode/cli/db/db.sqlite"))
        #expect(paths.matches(home.path + "/.zcode/cli/db/db.sqlite-wal"))
        #expect(paths.matches(home.path + "/.zcode/cli/rollout/a.jsonl"))
        #expect(paths.matches(home.path + "/.zcode/cli/debug/a.jsonl"))
        #expect(paths.matches("/tmp/zcode-custom-base/.zcode/cli/db/db.sqlite"))
        #expect(!paths.matches(home.path + "/.zcode/cli/db/db.sqlite-shm"))
        #expect(!paths.matches(home.path + "/Library/Caches/TokenBar/zcode.json"))
        let overridden = ActivityFilePaths(environment: ["ZCODE_DATA_BASE_DIR": "/tmp/zcode-env"], homeDirectory: home)
        #expect(overridden.matches("/tmp/zcode-env/.zcode/cli/rollout/a.jsonl"))
        #expect(!overridden.matches("/tmp/zcode-custom-base/.zcode/cli/db/db.sqlite"))
    }

    @Test @MainActor func customPricesPersistForZCode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prices.json")
        let store = ModelPricingStore(fileURL: url)
        let rule = ModelPriceOverride(platform: .zcode, modelID: "glm-fixture", inputPerMillion: 1,
            cachedInputPerMillion: 0.1, cacheWritePerMillion: 1, outputPerMillion: 2)
        try store.upsert(rule)
        #expect(ModelPricingStore(fileURL: url).overrides == [rule])
    }
}
