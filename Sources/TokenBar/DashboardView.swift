import Charts
import SwiftUI
import TokenBarCore

struct DashboardSummaryView: View {
    static let defaultSections: [TokenBarDashboardSection] = [.speed, .quota, .today, .weeklyReset, .activity]

    @Bindable var model: DashboardModel
    let showsClaude: Bool
    let showsGrok: Bool
    let showsAntigravity: Bool
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color
    var sections: [TokenBarDashboardSection] = DashboardSummaryView.defaultSections

    static func preferredHeight(
        quota: QuotaSnapshot?,
        providesQuota: Bool = true,
        showsClaude: Bool,
        showsGrok: Bool,
        showsAntigravity: Bool,
        sections: [TokenBarDashboardSection] = DashboardSummaryView.defaultSections) -> CGFloat
    {
        DashboardLayout.headerHeight(
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            showsAntigravity: showsAntigravity)
            + self.summarySections(sections, providesQuota: providesQuota).reduce(0) { total, section in
                total + (section == .activity
                    ? ActivitySummarySection.preferredHeight + 1
                    : DashboardSectionContentView.preferredHeight(
                        for: section, quota: quota, showsWeeklyUsage: sections.contains(.quota) && sections.contains(.weeklyReset)))
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            DashboardHeaderView(
                model: self.model,
                showsClaude: self.showsClaude,
                showsGrok: self.showsGrok,
                showsAntigravity: self.showsAntigravity,
                accentColor: self.accentColor,
                onSelectScope: nil)
                .frame(height: DashboardLayout.headerHeight(
                    showsClaude: self.showsClaude,
                    showsGrok: self.showsGrok,
                    showsAntigravity: self.showsAntigravity))
            ForEach(Self.summarySections(
                self.sections,
                providesQuota: self.model.providesQuota(for: self.model.scope.platform)), id: \.self)
            { section in
                if section == .activity {
                    Divider().padding(.horizontal, 12).frame(height: 1)
                    ActivitySummarySection(
                        state: self.model.visibleActivity,
                        accentColor: self.accentColor,
                        showsChevron: false,
                        model: self.model,
                        platform: self.model.scope.platform)
                        .frame(height: ActivitySummarySection.preferredHeight)
                } else {
                    DashboardSectionContentView(
                        section: section,
                        model: self.model,
                        usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                        accentColor: self.accentColor,
                        showsWeeklyUsage: self.sections.contains(.quota) && self.sections.contains(.weeklyReset))
                }
            }
        }
        .background(Color.clear)
    }

    static func summarySections(
        _ sections: [TokenBarDashboardSection],
        providesQuota: Bool) -> [TokenBarDashboardSection]
    {
        var seen: Set<TokenBarDashboardSection> = []
        return sections.filter { section in
            guard seen.insert(section).inserted else { return false }
            switch section {
            case .speed, .today, .activity: return true
            case .quota: return providesQuota
            case .weeklyReset: return providesQuota && !sections.contains(.quota)
            case .memory, .recentSessions: return false
            }
        }
    }
}

/// The independently hosted, fixed-height summary sections used by the menu.
struct DashboardSectionContentView: View {
    let section: TokenBarDashboardSection
    @Bindable var model: DashboardModel
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color
    var showsResetCredits = true
    var showsWeeklyUsage = false

    static func preferredHeight(
        for section: TokenBarDashboardSection,
        quota: QuotaSnapshot?,
        showsResetCredits: Bool = true,
        showsWeeklyUsage: Bool = false) -> CGFloat
    {
        switch section {
        case .speed: SpeedSummarySection.preferredHeight + 1
        case .quota:
            DashboardLayout.quotaHeight(quota: quota) + 1
                + (showsWeeklyUsage ? 40 : 0)
                - (!showsResetCredits && quota?.resetCredits != nil ? DashboardLayout.resetCreditsIncrement : 0)
        case .today: DashboardLayout.todayHeight + 1
        case .weeklyReset: DashboardLayout.weeklyResetActivityHeight + 1
        case .activity, .memory, .recentSessions: 0
        }
    }

    @ViewBuilder
    var body: some View {
        switch self.section {
        case .speed, .quota, .today, .weeklyReset:
            let quota = self.model.quotaState(for: self.model.scope.platform).value
            let height = Self.preferredHeight(
                for: self.section, quota: quota, showsResetCredits: self.showsResetCredits,
                showsWeeklyUsage: self.showsWeeklyUsage)
            VStack(spacing: 0) {
                Divider().padding(.horizontal, 12).frame(height: 1)
                self.sectionContent
                    .frame(height: height - 1, alignment: .top)
            }
            .frame(height: height, alignment: .top)
            .background(Color.clear)
        case .activity, .memory, .recentSessions:
            EmptyView()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        let platform = self.model.scope.platform
        let quotaState = self.model.quotaState(for: platform)
        switch self.section {
        case .speed:
            SpeedSummarySection(
                snapshot: self.model.visibleActivitySnapshot,
                platform: platform,
                accentColor: self.accentColor)
        case .quota:
            QuotaSummarySection(
                state: quotaState,
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor,
                showsResetCredits: self.showsResetCredits,
                showsWeeklyUsage: self.showsWeeklyUsage,
                weeklyUsage: self.model.visibleActivitySnapshot?.weeklySinceReset,
                dayBreakdown: self.model.weeklyQuotaDayBreakdown(for: platform))
        case .today:
            TodaySummarySection(
                state: self.model.visibleActivity,
                weeklyQuotaUsage: self.model.weeklyQuotaUsageToday(for: platform),
                dayBreakdown: self.model.weeklyQuotaDayBreakdown(for: platform),
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor)
        case .weeklyReset:
            WeeklyResetActivitySection(
                quota: quotaState.value,
                state: self.model.visibleActivity,
                usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                accentColor: self.accentColor)
        case .activity, .memory, .recentSessions:
            EmptyView()
        }
    }
}

struct SpeedSummarySection: View {
    static let preferredHeight: CGFloat = 164
    let snapshot: ActivitySnapshot?
    let platform: TokenPlatform
    let accentColor: Color
    @State private var selectedModel: String? = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TOKENBAR_DEMO_SPEED_MODEL"]
        #else
        return nil
        #endif
    }()

