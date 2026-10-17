import AppKit
import SwiftUI
import TokenBarCore

struct TokenBarSettingsView: View {
    @Bindable var settings: TokenBarSettings
    @Bindable var loginItem: LoginItemController
    let memoryTelemetry: MemoryTelemetryController?
    let activitySync: ActivitySyncController?
    let syncNow: () -> Void
    let testResetAnimation: () -> Void
    let pricingStore: ModelPricingStore
    let priceQuoteService: (any ModelPriceQuoting)?
    let observedPricingModels: [ObservedPricingModel]
    @State private var showsModelPricing = false

    init(
        settings: TokenBarSettings,
        loginItem: LoginItemController = .shared,
        memoryTelemetry: MemoryTelemetryController? = nil,
        activitySync: ActivitySyncController? = nil,
        syncNow: @escaping () -> Void = {},
        testResetAnimation: @escaping () -> Void = {},
        pricingStore: ModelPricingStore = .shared,
        priceQuoteService: (any ModelPriceQuoting)? = nil,
        observedPricingModels: [ObservedPricingModel] = [])
    {
        self.settings = settings
        self.loginItem = loginItem
        self.memoryTelemetry = memoryTelemetry
        self.activitySync = activitySync
        self.syncNow = syncNow
        self.testResetAnimation = testResetAnimation
        self.pricingStore = pricingStore
        self.priceQuoteService = priceQuoteService
        self.observedPricingModels = observedPricingModels
    }

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题颜色", selection: self.$settings.theme) {
                    ForEach(TokenBarTheme.allCases) { theme in
                        Label {
                            Text(theme.displayName)
                        } icon: {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 9, height: 9)
                        }
                        .tag(theme)
                    }
                }
            }

            Section("启动") {
                Toggle(
                    "登录时启动 TokenBar",
                    isOn: Binding(
                        get: { self.loginItem.isEnabled },
                        set: { self.loginItem.setEnabled($0) }))
                    .disabled(!self.loginItem.isAvailable)

                Text(self.loginItem.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if self.loginItem.requiresApproval {
                    Button("打开登录项设置") {
                        self.loginItem.openSystemSettings()
                    }
                }

                if let errorMessage = self.loginItem.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("平台") {
                Toggle("显示 Claude Code", isOn: self.$settings.showsClaude)
                Toggle("显示 Grok Build", isOn: self.$settings.showsGrok)
                Toggle("显示 Antigravity", isOn: self.$settings.showsAntigravity)

                Text("显示各平台的今日／每周区域及仪表盘标签页。更改立即生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("菜单栏显示") {
                Picker("上行", selection: self.$settings.statusBarTopMetric) {
                    ForEach(TokenBarStatusMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }

                Picker("下行", selection: self.$settings.statusBarBottomMetric) {
                    ForEach(TokenBarStatusMetric.allCases) { metric in
                        Text(metric.displayName).tag(metric)
                    }
                }

                Toggle("显示速率折线图", isOn: self.$settings.showsStatusBarSpeedChart)

                Text("折线图展示最近最多 30 轮有效速率样本，并随刷新更新。上下行均可选择隐藏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            self.dashboardLayoutSection

            Section("模型价格") {
                Text("自动价格来源：官方价格表、OpenRouter、内置备用价。已启用的自定义规则优先使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("管理模型单价…") {
                    self.showsModelPricing = true
                }
            }

            Section("使用记录") {
                Picker("统计时区", selection: self.$settings.statisticsTimeZone) {
                    ForEach(TokenBarStatisticsTimeZone.allCases) { timeZone in
                        Text(timeZone.displayName).tag(timeZone)
                    }
                }

                Text("使用 UTC 可使今日及每日总量与 Codex 用量仪表盘保持一致。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("主菜单最近会话上限", selection: self.$settings.recentSessionCount) {
                    ForEach(TokenBarRecentSessionCount.allCases) { count in
                        Text("\(count.rawValue)").tag(count)
                    }
                }

                Toggle(
                    "悬停时显示完整请求内容",
                    isOn: self.$settings.showsFullRequestContentOnHover)
            }

            Section("额度") {
                Toggle(
                    "按工作日计算每周使用进度",
                    isOn: self.$settings.usesWeekdayWeeklyPacing)

                Text("将每周使用进度分配至五个工作日。周六和周日维持预期用量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let activitySync = self.activitySync {
                Section("多设备同步") {
                    Toggle("跨设备同步使用记录", isOn: self.$settings.syncEnabled)

                    TextField(
                        "服务器 URL",
                        text: self.$settings.syncServerURL,
                        prompt: Text("https://sync.example.com"))

                    SecureField(
                        "设备访问令牌",
                        text: Binding(
                            get: { activitySync.token },
                            set: { activitySync.token = $0 }))

                    TextField("设备名称", text: self.$settings.syncDeviceName)

                    LabeledContent("设备 ID") {
                        Text(self.settings.syncDeviceID)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Circle()
                            .fill(self.syncStatusColor(
                                self.syncDisplayPhase(activitySync.report)))
                            .frame(width: 7, height: 7)
                        Text(self.syncStatusTitle(activitySync.report))
                        Spacer()
                        Button("立即同步") {
                            self.syncNow()
                        }
                        .disabled(
                            !self.settings.syncEnabled
                                || activitySync.report.phase == .syncing)
                    }

                    if self.settings.syncEnabled,
                       let message = activitySync.credentialMessage
                        ?? activitySync.configurationMessage
                        ?? activitySync.report.message,
                       !message.isEmpty
                    {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(
                                activitySync.report.phase == .success
                                    ? Color.secondary
                                    : Color.red)
                    }

                    Text("上传会话名称、ID、token 数量、模型及时间信息，便于识别和复制已同步的会话。传输前会移除提示词与输出正文、工作区详情、绝对路径及平台凭据。同步出错时保留本地使用记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let memoryTelemetry = self.memoryTelemetry {
                Section("Codex 记忆") {
                    Toggle(
                        "监测 Codex 记忆用量",
                        isOn: self.$settings.monitorsCodexMemory)

                    Text("关闭后，TokenBar 会停止本地接收器、隐藏记忆用量，并将记忆遥测数据从多设备同步中移除。Codex 的记忆设置保持原样。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if self.settings.monitorsCodexMemory {
                        LabeledContent("接收器") {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(memoryTelemetry.receiverState.isListening ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(memoryTelemetry.receiverState.title)
                            }
                        }

                        Text(memoryTelemetry.receiverState.detail ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("Codex 配置") {
                            Text(memoryTelemetry.configurationState.title)
                        }

                        Text(memoryTelemetry.configurationState.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if memoryTelemetry.configurationState.canInstall {
                            Button(
                                memoryTelemetry.configurationState == .needsAnalytics
                                    ? "启用 Codex 分析"
                                    : "启用记忆指标")
                            {
                                memoryTelemetry.installConfiguration()
                            }
                        }

                        if let message = memoryTelemetry.configurationErrorMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Text("Codex 在本地进程启动时加载此设置。启用后请重启一次 Codex 或 ChatGPT。日志、调用追踪及提示词正文仍保持关闭。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("更新") {
                Picker("后台刷新间隔", selection: self.$settings.refreshInterval) {
                    ForEach(TokenBarRefreshInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                Text("会话活跃时，每轮完成后等待所选间隔。会话静止 60 秒后，刷新间隔至少为 5 分钟；检测到新的会话记录时立即恢复。额度自动查询最短间隔为 60 秒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("庆祝动画") {
                LabeledContent("额度重置时显示彩纸") {
                    HStack(spacing: 8) {
                        Picker("", selection: self.$settings.resetCelebration) {
                            ForEach(TokenBarResetCelebration.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .labelsHidden()

                        Button("测试动画") {
                            self.testResetAnimation()
                        }
                    }
                }

                Text("从平台对应的菜单栏区域播放动画，鼠标点击可穿透动画。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("恢复默认设置") {
                    self.settings.resetToDefaults()
                    self.loginItem.setEnabled(false)
                }
            }
        }
        .formStyle(.grouped)
        .frame(
            width: self.activitySync == nil ? 440 : 480,
            height: self.activitySync == nil
                ? (self.memoryTelemetry == nil ? 620 : 760)
                : 820)
        .onAppear {
            self.loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification))
        { _ in
            self.loginItem.refresh()
        }
        .sheet(isPresented: self.$showsModelPricing) {
            ModelPricingSettingsView(
                store: self.pricingStore,
                quoteService: self.priceQuoteService,
                observedModels: self.observedPricingModels)
        }
    }

    private var dashboardLayoutSection: some View {
        Section("菜单布局") {
            Text("选择板块与顺序。重置以来的统计随额度合并显示。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(self.settings.dashboardSectionOrder.enumerated()), id: \.element) { index, section in
                self.dashboardLayoutRow(section, at: index)
            }

            Text("Codex 记忆板块在 Codex 平台且已启用记忆监测时显示；显示偏好与采集设置分别保存。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func dashboardLayoutRow(_ section: TokenBarDashboardSection, at index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
                .accessibilityHidden(true)

            Toggle(
                section.displayName,
                isOn: Binding(
                    get: { self.settings.isDashboardSectionVisible(section) },
                    set: { self.settings.setDashboardSection(section, isVisible: $0) }))
                .toggleStyle(.checkbox)
                .accessibilityLabel("显示\(section.displayName)")
                .accessibilityHint("排列第 \(index + 1) 位；按空格键切换显示状态")

            Spacer(minLength: 8)

            Button("上移\(section.displayName)", systemImage: "arrow.up") {
                self.settings.moveDashboardSection(section, by: -1)
            }
            .labelStyle(.iconOnly)
            .help("上移\(section.displayName)")
            .accessibilityHint("按空格键向上移动一位")
            .disabled(index == 0)

            Button("下移\(section.displayName)", systemImage: "arrow.down") {
                self.settings.moveDashboardSection(section, by: 1)
            }
            .labelStyle(.iconOnly)
            .help("下移\(section.displayName)")
            .accessibilityHint("按空格键向下移动一位")
            .disabled(index == self.settings.dashboardSectionOrder.count - 1)
        }
    }

    private func syncStatusTitle(_ report: ActivitySyncReport) -> String {
        switch self.syncDisplayPhase(report) {
        case .disabled:
            "已关闭"
        case .ready:
            "就绪"
        case .syncing:
            "正在同步…"
        case .success:
            "已同步 \(report.deviceCount) 台设备"
        case .partial:
            "部分同步完成"
        case .failure:
            "同步出错"
        }
    }

    private func syncDisplayPhase(_ report: ActivitySyncReport) -> ActivitySyncPhase {
        guard self.settings.syncEnabled else { return .disabled }
        return report.phase == .disabled ? .ready : report.phase
    }

    private func syncStatusColor(_ phase: ActivitySyncPhase) -> Color {
        switch phase {
        case .success: .green
        case .syncing: .blue
        case .partial, .failure: .orange
        case .disabled, .ready: .secondary
        }
    }
}

extension TokenBarTheme {
    var color: Color {
        switch self {
        case .system: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        }
    }
}
