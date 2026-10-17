import AppKit
import Foundation
import Testing
@testable import TokenBar
import TokenBarCore

@MainActor
@Suite("Session history cancellation")
struct SessionHistoryCancellationTests {
    @Test("A cancelled same-date request's ordinary error preserves the replacement request and its result")
    func cancelledErrorPreservesReplacement() async throws {
        let historicalDate = "2026-09-01"
        let latestDate = "2026-09-02"
        let snapshot = ActivitySnapshot(
            schemaVersion: 11, generatedAtMs: 2_000, timezone: "UTC", today: .zero,
            sessions: [Self.session("today", endedAtMs: 2_000)],
            days: [historicalDate, latestDate].map {
                DailySummary(date: $0, tokens: .zero, costUsd: 0, requestCount: 1, sessionCount: 1)
            })
        let harness = try await HistoryCancellationHarness.make(snapshot: snapshot)
        defer { harness.tearDown() }
        let provider = harness.provider
        let controller = harness.controller

        controller.selectActivityDateForTesting(historicalDate)
        try await self.waitUntil { provider.hasPendingRequest(1) }

        controller.selectActivityDateForTesting(latestDate)
        controller.selectActivityDateForTesting(historicalDate)
        try await self.waitUntil { provider.hasPendingRequest(2) }
        #expect(provider.requestedDates == [historicalDate, historicalDate])
        #expect(controller.isLoadingSessionHistoryForTesting())

        provider.failRequest(1)
        try await self.waitUntil { provider.settledRequests.contains(1) }
        #expect(provider.cancelledRequests.contains(1))
        #expect(provider.hasPendingRequest(2))
        #expect(controller.isLoadingSessionHistoryForTesting())
        #expect(controller.selectedSessionDateForTesting() == historicalDate)

        provider.succeedRequest(2, sessions: [Self.session("replacement", endedAtMs: 1_000)])
        try await self.waitUntil {
            !controller.isLoadingSessionHistoryForTesting()
                && controller.renderedActivitySessionIDsForTesting() == ["codex:replacement"]
        }
        let menu = try #require(controller.activitySessionMenuForTesting())
        #expect(menu.items.compactMap { ($0.representedObject as? SessionSummary)?.id } == ["replacement"])
        #expect(controller.firstActivitySessionSubmenuForTesting()?.title == "replacement")
        #expect(provider.requestedDates == [historicalDate, historicalDate])
    }

    @Test("History browsing retains sixteen recent dates and reloads the evicted date")
    func historyCacheEvictsLeastRecentlyUsedDate() async throws {
        let dates = (1 ... 18).map { String(format: "2026-09-%02d", $0) }
        let snapshot = ActivitySnapshot(
            schemaVersion: 11, generatedAtMs: 2_000, timezone: "UTC", today: .zero,
            sessions: [Self.session("today", endedAtMs: 2_000)],
            days: dates.map {
                DailySummary(date: $0, tokens: .zero, costUsd: 0, requestCount: 1, sessionCount: 1)
            })
        let harness = try await HistoryCancellationHarness.make(snapshot: snapshot)
        defer { harness.tearDown() }
        let controller = harness.controller
        let provider = harness.provider

        for index in 0 ..< 16 {
            controller.selectActivityDateForTesting(dates[index])
            try await self.waitUntil { provider.hasPendingRequest(index + 1) }
            provider.succeedRequest(index + 1, sessions: [])
            try await self.waitUntil { !controller.isLoadingSessionHistoryForTesting() }
        }
        #expect(controller.cachedSessionHistoryDatesForTesting() == Array(dates.prefix(16)))
        // Revisiting a cached date updates recency without an additional helper request.
        controller.selectActivityDateForTesting(dates[0])
        #expect(provider.requestedDates.count == 16)
        controller.selectActivityDateForTesting(dates[16])
        try await self.waitUntil { provider.hasPendingRequest(17) }
        provider.succeedRequest(17, sessions: [])
        try await self.waitUntil { !controller.isLoadingSessionHistoryForTesting() }
        let cached = controller.cachedSessionHistoryDatesForTesting()
        #expect(cached.count == 16)
        #expect(cached.contains(dates[0]))
        #expect(!cached.contains(dates[1]))
        #expect(cached.last == dates[16])

        controller.selectActivityDateForTesting(dates[1])
        try await self.waitUntil { provider.hasPendingRequest(18) }
        #expect(provider.requestedDates.last == dates[1])
        provider.succeedRequest(18, sessions: [])
        try await self.waitUntil { !controller.isLoadingSessionHistoryForTesting() }
        #expect(controller.cachedSessionHistoryDatesForTesting().count == 16)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "历史会话请求应按受控响应顺序完成")
    }

