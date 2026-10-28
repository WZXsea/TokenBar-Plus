import AppKit
import Testing
import TokenBarCore
@testable import TokenBar

struct SpeedChartScaleTests {
    @Test("Parallel models retain independent rates and each model's latest sample")
    func latestSamplesRemainSeparateByModel() {
        let tokens = TokenBreakdown(input: 0, output: 100, cacheRead: 0, cacheWrite: 0, reasoning: 0)
        func request(_ id: String, model: String, end: Int64, duration: Int64) -> RequestSummary {
            RequestSummary(id: id, sessionId: "session", physicalSessionId: "session", isSubagent: false,
                agent: nil, model: model, provider: "fixture", startedAtMs: end - duration, endedAtMs: end,
                durationMs: duration, modelDurationMs: duration, timeToFirstTokenMs: nil,
                tokens: tokens, costUsd: 0, costSource: .unknown,
                promptPreview: nil, outputPreview: nil, sessionPath: nil)
        }
        let snapshot = ActivitySnapshot(schemaVersion: 11, generatedAtMs: 10_000, timezone: "UTC",
            today: ActivityTotals(tokens: tokens, costUsd: 0, requestCount: 3, sessionCount: 1),
            sessions: [SessionSummary(id: "session", workspaceLabel: nil, startedAtMs: 1_000, endedAtMs: 6_000,
                tokens: tokens, costUsd: 0, models: ["model-a", "model-b"], requests: [
                    request("a1", model: "model-a", end: 3_000, duration: 2_000),
                    request("b1", model: "model-b", end: 5_000, duration: 500),
                    request("a2", model: "model-a", end: 6_000, duration: 1_000),
                ])], days: [])
        let presentation = SpeedModelPresentation(snapshot: snapshot, platform: .codex)
        #expect(presentation.latestModelSamples.map(\.model) == ["model-a", "model-b"])
        #expect(presentation.latestModelSamples.map(\.tokensPerSecond) == [100, 200])
        #expect(presentation.points.count == 3)
    }

    @Test("Isolated and repeated spikes retain raw values while regular samples keep a readable range")
    func spikesUseADisclosedDisplayBoundary() {
        let rates: [Double] = [28, 29, 30, 31, 32, 30, 29, 20_000, 40_000, 80_000]
        let samples = self.points(rates, model: "ordinary")
        let scale = SpeedChartScale(points: samples)
        #expect(scale.maximum == 40)
        #expect(scale.overflowIndices == Set([7, 8, 9]))
        #expect(samples[9].tokensPerSecond == 80_000)
        let rect = NSRect(x: 0, y: 0, width: 100, height: 10)
        let compact = StatusSpeedChartGeometry.points(rates: rates, in: rect)
        #expect(compact[0].y > rect.midY)
        #expect(compact[9].y == rect.maxY)
        #expect(compact.allSatisfy { rect.minY <= $0.y && $0.y <= rect.maxY })
    }

    @Test("Sparse spikes use the display boundary while genuinely faster models retain their range")
    func sparseSpikesAndFasterModelsUseDistinctBaselines() {
        let sparse = SpeedChartScale(points: self.points([30, 31, 32, 10_000], model: "sparse"))
        #expect(sparse.maximum == 40)
        #expect(sparse.overflowIndices == [3])
        let three = SpeedChartScale(points: self.points([30, 31, 10_000], model: "sparse"))
        #expect(three.maximum == 40 && three.overflowIndices == [2])
        let two = SpeedChartScale(points: self.points([30, 10_000], model: "sparse"))
        #expect(two.maximum == 30 && two.overflowIndices == [1])
        let single = SpeedChartScale(points: self.points([10_000], model: "single"))
        #expect(single.maximum == 10_000 && single.overflowIndices.isEmpty)
        let newModel = SpeedChartScale(points: self.points([30, 31, 32], model: "ordinary")
            + self.points([10_000], model: "new-model"))
        #expect(newModel.maximum == 40 && newModel.overflowIndices == [3])
        let mixed = SpeedChartScale(points: self.points([28, 29, 30, 31, 32, 30], model: "ordinary")
            + self.points([99, 103], model: "faster"))
        #expect(mixed.maximum == 125)
        #expect(mixed.overflowIndices.isEmpty)
        let fast = SpeedChartScale(points: self.points([1_900, 2_000, 2_100, 2_200, 2_300], model: "fast"))
        #expect(fast.maximum == 2_500)
        #expect(fast.overflowIndices.isEmpty)
        let empty = SpeedChartScale(rates: [.infinity, .nan, 0, -1])
        #expect(empty.maximum == 1 && empty.overflowIndices.isEmpty)
        #expect(SpeedTrendChartGeometry.niceMaximum(103) == 125)
    }

    private func points(_ rates: [Double], model: String) -> [SpeedTrendPoint] {
        rates.enumerated().map {
            SpeedTrendPoint(id: "\(model)-\($0.offset)", endedAtMs: Int64($0.offset), tokensPerSecond: $0.element, model: model)
        }
    }
}
