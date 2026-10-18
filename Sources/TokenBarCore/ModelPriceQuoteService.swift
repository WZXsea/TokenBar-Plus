import Foundation

public enum ModelPriceQuoteError: LocalizedError, Sendable {
    case invalidModel
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidModel: "请填写有效的模型 ID，并选择对应平台。"
        case .invalidResponse: "自动单价的返回数据有误，请重试或填写自定义单价。"
        }
    }
}

/// Reads the same automatic pricing engines used for local activity estimates.
public struct ModelPriceQuoteService: ModelPriceQuoting, Sendable {
    private let environment: [String: String]
    private let openAI: (any OpenAIPricingCatalogUpdating)?
    private let anthropic: (any AnthropicPricingCatalogUpdating)?
    private let openRouter: (any OpenRouterPricingCatalogUpdating)?
    private let resolveHelper: @Sendable () throws -> URL
    private let runner: any ActivityHelperRunning

    public init(
        helperURL: URL? = nil,
        openAIPricingCatalog: (any OpenAIPricingCatalogUpdating)? = nil,
        anthropicPricingCatalog: (any AnthropicPricingCatalogUpdating)? = nil,
        openRouterPricingCatalog: (any OpenRouterPricingCatalogUpdating)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: any ActivityHelperRunning = SubprocessActivityHelperRunner())
    {
        self.environment = environment
        self.openAI = openAIPricingCatalog
        self.anthropic = anthropicPricingCatalog
        self.openRouter = openRouterPricingCatalog
        self.runner = runner
        self.resolveHelper = {
            try ActivityService.resolveHelperExecutable(explicitURL: helperURL, environment: environment)
        }
    }

    public func quote(
        platform: TokenPlatform,
        modelID: String,
        tier: ModelPriceTier) async throws -> AutomaticModelPriceQuote
    {
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, modelID.unicodeScalars.count <= 200,
              modelID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              [TokenPlatform.codex, .claude, .grok, .antigravity, .zcode].contains(platform)
        else { throw ModelPriceQuoteError.invalidModel }
        let helper = try self.resolveHelper()
        async let openAIURL = self.openAI?.refreshIfNeeded()
        async let anthropicURL = self.anthropic?.refreshIfNeeded()
        async let openRouterURL = self.openRouter?.refreshIfNeeded()
        let urls = await (openAIURL, anthropicURL, openRouterURL)
        let effectiveTier: ModelPriceTier = tier == .fast ? .fast : .standard
        var arguments = [
            "price-quote", "--platform", platform.rawValue,
            "--model", modelID, "--service-tier", effectiveTier.rawValue,
            "--offline-pricing",
        ]
        if let url = urls.0 { arguments += ["--openai-pricing-markdown", url.path] }
        if let url = urls.1 { arguments += ["--anthropic-pricing-markdown", url.path] }
        if let url = urls.2 { arguments += ["--openrouter-pricing-json", url.path] }
        var environment = self.environment
        environment.removeValue(forKey: "TOKENBAR_SYNC_TOKEN")
        let data = try await self.runner.run(
            executableURL: helper,
            arguments: arguments,
            environment: environment,
            timeout: 30)
        guard !data.isEmpty, data.count <= 1_048_576,
              let quote = try? JSONDecoder().decode(AutomaticModelPriceQuote.self, from: data),
              quote.platform == platform,
              quote.modelID.lowercased() == modelID.lowercased(),
              quote.serviceTier == effectiveTier
        else { throw ModelPriceQuoteError.invalidResponse }
        if let rates = quote.rates {
            let fields = [rates.inputPerMillion, rates.cachedInputPerMillion,
                          rates.cacheWritePerMillion, rates.outputPerMillion]
            guard fields.compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 })
            else { throw ModelPriceQuoteError.invalidResponse }
        }
        return quote
    }
}