    private static func session(_ id: String, endedAtMs: Int64) -> SessionSummary {
        SessionSummary(
            id: id, workspaceLabel: "TokenBar", startedAtMs: endedAtMs - 100, endedAtMs: endedAtMs,
            tokens: .zero, costUsd: 0, models: ["gpt-test"], requests: [], title: id, platform: .codex)
    }
}

private enum HistoricalRequestFailure: Error {
    case ordinaryFailure
}

/// Main-actor responses let the completion marker run after the caller has
/// handled the response, without elapsed-time assumptions about the race.
@MainActor
private final class ControlledHistoricalSessionProvider: ActivityProviding {
    private let snapshot: ActivitySnapshot
    private var pending: [Int: CheckedContinuation<[SessionSummary], any Error>] = [:]
    private(set) var requestedDates: [String] = []
    private(set) var settledRequests: Set<Int> = []
    private(set) var cancelledRequests: Set<Int> = []

    init(snapshot: ActivitySnapshot) {
        self.snapshot = snapshot
    }

    func fetchActivity(
        sinceWeeklyResetAt _: Date?,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> ActivitySnapshot
    {
        self.snapshot
    }

    func fetchSessions(
        on date: String,
        statisticsTimeZone _: TokenBarStatisticsTimeZone) async throws -> [SessionSummary]
    {
        self.requestedDates.append(date)
        let requestID = self.requestedDates.count
        defer {
            let wasCancelled = Task.isCancelled
            Task { @MainActor in
                if wasCancelled { self.cancelledRequests.insert(requestID) }
                self.settledRequests.insert(requestID)
            }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SessionSummary], any Error>) in
            self.pending[requestID] = continuation
        }
    }

    func hasPendingRequest(_ requestID: Int) -> Bool {
        self.pending[requestID] != nil
    }

    func failRequest(_ requestID: Int) {
        self.pending.removeValue(forKey: requestID)?.resume(throwing: HistoricalRequestFailure.ordinaryFailure)
    }

    func succeedRequest(_ requestID: Int, sessions: [SessionSummary]) {
        self.pending.removeValue(forKey: requestID)?.resume(returning: sessions)
    }

    func releasePendingRequests() {
        let continuations = Array(self.pending.values)
        self.pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

private struct HistoryCancellationCredentials: ActivitySyncCredentialStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String?) throws {}
}

@MainActor
private struct HistoryCancellationHarness {
    let provider: ControlledHistoricalSessionProvider
    let model: DashboardModel
    let controller: TokenBarStatusItemController
    let defaults: UserDefaults
    let suite: String
    let directory: URL

    static func make(snapshot: ActivitySnapshot) async throws -> Self {
        let suite = "SessionHistoryCancellationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = TokenBarSettings(defaults: defaults, keyPrefix: "test.settings")
        settings.monitorsCodexMemory = false
        let provider = ControlledHistoricalSessionProvider(snapshot: snapshot)
        let model = DashboardModel(quotaService: DemoQuotaProvider(), activityService: provider, cache: nil)
        await model.start()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionHistoryCancellationTests-\(UUID().uuidString)")
        let telemetry = MemoryTelemetryController(
            paths: MemoryTelemetryPaths(directoryURL: directory),
            configurationService: CodexMemoryConfigurationService(configurationURL: directory.appendingPathComponent("config.toml")))
        let sync = ActivitySyncController(settings: settings, credentials: HistoryCancellationCredentials())
        let controller = TokenBarStatusItemController(
            model: model, settings: settings, memoryTelemetry: telemetry,
            activitySync: sync, showSettings: {},
            pricingStore: ModelPricingStore(fileURL: directory.appendingPathComponent("pricing.json")))
        return Self(provider: provider, model: model, controller: controller,
                    defaults: defaults, suite: suite, directory: directory)
    }

    func tearDown() {
        self.controller.tearDown()
        self.model.stop()
        self.provider.releasePendingRequests()
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.directory)
    }
}
