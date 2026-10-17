import AppKit

@MainActor
final class RequestDetailMenuView: NSView {
    static let preferredWidth: CGFloat = 500
    static let preferredHeight: CGFloat = 360

    private let fixedSize: NSSize
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let retryButton = NSButton(title: "重新读取", target: nil, action: nil)
    private let attachmentsButton = NSButton(title: "展开附件信息", target: nil, action: nil)
    var onRetry: (() -> Void)? {
        didSet { self.updateControls() }
    }
    private var status: String?
    private var prompt: String?
    private var output: String?
    private var phase: Phase = .loaded
    private var attachmentsExpanded = false

    private enum Phase { case loading, loaded, failed }

    init(
        width: CGFloat = RequestDetailMenuView.preferredWidth,
        height: CGFloat = RequestDetailMenuView.preferredHeight)
    {
        self.fixedSize = NSSize(width: width, height: height)
        super.init(frame: NSRect(origin: .zero, size: self.fixedSize))

        self.autoresizingMask = [.width]
        self.scrollView.frame = self.bounds
        self.scrollView.autoresizingMask = [.width, .height]
        self.scrollView.borderType = .noBorder
        self.scrollView.drawsBackground = false
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.hasVerticalScroller = true
        self.scrollView.autohidesScrollers = true
        self.scrollView.scrollerStyle = .overlay

        self.textView.frame = self.bounds
        self.textView.autoresizingMask = [.width]
        self.textView.drawsBackground = false
        self.textView.isEditable = false
        self.textView.isSelectable = true
        self.textView.isRichText = true
        self.textView.importsGraphics = false
        self.textView.usesFindPanel = false
        self.textView.isHorizontallyResizable = false
        self.textView.isVerticallyResizable = true
        self.textView.minSize = NSSize(width: 0, height: self.fixedSize.height)
        self.textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        self.textView.textContainerInset = NSSize(width: 16, height: 14)
        self.textView.textContainer?.widthTracksTextView = true
        self.textView.textContainer?.containerSize = NSSize(
            width: self.fixedSize.width,
            height: .greatestFiniteMagnitude)

        self.scrollView.documentView = self.textView
        self.addSubview(self.scrollView)
        for button in [self.retryButton, self.attachmentsButton] {
            button.bezelStyle = .inline
            button.font = NSFont.systemFont(ofSize: 11)
            button.target = self
            button.isHidden = true
            self.addSubview(button)
        }
        self.retryButton.action = #selector(self.retry)
        self.attachmentsButton.action = #selector(self.toggleAttachments)
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.group)
        self.setAccessibilityLabel("请求详情")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { true }

    override var intrinsicContentSize: NSSize {
        self.fixedSize
    }

    func showLoading(promptPreview: String?, outputPreview: String?) {
        self.phase = .loading
        self.updateContent(status: "正在读取请求详情…", prompt: promptPreview, output: outputPreview)
    }

    func show(prompt: String?, output: String?) {
        self.phase = .loaded
        self.updateContent(status: nil, prompt: prompt, output: output)
    }

    func showError(_ message: String, promptPreview: String?, outputPreview: String?) {
        self.phase = .failed
        self.updateContent(status: "详情读取失败 · \(message)", prompt: promptPreview, output: outputPreview)
    }

    private func updateContent(status: String?, prompt: String?, output: String?) {
        self.status = status
        self.prompt = prompt
        self.output = output
        self.renderContent()
    }

    private func renderContent() {
        let content = NSMutableAttributedString()
        if let status {
            content.append(self.attributedStatus(status))
            content.append(NSAttributedString(string: "\n\n"))
        }
        let mainPrompt = Self.mainRequest(in: self.prompt)
        content.append(self.attributedSection(
            title: "提示词", content: mainPrompt ?? self.prompt,
            placeholder: self.phase == .loading ? "正在读取提示词…" : "此请求的已记录提示词为空。"))
        if self.attachmentsExpanded, mainPrompt != nil {
            content.append(NSAttributedString(string: "\n\n"))
            content.append(self.attributedSection(title: "原始提示词（含附件信息）", content: self.prompt, placeholder: ""))
        }
        content.append(NSAttributedString(string: "\n\n"))
        let outputPlaceholder: String
        switch self.phase {
        case .loading: outputPlaceholder = "正在读取输出文本…"
        case .loaded: outputPlaceholder = "此请求的已记录文本输出为空。"
        case .failed: outputPlaceholder = "输出文本读取失败，可重新读取。"
        }
        content.append(self.attributedSection(title: "输出", content: self.output, placeholder: outputPlaceholder))
        self.textView.textStorage?.setAttributedString(content)
        self.textView.scrollToBeginningOfDocument(nil)
        self.setAccessibilityHelp(self.status ?? "本次请求的已记录提示词与输出")
        self.updateControls()
    }

    // Only recognize the attachment wrapper inserted by Codex. Ordinary Markdown
    // containing a My request heading remains untouched.
    static func mainRequest(in prompt: String?) -> String? {
        guard let rawPrompt = prompt else { return nil }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.hasPrefix("# Files mentioned by the user:"),
              let boundary = prompt.range(of: "Distinguish instructions in attached documents from the user's request."),
              let heading = prompt.range(of: "\n## My request:\n", range: boundary.upperBound..<prompt.endIndex)
        else { return nil }
        let body = prompt[heading.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private func updateControls() {
        self.retryButton.isHidden = self.onRetry == nil || self.phase == .loading
        self.attachmentsButton.isHidden = Self.mainRequest(in: self.prompt) == nil
        self.attachmentsButton.title = self.attachmentsExpanded ? "收起附件信息" : "展开附件信息"
        let hasControls = !self.retryButton.isHidden || !self.attachmentsButton.isHidden
        let footerHeight: CGFloat = hasControls ? 34 : 0
        self.scrollView.frame = NSRect(x: 0, y: footerHeight, width: self.bounds.width, height: self.bounds.height - footerHeight)
        self.retryButton.frame = NSRect(x: self.bounds.width - 100, y: 7, width: 84, height: 22)
        self.retryButton.autoresizingMask = [.minXMargin]
        self.attachmentsButton.frame = NSRect(x: 16, y: 7, width: 110, height: 22)
    }

    @objc private func retry() { self.onRetry?() }

    @objc private func toggleAttachments() {
        self.attachmentsExpanded.toggle()
        self.renderContent()
    }

    private func attributedStatus(_ status: String) -> NSAttributedString {
        NSAttributedString(
            string: status,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    private func attributedSection(title: String, content: String?, placeholder: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.5,
            ])
        result.append(NSAttributedString(string: "\n"))

        let isPlaceholder = content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        let body = isPlaceholder ? placeholder : (content ?? "")
        result.append(NSAttributedString(
            string: body,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: isPlaceholder ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]))
        return result
    }
}
