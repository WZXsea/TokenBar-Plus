import AppKit
import Testing
import TokenBarCore
@testable import TokenBar

@MainActor
struct StatusSpeedCarouselDriverTests {
    @Test("Automatic rotation uses cached samples, ends reduced-motion frames and stays stopped")
    func automaticRotationAndShutdown() async throws {
        var selections = 0
        var lastFrame: [TokenPlatform: StatusSpeedTransition]?
        let driver = StatusSpeedCarouselDriver(onSelectionChange: { selections += 1 },
            onAnimationFrame: { lastFrame = $0 }, platformForScroll: { _ in nil }, reduceMotion: { true })
        defer { driver.stop() }
        driver.updateSamples([
            SpeedTrendPoint(id: "a", endedAtMs: 1_000, tokensPerSecond: 30, model: "a"),
            SpeedTrendPoint(id: "b", endedAtMs: 2_000, tokensPerSecond: 60, model: "b"),
        ], for: .codex)
        let contents = [StatusBarPlatformContent(scope: .codex, top: "60t/s", bottom: "433M")]
        driver.synchronize(contents: contents, latestTop: true, latestBottom: false)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while selections == 0 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selections == 1)
        #expect(driver.currentSample(for: .codex)?.model == "a")
        #expect(lastFrame?.isEmpty == true && driver.transitions.isEmpty)
        driver.stop()
        driver.synchronize(contents: contents, latestTop: true, latestBottom: false)
        driver.rotate(direction: 1)
        #expect(selections == 1)
    }
}
