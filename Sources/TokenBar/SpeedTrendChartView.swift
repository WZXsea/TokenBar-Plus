import SwiftUI
import TokenBarCore

/// The curve interpolates recorded values; each model has an independent path.
struct SpeedTrendChartView: View {
    static let preferredHeight: CGFloat = 68
    let points: [SpeedTrendPoint]
    let accentColor: Color
    @State private var hoveredIndex: Int?

    static func modelColor(model: String, accentColor: Color) -> Color {
        guard !model.isEmpty else { return accentColor }
        let hash = model.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        return Color(hue: Double(hash % 997) / 997, saturation: 0.72, brightness: 0.76)
    }

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(x: 31, y: 4, width: max(1, geometry.size.width - 35), height: 46)
            let scale = SpeedChartScale(points: self.points)
            let maximum = scale.maximum
            let locations = self.locations(in: rect, maximum: maximum)
            ZStack(alignment: .topLeading) {
                self.axes(in: rect, maximum: maximum)
                ForEach(self.models, id: \.self) { model in
                    let indices = self.points.indices.filter { self.points[$0].model == model }
                    let samples = indices.map { locations[$0] }
                    let color = Self.modelColor(model: model, accentColor: self.accentColor)
                    let curve = SpeedTrendChartGeometry.curve(points: samples)
                    if samples.count > 1, let first = samples.first, let last = samples.last {
                        Path { path in
                            path.addPath(curve)
                            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
                            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
                            path.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [color.opacity(0.15), color.opacity(0.015)],
                                             startPoint: .top, endPoint: .bottom))
                        curve.stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    }
                    if let index = self.hoveredIndex.flatMap({ indices.contains($0) ? $0 : nil }) ?? indices.last,
                       !scale.overflowIndices.contains(index) {
                        Circle().fill(color).frame(width: 4, height: 4).position(locations[index])
                    }
                    ForEach(indices.filter { scale.overflowIndices.contains($0) }, id: \.self) { index in
                        Image(systemName: "arrowtriangle.up.fill")
                            .font(.system(size: 6, weight: .bold)).foregroundStyle(color)
                            .position(locations[index])
                    }
                }
                if self.points.isEmpty {
                    Text("等待有效速率样本")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let index = self.hoveredIndex, self.points.indices.contains(index) {
                    let point = self.points[index]
                    Text("\(scale.overflowIndices.contains(index) ? "↑ " : "")\(point.model.isEmpty ? "" : point.model + " · ")\(Self.rateText(point.tokensPerSecond)) tok/s · \(Self.sampleTimeText(point))")
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .allowsHitTesting(false)
                } else if !scale.overflowIndices.isEmpty {
                    Text("↑ \(scale.overflowIndices.count) 个超界样本")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    self.hoveredIndex = locations.indices.min {
                        hypot(locations[$0].x - location.x, locations[$0].y - location.y)
                            < hypot(locations[$1].x - location.x, locations[$1].y - location.y)
                    }
                case .ended: self.hoveredIndex = nil
                }
            }
        }
        .frame(height: Self.preferredHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityText)
        .help("\(self.accessibilityText)悬停查看模型、实测速率与时间。↑ 表示超出常规显示范围，提示保留原始速率。")
    }

    private var models: [String] { Array(Set(self.points.map(\.model))).sorted() }

    private func locations(in rect: CGRect, maximum: Double) -> [CGPoint] {
        let times = Array(Set(self.points.map(\.endedAtMs))).sorted()
        let first = Double(times.first ?? 0)
        let span = Double(times.last ?? 0) - first
        return self.points.map { point in
            let fraction = span <= 0 ? 0.5 : (Double(point.endedAtMs) - first) / span
            return CGPoint(x: rect.minX + fraction * rect.width,
                           y: rect.maxY - max(0, min(1, point.tokensPerSecond / maximum)) * rect.height)
        }
    }

    private func axes(in rect: CGRect, maximum: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0 ..< 3) { index in
                let fraction = CGFloat(index) / 2
                let y = rect.maxY - fraction * rect.height
                Path { path in
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                .stroke(Color.secondary.opacity(index == 0 ? 0.3 : 0.16),
                        style: StrokeStyle(lineWidth: 0.5, dash: index == 0 ? [] : [2, 3]))
                Text(Self.axisText(maximum * Double(fraction)))
                    .font(.system(size: 8)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 27, alignment: .trailing).position(x: 13.5, y: y)
            }
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            }
            .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
            Text("tok/s")
                .font(.system(size: 7.5)).foregroundStyle(.secondary)
                .position(x: 13.5, y: rect.maxY + 10)
            HStack {
                Text(self.axisTimeText(self.points.map(\.endedAtMs).min()))
                Spacer()
                Text(self.axisTimeText(self.points.map(\.endedAtMs).max()))
            }
            .font(.system(size: 8)).foregroundStyle(.secondary)
            .frame(width: rect.width)
            .position(x: rect.midX, y: rect.maxY + 10)
        }
    }

    private var accessibilityText: String {
        guard let point = self.points.last else { return "生成速率趋势，等待有效速率样本" }
        return "生成速率趋势，\(self.models.count) 类模型，\(self.points.count) 个样本，横轴为样本结束时间，纵轴为 tok/s。"
            + "最新 \(Self.rateText(point.tokensPerSecond)) tok/s，样本时间 \(Self.sampleTimeText(point))。曲线以单调插值连接实测值。"
            + "\(SpeedChartScale(points: self.points).overflowIndices.count) 个样本超出常规显示范围，原始数据保留。"
    }

    private func axisTimeText(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let sameDay = self.points.map { Date(timeIntervalSince1970: Double($0.endedAtMs) / 1_000) }
            .allSatisfy { Calendar.current.isDate($0, inSameDayAs: date) }
        return sameDay ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private static func sampleTimeText(_ point: SpeedTrendPoint) -> String {
        Date(timeIntervalSince1970: Double(point.endedAtMs) / 1_000)
            .formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute().second()
                .locale(Locale(identifier: "zh_CN")))
    }

    private static func rateText(_ rate: Double) -> String { SpeedSummaryPresentation.rateValueText(rate) }
    private static func axisText(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value >= 10_000 { return value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1))) }
        return Self.rateText(value)
    }
}

