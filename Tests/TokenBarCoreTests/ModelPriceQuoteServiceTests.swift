import Foundation
import Testing
@testable import TokenBarCore

private actor QuoteRunner: ActivityHelperRunning {
    let output: Data
    private(set) var arguments: [String] = []
    private(set) var environment: [String: String] = [:]
    init(_ output: Data) { self.output = output }
    func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) -> Data {
        self.arguments = arguments
        self.environment = environment
        return self.output
    }
}

@Suite("Automatic model price quote service")
struct ModelPriceQuoteServiceTests {
    @Test("quotes use the helper and map any mode to standard while stripping sync credentials")
    func quotesAutomaticRates() async throws {
        let quote = AutomaticModelPriceQuote(
            platform: .codex, modelID: "test-model", serviceTier: .standard,
            rates: .init(inputPerMillion: 2, cachedInputPerMillion: 0.2, outputPerMillion: 10))
        let runner = QuoteRunner(try JSONEncoder().encode(quote))
        let service = ModelPriceQuoteService(
            helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ["TOKENBAR_SYNC_TOKEN": "private", "PRESERVED": "value"], runner: runner)
        let result = try await service.quote(platform: .codex, modelID: " test-model ", tier: .any)
        #expect(result == quote)
        #expect(result.rates?.cacheWritePerMillion == nil)
        #expect(await runner.arguments == [
            "price-quote", "--platform", "codex", "--model", "test-model",
            "--service-tier", "standard", "--offline-pricing",
        ])
        #expect(await runner.environment["TOKENBAR_SYNC_TOKEN"] == nil)
        #expect(await runner.environment["PRESERVED"] == "value")
    }

    @Test("unknown automatic models retain null rates")
    func unknownRates() async throws {
        let quote = AutomaticModelPriceQuote(platform: .grok, modelID: "unknown-model", serviceTier: .fast)
        let runner = QuoteRunner(try JSONEncoder().encode(quote))
        let service = ModelPriceQuoteService(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        #expect(try await service.quote(platform: .grok, modelID: "unknown-model", tier: .fast).rates == nil)
    }

    @Test("metadata mismatches, malformed data, oversized data and invalid prices are rejected")
    func rejectsInvalidResponses() async throws {
        let invalidQuotes = [
            AutomaticModelPriceQuote(platform: .claude, modelID: "test-model", serviceTier: .standard),
            AutomaticModelPriceQuote(platform: .codex, modelID: "other-model", serviceTier: .standard),
            AutomaticModelPriceQuote(platform: .codex, modelID: "test-model", serviceTier: .fast),
            AutomaticModelPriceQuote(platform: .codex, modelID: "test-model", serviceTier: .standard,
                                     rates: .init(inputPerMillion: -1)),
            AutomaticModelPriceQuote(platform: .codex, modelID: "test-model", serviceTier: .standard,
                                     rates: .init(outputPerMillion: 1_000_001)),
        ]
        let outputs = try invalidQuotes.map { try JSONEncoder().encode($0) } + [
            Data(), Data("invalid".utf8), Data(repeating: 32, count: 1_048_577),
        ]
        for output in outputs {
            let service = ModelPriceQuoteService(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: QuoteRunner(output))
            await #expect(throws: ModelPriceQuoteError.self) {
                try await service.quote(platform: .codex, modelID: "test-model", tier: .standard)
            }
        }
    }

    @Test("invalid model identifiers are rejected before invoking the helper")
    func rejectsInvalidModel() async throws {
        let runner = QuoteRunner(Data())
        let service = ModelPriceQuoteService(helperURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        for model in ["  ", "model\u{0}name", String(repeating: "x", count: 201)] {
            await #expect(throws: ModelPriceQuoteError.self) {
                try await service.quote(platform: .codex, modelID: model, tier: .any)
            }
        }
        #expect(await runner.arguments.isEmpty)
    }
}
