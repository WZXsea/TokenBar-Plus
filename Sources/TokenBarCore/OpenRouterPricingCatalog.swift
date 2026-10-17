import Foundation

public protocol OpenRouterPricingCatalogUpdating: Sendable {
    func refreshIfNeeded() async -> URL?
    func refreshNowIfAllowed() async -> URL?
}

public extension OpenRouterPricingCatalogUpdating {
    func refreshNowIfAllowed() async -> URL? { nil }
}

/// Keeps a local copy of OpenRouter's public model catalog.
///
/// Google publishes no machine-readable Gemini rate table, so TokenBar reads
/// the same rates from this catalog, which lists them as per-token JSON along
/// with the long-context override. The helper falls back to its bundled table
/// whenever the catalog fails the checks below, so a schema change costs
/// freshness instead of correctness.
public actor OpenRouterPricingCatalogUpdater: OpenRouterPricingCatalogUpdating {
    public static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models")!
    public static let defaultRefreshInterval: TimeInterval = 24 * 60 * 60
    public static let defaultRetryInterval: TimeInterval = 60 * 60

    private let cache: CachedPricingCatalog

    public init(
        sourceURL: URL = OpenRouterPricingCatalogUpdater.catalogURL,
        fileURL: URL = OpenRouterPricingCatalogUpdater.defaultURL(),
        refreshInterval: TimeInterval = OpenRouterPricingCatalogUpdater.defaultRefreshInterval,
        retryInterval: TimeInterval = OpenRouterPricingCatalogUpdater.defaultRetryInterval,
        now: @escaping @Sendable () -> Date = Date.init,
        fetch: (@Sendable (URL) async throws -> Data)? = nil)
    {
        self.cache = CachedPricingCatalog(
            sourceURL: sourceURL, fileURL: fileURL,
            refreshInterval: refreshInterval, retryInterval: retryInterval,
            now: now, fetch: fetch ?? Self.download, validate: Self.isValidCatalog)
    }

    public func refreshIfNeeded() async -> URL? {
        await self.cache.refresh(force: false)
    }

    public func refreshNowIfAllowed() async -> URL? {
        await self.cache.refresh(force: true)
    }

    public nonisolated static func defaultURL() -> URL {
        CachedPricingCatalog.defaultURL(filename: "openrouter-models.json")
    }

    nonisolated static func isValidCatalog(_ data: Data) -> Bool {
        guard data.count >= 4_096,
              data.count <= 16_000_000,
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = catalog["data"] as? [[String: Any]],
              models.count >= 50
        else {
            return false
        }
        return models.filter { model in
            guard let id = model["id"] as? String,
                  id.hasPrefix("google/gemini"),
                  !id.contains(":"),
                  let pricing = model["pricing"] as? [String: Any]
            else {
                return false
            }
            return pricing["prompt"] != nil && pricing["completion"] != nil
        }.count >= 8
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        try await CachedPricingCatalog.download(
            url, expectedHost: catalogURL.host, accept: "application/json",
            requiredMIMEType: nil)
    }
}
