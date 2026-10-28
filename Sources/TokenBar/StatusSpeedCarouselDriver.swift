import AppKit
import TokenBarCore

/// Rotates recorded model samples without requesting fresh usage data.
@MainActor
final class StatusSpeedCarouselDriver: NSObject {
    private var carousels: [TokenPlatform: StatusSpeedCarousel] = [:]
    private var contents: [StatusBarPlatformContent] = []
    private var latestTop = false
    private var latestBottom = false
    private var timerTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private weak var button: NSStatusBarButton?
    private var trackingArea: NSTrackingArea?
    private var scrollMonitor: Any?
    private var hovered = false
    private var isStopped = false
    private var lastScrollTimestamp: TimeInterval = -.infinity
    private let onSelectionChange: () -> Void
    private let onAnimationFrame: ([TokenPlatform: StatusSpeedTransition]) -> Void
    private let platformForScroll: (NSEvent) -> TokenPlatform?
    private let reduceMotion: () -> Bool
    private(set) var transitions: [TokenPlatform: StatusSpeedTransition] = [:]
    var menuIsOpen = false

    init(onSelectionChange: @escaping () -> Void,
         onAnimationFrame: @escaping ([TokenPlatform: StatusSpeedTransition]) -> Void,
         platformForScroll: @escaping (NSEvent) -> TokenPlatform?,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.onSelectionChange = onSelectionChange
        self.onAnimationFrame = onAnimationFrame
        self.platformForScroll = platformForScroll
        self.reduceMotion = reduceMotion
        super.init()
    }

    func updateSamples(_ samples: [SpeedTrendPoint], for platform: TokenPlatform) {
        var carousel = self.carousels[platform] ?? StatusSpeedCarousel()
        carousel.update(samples: samples)
        self.carousels[platform] = carousel
    }

    func currentSample(for platform: TokenPlatform) -> SpeedTrendPoint? {
        self.carousels[platform]?.currentSample
    }

    func samples(for platform: TokenPlatform) -> [SpeedTrendPoint] {
        self.carousels[platform]?.samples ?? []
    }

    func synchronize(contents: [StatusBarPlatformContent], latestTop: Bool, latestBottom: Bool) {
        guard !self.isStopped else { return }
        self.contents = contents
        self.latestTop = latestTop
        self.latestBottom = latestBottom
        let visible = Set(contents.map { $0.scope.platform })
        self.carousels = self.carousels.filter { visible.contains($0.key) }
        let eligible = (latestTop || latestBottom) && self.carousels.values.contains { $0.canRotate }
        if !eligible {
            self.timerTask?.cancel()
            self.timerTask = nil
            self.finishAnimation()
        } else if self.timerTask == nil {
            self.timerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    if !self.isPointerOverButton && !self.menuIsOpen {
                        self.rotate(direction: 1)
                        await self.animationTask?.value
                    }
                }
            }
        }
    }

    func attach(to button: NSStatusBarButton) {
        self.isStopped = false
        self.button = button
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        button.addTrackingArea(area)
        self.trackingArea = area
        self.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, !self.menuIsOpen, event.momentumPhase.isEmpty,
                      let platform = self.platformForScroll(event),
                      self.carousels[platform]?.canRotate == true
                else { return false }
                let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                    ? event.scrollingDeltaX : event.scrollingDeltaY
                if abs(delta) >= (event.hasPreciseScrollingDeltas ? 2 : 0.1),
                   self.animationTask == nil,
                   event.timestamp - self.lastScrollTimestamp >= 1.6 {
                    self.lastScrollTimestamp = event.timestamp
                    self.rotate(platform: platform, direction: delta > 0 ? 1 : -1)
                }
                return true
            }
            return handled ? nil : event
        }
    }

    @objc private func mouseEntered(with event: NSEvent) {
        self.hovered = true
        self.finishAnimation()
    }

    @objc private func mouseExited(with event: NSEvent) {
        self.hovered = false
    }

    private var isPointerOverButton: Bool {
        guard let button = self.button, let window = button.window else { return self.hovered }
        // Menu tracking may consume an exit event; sample the current pointer
        // when the next rotation is due so closing a menu cannot leave it paused.
        let point = button.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return button.bounds.contains(point)
    }

    func rotate(platform: TokenPlatform? = nil, direction: Int) {
        guard !self.isStopped, self.latestTop || self.latestBottom else { return }
        self.finishAnimation()
        for content in self.contents where platform == nil || content.scope.platform == platform {
            let key = content.scope.platform
            guard var carousel = self.carousels[key], carousel.step(direction) else { continue }
            self.carousels[key] = carousel
            self.transitions[key] = StatusSpeedTransition(
                previousTop: self.latestTop ? content.top : nil,
                previousBottom: self.latestBottom ? content.bottom : nil,
                progress: 0, direction: direction,
                previousSpeedTone: self.latestTop ? content.topSpeedTone ?? content.speedTone
                    : content.bottomSpeedTone ?? content.speedTone,
                previousModel: self.latestTop ? content.topSpeedModel : content.bottomSpeedModel)
        }
        guard !self.transitions.isEmpty else { return }
        self.onSelectionChange()
        if self.reduceMotion() {
            self.finishAnimation()
            return
        }
        self.animationTask = Task { @MainActor [weak self] in
            for frame in 1 ... 50 {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard let self else { return }
                let t = Double(frame) / 50
                let progress = t * t * (3 - 2 * t)
                self.transitions = self.transitions.mapValues {
                    StatusSpeedTransition(previousTop: $0.previousTop, previousBottom: $0.previousBottom,
                        progress: progress, direction: $0.direction, previousSpeedTone: $0.previousSpeedTone,
                        previousModel: $0.previousModel)
                }
                self.onAnimationFrame(self.transitions)
            }
            self?.finishAnimation()
        }
    }

    private func finishAnimation() {
        self.animationTask?.cancel()
        self.animationTask = nil
        guard !self.transitions.isEmpty else { return }
        self.transitions = [:]
        self.onAnimationFrame([:])
    }

    func stop() {
        self.isStopped = true
        self.timerTask?.cancel()
        self.timerTask = nil
        self.finishAnimation()
        if let monitor = self.scrollMonitor { NSEvent.removeMonitor(monitor) }
        self.scrollMonitor = nil
        if let area = self.trackingArea { self.button?.removeTrackingArea(area) }
        self.trackingArea = nil
        self.button = nil
    }
}
