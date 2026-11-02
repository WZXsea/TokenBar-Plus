import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Serial snapshot requests reuse one helper and its process-local accounting cache.
public final class PersistentActivityHelperRunner: ActivityHelperRunning, @unchecked Sendable {
    private static let helperErrorPrefix = Data("{\"helperError\":".utf8)

    private struct HelperErrorReply: Decodable {
        let helperError: String
    }

    private let queue = DispatchQueue(label: "TokenBar.ActivityHelper", qos: .utility)
    private let lock = NSLock()
    private let maximumOutputBytes: Int
    private var session: ActivityHelperSession?
    private var requests: [UUID: ActivityHelperRequest] = [:]

    public init(maximumOutputBytes: Int = ProcessRunner.defaultMaximumOutputBytes) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    deinit { self.stop() }

    public func run(executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> Data {
        let id = UUID()
        let request = ActivityHelperRequest { [weak self] in
            self?.lock.withLock { self?.requests.removeValue(forKey: id) }
        }
        self.lock.withLock { self.requests[id] = request }
        request.startTimeout(timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                self.queue.async {
                    self.perform(request, executableURL: executableURL, arguments: arguments, environment: environment, timeout: timeout)
                }
            }
        } onCancel: {
            request.cancel(CancellationError())
        }
    }

    /// Cancels current/queued requests and releases the idle helper. Later calls may restart it.
    public func stop() {
        let (session, requests) = self.lock.withLock {
            let result = (self.session, Array(self.requests.values))
            self.session = nil
            self.requests.removeAll()
            return result
        }
        for request in requests { request.cancel(CancellationError()) }
        session?.abort()
    }

    private func perform(_ request: ActivityHelperRequest, executableURL: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) {
        guard request.isPending else { return }
        var activeSession: ActivityHelperSession?
        do {
            let session = try self.sessionFor(executableURL: executableURL, environment: environment)
            activeSession = session
            guard request.activate(session) else {
                self.discard(session)
                return
            }
            let data = try session.request(arguments, maximumBytes: self.maximumOutputBytes)
            if data.starts(with: Self.helperErrorPrefix) {
                let error = try JSONDecoder().decode(HelperErrorReply.self, from: data)
                request.complete(.failure(ProcessRunnerError.nonZeroExit(code: 1, stderr: error.helperError)))
            } else {
                request.complete(.success(data))
            }
        } catch {
            if let activeSession { self.discard(activeSession) }
            request.complete(.failure(error))
        }
    }

    private func sessionFor(executableURL: URL, environment: [String: String]) throws -> ActivityHelperSession {
        if let current = self.lock.withLock({ self.session }) {
            if current.matches(executableURL: executableURL, environment: environment) { return current }
            self.discard(current)
        }
        let created = try ActivityHelperSession(executableURL: executableURL, environment: environment)
        self.lock.withLock { self.session = created }
        return created
    }

    private func discard(_ session: ActivityHelperSession) {
        self.lock.withLock {
            if self.session === session { self.session = nil }
        }
        session.abort()
    }
}

private final class ActivityHelperRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let onFinish: @Sendable () -> Void
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var session: ActivityHelperSession?
    private var timeoutTask: Task<Void, Never>?

    init(onFinish: @escaping @Sendable () -> Void) { self.onFinish = onFinish }

    var isPending: Bool { self.lock.withLock { self.result == nil } }

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        let result = self.lock.withLock {
            if self.result == nil { self.continuation = continuation }
            return self.result
        }
        if let result { continuation.resume(with: result) }
    }

    func activate(_ session: ActivityHelperSession) -> Bool {
        self.lock.withLock {
            guard self.result == nil else { return false }
            self.session = session
            return true
        }
    }

    func startTimeout(_ timeout: TimeInterval) {
        guard timeout.isFinite else { return }
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, timeout))) } catch { return }
            self?.cancel(ProcessRunnerError.timedOut(timeout))
        }
        self.lock.withLock {
            if self.result == nil { self.timeoutTask = timer } else { timer.cancel() }
        }
    }

    func cancel(_ error: any Error) {
        self.finish(.failure(error), interrupting: true)
    }

    func complete(_ result: Result<Data, any Error>) {
        self.finish(result, interrupting: false)
    }

    private func finish(_ result: Result<Data, any Error>, interrupting: Bool) {
        let captured = self.lock.withLock { () -> (CheckedContinuation<Data, any Error>?, ActivityHelperSession?, Task<Void, Never>?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let captured = (self.continuation, self.session, self.timeoutTask)
            self.continuation = nil
            self.session = nil
            self.timeoutTask = nil
            return captured
        }
        guard let (continuation, session, timer) = captured else { return }
        timer?.cancel()
        if interrupting { session?.abort() }
        self.onFinish()
        continuation?.resume(with: result)
    }
}

