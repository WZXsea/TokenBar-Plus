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

    @Test("Optional status rows center the remaining row and preserve the icon and mini chart")
    func optionalRowsAndChartGeometry() throws {
        let bottomOnly = StatusLabelRenderer.geometry(platform: .codex, top: nil, bottom: "80%", showsTrend: true)
        #expect(bottomOnly.topRect == nil)
        #expect(try #require(bottomOnly.bottomRect).midY == 10)
        let topOnly = StatusLabelRenderer.geometry(platform: .codex, top: "42t/s", bottom: nil, showsTrend: false)
        #expect(try #require(topOnly.topRect).midY == 10)
        #expect(topOnly.bottomRect == nil)
        #expect(topOnly.chartRect == nil)
        let iconAndChart = StatusLabelRenderer.geometry(platform: .codex, top: nil, bottom: nil, showsTrend: true)
        #expect(iconAndChart.iconRect != nil)
        #expect(iconAndChart.topRect == nil && iconAndChart.bottomRect == nil)
        #expect(iconAndChart.chartRect?.size == NSSize(width: 34, height: 14))
        #expect(StatusLabelRenderer.image(platform: .codex, top: nil, bottom: nil, trendRates: []).isTemplate)
        let longValue = String(repeating: "9", count: 100)
        let bounded = StatusLabelRenderer.geometry(platform: .codex, top: longValue, bottom: longValue, showsTrend: true)
        #expect(bounded.size.width <= 115)
    }

    @Test("Mini chart geometry uses actual positive finite samples with a shared zero baseline")
    func miniChartSamples() throws {
        let rect = NSRect(x: 2, y: 3, width: 34, height: 14)
        #expect(StatusSpeedChartGeometry.points(rates: [], in: rect).isEmpty)
        #expect(StatusSpeedChartGeometry.points(rates: [0, -1, .nan, .infinity], in: rect).isEmpty)
        let single = try #require(StatusSpeedChartGeometry.points(rates: [10], in: rect).first)
        #expect(single.x == rect.midX && single.y == rect.maxY)
        let points = StatusSpeedChartGeometry.points(rates: [0, 10, .nan, 20], in: rect)
        #expect(points.count == 2)
        #expect(points[0] == NSPoint(x: rect.minX, y: rect.midY))
        #expect(points[1] == NSPoint(x: rect.maxX, y: rect.maxY))
        let extreme = StatusSpeedChartGeometry.points(rates: [Double.greatestFiniteMagnitude / 2, .greatestFiniteMagnitude], in: rect)
        #expect(extreme.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(extreme.first?.y == rect.midY)
    }

    @Test("Dynamic mini-chart labels preserve platform click regions and celebration centers")
    func dynamicRegions() throws {
        let contents = [
            StatusBarPlatformContent(scope: .codex, top: "42t/s", bottom: nil, unreadCount: 12, trendRates: [30, 42]),
            StatusBarPlatformContent(scope: .grok, top: nil, bottom: "~$0.42", trendRates: []),
            StatusBarPlatformContent(scope: .antigravity, top: nil, bottom: nil),
        ]
        let layout = StatusLabelRenderer.layout(contents: contents)
        #expect(layout.image.isTemplate)
        #expect(layout.image.size.height == 20)
        #expect(layout.regions.map(\.scope) == [.codex, .grok, .antigravity])
        for region in layout.regions {
            #expect(layout.scope(at: region.centerX) == region.scope)
            #expect(layout.centerX(for: region.scope.platform) == region.centerX)
            #expect(layout.scope(at: region.startX) == region.scope)
        }
        let plain = StatusLabelRenderer.image(platform: .codex, top: "42t/s", bottom: nil, trendRates: [30, 42])
        let badged = StatusLabelRenderer.image(platform: .codex, top: "42t/s", bottom: nil, unreadCount: 100, trendRates: [30, 42])
        #expect(plain.size == badged.size)
    }

    @Test("Platform status labels use icons beside the stacked values")
    func platformIcons() {
        let plain = StatusLabelRenderer.image(today: "12K", weekly: "80%")
        let codex = StatusLabelRenderer.image(
            platform: .codex,
            today: "12K",
            weekly: "80%")
        let claude = StatusLabelRenderer.image(
            platform: .claude,
            today: "12K",
            weekly: "80%")
        let grok = StatusLabelRenderer.image(
            platform: .grok,
            today: "12K",
            weekly: "80%")
        let antigravity = StatusLabelRenderer.image(
            platform: .antigravity,
            today: "12K",
            weekly: "80%")

        #expect(codex.isTemplate)
        #expect(claude.isTemplate)
        #expect(grok.isTemplate)
        #expect(antigravity.isTemplate)
        #expect(codex.size.width > plain.size.width)
        #expect(claude.size.width > plain.size.width)
        #expect(grok.size.width > plain.size.width)
        #expect(antigravity.size.width > plain.size.width)
        #expect(codex.size.height == plain.size.height)
        #expect(claude.size.height == plain.size.height)
        #expect(grok.size.height == plain.size.height)
        #expect(antigravity.size.height == plain.size.height)
    }

    @Test("Combined status label routes all visual regions to matching tabs")
    func combinedHitRegions() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%",
            claudeToday: "8K",
            claudeWeekly: "60%",
            grokToday: "4K",
            grokWeekly: "40%",
            antigravityToday: "2K",
            antigravityWeekly: "—")
        let claudeStart = layout.regions[1].startX
        let grokStart = layout.regions[2].startX
        let antigravityStart = layout.regions[3].startX

        #expect(layout.image.isTemplate)
        #expect(layout.regions.map(\.scope) == [.codex, .claude, .grok, .antigravity])
        #expect(layout.scope(at: 0) == .codex)
        #expect(layout.scope(at: claudeStart - 0.1) == .codex)
        #expect(layout.scope(at: claudeStart) == .claude)
        #expect(layout.scope(at: grokStart - 0.1) == .claude)
        #expect(layout.scope(at: grokStart) == .grok)
        #expect(layout.scope(at: antigravityStart - 0.1) == .grok)
        #expect(layout.scope(at: antigravityStart) == .antigravity)
        #expect(layout.scope(at: layout.image.size.width) == .antigravity)
    }

    @Test("Codex-only status label has one hit region")
    func codexOnlyHitRegion() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%")

        #expect(layout.regions.map(\.scope) == [.codex])
        #expect(layout.scope(at: layout.image.size.width) == .codex)
    }

    @Test("Menu opening uses pointer position even when AppKit reports mouseMoved")
    func menuOpeningHitRegions() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%",
            claudeToday: "8K",
            claudeWeekly: "60%")
        let padding: CGFloat = 8
        let bounds = NSRect(x: 0, y: 0, width: layout.image.size.width + padding * 2, height: 22)
        for region in layout.regions {
            let point = NSPoint(x: padding + region.centerX, y: bounds.midY)
            for eventType: NSEvent.EventType? in [.leftMouseDown, .leftMouseUp, .mouseMoved, .appKitDefined, nil] {
                #expect(layout.scope(at: point, in: bounds, eventType: eventType) == region.scope)
            }
            #expect(layout.scope(at: point, in: bounds, eventType: .keyDown) == nil)
            #expect(layout.scope(at: point, in: bounds, eventType: .keyUp) == nil)
        }
        #expect(layout.scope(at: NSPoint(x: bounds.midX, y: -1), in: bounds, eventType: .mouseMoved) == nil)
    }

    @Test("Grok remains clickable when Claude is hidden")
    func codexAndGrokHitRegions() {
        let layout = StatusLabelRenderer.layout(
            codexToday: "12K",
            codexWeekly: "80%",
            grokToday: "4K",
            grokWeekly: "40%")

        #expect(layout.regions.map(\.scope) == [.codex, .grok])
        #expect(layout.scope(at: layout.regions[1].startX) == .grok)
    }
}
