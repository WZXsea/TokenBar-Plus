import Foundation

public protocol OpenAIPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
    func refreshNowIfAllowed() async -> URL?
}

public extension OpenAIPricingCatalogUpdating {
    func refreshNowIfAllowed() async -> URL? { nil }
}

public actor OpenAIPricingCatalogUpdater: OpenAIPricingCatalogUpdating {
    public static let officialMarkdownURL = URL(
        string: "https://developers.openai.com/api/docs/pricing.md")!
    public static let defaultRefreshInterval: TimeInterval = 24 * 60 * 60
    public static let defaultRetryInterval: TimeInterval = 60 * 60

    private let cache: CachedPricingCatalog

    public init(
        sourceURL: URL = OpenAIPricingCatalogUpdater.officialMarkdownURL,
        fileURL: URL = OpenAIPricingCatalogUpdater.defaultURL(),
        refreshInterval: TimeInterval = OpenAIPricingCatalogUpdater.defaultRefreshInterval,
        retryInterval: TimeInterval = OpenAIPricingCatalogUpdater.defaultRetryInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil)
    {
        self.cache = CachedPricingCatalog(
            sourceURL: sourceURL, fileURL: fileURL,
            refreshInterval: refreshInterval, retryInterval: retryInterval,
            now: now, fetch: fetch ?? Self.download, validate: Self.isValidOfficialMarkdown)
    }

    public func refreshIfNeeded() async -> URL? {
        await self.cache.refresh(force: false)
    }

    public func refreshNowIfAllowed() async -> URL? {
        await self.cache.refresh(force: true)
    }

    public nonisolated static func defaultURL() -> URL {
        CachedPricingCatalog.defaultURL(filename: "openai-pricing.md")
    }

    private nonisolated static func isValidOfficialMarkdown(_ data: Data) -> Bool {
        guard data.count >= 1_024,
              data.count <= 2_000_000,
              let markdown = String(data: data, encoding: .utf8)
        else {
            return false
        }
        let lines = markdown.lines
        guard lines.contains(where: { $0 == "# Pricing" }) else { return false }
        return Self.hasValidPricingSection(lines, heading: "### Standard pricing data")
            && Self.hasValidPricingSection(lines, heading: "### Fast pricing data")
    }

    private nonisolated static func hasValidPricingSection(
        _ lines: [String],
        heading: String) -> Bool
    {
        let expectedHeader = [
            "Model",
            "Short context input",
            "Short context cached input",
            "Short context cache writes",
            "Short context output",
            "Long context input",
            "Long context cached input",
            "Long context cache writes",
            "Long context output",
        ]
        guard let headingIndex = lines.firstIndex(of: heading) else { return false }
        let section = lines[lines.index(after: headingIndex)...]
        guard let headerIndex = section.firstIndex(where: { $0.hasPrefix("| Model |") }),
              Self.tableCells(section[headerIndex]) == expectedHeader
        else {
            return false
        }

        let rows = section[section.index(after: headerIndex)...]
            .dropFirst()
            .prefix(while: { $0.hasPrefix("|") })
            .map(Self.tableCells)
        guard rows.count >= 8,
              rows.allSatisfy({ cells in
                  cells.count == expectedHeader.count
                      && !cells[0].isEmpty
                      && cells.dropFirst().allSatisfy(Self.isPriceCell)
              })
        else {
            return false
        }

        let requiredModels = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        return requiredModels.allSatisfy { model in
            rows.contains(where: { cells in
                cells[0] == model
            })
        }
    }

    private nonisolated static func tableCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private nonisolated static func isPriceCell(_ value: String) -> Bool {
        if value == "-" { return true }
        guard value.hasPrefix("$"),
              let price = Double(value.dropFirst())
        else {
            return false
        }
        return price.isFinite && price > 0 && price <= 1_000
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        try await CachedPricingCatalog.download(
            url, expectedHost: officialMarkdownURL.host, accept: "text/markdown",
            requiredMIMEType: "text/markdown")
    }
}

private extension String {
    var lines: [String] {
        self.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
