import AppKit
import Testing
import TokenBarCore
@testable import TokenBar

@MainActor
struct StatusLabelRendererTests {
    @Test("Live speed colors use a strict 20 tok/s threshold and idle stays neutral")
    func liveSpeedTone() {
        #expect(StatusSpeedTone(isActive: true, tokensPerSecond: 19.9) == .slow)
        #expect(StatusSpeedTone(isActive: true, tokensPerSecond: 20) == .active)
        #expect(StatusSpeedTone(isActive: true, tokensPerSecond: 58.3) == .active)
        #expect(StatusSpeedTone(isActive: false, tokensPerSecond: 12) == .idle)
        let invalidRates: [Double?] = [nil, 0, -1, .nan, .infinity]
        for invalid in invalidRates {
            #expect(StatusSpeedTone(isActive: true, tokensPerSecond: invalid) == .idle)
        }
    }

    @Test("Rendered speed values and charts retain green or red colors while other metrics stay neutral")
    func renderedSpeedColors() throws {
        for (tone, isRed) in [(StatusSpeedTone.active, false), (.slow, true)] {
            let text = StatusLabelRenderer.image(top: "18t/s", bottom: nil,
                                                speedTone: tone, topIsSpeed: true)
            let chart = StatusLabelRenderer.image(top: nil, bottom: nil, trendRates: [15, 18], speedTone: tone)
            #expect(!text.isTemplate && !chart.isTemplate)
            #expect(try self.hasSpeedColor(text, red: isRed))
            #expect(try self.hasSpeedColor(chart, red: isRed))
            let ordinary = StatusLabelRenderer.image(top: "58%", bottom: nil, speedTone: tone)
            #expect(try !self.hasSpeedColor(ordinary, red: isRed))
        }
        #expect(StatusLabelRenderer.image(top: "18t/s", bottom: nil, speedTone: .idle,
                                         topIsSpeed: true).isTemplate)
    }

    @Test("Mixed active and idle platform groups retain colors and correct click regions")
    func mixedActivityColorsAndRegions() throws {
        let layout = StatusLabelRenderer.layout(contents: [
            StatusBarPlatformContent(scope: .codex, top: "58t/s", bottom: nil,
                                     speedTone: .active, topIsSpeed: true),
            StatusBarPlatformContent(scope: .claude, top: "12t/s", bottom: nil,
                                     speedTone: .slow, topIsSpeed: true),
            StatusBarPlatformContent(scope: .grok, top: "42t/s", bottom: nil),
        ])
        #expect(!layout.image.isTemplate)
        let raster = try #require(layout.image.representations.first as? NSBitmapImageRep)
        #expect(raster.pixelsHigh >= Int(layout.image.size.height * 2))
        #expect(try self.hasSpeedColor(layout.image, red: false))
        #expect(try self.hasSpeedColor(layout.image, red: true))
        for region in layout.regions {
            #expect(layout.scope(at: region.centerX) == region.scope)
        }
    }

    private func hasSpeedColor(_ image: NSImage, red: Bool) throws -> Bool {
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.4 else { continue }
                if red, color.redComponent > color.greenComponent + 0.15 { return true }
                if !red, color.greenComponent > color.redComponent + 0.15 { return true }
            }
        }
        return false
    }

    @Test("Unread badge stays legible in light and dark menu bars with colored speeds")
    func unreadBadgeAppearance() throws {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            let appearance = try #require(NSAppearance(named: name))
            for tone in [StatusSpeedTone.active, .slow] {
                var layout: StatusLabelLayout!
                appearance.performAsCurrentDrawingAppearance {
                    layout = StatusLabelRenderer.layout(contents: [
                        StatusBarPlatformContent(scope: .codex, top: "54.8t/s", bottom: "433M",
                                                 unreadCount: 1, speedTone: tone, topIsSpeed: true),
                    ])
                }
                let raster = try #require(layout.image.representations.first as? NSBitmapImageRep)
                let geometry = StatusLabelRenderer.geometry(platform: .codex, top: "54.8t/s",
                                                           bottom: "433M", showsTrend: false)
                let icon = try #require(geometry.iconRect)
                // The badge extends past the icon; this column contains only its pill.
                let scale = CGFloat(raster.pixelsWide) / layout.image.size.width
                let x = Int((icon.maxX + 0.5) * scale)
                let colors = (0..<raster.pixelsHigh).compactMap { y -> NSColor? in
                    guard let color = raster.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.8 else { return nil }
                    return color
                }
                #expect(!colors.isEmpty)
                #expect(colors.allSatisfy { color in
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    return dark ? brightness > 0.7 : brightness < 0.3
                })
            }
        }
    }
}