    private var selection: SpeedModelPresentation {
        SpeedModelPresentation(snapshot: self.snapshot, platform: self.platform, model: self.selectedModel)
    }

    var body: some View {
        let selection = self.selection
        let presentation = selection.summary
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("生成速度").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("最近一轮").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(presentation.latestSpeedValueText)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(presentation.latestSample == nil ? Color.secondary : self.accentColor)
                Text("tok/s").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                self.metric(self.selectedModel == nil ? "今日平均" : "样本均速",
                    value: self.selectedModel == nil ? presentation.todaySpeedText
                        : selection.sampleTokensPerSecond.map { SpeedSummaryPresentation.rateValueText($0) + " tok/s" } ?? "—")
                Spacer(minLength: 4)
                self.metric("首 token", value: presentation.latestFirstTokenText)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    self.modelButton(nil, label: "全部")
                    ForEach(selection.models, id: \.self) { model in
                        self.modelButton(model, label: model)
                    }
                }
            }
            .frame(height: 18)
            SpeedTrendChartView(points: selection.points, accentColor: self.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(height: Self.preferredHeight, alignment: .topLeading)
        .onChange(of: self.platform) { self.selectedModel = nil }
        .onChange(of: selection.models) { _, models in
            if let selectedModel = self.selectedModel, !models.contains(selectedModel) { self.selectedModel = nil }
        }
        .help("速率统计输出与推理 token，按实际请求耗时加权。曲线按模型分别绘制；悬停查看原始样本。")
    }

    private func modelButton(_ model: String?, label: String) -> some View {
        Button { self.selectedModel = model } label: {
            HStack(spacing: 3) {
                if let model {
                    Circle().fill(SpeedTrendChartView.modelColor(model: model, accentColor: self.accentColor))
                        .frame(width: 5, height: 5)
                }
                Text(label).font(.system(size: 9, weight: self.selectedModel == model ? .semibold : .regular))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(self.selectedModel == model ? self.accentColor.opacity(0.13) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.map { "查看 \($0) 速率" } ?? "查看全部模型速率")
        .accessibilityAddTraits(self.selectedModel == model ? .isSelected : [])
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 10.5, weight: .medium, design: .rounded))
                .monospacedDigit().lineLimit(1)
        }
    }
}

enum DashboardLayout {
    static let headerHeight: CGFloat = 64
    static let compactHeaderHeight: CGFloat = 28
    private static let unavailableQuotaHeight: CGFloat = 48
    private static let weeklyQuotaHeight: CGFloat = 71
    private static let fiveHourQuotaIncrement: CGFloat = 54
    static let resetCreditsIncrement: CGFloat = 24
    static let todayHeight: CGFloat = 112
    static let weeklyResetActivityHeight: CGFloat = 64

    static func headerHeight(
        showsClaude: Bool,
        showsGrok: Bool,
        showsAntigravity: Bool) -> CGFloat
    {
        DashboardScope.visibleScopes(
            showsClaude: showsClaude,
            showsGrok: showsGrok,
            showsAntigravity: showsAntigravity).count > 1
            ? self.headerHeight
            : self.compactHeaderHeight
    }

    static func quotaHeight(
        hasWeekly: Bool,
        hasFiveHour: Bool,
        hasResetCredits: Bool) -> CGFloat
    {
        (hasWeekly ? self.weeklyQuotaHeight : self.unavailableQuotaHeight)
            + (hasFiveHour ? self.fiveHourQuotaIncrement : 0)
            + (hasResetCredits ? self.resetCreditsIncrement : 0)
    }

    static func quotaHeight(quota: QuotaSnapshot?) -> CGFloat {
        self.quotaHeight(
            hasWeekly: quota?.weekly != nil,
            hasFiveHour: quota?.session != nil,
            hasResetCredits: quota?.resetCredits != nil)
    }
}

struct DashboardHeaderView: View {
    @Bindable var model: DashboardModel
    let showsClaude: Bool
    let showsGrok: Bool
    let showsAntigravity: Bool
    let accentColor: Color
    let onSelectScope: ((DashboardScope) -> Void)?

    var body: some View {
        let scopes = DashboardScope.visibleScopes(
            showsClaude: self.showsClaude,
            showsGrok: self.showsGrok,
            showsAntigravity: self.showsAntigravity)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("TokenBar")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if self.model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(self.updatedText)
                    .accessibilityLabel(self.updatedText)
            }

