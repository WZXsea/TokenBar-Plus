import AppKit
import SwiftUI
import Testing
import TokenBarCore
@testable import TokenBar

@MainActor
struct StatusSpeedCarouselRenderingTests {
    private let candidates = ["9.5t/s", "104t/s", "1.25Kt/s"]

    @Test("Carousel candidates reserve a stable numeric column and preserve provider hit regions")
    func reservedColumnKeepsLayoutStable() throws {
        let geometries = self.candidates.map { text in
            StatusLabelRenderer.geometry(platform: .codex, top: text, bottom: "433M", showsTrend: true,
                                         reservedSpeedTexts: self.candidates)
        }
        for geometry in geometries {
            #expect(geometry.size == geometries[0].size)
            #expect(geometry.topRect == geometries[0].topRect)
            #expect(geometry.bottomRect == geometries[0].bottomRect)
        }
        let layouts = self.candidates.map { text in
            StatusLabelRenderer.layout(contents: [
                StatusBarPlatformContent(scope: .codex, top: text, bottom: "433M", unreadCount: 1,
                    trendRates: [28, 32], speedTone: .active, topIsSpeed: true,
                    reservedSpeedTexts: self.candidates),
                StatusBarPlatformContent(scope: .claude, top: "65%", bottom: "24M"),
            ])
        }
        for layout in layouts {
            #expect(layout.image.size == layouts[0].image.size)
            #expect(layout.regions.map(\.startX) == layouts[0].regions.map(\.startX))
            #expect(layout.regions.map(\.centerX) == layouts[0].regions.map(\.centerX))
        }
        for model in ["gpt-6.1-sol", "gpt-6.1-terra"] {
            let chartColor = NSColor(SpeedTrendChartView.modelColor(model: model, accentColor: .purple))
            let statusColor = StatusLabelRenderer.modelSpeedColor(model)
            #expect(chartColor == statusColor)
            let idle = StatusLabelRenderer.image(top: "104t/s", bottom: nil, topIsSpeed: true,
                                                 topSpeedModel: model, reservedSpeedTexts: self.candidates)
            #expect(!idle.isTemplate)
            #expect(try self.hasColor(idle, color: chartColor))
        }
    }

