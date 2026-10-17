import CoreServices
import Foundation
import Testing
@testable import TokenBarCore

struct ActivityFileWatcherTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { self.lock.withLock { self.count += 1 } }
        var value: Int { self.lock.withLock { self.count } }
    }

    @Test("Only usage transcripts and conversation DB writes trigger activity")
    func matchesUsageInputs() {
        let home = URL(fileURLWithPath: "/tmp/tokenbar-activity").resolvingSymlinksInPath()
        let paths = ActivityFilePaths(environment: [:], homeDirectory: home)
        for path in [
            ".codex/sessions/2026/10/17/rollout.jsonl",
            ".codex/archived_sessions/rollout.jsonl",
            ".claude/projects/workspace/subagents/agent.jsonl",
            ".grok/sessions/id/updates.jsonl",
            ".gemini/antigravity/conversations/id.db",
            ".gemini/antigravity/conversations/id.db-wal",
        ] {
            #expect(paths.matches(home.path + "/" + path), "\(path)")
        }
        for path in [
            ".codex/.codex-global-state.json", ".codex/state_5.sqlite-wal",
            ".codex/session_index.jsonl", ".codex/tokenbar-cache.jsonl",
            ".codex/sessions-other/rollout.jsonl", ".claude/stats-cache.json",
            ".claude/projects/a/session.jsonl.tmp", ".grok/sessions/id/summary.json",
            ".gemini/antigravity/conversations/id.db-shm",
            ".gemini/antigravity/conversations/nested/id.db",
        ] {
            #expect(!paths.matches(home.path + "/" + path), "\(path)")
        }
    }

    @Test("Provider environment overrides follow helper discovery")
    func environmentOverrides() {
        let paths = ActivityFilePaths(environment: [
            "CODEX_HOME": "/tmp/custom-codex", "CLAUDE_CONFIG_DIR": "/tmp/custom-claude",
            "GROK_HOME": "/tmp/custom-grok", "ANTIGRAVITY_HOME": "/tmp/custom-antigravity",
        ], homeDirectory: URL(fileURLWithPath: "/tmp/home"))
        #expect(paths.matches(paths.directories[0] + "/a.jsonl"))
        #expect(paths.matches(paths.directories[2] + "/a.jsonl"))
        #expect(paths.matches(paths.directories[3] + "/a/updates.jsonl"))
        #expect(paths.matches(paths.directories[4] + "/a.db-wal"))
        #expect(!paths.matches("/tmp/home/.codex/sessions/a.jsonl"))
    }

    @Test("Bursts coalesce, metadata stays quiet, and stop cancels pending work across restart")
    func eventLifecycle() async throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let counter = Counter()
        let watcher = ActivityFileWatcher(environment: [:], homeDirectory: home, debounceInterval: 0.03) {
            counter.increment()
        }
        defer { watcher.stop() }
        let transcript = home.appendingPathComponent(".codex/sessions/a.jsonl").path
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        watcher.start()
        watcher.receiveEvents([transcript], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemInodeMetaMod)])
        try await Task.sleep(for: .milliseconds(80))
        #expect(counter.value == 0)
        for _ in 0..<20 { watcher.receiveEvents([transcript], flags: [modified]) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 1)
        watcher.receiveEvents([transcript], flags: [modified])
        watcher.stop()
        watcher.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 1)
        watcher.receiveEvents([transcript], flags: [modified])
        try await Task.sleep(for: .milliseconds(100))
        #expect(counter.value == 2)
        watcher.stop()
        watcher.receiveEvents([transcript], flags: [modified])
        try await Task.sleep(for: .milliseconds(80))
        #expect(counter.value == 2)
    }

    @Test("Real transcript writes produce an FSEvents callback")
    func fileSystemDelivery() async throws {
        // FSEvents excludes the macOS per-user temporary directory on this host.
        // A disposable directory in the workspace exercises normal persistent storage.
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work/activity-watcher-tests")
            .appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".codex/sessions/2026/10/17")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let counter = Counter()
        let watcher = ActivityFileWatcher(environment: [:], homeDirectory: home, debounceInterval: 0.02) {
            counter.increment()
        }
        watcher.start()
        defer { watcher.stop() }
        try Data("{\"type\":\"token_count\"}\n".utf8).write(to: directory.appendingPathComponent("rollout.jsonl"))
        for _ in 0..<50 {
            if counter.value > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(counter.value > 0)
    }

}
