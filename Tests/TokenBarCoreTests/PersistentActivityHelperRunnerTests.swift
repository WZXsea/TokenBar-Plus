import Foundation
import Darwin
import Testing
@testable import TokenBarCore

@Suite("Persistent activity helper")
struct PersistentActivityHelperRunnerTests {
    @Test("Serial and concurrent snapshots reuse one process; changed environment restarts it")
    func reusesProcessAndSerializesRequests() async throws {
        let fixture = try HelperFixture()
        defer { fixture.remove() }
        let runner = PersistentActivityHelperRunner()
        defer { runner.stop() }
        let first = try await self.reply(runner, fixture: fixture, arguments: ["first"])
        async let second = self.reply(runner, fixture: fixture, arguments: ["second"])
        async let third = self.reply(runner, fixture: fixture, arguments: ["third"])
        let (a, b) = try await (second, third)
        #expect(first.pid == a.pid && a.pid == b.pid)
        #expect(Set([a.counter, b.counter]) == [2, 3])
        #expect(a.arguments == ["second"] && b.arguments == ["third"])

        await #expect(throws: ProcessRunnerError.self) {
            try await runner.run(executableURL: fixture.helper, arguments: ["error"], environment: [:], timeout: 3)
        }
        let afterError = try await self.reply(runner, fixture: fixture, arguments: ["after-error"])
        #expect(afterError.pid == first.pid)
        let reconfigured = try await self.reply(runner, fixture: fixture, arguments: ["changed"], environment: ["TZ": "UTC"])
        #expect(reconfigured.pid != first.pid)
        #expect(reconfigured.counter == 1)
        let service = ActivityService(helperURL: fixture.helper, runner: runner)
        let synchronized = SynchronizedActivityService(local: service, configuration: { nil })
        synchronized.stop()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while Darwin.kill(Int32(reconfigured.pid), 0) == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Darwin.kill(Int32(reconfigured.pid), 0) != 0)
        let restarted = try await self.reply(runner, fixture: fixture, arguments: ["after-stop"], environment: ["TZ": "UTC"])
        #expect(restarted.pid != reconfigured.pid)
        #expect(restarted.counter == 1)
    }

    @Test("Timeout, cancellation, EOF and oversized output release the helper and allow recovery")
    func failureRecoveryAndBoundedPipes() async throws {
        let fixture = try HelperFixture()
        defer { fixture.remove() }
        let runner = PersistentActivityHelperRunner(maximumOutputBytes: 256)
        defer { runner.stop() }
        let first = try await self.reply(runner, fixture: fixture, arguments: ["stderr"])
        let barrier = fixture.directory.appendingPathComponent("queued").path
        let blocking = Task { try await self.reply(runner, fixture: fixture, arguments: ["wait", barrier]) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: barrier + ".started"), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: barrier + ".started"))
        await #expect(throws: ProcessRunnerError.self) {
            try await runner.run(executableURL: fixture.helper, arguments: ["queued-timeout"], environment: [:], timeout: 0.05)
        }
        try Data().write(to: URL(fileURLWithPath: barrier + ".release"))
        let afterQueuedTimeout = try await blocking.value
        #expect(afterQueuedTimeout.pid == first.pid)
        await #expect(throws: ProcessRunnerError.self) {
            try await runner.run(executableURL: fixture.helper, arguments: ["hang"], environment: [:], timeout: 0.1)
        }
        let afterTimeout = try await self.reply(runner, fixture: fixture, arguments: ["after-timeout"])
        #expect(afterTimeout.pid != first.pid)

        let cancelled = Task {
            try await runner.run(executableURL: fixture.helper, arguments: ["hang"], environment: [:], timeout: 3)
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let afterCancellation = try await self.reply(runner, fixture: fixture, arguments: ["after-cancel"])
        #expect(afterCancellation.pid != afterTimeout.pid)
        for mode in ["exit", "oversized"] {
            await #expect(throws: ProcessRunnerError.self) {
                try await runner.run(executableURL: fixture.helper, arguments: [mode], environment: [:], timeout: 3)
            }
            _ = try await self.reply(runner, fixture: fixture, arguments: ["recovered"])
        }
    }

    @Test("Legacy helper overrides and slow history queries leave live snapshots responsive")
    func historyQueryIsIsolatedFromLiveSnapshots() async throws {
        let fixture = try HelperFixture()
        defer { fixture.remove() }
        let snapshot = String(decoding: try JSONEncoder().encode(TestFixtures.activity()), as: UTF8.self)
        let service = ActivityService(helperURL: fixture.helper, environment: [
            "FIXTURE_SNAPSHOT": snapshot,
            "FIXTURE_MARKER": fixture.directory.appendingPathComponent("history").path,
            "FIXTURE_LEGACY_ONLY": "1",
        ])
        let history = Task { try await service.fetchHistory(days: 366, endDate: "2026-11-02", statisticsTimeZone: .utc) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("history.started").path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("history.started").path))
        let live = try await service.fetchActivity()
        #expect(live == TestFixtures.activity())
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("history.finished").path))
        _ = try await history.value
        let overridden = ActivityService(environment: [
            "TOKENBAR_HELPER_PATH": fixture.helper.path,
            "FIXTURE_SNAPSHOT": snapshot,
            "FIXTURE_LEGACY_ONLY": "1",
        ])
        #expect(try await overridden.fetchActivity() == TestFixtures.activity())
    }

    private struct Reply: Decodable {
        let pid: Int
        let counter: Int
        let arguments: [String]
    }

    private func reply(_ runner: PersistentActivityHelperRunner, fixture: HelperFixture, arguments: [String], environment: [String: String] = [:]) async throws -> Reply {
        let data = try await runner.run(executableURL: fixture.helper, arguments: arguments, environment: environment, timeout: 3)
        return try JSONDecoder().decode(Reply.self, from: data)
    }
}

private struct HelperFixture {
    let directory: URL
    let helper: URL

    init() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar-helper-\(UUID().uuidString)", isDirectory: true)
        self.helper = self.directory.appendingPathComponent("helper.py")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys, time

        def respond(arguments, counter):
            if "--days" in arguments:
                marker = os.environ["FIXTURE_MARKER"]
                pathlib.Path(marker + ".started").touch()
                time.sleep(2)
                pathlib.Path(marker + ".finished").touch()
            mode = arguments[0] if arguments else "normal"
            if mode == "wait":
                pathlib.Path(arguments[1] + ".started").touch()
                while not pathlib.Path(arguments[1] + ".release").exists(): time.sleep(0.01)
            if mode == "hang": time.sleep(20)
            if mode == "exit": sys.exit(7)
            if mode == "oversized":
                print("x" * 4096, flush=True)
                return
            if mode == "stderr":
                sys.stderr.write("e" * 1_000_000)
                sys.stderr.flush()
            if mode == "error":
                print(json.dumps({"helperError": "synthetic request error"}), flush=True)
                return
            snapshot = os.environ.get("FIXTURE_SNAPSHOT")
            print(snapshot if snapshot else json.dumps({"pid": os.getpid(), "counter": counter, "arguments": arguments}), flush=True)

        if sys.argv[1:] == ["serve"]:
            if os.environ.get("FIXTURE_LEGACY_ONLY") == "1": sys.exit(5)
            for counter, line in enumerate(sys.stdin, 1):
                respond(json.loads(line), counter)
        else:
            respond(sys.argv[1:], 1)
        """#.write(to: self.helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.helper.path)
    }

    func remove() { try? FileManager.default.removeItem(at: self.directory) }
}