            if scopes.count > 1 {
                DashboardScopeSelector(
                    selection: self.model.scope,
                    scopes: scopes,
                    accentColor: self.accentColor)
                { scope in
                    if let onSelectScope = self.onSelectScope {
                        onSelectScope(scope)
                    } else {
                        self.model.scope = scope
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var updatedText: String {
        guard let date = self.model.activitySnapshot?.generatedAt else {
            return self.model.activity.isRefreshing ? "正在刷新…" : "等待数据"
        }
        return "更新于\(date.compactPastText)"
    }
}

private struct DashboardScopeSelector: View {
    let selection: DashboardScope
    let scopes: [DashboardScope]
    let accentColor: Color
    let onSelect: (DashboardScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(self.scopes) { scope in
                Text(scope.displayName)
                    .font(.system(
                        size: 10.5,
                        weight: self.selection == scope ? .semibold : .medium))
                    .foregroundStyle(self.selection == scope ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background {
                        if self.selection == scope {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(self.accentColor.opacity(0.18))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard self.selection != scope else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            self.onSelect(scope)
                        }
                    }
                    .accessibilityAddTraits(self.selection == scope ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("平台")
    }
}

struct QuotaPlanBadgePresentation: Equatable {
    enum Style: Equatable {
        case premium
        case standard
    }

    let title: String
    let style: Style
    let helpText: String

    init?(snapshot: QuotaSnapshot?) {
        guard let snapshot, let title = snapshot.planDisplayName else { return nil }
        self.title = ["pro", "plus"].contains(title.lowercased()) ? title.uppercased() : title
        self.style = title.caseInsensitiveCompare("Pro") == .orderedSame ? .premium : .standard
        self.helpText = "套餐：\(title)" + (snapshot.planType.map { " · \($0)" } ?? "")
    }
}

private struct QuotaPlanBadge: View {
    let presentation: QuotaPlanBadgePresentation

    var body: some View {
        Group {
            if self.presentation.style == .premium {
                HStack(spacing: 3) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(self.presentation.title)
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(Color(red: 0.31, green: 0.20, blue: 0.04))
                .padding(.horizontal, 6)
                .frame(height: 17)
                .background(LinearGradient(
                    colors: [Color(red: 1, green: 0.94, blue: 0.70),
                             Color(red: 0.91, green: 0.69, blue: 0.27),
                             Color(red: 1, green: 0.88, blue: 0.54)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5))
            } else {
                Text(self.presentation.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
        }
        .lineLimit(1)
        .help(self.presentation.helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("套餐：\(self.presentation.title)")
    }
}

private struct QuotaSummarySection: View {
    let state: DashboardSourceState<QuotaSnapshot>
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color
    var showsResetCredits = true
    var showsWeeklyUsage = false
    var weeklyUsage: ActivityRangeSummary?
    var dayBreakdown: WeeklyQuotaDayBreakdown?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("额度")
                    .font(.system(size: 12, weight: .semibold))
                if let plan = QuotaPlanBadgePresentation(snapshot: self.state.value) {
                    QuotaPlanBadge(presentation: plan)
                        .frame(height: 14)
                }
                Spacer()
                if self.state.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(self.state.errorMessage ?? "额度刷新失败")
                }
            }

            if let snapshot = self.state.value, let weekly = snapshot.weekly {
                WeeklyQuotaProgressRow(
                    window: weekly,
                    measuredAt: snapshot.updatedAt,
                    usesWeekdayWeeklyPacing: self.usesWeekdayWeeklyPacing,
                    accentColor: self.accentColor,
                    dayBreakdown: self.dayBreakdown)
            } else {
                InlinePlaceholder(
                    text: self.state.isRefreshing
                        ? "正在加载每周额度…"
                        : "每周额度待获取")
            }

            if let fiveHour = self.state.value?.session {
                QuotaProgressRow(
                    title: "5 小时",
                    window: fiveHour,
                    accentColor: self.accentColor)
            }

            if self.showsWeeklyUsage {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("重置以来").foregroundStyle(.secondary)
                        Spacer()
                        if let totals = self.validWeeklyUsage?.totals {
                            Text("\(totals.tokens.total.compactCount) token")
                                .fontWeight(.medium).monospacedDigit()
                            Text(totals.costUsd.costText(tokenTotal: totals.tokens.total))
                                .foregroundStyle(TokenBarVisualStyle.costAccentColor)
                        }
                    }
                    if let totals = self.validWeeklyUsage?.totals {
                        Text("\(totals.sessionCount) 个会话 · \(totals.requestCount) 轮")
                            .foregroundStyle(.secondary)
                    } else {
                        InlinePlaceholder(text: "重置后的用量待获取")
                    }
                }
                .font(.system(size: 10.5))
                .frame(height: 32, alignment: .center)
            }
            if self.showsResetCredits, let resetCredits = self.state.value?.resetCredits {
                ResetCreditsRow(snapshot: resetCredits)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .help(self.state.value.map(self.sampleText) ?? "额度数据待获取")
    }

    private var validWeeklyUsage: ActivityRangeSummary? {
        WeeklyResetUsagePresentation.summary(quota: self.state.value, usage: self.weeklyUsage)
    }

    private func sampleText(_ snapshot: QuotaSnapshot) -> String {
        let age = snapshot.updatedAt.compactPastText
        switch snapshot.origin {
        case .claudeDesktop:
            return "Claude Desktop · \(age)"
        case .liveProvider:
            return "Anthropic · \(age)"
        case nil:
            return "采样于\(age)"
        }
    }
}

private struct WeeklyQuotaProgressRow: View {
    let window: QuotaWindowSnapshot
    let measuredAt: Date
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color
    var dayBreakdown: WeeklyQuotaDayBreakdown?

    var body: some View {
        if let reset = self.window.resetsAt,
           reset > Date(),
           let pacing = self.window.weeklyPacing(
               at: self.measuredAt,
               weekdaysOnly: self.usesWeekdayWeeklyPacing)
        {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("每周")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("· \(self.resetText)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text("剩余 \(Int((100 - pacing.actualUsedPercent).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }

                WeeklyQuotaSegmentedBar(
                    pacing: pacing,
                    tint: self.accentColor,
                    dayBreakdown: self.dayBreakdown)
                HStack(spacing: 10) {
                    self.dayLegend("今日", value: self.dayBreakdown?.todayUsedPercentagePoints,
                        color: self.accentColor, partial: self.dayBreakdown?.todayIsPartial ?? false)
                    self.dayLegend("昨日", value: self.dayBreakdown?.yesterdayUsedPercentagePoints,
                        color: TokenBarPalette.yesterday(for: self.accentColor), partial: self.dayBreakdown?.yesterdayIsPartial ?? false)
                    self.dayLegend("更早/未分日", value: self.dayBreakdown?.earlierUsedPercentagePoints,
                        color: .secondary.opacity(0.55), partial: false)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("按当前统计时区归属采样增量；开始追踪前的累计用量归入更早/未分日。")

            }
            .help(self.helpText(pacing))
        } else {
            QuotaProgressRow(
                title: "每周",
                window: self.window,
                accentColor: self.accentColor)
        }
    }

    private func dayLegend(_ title: String, value: Double?, color: Color, partial: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(title + " " + QuotaDayText.value(value, partial: partial,
                adjusted: self.dayBreakdown?.wasAdjustedForQuotaCorrection ?? false))
        }
    }

    private var tint: Color {
        switch self.window.remainingPercent {
        case ..<10: .red
        case ..<20: .orange
        default: self.accentColor
        }
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt else { return "重置时间待获取" }
        return "\(reset.compactFutureText)重置"
    }

    private func deltaText(_ pacing: WeeklyQuotaPacing) -> String {
        let delta = pacing.deltaPercentagePoints
        guard abs(delta) >= 1 else { return "符合进度" }
        return "\(delta > 0 ? "高于" : "低于")\(Int(abs(delta).rounded()))pp"
    }

    private func deltaColor(_ pacing: WeeklyQuotaPacing) -> Color {
        let delta = pacing.deltaPercentagePoints
        if delta >= 1 {
            return .orange
        }
        if delta <= -1 {
            return TokenBarPalette.mint
        }
        return .secondary
    }

    private func helpText(_ pacing: WeeklyQuotaPacing) -> String {
        let start = pacing.windowStart.formatted(date: .abbreviated, time: .shortened)
        let end = pacing.windowEnd.formatted(date: .abbreviated, time: .shortened)
        let paceDescription = pacing.weekdaysOnly
            ? "每段对应一个从零点开始的完整工作日；进度按工作日推进。"
            : "每段对应额度周期的七分之一。"
        return "每周周期：\(start) – \(end)。\(paceDescription)"
            + "已用 \(Int(pacing.actualUsedPercent.rounded()))%；"
            + "匀速进度为 \(Int(pacing.expectedUsedPercent.rounded()))%，\(self.deltaText(pacing))。"
    }
}

private struct WeeklyQuotaSegmentedBar: View {
    let pacing: WeeklyQuotaPacing
    let tint: Color
    var dayBreakdown: WeeklyQuotaDayBreakdown?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    ForEach(0 ..< self.pacing.segmentCount, id: \.self) { index in
                        GeometryReader { segment in
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.15))
                                if let days = self.dayBreakdown {
                                    self.dayFill(in: segment.size.width, index: index, days: days)
                                } else {
                                    Rectangle().fill(self.tint)
                                        .frame(width: segment.size.width * self.fillFraction(for: index))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }
                    }
                }
                .frame(height: 8)

                Capsule()
                    .fill(Color.primary.opacity(0.72))
                    .frame(width: 1.5, height: 12)
                    .position(
                        x: self.markerX(in: proxy.size.width),
                        y: proxy.size.height / 2)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityText)
    }

    private func dayFill(in width: CGFloat, index: Int, days: WeeklyQuotaDayBreakdown) -> some View {
        let segmentPercent = 100 / Double(self.pacing.segmentCount)
        let start = Double(index) * segmentPercent
        let end = start + segmentPercent
        let earlier = days.earlierUsedPercentagePoints
        let yesterday = days.yesterdayUsedPercentagePoints ?? 0
        return ZStack(alignment: .leading) {
            self.coloredInterval(start: 0, end: earlier, color: .secondary.opacity(0.55),
                segmentStart: start, segmentEnd: end, width: width)
            self.coloredInterval(start: earlier, end: earlier + yesterday, color: TokenBarPalette.yesterday(for: self.tint),
                segmentStart: start, segmentEnd: end, width: width)
            self.coloredInterval(start: earlier + yesterday, end: days.totalUsedPercent, color: self.tint,
                segmentStart: start, segmentEnd: end, width: width)
        }
    }

    private func coloredInterval(start: Double, end: Double, color: Color,
        segmentStart: Double, segmentEnd: Double, width: CGFloat) -> some View {
        let left = max(segmentStart, start)
        let right = min(segmentEnd, end)
        let fraction = max(0, right - left) / (segmentEnd - segmentStart)
        return Rectangle().fill(color).frame(width: width * fraction)
            .offset(x: width * max(0, left - segmentStart) / (segmentEnd - segmentStart))
    }

    private func fillFraction(for index: Int) -> Double {
        let segmentPercent = 100 / Double(self.pacing.segmentCount)
        let segmentStart = Double(index) * segmentPercent
        return ((self.pacing.actualUsedPercent - segmentStart) / segmentPercent).clamped(to: 0 ... 1)
    }

    private func markerX(in width: CGFloat) -> CGFloat {
        let raw = width * CGFloat(self.pacing.expectedUsedPercent / 100)
        return raw.clamped(to: 1 ... max(1, width - 1))
    }

    private var accessibilityText: String {
        let delta = self.pacing.deltaPercentagePoints
        let comparison = abs(delta) < 1
            ? "符合进度"
            : "比预计进度\(delta > 0 ? "高" : "低")\(Int(abs(delta).rounded()))个百分点"
        return "每周额度，已用百分之\(Int(self.pacing.actualUsedPercent.rounded()))，"
            + "预计百分之\(Int(self.pacing.expectedUsedPercent.rounded()))，\(comparison)。"
    }
}

private struct QuotaProgressRow: View {
    let title: String
    let window: QuotaWindowSnapshot
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(self.title)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                if self.window.usageKnown {
                    Text("剩余 \(Int(self.window.remainingPercent.clamped(to: 0 ... 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }

            if self.window.usageKnown {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.17))
                        Capsule()
                            .fill(self.tint)
                            .frame(
                                width: proxy.size.width
                                    * self.window.remainingPercent.clamped(to: 0 ... 100) / 100)
                    }
                }
                .frame(height: 6)
            } else {
                Text("用量待获取")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Text(self.resetText)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var tint: Color {
        switch self.window.remainingPercent {
        case ..<10: .red
        case ..<20: .orange
        default: self.accentColor
        }
    }

    private var resetText: String {
        guard let reset = self.window.resetsAt, reset > Date() else {
            return "重置时间待获取"
        }
        return "\(reset.compactFutureText)重置"
    }
}

private struct ResetCreditsRow: View {
    let snapshot: QuotaResetCreditsSnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text("额外重置")
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Text(self.countText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let expiration = self.snapshot.nextExpiresAt {
                Text("· \(expiration.compactFutureText)到期")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("额外重置，\(self.countText)，展开查看全部记录")
        .help(ResetCreditsDetailPresentation.countText(self.snapshot) + "；展开查看全部记录")
    }

    private var countText: String {
        "可用 \(self.snapshot.availableCount) 次"
    }
}

struct ResetCreditsMenuRowView: View {
    static let preferredHeight = DashboardLayout.resetCreditsIncrement
    let snapshot: QuotaResetCreditsSnapshot

    var body: some View {
        ResetCreditsRow(snapshot: self.snapshot)
            .padding(.horizontal, 16)
            .frame(height: Self.preferredHeight)
    }
}

enum ResetCreditsDetailPresentation {
    static func hasInventory(_ snapshot: QuotaResetCreditsSnapshot) -> Bool {
        !snapshot.credits.isEmpty || snapshot.serverAvailableCount != nil
    }

    static func countText(_ snapshot: QuotaResetCreditsSnapshot) -> String {
        let available = "可用 \(snapshot.availableCount) 次"
        return self.hasInventory(snapshot) ? available + " / 共 \(snapshot.credits.count) 次" : available
    }

    static func title(for credit: QuotaResetCredit, index: Int, sampledAt: Date) -> String {
        "记录 \(index + 1) · \(self.statusText(for: credit, sampledAt: sampledAt))"
    }

    static func statusText(for credit: QuotaResetCredit, sampledAt: Date) -> String {
        switch credit.effectiveStatus(at: sampledAt) {
        case "available": "可用"
        case "used", "redeemed", "consumed": "已使用"
        case "expired": "已到期"
        case "revoked": "已撤销"
        default: credit.status.isEmpty ? "状态待获取" : credit.status
        }
    }

    static func expirationText(for credit: QuotaResetCredit) -> String {
        credit.expiresAt.map { "到期：\(self.timestampText($0))" } ?? "到期时间：服务端留空"
    }

    static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    static func emptyText(_ snapshot: QuotaResetCreditsSnapshot) -> String {
        self.hasInventory(snapshot)
            ? "服务端本次返回 0 条重置记录。"
            : "当前缓存保留可用次数；刷新后获取全部条目。"
    }
}

struct ResetCreditsDetailHeaderView: View {
    let snapshot: QuotaResetCreditsSnapshot

    static func preferredHeight(for snapshot: QuotaResetCreditsSnapshot) -> CGFloat {
        self.showsServerCount(snapshot) ? 68 : 52
    }

    static func showsServerCount(_ snapshot: QuotaResetCreditsSnapshot) -> Bool {
        snapshot.serverAvailableCount.map { $0 != snapshot.availableCount } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("额外重置")
                .font(.system(size: 13, weight: .semibold))
            Text(ResetCreditsDetailPresentation.countText(self.snapshot))
                .font(.system(size: 11, weight: .medium))
            if Self.showsServerCount(self.snapshot), let count = self.snapshot.serverAvailableCount {
                Text("服务端标记可用 \(count) 次；上方为采样时仍有效的次数。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(height: Self.preferredHeight(for: self.snapshot), alignment: .center)
    }
}

struct ResetCreditDetailEntryView: View {
    static let preferredHeight: CGFloat = 48
    let credit: QuotaResetCredit
    let index: Int
    let sampledAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ResetCreditsDetailPresentation.title(for: self.credit, index: self.index, sampledAt: self.sampledAt))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(self.credit.isAvailable(at: self.sampledAt) ? Color.green : Color.primary)
                .lineLimit(1)
            Text(ResetCreditsDetailPresentation.expirationText(for: self.credit))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .frame(height: Self.preferredHeight, alignment: .center)
        .accessibilityElement(children: .combine)
        .help("服务端状态：\(self.credit.status)\n\(ResetCreditsDetailPresentation.expirationText(for: self.credit))")
    }
}

struct ResetCreditsDetailEmptyView: View {
    static let preferredHeight: CGFloat = 48
    let snapshot: QuotaResetCreditsSnapshot

    var body: some View {
        Text(ResetCreditsDetailPresentation.emptyText(self.snapshot))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: Self.preferredHeight)
    }
}

struct ResetCreditsDetailFooterView: View {
    static let preferredHeight: CGFloat = 28
    let sampledAt: Date

    var body: some View {
        Text("本次返回的全部记录 · 采样：\(ResetCreditsDetailPresentation.timestampText(self.sampledAt))")
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: Self.preferredHeight)
    }
}

/// Uses the same header, rows and footer as the native detail submenu.
struct ResetCreditsDetailView: View {
    static let preferredWidth: CGFloat = 384
    let snapshot: QuotaResetCreditsSnapshot
    let sampledAt: Date