private final class ActivityHelperSession: @unchecked Sendable {
    private let executableURL: URL
    private let environment: [String: String]
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errors: ActivityHelperStderr
    private let completion: ProcessCompletion
    private let control: ProcessControl
    private let lock = NSLock()
    private var closed = false

    init(executableURL: URL, environment: [String: String]) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProcessRunnerError.executableNotFound(executableURL.path)
        }
        self.executableURL = executableURL
        self.environment = environment
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.output = stdout.fileHandleForReading
        self.errors = ActivityHelperStderr(handle: stderr.fileHandleForReading)
        self.completion = ProcessCompletion()
        self.control = ProcessControl(process: process)
        process.executableURL = executableURL
        process.arguments = ["serve"]
        var workerEnvironment = environment
        // Keep background parsing bounded while preserving explicit developer overrides.
        if workerEnvironment["RAYON_NUM_THREADS"] == nil {
            workerEnvironment["RAYON_NUM_THREADS"] = "2"
        }
        process.environment = workerEnvironment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let completion = self.completion
        process.terminationHandler = { completion.resolve($0.terminationStatus) }
        self.errors.start()
        do { try process.run() } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        #if canImport(Darwin)
        _ = Darwin.fcntl(self.input.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    deinit {
        self.abort()
        try? self.output.close()
    }

    func matches(executableURL: URL, environment: [String: String]) -> Bool {
        self.executableURL == executableURL && self.environment == environment && self.process.isRunning
            && self.lock.withLock { !self.closed }
    }

    func request(_ arguments: [String], maximumBytes: Int) throws -> Data {
        var request = try JSONEncoder().encode(arguments)
        request.append(0x0A)
        try self.input.write(contentsOf: request)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // POSIX read returns the bytes currently available in the pipe.
            // FileHandle.read(upToCount:) can wait for a full buffer on macOS.
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(self.output.fileDescriptor, bytes.baseAddress, bytes.count)
                #else
                Glibc.read(self.output.fileDescriptor, bytes.baseAddress, bytes.count)
                #endif
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            response.append(contentsOf: buffer.prefix(count))
            if let newline = response.firstIndex(of: 0x0A) {
                guard newline <= maximumBytes else {
                    throw ProcessRunnerError.outputTooLarge(stream: "stdout", limitBytes: maximumBytes)
                }
                guard response.index(after: newline) == response.endIndex else {
                    throw ActivityServiceError.invalidOutput("helper 返回了额外的响应行。")
                }
                return response.prefix(upTo: newline)
            }
            guard response.count <= maximumBytes else {
                throw ProcessRunnerError.outputTooLarge(stream: "stdout", limitBytes: maximumBytes)
            }
        }
        throw ProcessRunnerError.nonZeroExit(code: self.process.isRunning ? -1 : self.process.terminationStatus,
                                             stderr: self.errors.snapshot())
    }

    func abort() {
        let shouldClose = self.lock.withLock {
            guard !self.closed else { return false }
            self.closed = true
            return true
        }
        guard shouldClose else { return }
        self.control.terminate()
        let control = self.control
        let completion = self.completion
        Task.detached { await control.terminateAndWait(completion: completion) }
        try? self.input.close()
    }
}

private final class ActivityHelperStderr: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()

    init(handle: FileHandle) { self.handle = handle }

    deinit {
        self.handle.readabilityHandler = nil
        try? self.handle.close()
    }

    func start() {
        self.handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            self.lock.withLock {
                let remaining = max(0, 65_536 - self.data.count)
                self.data.append(chunk.prefix(remaining))
            }
        }
    }

    func snapshot() -> String {
        self.lock.withLock { String(decoding: self.data, as: UTF8.self) }
    }
}
