import Foundation

/// Shared storage and retry policy; each provider keeps its own schema checks.
actor CachedPricingCatalog {
    private let sourceURL: URL
    private let fileURL: URL
    private let refreshInterval: TimeInterval
    private let retryInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URL) async throws -> Data
    private let validate: @Sendable (Data) -> Bool
    private var lastAttemptAt: Date?

    init(
        sourceURL: URL, fileURL: URL,
        refreshInterval: TimeInterval, retryInterval: TimeInterval,
        now: @escaping @Sendable () -> Date,
        fetch: @escaping @Sendable (URL) async throws -> Data,
        validate: @escaping @Sendable (Data) -> Bool)
    {
        self.sourceURL = sourceURL
        self.fileURL = fileURL
        self.refreshInterval = refreshInterval
        self.retryInterval = retryInterval
        self.now = now
        self.fetch = fetch
        self.validate = validate
    }

    func refresh(force: Bool) async -> URL? {
        let now = self.now()
        if !force, let modifiedAt = try? FileManager.default
            .attributesOfItem(atPath: self.fileURL.path)[.modificationDate] as? Date,
           now.timeIntervalSince(modifiedAt) < self.refreshInterval
        {
            return self.fileURL
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < self.retryInterval {
            return force ? nil : self.existingURL
        }
        self.lastAttemptAt = now
        do {
            let data = try await self.fetch(self.sourceURL)
            guard self.validate(data) else { return force ? nil : self.existingURL }
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: self.fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: self.fileURL.path)
            return self.fileURL
        } catch {
            return force ? nil : self.existingURL
        }
    }

    private var existingURL: URL? {
        FileManager.default.fileExists(atPath: self.fileURL.path) ? self.fileURL : nil
    }

    nonisolated static func defaultURL(filename: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    nonisolated static func download(
        _ url: URL, expectedHost: String?, accept: String, requiredMIMEType: String? = nil) async throws -> Data
    {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == expectedHost,
              requiredMIMEType == nil || response.mimeType == requiredMIMEType
        else { throw URLError(.badServerResponse) }
        return data
    }
}
