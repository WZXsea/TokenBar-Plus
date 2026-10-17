import Charts
import SwiftUI
import TokenBarCore

struct ActivitySummarySection: View {
    static let preferredHeight: CGFloat = 136
    let state: DashboardSourceState<ActivitySnapshot>
    let accentColor: Color
    let showsChevron: Bool
    var model: DashboardModel? = nil
    var platform: TokenPlatform? = nil
    @State private var range: ActivityHistoryRange = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["TOKENBAR_DEMO_HISTORY_RANGE"].flatMap(ActivityHistoryRange.init(rawValue:)) ?? .month
        #else
        return .month
        #endif
    }()
    @State private var hoveredID: String?

    private var historyState: DashboardSourceState<ActivitySnapshot>? { self.model?.history }
    private var isExtendedReady: Bool { self.range != .year || self.historyState?.value != nil }
    private var presentation: ActivityHistoryPresentation {
        let days = self.range == .year ? self.model?.historyDays(for: self.platform) ?? self.state.value?.days ?? [] : self.state.value?.days ?? []
        let zone = self.model?.historyTimeZone ?? self.state.value.flatMap { TimeZone(identifier: $0.timezone) } ?? TimeZone(secondsFromGMT: 0)!
        return ActivityHistoryPresentation(days: days, range: self.range, now: self.state.value?.generatedAt ?? Date(), timeZone: zone)
    }

    var body: some View {
        let data = self.presentation
        let labeledDates = Set(self.axisIDs(data))
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text("使用记录").font(.system(size: 12, weight: .semibold))
                Picker("时间范围", selection: Self.historySelection(self.$range, model: self.model)) {
                    ForEach(ActivityHistoryRange.allCases) { range in Text(range.title).tag(range) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 92)
                .controlSize(.mini)
                .help(self.range.subtitle)
                Spacer(minLength: 2)
                Text(self.isExtendedReady ? data.totalTokens.compactCount : "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("token").font(.system(size: 10)).foregroundStyle(.secondary)
                if self.showsChevron { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            ZStack(alignment: .topLeading) {
                Chart(data.buckets) { bucket in
                    BarMark(x: .value("日期", bucket.id), y: .value("token", bucket.tokens))
                        .foregroundStyle(self.accentColor.opacity(bucket.id == data.buckets.last?.id ? 0.95 : 0.55))
                        .cornerRadius(1.5)
                }
                .chartYScale(domain: 0 ... max(1, data.maximumTokens))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel { if let count = value.as(Int64.self) { Text(count.compactCount).font(.system(size: 8)) } }
                    }
                }
                .chartXAxis {
                    // Charts may emit every categorical value even when explicit marks are requested.
                    // Gate the label itself so all ranges retain only start, middle and end dates.
                    AxisMarks(values: data.buckets.map(\.id)) { value in
                        if let key = value.as(String.self), labeledDates.contains(key) {
                            AxisValueLabel(anchor: self.axisAnchor(key, data: data)) {
                                Text(self.axisLabel(key)).font(.system(size: 8)).fixedSize()
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Color.clear.onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                guard let frame = proxy.plotFrame else { self.hoveredID = nil; return }
                                let plot = geometry[frame]
                                guard plot.contains(location) else { self.hoveredID = nil; return }
                                self.hoveredID = proxy.value(atX: location.x - plot.minX, as: String.self)
                            case .ended: self.hoveredID = nil
                            }
                        }
                    }
                }
                .opacity(self.isExtendedReady ? 1 : 0.3)
                if let bucket = data.buckets.first(where: { $0.id == self.hoveredID }), self.isExtendedReady {
                    Text("\(bucket.id) · \(bucket.tokens.compactCount) token · \(bucket.costUsd.usdText) · \(bucket.requestCount) 轮")
                        .font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 35)
                        .allowsHitTesting(false)
                }
                if !self.isExtendedReady {
                    VStack(spacing: 3) {
                        Text(self.historyState?.errorMessage ?? "正在加载近 12 个月…")
                        if self.historyState?.errorMessage != nil {
                            Button("重新加载") { Task { await self.model?.loadHistoryIfNeeded() } }.buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if data.totalTokens == 0 {
                    Text(self.state.isRefreshing ? "正在加载…" : "暂无使用记录")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if self.hoveredID == nil {
                    Text(self.range == .year ? "近 12 个月 · 本机" : self.range.subtitle).font(.system(size: 8)).foregroundStyle(.secondary).padding(.top, -2).allowsHitTesting(false)
                }
            }
            .frame(height: 95)
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .help("\(self.range.subtitle)；\(self.range == .year ? "每柱为一个月，仅本机记录，约每 5 分钟更新" : "每柱为一天")；悬停查看 Token、费用和轮数。")
        .task(id: "\(self.range.rawValue)-\(self.model?.historyRevision ?? 0)-\(self.platform?.rawValue ?? "all")-\((self.state.value?.generatedAtMs ?? 0) / 300_000)") {
            if self.range == .year { await self.model?.loadHistoryIfNeeded() }
        }
    }

    /// Menu item hosts can receive control actions before SwiftUI starts appearance tasks.
    /// Start the on-demand fetch from the selection action as well as the appearance task.
    @MainActor
    static func historySelection(
        _ selection: Binding<ActivityHistoryRange>,
        model: DashboardModel?
    ) -> Binding<ActivityHistoryRange> {
        Binding(
            get: { selection.wrappedValue },
            set: { range in
                selection.wrappedValue = range
                if range == .year {
                    Task { await model?.loadHistoryIfNeeded() }
                }
            })
    }

    private func axisAnchor(_ key: String?, data: ActivityHistoryPresentation) -> UnitPoint {
        key == data.buckets.first?.id ? .topLeading : key == data.buckets.last?.id ? .topTrailing : .top
    }

    private func axisIDs(_ data: ActivityHistoryPresentation) -> [String] {
        guard !data.buckets.isEmpty else { return [] }
        let last = data.buckets.count - 1
        return Array(Set([0, last / 2, last])).sorted().map { data.buckets[$0].id }
    }
    private func axisLabel(_ key: String) -> String {
        self.range == .year ? String(key.dropFirst(2)).replacingOccurrences(of: "-", with: "/") : key.shortDateLabel
    }
}