enum SpeedTrendChartGeometry {
    static func niceMaximum(_ peak: Double) -> Double {
        SpeedChartScale.niceMaximum(peak)
    }

    /// Control points stay inside each pair's bounding rectangle, retaining every measured extremum.
    static func controls(points: [CGPoint]) -> [(CGPoint, CGPoint)] {
        guard points.count > 1 else { return [] }
        let slopes = zip(points, points.dropFirst()).map { a, b in b.x > a.x ? (b.y - a.y) / (b.x - a.x) : 0 }
        var tangents = Array(repeating: CGFloat.zero, count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[slopes.count - 1]
        if points.count > 2 {
            for i in 1 ..< points.count - 1 {
                let a = slopes[i - 1], b = slopes[i]
                tangents[i] = a * b > 0 ? (a > 0 ? 1 : -1) * min(abs(a), abs(b)) : 0
            }
        }
        return (0 ..< points.count - 1).map { i in
            let a = points[i], b = points[i + 1], third = (b.x - a.x) / 3
            let low = min(a.y, b.y), high = max(a.y, b.y)
            return (CGPoint(x: a.x + third, y: max(low, min(high, a.y + tangents[i] * third))),
                    CGPoint(x: b.x - third, y: max(low, min(high, b.y - tangents[i + 1] * third))))
        }
    }

    static func curve(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for (i, control) in controls(points: points).enumerated() {
                path.addCurve(to: points[i + 1], control1: control.0, control2: control.1)
            }
        }
    }

    /// Kept for the compact menu-bar plot and its zero-baseline geometry contract.
    static func normalizedPoints(rates: [Double]) -> [CGPoint] {
        guard !rates.isEmpty, rates.allSatisfy({ $0.isFinite && $0 > 0 }) else { return [] }
        let peak = SpeedChartScale(rates: rates).maximum
        return rates.enumerated().map { index, rate in
            CGPoint(x: rates.count == 1 ? 0.5 : Double(index) / Double(rates.count - 1),
                    y: max(0, min(1, 1 - rate / peak)))
        }
    }
}