    static func preferredHeight(for snapshot: QuotaResetCreditsSnapshot) -> CGFloat {
        ResetCreditsDetailHeaderView.preferredHeight(for: snapshot) + 2
            + CGFloat(max(1, snapshot.credits.count)) * ResetCreditDetailEntryView.preferredHeight
            + ResetCreditsDetailFooterView.preferredHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ResetCreditsDetailHeaderView(snapshot: self.snapshot)
            Divider().frame(height: 1)
            if self.snapshot.credits.isEmpty {
                ResetCreditsDetailEmptyView(snapshot: self.snapshot)
            } else {
                ForEach(Array(self.snapshot.credits.enumerated()), id: \.offset) { index, credit in
                    ResetCreditDetailEntryView(credit: credit, index: index, sampledAt: self.sampledAt)
                }
            }
            Divider().frame(height: 1)
            ResetCreditsDetailFooterView(sampledAt: self.sampledAt)
        }
        .frame(width: Self.preferredWidth, height: Self.preferredHeight(for: self.snapshot))
    }
}

private struct WeeklyResetActivitySection: View {
    let quota: QuotaSnapshot?
    let state: DashboardSourceState<ActivitySnapshot>
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    private var pacing: WeeklyQuotaPacing? {
        guard let quota,
              let weekly = quota.weekly,
              let reset = weekly.resetsAt,
              reset > Date()
        else {
            return nil
        }
        return weekly.weeklyPacing(
            at: quota.updatedAt,
            weekdaysOnly: self.usesWeekdayWeeklyPacing)
    }

