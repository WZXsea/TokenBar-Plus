import Foundation

public protocol AnthropicPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
    func refreshNowIfAllowed() async -> URL?
}

public extension AnthropicPricingCatalogUpdating {
    func refreshNowIfAllowed() async -> URL? { nil }
}

public actor AnthropicPricingCatalogUpdater: AnthropicPricingCatalogUpdating {
    public static let officialMarkdownURL = URL(
        string: "https://platform.claude.com/docs/en/about-claude/pricing.md")!
    public static let defaultRefreshInterval: TimeInterval = 24 * 60 * 60
    public static let defaultRetryInterval: TimeInterval = 60 * 60

    private let cache: CachedPricingCatalog

    public init(
        sourceURL: URL = AnthropicPricingCatalogUpdater.officialMarkdownURL,
        fileURL: URL = AnthropicPricingCatalogUpdater.defaultURL(),
        refreshInterval: TimeInterval = AnthropicPricingCatalogUpdater.defaultRefreshInterval,
        retryInterval: TimeInterval = AnthropicPricingCatalogUpdater.defaultRetryInterval,
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
        CachedPricingCatalog.defaultURL(filename: "anthropic-pricing.md")
    }

    private nonisolated static func isValidOfficialMarkdown(_ data: Data) -> Bool {
        guard data.count >= 256,
              data.count <= 2_000_000,
              let markdown = String(data: data, encoding: .utf8),
              markdown.contains("## Model pricing"),
              let header = markdown.split(separator: "\n").first(where: {
                  Self.isOfficialPricingHeader(String($0))
              }),
              Self.tableCells(String(header)).count == 6
        else {
            return false
        }
        return markdown.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("| Claude ") }
            .count >= 5
    }

    private nonisolated static func isOfficialPricingHeader(_ line: String) -> Bool {
        let header = line.trimmingCharacters(in: .whitespaces).lowercased()
        return header.hasPrefix("| model")
            && header.contains("base input tokens")
            && header.contains("5m cache writes")
            && header.contains("1h cache writes")
            && (header.contains("cache hits and refreshes")
                || header.contains("cache hits & refreshes"))
            && header.contains("output tokens")
    }

    private nonisolated static func tableCells(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        try await CachedPricingCatalog.download(
            url, expectedHost: officialMarkdownURL.host, accept: "text/markdown",
            requiredMIMEType: nil)
    }
}
