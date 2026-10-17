import Foundation

public struct RequestDetail: Codable, Equatable, Sendable {
    public let prompt: String?
    public let output: String?

    public init(prompt: String?, output: String?) {
        self.prompt = prompt
        self.output = output
    }
}

public protocol RequestDetailProviding: Sendable {
    func fetchDetail(for request: RequestSummary) async throws -> RequestDetail
}

public enum RequestDetailServiceError: LocalizedError, Sendable {
    case missingSessionPath
    case helperNotFound([String])
    case emptyOutput
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .missingSessionPath:
            return "原始会话文件暂不可用。请刷新 TokenBar 后重试。"
        case let .helperNotFound(paths):
            let searched = paths.isEmpty ? "候选路径为空" : paths.joined(separator: ", ")
            return "tokenbar-helper 定位失败（已搜索：\(searched)）。"
        case .emptyOutput:
            return "tokenbar-helper 返回的请求详情为空。"
        case let .invalidOutput(message):
            return "tokenbar-helper 返回的请求详情 JSON 无效：\(message)"
        }
    }
}

public struct CodexRequestDetailService: RequestDetailProviding, Sendable {
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let resolveHelper: @Sendable () throws -> URL
    private let runner: any ActivityHelperRunning

    public init(
        helperURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 15,
        runner: any ActivityHelperRunning = SubprocessActivityHelperRunner())
    {
        self.environment = environment
        self.timeout = timeout
        self.runner = runner
        let candidates = ActivityService.helperCandidates(explicitURL: helperURL, environment: environment)
        self.resolveHelper = {
            if let candidate = candidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }) {
                return candidate
            }
            throw RequestDetailServiceError.helperNotFound(candidates.map(\.path))
        }
    }

    init(
        environment: [String: String] = [:],
        timeout: TimeInterval = 15,
        resolveHelper: @escaping @Sendable () throws -> URL,
        runner: any ActivityHelperRunning)
    {
        self.environment = environment
        self.timeout = timeout
        self.resolveHelper = resolveHelper
        self.runner = runner
    }

    public func fetchDetail(for request: RequestSummary) async throws -> RequestDetail {
        guard let sessionPath = request.sessionPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionPath.isEmpty
        else {
            throw RequestDetailServiceError.missingSessionPath
        }

        let helperURL = try self.resolveHelper()
        let data = try await self.runner.run(
            executableURL: helperURL,
            arguments: [
                "request-detail",
                "--platform", request.platformID.rawValue,
                "--session-path", sessionPath,
                "--start-ms", String(request.startedAtMs),
                "--end-ms", String(request.endedAtMs),
            ],
            environment: self.environment,
            timeout: self.timeout)
        guard !data.isEmpty else {
            throw RequestDetailServiceError.emptyOutput
        }
        do {
            return try JSONDecoder().decode(RequestDetail.self, from: data)
        } catch {
            throw RequestDetailServiceError.invalidOutput(error.localizedDescription)
        }
    }
}
