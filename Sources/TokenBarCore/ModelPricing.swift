import Darwin
import Foundation
import Observation

public enum ModelPriceTier: String, CaseIterable, Codable, Identifiable, Sendable {
    case any
    case standard
    case fast

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .any: "所有模式"
        case .standard: "标准／未标注"
        case .fast: "Fast"
        }
    }
}

public struct ModelPriceOverride: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var platform: TokenPlatform
    public var modelID: String
    public var serviceTier: ModelPriceTier
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var cacheWritePerMillion: Double
    public var outputPerMillion: Double
    public var enabled: Bool

    public init(
        id: UUID = UUID(), platform: TokenPlatform, modelID: String,
        serviceTier: ModelPriceTier = .any, inputPerMillion: Double = 0,
        cachedInputPerMillion: Double = 0, cacheWritePerMillion: Double = 0,
        outputPerMillion: Double = 0, enabled: Bool = true)
    {
        self.id = id
        self.platform = platform
        self.modelID = modelID
        self.serviceTier = serviceTier
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.outputPerMillion = outputPerMillion
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, platform, modelID, serviceTier, inputPerMillion, cachedInputPerMillion
        case cacheWritePerMillion, outputPerMillion, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.platform = try container.decode(TokenPlatform.self, forKey: .platform)
        self.modelID = try container.decode(String.self, forKey: .modelID)
        self.serviceTier = try container.decodeIfPresent(ModelPriceTier.self, forKey: .serviceTier) ?? .any
        self.inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
        self.cachedInputPerMillion = try container.decode(Double.self, forKey: .cachedInputPerMillion)
        self.cacheWritePerMillion = try container.decode(Double.self, forKey: .cacheWritePerMillion)
        self.outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public struct ObservedPricingModel: Codable, Identifiable, Equatable, Sendable {
    public let platform: TokenPlatform
    public let modelID: String

    public var id: String { "\(self.platform.rawValue):\(self.modelID)" }

    public init(platform: TokenPlatform, modelID: String) {
        self.platform = platform
        self.modelID = modelID
    }
}

public struct AutomaticModelPriceRates: Codable, Equatable, Sendable {
    public let inputPerMillion: Double?
    public let cachedInputPerMillion: Double?
    public let cacheWritePerMillion: Double?
    public let outputPerMillion: Double?

    public init(
        inputPerMillion: Double? = nil, cachedInputPerMillion: Double? = nil,
        cacheWritePerMillion: Double? = nil, outputPerMillion: Double? = nil)
    {
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.outputPerMillion = outputPerMillion
    }
}

public struct AutomaticModelPriceQuote: Codable, Equatable, Sendable {
    public let platform: TokenPlatform
    public let modelID: String
    public let serviceTier: ModelPriceTier
    public let rates: AutomaticModelPriceRates?

    public init(
        platform: TokenPlatform, modelID: String, serviceTier: ModelPriceTier = .any,
        rates: AutomaticModelPriceRates? = nil)
    {
        self.platform = platform
        self.modelID = modelID
        self.serviceTier = serviceTier
        self.rates = rates
    }
}

public protocol ModelPriceQuoting: Sendable {
    func quote(platform: TokenPlatform, modelID: String, tier: ModelPriceTier) async throws -> AutomaticModelPriceQuote
}

public enum ModelPricingError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema
    case invalidPlatform
    case invalidModelID
    case invalidRate
    case duplicateID
    case duplicateTarget
    case fileTooLarge
    case regularFileRequired
    case ruleNotFound
    case recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "自定义价格文件需要 schemaVersion 1。"
        case .invalidPlatform: "平台请选择 Codex、Claude、Grok 或 Antigravity。"
        case .invalidModelID: "模型 ID 应为 1 至 200 个字符，并使用可显示字符。"
        case .invalidRate: "每百万 token 价格应为 0 至 1,000,000 之间的有限数值。"
        case .duplicateID: "每条价格规则需要独立的 UUID。"
        case .duplicateTarget: "每个平台、模型 ID 和模式组合仅保留一条规则。"
        case .fileTooLarge: "自定义价格文件大小应在 1 MiB 以内。"
        case .regularFileRequired: "自定义价格路径需要指向本地常规文件。"
        case .ruleNotFound: "该价格规则已变化，请刷新后重试。"
        case .recoveryRequired: "请先使用“恢复自动价格”修复当前价格文件。"
        }
    }
}

@MainActor
@Observable
public final class ModelPricingStore {
    public static let shared = ModelPricingStore()
    public private(set) var overrides: [ModelPriceOverride] = []
    public private(set) var revision = 0
    public private(set) var errorMessage: String?

    @ObservationIgnored private let fileURL: URL
    private static let maximumFileSize = 1_048_576

