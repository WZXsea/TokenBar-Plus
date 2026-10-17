import AppKit
import Testing
@testable import TokenBar

@MainActor
@Suite("Token menu row rate layout")
struct TokenMenuRowViewTests {
    @Test("compact session rows use one line while retaining full accessible information")
    func compactRowKeepsDetailsAccessible() throws {
        let row = TokenMenuRowView(width: 380, compact: true)
        self.configure(row, rate: "125.4 tok/s")
        row.layoutSubtreeIfNeeded()

        #expect(row.frame.height == 26)
        #expect(row.intrinsicContentSize.height == 26)
        let title = try self.field("会话标题", in: row)
        let time = try self.field("12:34", in: row)
        let badge = try self.field("快速", in: row)
        #expect(title.frame.midY == time.frame.midY)
        #expect(title.frame.midY == badge.frame.midY)
        #expect(title.frame.maxX < badge.frame.minX)
        #expect(badge.frame.maxX < time.frame.minX)
        for text in ["$0.12", "· 120K · 75% · TTFT 1.2s", "125.4 tok/s"] {
            let field = try self.field(text, in: row)
            #expect(field.isHidden)
            #expect(field.frame == .zero)
        }
        #expect(row.accessibilityLabel() == "会话标题, 快速, 生成速率 125.4 tok/s")
        #expect(row.accessibilityHelp() == "$0.12. 120K · 75% · TTFT 1.2s. 12:34")
    }

    @Test("compact rows truncate long titles without overlapping the time or badge", arguments: [96, 140, 380])
    func compactRowPreservesSingleLineAtNarrowWidths(width: Int) throws {
        let row = TokenMenuRowView(width: CGFloat(width), compact: true)
        let titleText = String(repeating: "很长的会话名称", count: 10)
        row.configure(
            title: titleText, cost: "$123.45", detail: "120M",
            trailing: "12:34", showsChevron: true, badge: "快速")
        row.layoutSubtreeIfNeeded()
        let title = try self.field(titleText, in: row)
        let badge = try self.field("快速", in: row)
        let time = try self.field("12:34", in: row)
        #expect(title.frame.width >= 0)
        #expect(title.frame.maxX <= badge.frame.minX)
        #expect(badge.frame.maxX <= time.frame.minX)
        #expect(time.frame.maxX <= row.bounds.width - 14)
        #expect(title.maximumNumberOfLines == 1)
        #expect(title.lineBreakMode == .byTruncatingTail)
        #expect(title.frame.midY == row.bounds.midY)
    }

    @Test("reconfiguring a compact row keeps supplementary fields hidden and preserves activation")
    func compactRowReuseAndActivation() throws {
        let row = TokenMenuRowView(width: 380, compact: true)
        self.configure(row, rate: nil)
        row.configure(
            title: "新会话", cost: "$0.25", detail: "250K",
            trailing: "", showsChevron: false, rate: "50 tok/s")
        row.layoutSubtreeIfNeeded()
        let visible = row.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        #expect(visible.map(\.stringValue) == ["新会话", ""])
        #expect(try self.field("新会话", in: row).frame.width == 350)
        #expect(row.accessibilityHelp() == "$0.25. 250K. ")
        var activationCount = 0
        row.onActivate = { activationCount += 1 }
        #expect(row.accessibilityPerformPress())
        #expect(activationCount == 1)
        #expect(TokenMenuRowView(width: 380).intrinsicContentSize.height == 42)
    }

    @Test("rows without a rate retain the original detail area")
    func legacyDetailLayout() throws {
        let row = TokenMenuRowView(width: 380)
        row.configure(
            title: "会话标题",
            cost: nil,
            detail: "120K · 75% · TTFT 1.2s",
            trailing: "12:34",
            showsChevron: true)
        row.layoutSubtreeIfNeeded()

        let detail = try self.field("120K · 75% · TTFT 1.2s", in: row)
        #expect(detail.frame == NSRect(x: 16, y: 4, width: 332, height: 15))
        #expect(row.subviews.compactMap { $0 as? NSTextField }.filter(\.isHidden).count == 3)
        #expect(row.accessibilityLabel() == "会话标题")
    }

