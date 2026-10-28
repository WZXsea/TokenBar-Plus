import Testing
@testable import TokenBarCore

@Suite("Status speed model carousel")
struct StatusSpeedCarouselTests {
    @Test("Bidirectional rotation keeps model order and selection across changing snapshots")
    func rotationAndSnapshotUpdates() {
        var carousel = StatusSpeedCarousel()
        carousel.update(samples: [self.sample("b", rate: 60, time: 2), self.sample("a", rate: 30, time: 1)])
        #expect(carousel.samples.map(\.model) == ["a", "b"])
        #expect(carousel.currentSample?.model == "b")
        #expect(carousel.canRotate)
        let forward = carousel.step(1)
        #expect(forward)
        #expect(carousel.currentSample?.model == "a")
        let backward = carousel.step(-1)
        #expect(backward)
        #expect(carousel.currentSample?.model == "b")

        carousel.update(samples: [self.sample("a", rate: 35, time: 4), self.sample("b", rate: 65, time: 3),
                                  self.sample("c", rate: 90, time: 5)])
        #expect(carousel.samples.map(\.model) == ["a", "b", "c"])
        #expect(carousel.currentSample?.model == "b")
        #expect(carousel.currentSample?.tokensPerSecond == 65)
        let stationary = carousel.step(0)
        #expect(!stationary)
        let wrapped = carousel.step(-2)
        #expect(wrapped)
        #expect(carousel.currentSample?.model == "c")

        carousel.update(samples: [self.sample("a", rate: 36, time: 6), self.sample("b", rate: 66, time: 7)])
        #expect(carousel.currentSample?.model == "b")
    }

    @Test("Empty, single-model and duplicate inputs retain only valid latest samples")
    func emptySingleAndDuplicateSamples() {
        var carousel = StatusSpeedCarousel()
        #expect(!carousel.canRotate && carousel.currentSample == nil)
        let emptyStep = carousel.step(1)
        #expect(!emptyStep)
        carousel.update(samples: [self.sample("a", rate: 30, time: 1), self.sample("a", rate: 40, time: 2),
                                  self.sample("b", rate: .infinity, time: 3), self.sample("c", rate: 0, time: 3)])
        #expect(carousel.samples.count == 1)
        #expect(carousel.currentSample?.tokensPerSecond == 40)
        let singleStep = carousel.step(-1)
        #expect(!carousel.canRotate && !singleStep)
        carousel.update(samples: [])
        #expect(carousel.samples.isEmpty && carousel.currentSample == nil)
        carousel.update(samples: [self.sample("c", rate: 80, time: 4)])
        #expect(carousel.currentSample?.model == "c")
    }

    private func sample(_ model: String, rate: Double, time: Int64) -> SpeedTrendPoint {
        SpeedTrendPoint(id: "\(model)-\(time)", endedAtMs: time, tokensPerSecond: rate, model: model)
    }
}
