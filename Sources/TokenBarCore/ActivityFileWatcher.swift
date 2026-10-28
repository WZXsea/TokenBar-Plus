import CoreServices
import Foundation

/// Watches usage inputs without periodically enumerating or reading transcripts.
/// The callback runs on a private utility queue. Call `stop()` when observation ends.
public final class ActivityFileWatcher: @unchecked Sendable {
    private final class Context {
        weak var watcher: ActivityFileWatcher?
        init(_ watcher: ActivityFileWatcher) { self.watcher = watcher }
    }

    private let queue = DispatchQueue(label: "TokenBar.ActivityFiles", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let paths: ActivityFilePaths
    private let debounceInterval: TimeInterval
    private let onActivity: @Sendable () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var running = false
    private var generation = 0

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        debounceInterval: TimeInterval = 0.1,
        onActivity: @escaping @Sendable () -> Void)
    {
        self.paths = ActivityFilePaths(environment: environment, homeDirectory: homeDirectory)
        self.debounceInterval = max(0, debounceInterval)
        self.onActivity = onActivity
        self.queue.setSpecific(key: self.queueKey, value: true)
    }

    deinit { self.stop() }

    public func start() {
        self.synchronized {
            guard !self.running else { return }
            self.running = true
            self.generation += 1
            self.startStream()
        }
    }

    public func stop() {
        self.synchronized {
            self.running = false
            self.generation += 1
            self.pending?.cancel()
            self.pending = nil
            if let stream = self.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    private func synchronized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: self.queueKey) == true {
            operation()
        } else {
            self.queue.sync(execute: operation)
        }
    }

    private func startStream() {
        // Existing ancestors also observe first-time creation of a provider directory.
        let roots = Set(self.paths.directories.map { directory in
            var ancestor = URL(fileURLWithPath: directory, isDirectory: true)
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            return ancestor.path
        })
        let contextObject = Context(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(contextObject).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Context>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Context>.fromOpaque(pointer).release()
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info,
                  let watcher = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().watcher
            else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            watcher.handle(paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, Array(roots) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else { return }
        FSEventStreamSetDispatchQueue(stream, self.queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    // Internal entry point also allows deterministic tests independent of OS batching.
    func receiveEvents(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        self.synchronized { self.handle(paths, flags: flags) }
    }

    private func handle(_ paths: [String], flags: [FSEventStreamEventFlags]) {
        guard self.running, self.pending == nil else { return }
        let recovery = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        let mutation = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
        let relevant = paths.enumerated().contains { index, path in
            guard index < flags.count else { return false }
            if flags[index] & recovery != 0 {
                return self.paths.intersectsDirectory(path)
            }
            return flags[index] & mutation != 0 && self.paths.matches(path)
        }
        guard relevant else { return }
        let generation = self.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.generation == generation else { return }
            self.pending = nil
            self.onActivity()
        }
        self.pending = item
        self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
    }
}

struct ActivityFilePaths: Sendable {
    let directories: [String]

    init(environment: [String: String], homeDirectory: URL) {
        func root(_ key: String, fallback: String) -> URL {
            if let value = environment[key], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return homeDirectory.appendingPathComponent(fallback, isDirectory: true)
        }
        let codex = root("CODEX_HOME", fallback: ".codex")
        var directories = [
            codex.appendingPathComponent("sessions"),
            codex.appendingPathComponent("archived_sessions"),
            root("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("projects"),
            root("GROK_HOME", fallback: ".grok").appendingPathComponent("sessions"),
            root("ANTIGRAVITY_HOME", fallback: ".gemini/antigravity").appendingPathComponent("conversations"),
        ]
        // ZCode's override is a home-level base; each base contains .zcode/cli.
        // Its legacy setting lives in the default home's .zcode/v2/setting.json.
        var zcodeBases = [homeDirectory]
        if let value = environment["ZCODE_DATA_BASE_DIR"], !value.isEmpty {
            zcodeBases.append(URL(fileURLWithPath: value, isDirectory: true))
        } else if let data = try? Data(contentsOf: homeDirectory.appendingPathComponent(".zcode/v2/setting.json")),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = settings["dataBaseDir"] as? String, !value.isEmpty
        {
            zcodeBases.append(URL(fileURLWithPath: value, isDirectory: true))
        }
        for base in zcodeBases {
            let cli = base.appendingPathComponent(".zcode/cli", isDirectory: true)
            directories += [cli.appendingPathComponent("db"), cli.appendingPathComponent("rollout"), cli.appendingPathComponent("debug")]
        }
        self.directories = directories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    func matches(_ path: String) -> Bool {
        for (index, directory) in self.directories.enumerated() {
            guard path.hasPrefix(directory + "/") else { continue }
            let relative = String(path.dropFirst(directory.count + 1))
            switch index {
            case 0, 1, 2: return relative.hasSuffix(".jsonl")
            case 3: return URL(fileURLWithPath: relative).lastPathComponent == "updates.jsonl"
            case 4:
                // SQLite readers touch SHM; DB/WAL mutations carry conversation writes.
                return !relative.contains("/") && (relative.hasSuffix(".db") || relative.hasSuffix(".db-wal"))
            default:
                if directory.hasSuffix("/db") {
                    return relative == "db.sqlite" || relative == "db.sqlite-wal"
                }
                return relative.hasSuffix(".jsonl")
            }
        }
        return false
    }

    func intersectsDirectory(_ path: String) -> Bool {
        self.directories.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
    }
}