    @Test("the rate receives its own field while preserving the first row")
    func rateIsSeparateFromDetailAndTitle() throws {
        let row = TokenMenuRowView(width: 380)
        self.configure(row, rate: nil)
        row.layoutSubtreeIfNeeded()
        let title = try self.field("会话标题", in: row)
        let trailing = try self.field("12:34", in: row)
        let badge = try self.field("快速", in: row)
        let originalTitleFrame = title.frame
        let originalTrailingFrame = trailing.frame
        let originalBadgeFrame = badge.frame

        self.configure(row, rate: "125.4 tok/s")
        row.layoutSubtreeIfNeeded()

        let rate = try self.field("125.4 tok/s", in: row)
        let detail = try self.field("· 120K · 75% · TTFT 1.2s", in: row)
        let cost = try self.field("$0.12", in: row)
        #expect(!rate.isHidden)
        #expect(rate.alignment == .right)
        #expect(rate.font?.pointSize == 11.5)
        #expect(rate.textColor == NSColor.labelColor)
        #expect(rate.frame.maxX == 348)
        #expect(detail.frame.maxX + 10 <= rate.frame.minX)
        #expect(cost.frame.maxX <= detail.frame.minX)
        #expect(title.frame == originalTitleFrame)
        #expect(trailing.frame == originalTrailingFrame)
        #expect(badge.frame == originalBadgeFrame)
        #expect(row.accessibilityLabel()?.contains("生成速率 125.4 tok/s") == true)
    }

    @Test("highlighting keeps the rate legible and restores its normal color")
    func rateFollowsMenuHighlight() throws {
        let row = TokenMenuRowView(width: 380)
        self.configure(row, rate: "125.4 tok/s")
        let rate = try self.field("125.4 tok/s", in: row)

        row.setMenuHighlighted(true)
        #expect(rate.textColor == NSColor.selectedMenuItemTextColor)
        row.setMenuHighlighted(false)
        #expect(rate.textColor == NSColor.labelColor)
    }

    @Test("long rate and detail fields remain separate at narrow widths", arguments: [96, 140, 380])
    func narrowLayoutKeepsFieldsSeparate(width: Int) throws {
        let row = TokenMenuRowView(width: CGFloat(width))
        let detailText = String(repeating: "非常长的使用明细 · TTFT 2.5s · ", count: 5)
        let rateText = "12345678901234567890.12345 tok/s"
        row.configure(
            title: "会话标题",
            cost: "$12345.67",
            detail: detailText,
            trailing: "12:34",
            showsChevron: true,
            badge: "快速",
            rate: rateText)
        row.layoutSubtreeIfNeeded()

        let rate = try self.field(rateText, in: row)
        let detail = try self.field("· \(detailText)", in: row)
        let cost = try self.field("$12345.67", in: row)
        #expect(rate.frame.width > 0)
        #expect(detail.frame.width >= 0)
        #expect(cost.frame.width >= 0)
        #expect(cost.frame.maxX <= detail.frame.minX)
        #expect(detail.frame.maxX <= rate.frame.minX)
        #expect(rate.frame.maxX <= row.bounds.width - 14)
        #expect(rate.lineBreakMode == .byTruncatingTail)
        #expect(detail.lineBreakMode == .byTruncatingTail)
        #expect(cost.lineBreakMode == .byTruncatingTail)
    }

    @Test("clearing a reused row's rate restores all legacy detail space", arguments: ["", " \n\t "])
    func emptyRateRestoresLayout(emptyRate: String) throws {
        let row = TokenMenuRowView(width: 380)
        self.configure(row, rate: nil)
        row.layoutSubtreeIfNeeded()
        let detail = try self.field("· 120K · 75% · TTFT 1.2s", in: row)
        let cost = try self.field("$0.12", in: row)
        let legacyDetailFrame = detail.frame
        let legacyCostFrame = cost.frame

        self.configure(row, rate: "125.4 tok/s")
        row.layoutSubtreeIfNeeded()
        let rate = try self.field("125.4 tok/s", in: row)
        #expect(detail.frame.width < legacyDetailFrame.width)

        self.configure(row, rate: emptyRate)
        row.layoutSubtreeIfNeeded()
        #expect(rate.isHidden)
        #expect(rate.frame == .zero)
        #expect(detail.frame == legacyDetailFrame)
        #expect(cost.frame == legacyCostFrame)
        #expect(cost.lineBreakMode == .byClipping)
        #expect(row.accessibilityLabel()?.contains("生成速率") == false)
    }

    private func configure(_ row: TokenMenuRowView, rate: String?) {
        row.configure(
            title: "会话标题",
            cost: "$0.12",
            detail: "120K · 75% · TTFT 1.2s",
            trailing: "12:34",
            showsChevron: true,
            badge: "快速",
            rate: rate)
    }

    private func field(_ text: String, in row: TokenMenuRowView) throws -> NSTextField {
        try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == text })
    }
}