    private struct Payload: Codable {
        let schemaVersion: Int
        let overrides: [ModelPriceOverride]
    }

    private struct Target: Hashable {
        let platform: TokenPlatform
        let modelID: String
        let tier: ModelPriceTier
    }

    public init(fileURL: URL = ModelPricingStore.defaultURL()) {
        self.fileURL = fileURL
        do {
            try self.validateFileLocation()
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= Self.maximumFileSize else {
                throw ModelPricingError.fileTooLarge
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumFileSize else { throw ModelPricingError.fileTooLarge }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.schemaVersion == 1 else { throw ModelPricingError.unsupportedSchema }
            self.overrides = try Self.validated(payload.overrides)
        } catch {
            self.errorMessage = "自定义价格文件待修复：\(error.localizedDescription)"
        }
    }

    public var activeFileURL: URL? {
        guard self.errorMessage == nil,
              self.overrides.contains(where: \.enabled),
              FileManager.default.fileExists(atPath: self.fileURL.path)
        else { return nil }
        return self.fileURL
    }

    public func upsert(_ rule: ModelPriceOverride) throws {
        try self.requireReadableState()
        var updated = self.overrides
        if let index = updated.firstIndex(where: { $0.id == rule.id }) {
            updated[index] = rule
        } else {
            updated.append(rule)
        }
        try self.save(updated)
    }

    public func remove(_ id: UUID) throws {
        try self.requireReadableState()
        guard self.overrides.contains(where: { $0.id == id }) else { throw ModelPricingError.ruleNotFound }
        try self.save(self.overrides.filter { $0.id != id })
    }

    public func setEnabled(_ id: UUID, isEnabled: Bool) throws {
        try self.requireReadableState()
        guard let index = self.overrides.firstIndex(where: { $0.id == id }) else {
            throw ModelPricingError.ruleNotFound
        }
        var updated = self.overrides
        updated[index].enabled = isEnabled
        try self.save(updated)
    }

    /// Explicit recovery replaces the rules file with an empty, valid payload.
    public func removeAll() throws {
        try self.save([])
    }

    public nonisolated static func defaultURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("custom-pricing.json", isDirectory: false)
    }

    private func requireReadableState() throws {
        guard self.errorMessage == nil else { throw ModelPricingError.recoveryRequired }
    }

    private func save(_ rules: [ModelPriceOverride]) throws {
        let normalized = try Self.validated(rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(schemaVersion: 1, overrides: normalized))
        guard data.count <= Self.maximumFileSize else { throw ModelPricingError.fileTooLarge }
        try self.validateFileLocation()
        try self.writeAtomically(data)
        self.overrides = normalized
        self.errorMessage = nil
        self.revision += 1
    }

    private static func validated(_ rules: [ModelPriceOverride]) throws -> [ModelPriceOverride] {
        let platforms: Set<TokenPlatform> = [.codex, .claude, .grok, .antigravity]
        var ids: Set<UUID> = []
        var targets: Set<Target> = []
        return try rules.map { original in
            var rule = original
            guard platforms.contains(rule.platform) else { throw ModelPricingError.invalidPlatform }
            rule.modelID = rule.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ModelPricingError.invalidModelID
            }
            guard !rule.modelID.isEmpty, rule.modelID.unicodeScalars.count <= 200 else { throw ModelPricingError.invalidModelID }
            let rates = [rule.inputPerMillion, rule.cachedInputPerMillion, rule.cacheWritePerMillion, rule.outputPerMillion]
            guard rates.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) else {
                throw ModelPricingError.invalidRate
            }
            guard ids.insert(rule.id).inserted else { throw ModelPricingError.duplicateID }
            let target = Target(platform: rule.platform, modelID: rule.modelID.lowercased(), tier: rule.serviceTier)
            guard targets.insert(target).inserted else { throw ModelPricingError.duplicateTarget }
            return rule
        }
    }

    private func validateFileLocation() throws {
        guard self.fileURL.isFileURL, !self.fileURL.hasDirectoryPath else { throw ModelPricingError.regularFileRequired }
        let path = self.fileURL.path
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           attributes[.type] as? FileAttributeType != .typeRegular
        {
            throw ModelPricingError.regularFileRequired
        }
    }

    /// Stage with owner-only permissions, then publish using a same-directory
    /// rename. A failed validation or write leaves the previous rules intact.
    private func writeAtomically(_ data: Data) throws {
        let manager = FileManager.default
        let directory = self.fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagingURL = directory.appendingPathComponent(".custom-pricing-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(stagingURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var isOpen = true
        defer {
            if isOpen { Darwin.close(descriptor) }
            try? manager.removeItem(at: stagingURL)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(descriptor, start.advanced(by: written), buffer.count - written)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let closeResult = Darwin.close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Darwin.rename(stagingURL.path, self.fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