    private var summary: ActivityRangeSummary? {
        WeeklyResetUsagePresentation.summary(quota: self.quota, usage: self.state.value?.weeklySinceReset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text("每周重置以来")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let totals = self.summary?.totals {
                    Text(totals.tokens.total.compactCount)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("token")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            TokenStackedBar(
                tokens: self.summary?.totals.tokens ?? .zero,
                accentColor: self.accentColor)

            if let totals = self.summary?.totals {
                HStack {
                    Text(
                        "\(totals.sessionCount) 个会话 · \(totals.requestCount) 轮")
                    Spacer(minLength: 6)
                    Text(totals.costUsd.costText(tokenTotal: totals.tokens.total))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarVisualStyle.costAccentColor)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            } else {
                InlinePlaceholder(text: self.placeholderText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .help(self.summary.map { "缓存 \($0.totals.tokens.cachePercentageText) · " + self.performanceText($0.totals) } ?? self.placeholderText)
    }

    private var placeholderText: String {
        if self.pacing == nil {
            return "等待有效的每周重置周期…"
        }
        if self.state.isRefreshing {
            return "正在统计重置后的用量…"
        }
        return self.state.errorMessage ?? "每周重置后的用量待获取"
    }

    private func performanceText(_ totals: ActivityTotals) -> String {
        totals.menuPerformanceText.map { "\($0) · " } ?? ""
    }
}

private struct TodaySummarySection: View {
    let state: DashboardSourceState<ActivitySnapshot>
    let weeklyQuotaUsage: WeeklyQuotaDailyUsage?
    var dayBreakdown: WeeklyQuotaDayBreakdown?
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let totals = self.state.value?.today {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(totals.tokens.total.compactCount)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("token")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(totals.costUsd.costText(tokenTotal: totals.tokens.total))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarVisualStyle.costAccentColor)
                }

                HStack(spacing: 4) {
                    Text(self.weeklyQuotaUsage == nil && self.dayBreakdown?.wasAdjustedForQuotaCorrection == true ? "今日估算周额度" : "今日已用周额度")
                        .foregroundStyle(.secondary)
                    Text(QuotaDayText.value(self.weeklyQuotaUsage?.usedPercentagePoints ?? self.dayBreakdown?.todayUsedPercentagePoints,
                        partial: self.weeklyQuotaUsage?.isPartial ?? self.dayBreakdown?.todayIsPartial ?? false,
                        adjusted: self.weeklyQuotaUsage == nil && self.dayBreakdown?.wasAdjustedForQuotaCorrection == true,
                        unknown: "待记录"))
                        .fontWeight(.medium).foregroundStyle(self.accentColor).monospacedDigit()
                    Spacer()
                }
                .font(.system(size: 10))
                .help("占完整周额度的比例，按统计日累计已记录增量，包含当日重置前的用量；额度条按当前周期分色。≥ 表示当天部分记录；≈ 表示校正估算。")

                TokenStackedBar(tokens: totals.tokens, accentColor: self.accentColor)

                ActivityTotalsBreakdown(
                    totals: totals,
                    performanceText: totals.menuPerformanceText
                        ?? self.state.value?.menuPerformanceText,
                    accentColor: self.accentColor,
                    showsBar: false,
                    showsMetadata: false,
                    showsTotalCost: false)
            } else {
                HStack {
                    Text("今日")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    InlinePlaceholder(text: self.state.isRefreshing ? "正在扫描使用记录…" : "等待今日使用记录")
                }
                TokenStackedBar(tokens: .zero, accentColor: self.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .help(self.weeklyQuotaUsage?.menuHelpText ?? "今日使用量")
    }
}

struct WeeklyQuotaUsageLabel: View {
    let usage: WeeklyQuotaDailyUsage
    let usesWeekdayWeeklyPacing: Bool
    let accentColor: Color
    var leadingSeparator = false

    var body: some View {
        HStack(spacing: 3) {
            Text(self.leadingSeparator ? "· 每周额度" : "每周额度")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(self.usage.menuValueText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(self.tint)
        }
        .help(self.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "今日已用每周额度 \(self.usage.menuValueText)")
    }

    // 匀速消耗周额度时单日应占的百分点：按 5 个工作日或 7 天平摊
    private var evenDailyShare: Double {
        100 / (self.usesWeekdayWeeklyPacing ? 5.0 : 7.0)
    }

    private var tint: Color {
        switch self.usage.usedPercentagePoints / self.evenDailyShare {
        case ..<0.85: TokenBarPalette.mint
        case ..<1.25: self.accentColor
        case ..<2: Color.orange
        default: Color.red
        }
    }

    private var helpText: String {
        let share = self.evenDailyShare.formatted(.number.precision(.fractionLength(0 ... 1)))
        let pace = self.usesWeekdayWeeklyPacing
            ? "按工作日均摊，每天约 \(share) 个百分点。"
            : "按自然日均摊，每天约 \(share) 个百分点。"
        return self.usage.menuHelpText + pace
    }
}

struct ActivityTotalsBreakdown: View {
    let totals: ActivityTotals
    let performanceText: String?
    let accentColor: Color
    var showsBar = true
    var showsMetadata = true
    var showsTotalCost = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if self.showsBar {
                TokenStackedBar(tokens: self.totals.tokens, accentColor: self.accentColor)
            }

            HStack(spacing: 16) {
                TokenLegend(
                    label: "输入",
                    value: self.totals.tokens.displayedInput,
                    costUsd: self.totals.tokenCosts?.displayedInput,
                    color: self.accentColor)
                TokenLegend(
                    label: "输出",
                    value: self.totals.tokens.output,
                    costUsd: self.totals.tokenCosts?.output,
                    color: TokenBarPalette.blue)
            }
            HStack(spacing: 16) {
                TokenLegend(
                    label: "缓存",
                    value: self.totals.tokens.displayedCache,
                    costUsd: self.totals.tokenCosts?.displayedCache,
                    color: TokenBarPalette.mint)
                TokenLegend(
                    label: "推理",
                    value: self.totals.tokens.reasoning,
                    costUsd: self.totals.tokenCosts?.reasoning,
                    color: TokenBarPalette.orange)
            }

            if self.showsMetadata || self.showsTotalCost {
            HStack {
                if self.showsMetadata {
                    Text(self.metadataText)
                }
                Spacer()
                if self.showsTotalCost {
                    Text(self.totals.costUsd.costText(tokenTotal: self.totals.tokens.total))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TokenBarVisualStyle.costAccentColor)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .help(self.metadataText)
            }
        }
    }

    private var metadataText: String {
        "缓存 \(self.totals.tokens.cachePercentageText) · " + self.performanceSuffix
            + "\(self.totals.sessionCount) 个会话 · \(self.totals.requestCount) 轮"
    }

    private var performanceSuffix: String {
        self.performanceText.map { "\($0) · " } ?? ""
    }
}

private struct TokenStackedBar: View {
    let tokens: TokenBreakdown
    let accentColor: Color

    private var components: [TokenComponent] {
        [
            TokenComponent(id: "input", value: self.tokens.displayedInput, color: self.accentColor),
            TokenComponent(id: "output", value: self.tokens.output, color: TokenBarPalette.blue),
            TokenComponent(
                id: "cache",
                value: self.tokens.displayedCache,
                color: TokenBarPalette.mint),
            TokenComponent(id: "reasoning", value: self.tokens.reasoning, color: TokenBarPalette.orange),
        ].filter { $0.value > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                if self.tokens.total > 0 {
                    HStack(spacing: 1) {
                        ForEach(self.components) { component in
                            Rectangle()
                                .fill(component.color)
                                .frame(
                                    width: max(
                                        1,
                                        (proxy.size.width - CGFloat(max(0, self.components.count - 1)))
                                            * CGFloat(component.value) / CGFloat(self.tokens.total)))
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 8)
    }
}

private struct TokenComponent: Identifiable {
    let id: String
    let value: Int64
    let color: Color
}

private struct TokenLegend: View {
    let label: String
    let value: Int64
    let costUsd: Double?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(self.color)
                .frame(width: 6, height: 6)
            Text(self.label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(self.value.compactCount)
                .monospacedDigit()
            if let costText = self.costText {
                Text(costText)
                    .fontWeight(.regular)
                    .foregroundStyle(TokenBarVisualStyle.costAccentColor.opacity(0.76))
                    .monospacedDigit()
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .frame(maxWidth: .infinity)
        .lineLimit(1)
    }

    private var costText: String? {
        guard let costUsd = self.costUsd, costUsd.isFinite, costUsd >= 0 else { return nil }
        return costUsd.tokenComponentCostText
    }
}

private enum QuotaDayText {
    static func value(_ value: Double?, partial: Bool, adjusted: Bool, unknown: String = "—") -> String {
        guard let value else { return unknown }
        let prefix = adjusted ? "≈" : partial ? "≥" : ""
        return prefix + value.formatted(.number.precision(.fractionLength(0 ... 1))) + "%"
    }
}

private struct InlinePlaceholder: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private enum TokenBarPalette {
    static func yesterday(for today: Color) -> Color {
        guard let rgb = NSColor(today).usingColorSpace(.deviceRGB) else { return self.blue }
        return rgb.blueComponent >= rgb.redComponent && rgb.blueComponent >= rgb.greenComponent * 0.9
            ? self.orange : self.blue
    }

    static let indigo = Color(red: 0.48, green: 0.41, blue: 0.86)
    static let blue = Color(red: 0.28, green: 0.58, blue: 0.88)
    static let mint = Color(red: 0.24, green: 0.69, blue: 0.59)
    static let orange = Color(red: 0.91, green: 0.57, blue: 0.25)
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Int64 {
    var compactCount: String {
        let absolute = abs(Double(self))
        let divisor: Double
        let suffix: String
        switch absolute {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return self.formatted()
        }
        return "\((Double(self) / divisor).formatted(.number.precision(.fractionLength(0 ... 1))))\(suffix)"
    }

    func saturatingAdd(_ other: Int64) -> Int64 {
        let (value, overflow) = self.addingReportingOverflow(other)
        guard overflow else { return value }
        return other >= 0 ? .max : .min
    }
}

extension Double {
    var usdText: String {
        String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            self)
    }

    func costText(tokenTotal: Int64) -> String {
        tokenTotal > 0 && self <= 0 ? "—" : self.usdText
    }

    fileprivate var tokenComponentCostText: String {
        self > 0 && self < 0.01 ? "<$0.01" : self.usdText
    }
}

extension String {
    func menuTruncated(to limit: Int) -> String {
        guard self.count > limit else { return self }
        return "\(self.prefix(max(0, limit - 1)))…"
    }

    var shortDateLabel: String {
        self.count >= 10 ? String(self.suffix(5)).replacingOccurrences(of: "-", with: "/") : self
    }
}

extension WeeklyQuotaDailyUsage {
    var menuValueText: String {
        self.usedPercentagePoints.formatted(
            .number.precision(.fractionLength(0 ... 1))) + "pp"
    }

    var menuHelpText: String {
        let base = "TokenBar 在 \(self.date) 各次采样之间观测到的每周额度变化。"
        guard self.isPartial else { return base }
        return base + "记录从额度周期中途开始，"
            + "仅覆盖开始记录后的当日用量。"
    }
}

private extension Date {
    var compactPastText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(self)))
        switch seconds {
        case 0 ..< 60:
            return "刚刚"
        case 60 ..< 3600:
            return "\(seconds / 60) 分钟前"
        case 3600 ..< 86_400:
            return "\(seconds / 3600) 小时前"
        default:
            return "\(seconds / 86_400) 天前"
        }
    }

    var compactFutureText: String {
        let seconds = max(0, Int(self.timeIntervalSinceNow))
        if seconds < 60 {
            return "1 分钟内"
        }
        if seconds < 3600 {
            return "\(seconds / 60) 分钟后"
        }
        if seconds < 86_400 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟后" : "\(hours) 小时后"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        return hours > 0 ? "\(days) 天 \(hours) 小时后" : "\(days) 天后"
    }
}