    @Test("Horizontal transitions match their endpoints and only change the requested speed row")
    func transitionClipsToItsSpeedRow() throws {
        for animatedTop in [true, false] {
            let previous = self.layout(top: animatedTop ? "9.5t/s" : "50.0t/s",
                                       bottom: animatedTop ? "50.0t/s" : "9.5t/s")
            let current = self.layout(top: animatedTop ? "104t/s" : "50.0t/s",
                                      bottom: animatedTop ? "50.0t/s" : "104t/s")
            for direction in [-1, 1] {
                func frame(_ progress: Double) -> StatusLabelLayout {
                    self.layout(top: animatedTop ? "104t/s" : "50.0t/s",
                                bottom: animatedTop ? "50.0t/s" : "104t/s",
                                transition: StatusSpeedTransition(
                                    previousTop: animatedTop ? "9.5t/s" : nil,
                                    previousBottom: animatedTop ? nil : "9.5t/s",
                                    progress: progress, direction: direction))
                }
                #expect(try self.pixels(frame(0).image) == self.pixels(previous.image))
                #expect(try self.pixels(frame(1).image) == self.pixels(current.image))
                let middle = frame(0.5)
                #expect(try self.pixels(middle.image) != self.pixels(current.image))
                let geometry = StatusLabelRenderer.geometry(platform: .codex,
                    top: animatedTop ? "104t/s" : "50.0t/s",
                    bottom: animatedTop ? "50.0t/s" : "104t/s", showsTrend: true,
                    reservedSpeedTexts: self.candidates)
                let fixedRow = try #require(animatedTop ? geometry.bottomRect : geometry.topRect)
                let chart = try #require(geometry.chartRect)
                for region in [fixedRow, NSRect(x: 0, y: 0, width: chart.maxX, height: 20)] {
                    #expect(try self.pixels(middle.image, region: region)
                            == self.pixels(current.image, region: region))
                }

                let independentlyColored = self.layout(
                    top: animatedTop ? "104t/s" : "50.0t/s",
                    bottom: animatedTop ? "50.0t/s" : "104t/s", speedTone: .idle,
                    transition: StatusSpeedTransition(
                        previousTop: animatedTop ? "9.5t/s" : nil,
                        previousBottom: animatedTop ? nil : "9.5t/s",
                        progress: 0.5, direction: direction, previousSpeedTone: .slow),
                    topSpeedTone: animatedTop ? .idle : .active,
                    bottomSpeedTone: animatedTop ? .active : .idle)
                let independentlyStatic = self.layout(
                    top: animatedTop ? "104t/s" : "50.0t/s",
                    bottom: animatedTop ? "50.0t/s" : "104t/s", speedTone: .idle,
                    topSpeedTone: animatedTop ? .idle : .active,
                    bottomSpeedTone: animatedTop ? .active : .idle)
                #expect(!independentlyColored.image.isTemplate)
                for region in [fixedRow, NSRect(x: 0, y: 0, width: chart.maxX, height: 20)] {
                    #expect(try self.pixels(independentlyColored.image, region: region)
                            == self.pixels(independentlyStatic.image, region: region))
                }
            }
        }
        let idle = StatusLabelRenderer.image(top: "104t/s", bottom: nil, topIsSpeed: true,
                                             topSpeedTone: .idle, reservedSpeedTexts: self.candidates)
        for progress in [0.0, 0.5, 1.0] {
            let transition = StatusLabelRenderer.image(top: "104t/s", bottom: nil, topIsSpeed: true,
                topSpeedTone: .idle,
                speedTransition: StatusSpeedTransition(previousTop: "9.5t/s", progress: progress,
                                                       previousSpeedTone: .active),
                reservedSpeedTexts: self.candidates)
            #expect(transition.isTemplate == (progress == 1))
            if progress == 1 {
                #expect(try self.pixels(transition) == self.pixels(idle))
            }
        }
        let previousModel = "gpt-6.1-sol"
        let nextModel = "gpt-6.1-terra"
        let previousModelImage = StatusLabelRenderer.image(top: "9.5t/s", bottom: nil, topIsSpeed: true,
            topSpeedModel: previousModel, reservedSpeedTexts: self.candidates)
        let nextModelImage = StatusLabelRenderer.image(top: "104t/s", bottom: nil, topIsSpeed: true,
            topSpeedModel: nextModel, reservedSpeedTexts: self.candidates)
        for progress in [0.0, 0.5, 1.0] {
            let frame = StatusLabelRenderer.image(top: "104t/s", bottom: nil, topIsSpeed: true,
                topSpeedModel: nextModel,
                speedTransition: StatusSpeedTransition(previousTop: "9.5t/s", progress: progress,
                    previousSpeedTone: .slow, previousModel: previousModel),
                reservedSpeedTexts: self.candidates)
            #expect(!frame.isTemplate)
            if progress == 0 {
                #expect(try self.pixels(frame) == self.pixels(previousModelImage))
            } else if progress == 1 {
                #expect(try self.pixels(frame) == self.pixels(nextModelImage))
            } else {
                #expect(try self.hasColor(frame, color: StatusLabelRenderer.modelSpeedColor(previousModel)))
                #expect(try self.hasColor(frame, color: StatusLabelRenderer.modelSpeedColor(nextModel)))
            }
        }
    }

    private func layout(top: String, bottom: String, speedTone: StatusSpeedTone = .active,
                        transition: StatusSpeedTransition? = nil,
                        topSpeedTone: StatusSpeedTone? = nil, bottomSpeedTone: StatusSpeedTone? = nil) -> StatusLabelLayout {
        StatusLabelRenderer.layout(contents: [StatusBarPlatformContent(
            scope: .codex, top: top, bottom: bottom, unreadCount: 2, trendRates: [28, 32],
            speedTone: speedTone, topIsSpeed: true, bottomIsSpeed: true,
            topSpeedTone: topSpeedTone, bottomSpeedTone: bottomSpeedTone,
            speedTransition: transition, reservedSpeedTexts: self.candidates)])
    }

    private func pixels(_ image: NSImage, region: NSRect? = nil) throws -> Data {
        let region = region ?? NSRect(origin: .zero, size: image.size)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(region.width * 2), pixelsHigh: Int(region.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        image.draw(in: NSRect(origin: .zero, size: region.size), from: region, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(bitmap.bitmapData)
        return Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func hasColor(_ image: NSImage, color expected: NSColor) throws -> Bool {
        let expected = try #require(expected.usingColorSpace(.deviceRGB))
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.8 else { continue }
                if abs(color.redComponent - expected.redComponent) < 0.05,
                   abs(color.greenComponent - expected.greenComponent) < 0.05,
                   abs(color.blueComponent - expected.blueComponent) < 0.05 {
                    return true
                }
            }
        }
        return false
    }
}
