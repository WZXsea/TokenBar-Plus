import AppKit
import TokenBarCore

@MainActor
final class TokenBarAppDelegate: NSObject, NSApplicationDelegate {
    let memoryTelemetryController = MemoryTelemetryController()
    let activitySyncController = ActivitySyncController(settings: .shared)
    let modelPricingStore = ModelPricingStore.shared
    private let openAIPricingCatalog = OpenAIPricingCatalogUpdater()
    private let anthropicPricingCatalog = AnthropicPricingCatalogUpdater()
    private let openRouterPricingCatalog = OpenRouterPricingCatalogUpdater()
    lazy var modelPriceQuoteService: any ModelPriceQuoting = ModelPriceQuoteService(
        openAIPricingCatalog: self.openAIPricingCatalog,
        anthropicPricingCatalog: self.anthropicPricingCatalog,
        openRouterPricingCatalog: self.openRouterPricingCatalog)
    private lazy var model: DashboardModel = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TOKENBAR_DEMO_MODE"] == "1" {
            return DashboardModel(
                quotaService: DemoQuotaProvider(),
                additionalQuotaServices: [
                    DemoClaudeQuotaProvider(),
                    DemoGrokQuotaProvider(),
                    DemoAntigravityQuotaProvider(),
                ],
                activityService: DemoActivityProvider(),
                cache: nil,
                weeklyQuotaUsageCache: ProcessInfo.processInfo.environment["TOKENBAR_DEMO_QUOTA_DAYS"] == "1"
                    ? DemoQuotaDayHistoryCache() : nil)
        }
        #endif
        let memoryDatabaseURL = self.memoryTelemetryController.paths.databaseURL
        let localActivity = ActivityService(
            memoryDatabaseURLProvider: { [weak settings = self.settings] in
                await MainActor.run {
                    settings?.monitorsCodexMemory == true ? memoryDatabaseURL : nil
                }
            },
            customPricingURLProvider: { [weak store = self.modelPricingStore] in
                await MainActor.run { store?.activeFileURL }
            },
            openAIPricingCatalog: self.openAIPricingCatalog,
            anthropicPricingCatalog: self.anthropicPricingCatalog,
            openRouterPricingCatalog: self.openRouterPricingCatalog)
        let synchronizedActivity = SynchronizedActivityService(
            local: localActivity,
            configuration: { [weak activitySyncController = self.activitySyncController] in
                await activitySyncController?.configuration()
            },
            report: { [weak activitySyncController = self.activitySyncController] report in
                await activitySyncController?.accept(report)
            })
        return DashboardModel(
            quotaService: CodexQuotaService(),
            additionalQuotaServices: [
                ClaudeQuotaService(),
                GrokQuotaService(),
                AntigravityQuotaService(),
            ],
            activityService: synchronizedActivity,
            quotaCache: QuotaSnapshotCache(),
            weeklyQuotaUsageCache: WeeklyQuotaUsageCache())
    }()
    private let settings = TokenBarSettings.shared
    private let confettiOverlayController = ScreenConfettiOverlayController()
    private var requestDetailService: (any RequestDetailProviding)?
    private var statusController: TokenBarStatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var previewTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let previewPath = environment["TOKENBAR_RENDER_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                if environment["TOKENBAR_DEMO_HISTORY_RANGE"] == "year" { await self.model.loadHistoryIfNeeded() }
                try? DemoPreviewRenderer.render(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_ROWS_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderRows(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_ACTIVITY_DETAIL_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderActivityDetail(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_MEMORY_PREVIEW"] {
            self.previewTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.model.start()
                try? DemoPreviewRenderer.renderMemory(model: self.model, path: previewPath)
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_REQUEST_DETAIL_PREVIEW"] {
            try? DemoPreviewRenderer.renderRequestDetail(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_SETTINGS_PREVIEW"] {
            try? DemoPreviewRenderer.renderSettings(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_PRICING_PREVIEW"] {
            try? DemoPreviewRenderer.renderPricing(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_RESET_CREDITS_PREVIEW"] {
            self.previewTask = Task { @MainActor in
                if let quota = try? await DemoQuotaProvider().fetchQuota(), let credits = quota.resetCredits {
                    try? DemoPreviewRenderer.renderResetCredits(
                        snapshot: credits, sampledAt: quota.updatedAt, path: previewPath)
                }
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if let previewPath = environment["TOKENBAR_RENDER_STATUS_PREVIEW"] {
            try? DemoPreviewRenderer.renderStatus(path: previewPath)
            NSApplication.shared.terminate(nil)
            return
        }
        #endif
        if self.settings.monitorsCodexMemory {
            self.memoryTelemetryController.start()
        }
        #if DEBUG
        let requestDetailService: any RequestDetailProviding = environment["TOKENBAR_DEMO_MODE"] == "1"
            ? DemoRequestDetailProvider()
            : CodexRequestDetailService()
        #else
        let requestDetailService: any RequestDetailProviding = CodexRequestDetailService()
        #endif
        self.requestDetailService = requestDetailService
        let controller = TokenBarStatusItemController(
            model: self.model,
            settings: self.settings,
            memoryTelemetry: self.memoryTelemetryController,
            activitySync: self.activitySyncController,
            showSettings: { [weak self] in
                self?.showSettings()
            },
            requestDetailService: requestDetailService,
            pricingStore: self.modelPricingStore)
        self.statusController = controller
        self.model.quotaResetHandler = { [weak self] event in
            self?.handleQuotaReset(event)
        }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.previewTask?.cancel()
        self.previewTask = nil
        self.memoryTelemetryController.stop()
        self.model.quotaResetHandler = nil
        self.model.stop()
        self.confettiOverlayController.dismiss()
        self.statusController?.tearDown()
        self.statusController = nil
        self.settingsWindowController?.close()
        self.settingsWindowController = nil
        self.requestDetailService = nil
    }

    private func showSettings() {
        if self.settingsWindowController?.window?.isVisible != true {
            self.settingsWindowController = SettingsWindowController(
                settings: self.settings,
                memoryTelemetry: self.memoryTelemetryController,
                activitySync: self.activitySyncController,
                syncNow: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.model.refreshActivity()
                    }
                },
                testResetAnimation: { [weak self] in
                    self?.testResetAnimation()
                },
                pricingStore: self.modelPricingStore,
                priceQuoteService: self.modelPriceQuoteService,
                observedPricingModels: self.observedPricingModels)
        }
        self.settingsWindowController?.show()
    }

    func testResetAnimation() {
        let platform = self.statusController == nil ? TokenPlatform.codex : self.model.scope.platform
        let origin = self.statusController?.celebrationOriginPoint(for: platform)
        self.confettiOverlayController.play(originInScreen: origin)
    }

    func refreshActivity() async {
        await self.model.refreshActivity()
    }

    var observedPricingModels: [ObservedPricingModel] {
        guard let snapshot = self.model.activitySnapshot else { return [] }
        var models: [String: ObservedPricingModel] = [:]
        let supported: Set<TokenPlatform> = [.codex, .claude, .grok, .antigravity]
        func insert(_ modelID: String, platform: TokenPlatform) {
            let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard supported.contains(platform), !modelID.isEmpty, modelID != "unknown" else { return }
            let model = ObservedPricingModel(platform: platform, modelID: modelID)
            models[model.id.lowercased()] = model
        }
        for model in snapshot.pricingModels ?? [] { insert(model.modelID, platform: model.platform) }
        return models.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private func handleQuotaReset(_ event: QuotaResetEvent) {
        guard self.settings.resetCelebration.includes(event.window) else { return }
        let origin = self.statusController?.celebrationOriginPoint(for: event.platform)
        self.confettiOverlayController.play(originInScreen: origin)
    }
}
