/// Keeps model selection stable while fresh usage snapshots replace the values.
/// Rotation timing and animation belong to the status-item controller.
public struct StatusSpeedCarousel: Equatable, Sendable {
    public private(set) var samples: [SpeedTrendPoint] = []
    public private(set) var selectedModel: String?

    public init() {}

    public var currentSample: SpeedTrendPoint? {
        self.samples.first { $0.model == self.selectedModel }
    }

    public var canRotate: Bool { self.samples.count > 1 }

    public mutating func update(samples incoming: [SpeedTrendPoint]) {
        var byModel: [String: SpeedTrendPoint] = [:]
        for sample in incoming where !sample.model.isEmpty
            && sample.tokensPerSecond.isFinite && sample.tokensPerSecond > 0
            && sample.endedAtMs >= 0
        {
            if let previous = byModel[sample.model],
               previous.endedAtMs > sample.endedAtMs
                || (previous.endedAtMs == sample.endedAtMs && previous.id < sample.id)
            {
                continue
            }
            byModel[sample.model] = sample
        }

        let previousSamples = self.samples
        let previousIndex = previousSamples.firstIndex { $0.model == self.selectedModel } ?? 0
        let retainedModels = previousSamples.map(\.model).filter { byModel[$0] != nil }
        let retainedSet = Set(retainedModels)
        let addedModels = byModel.keys.filter { !retainedSet.contains($0) }.sorted()
        self.samples = (retainedModels + addedModels).compactMap { byModel[$0] }

        if let selectedModel = self.selectedModel, byModel[selectedModel] != nil {
            return
        }
        if previousSamples.isEmpty {
            self.selectedModel = self.samples.max {
                $0.endedAtMs == $1.endedAtMs ? $0.model > $1.model : $0.endedAtMs < $1.endedAtMs
            }?.model
        } else {
            self.selectedModel = self.samples.isEmpty
                ? nil : self.samples[min(previousIndex, self.samples.count - 1)].model
        }
    }

    @discardableResult
    public mutating func step(_ direction: Int) -> Bool {
        guard self.canRotate,
              let index = self.samples.firstIndex(where: { $0.model == self.selectedModel })
        else { return false }
        var next = (index + direction % self.samples.count) % self.samples.count
        if next < 0 { next += self.samples.count }
        let nextModel = self.samples[next].model
        guard nextModel != self.selectedModel else { return false }
        self.selectedModel = nextModel
        return true
    }
}
