import AppKit
import MailFeatures
import MailTheme

@MainActor
public enum AIReaderAccessory {
    public static func view(reader: ReaderModel, environment: AppEnvironment, theme: ThemeTokens) -> NSView? {
        guard let center = environment.ai, environment.modules.modules.contains(.ai) else { return nil }
        return ThreadSummaryLineView(model: center.summary(for: reader.thread), reader: reader, center: center, theme: theme)
    }
}

@MainActor
final class ThreadSummaryLineView: NSView {
    let model: ThreadSummaryModel
    private let reader: ReaderModel
    private let center: AICenter
    private let theme: ThemeTokens
    private let stack = NSStackView()
    private let headerRow = NSStackView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let badgeIcon = NSImageView()
    let textLabel = NSTextField(wrappingLabelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: AIWording.suspicious)
    let oneLine = NSTextField(wrappingLabelWithString: "")
    let oneLinePlaceholder = NSView()
    private var summarizeLink: ReaderButton!
    private var retryLink: ReaderButton!
    private var observation: ObservationLoop?
    private var reportedCount = 0
    private var textBox: NSLayoutConstraint!
    private(set) var stage = SummaryBlockLayout.Stage.absent
    var onStageChange: ((SummaryBlockLayout.Stage) -> Void)?
    var applyChange: ((_ change: () -> Void) -> Void)?
    private var holding = false
    private var holdTimer: Task<Void, Never>?

    init(model: ThreadSummaryModel, reader: ReaderModel, center: AICenter, theme: ThemeTokens) {
        self.model = model
        self.reader = reader
        self.center = center
        self.theme = theme
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        observation = ObservationLoop.observe { [weak self] in self?.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        observation?.cancel()
        holdTimer?.cancel()
        center.conversationDisappeared(reader.thread)
    }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = theme.space2
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets()
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        oneLine.font = theme.typeBody.font
        oneLine.textColor = theme.textSecondary.nsColor
        oneLine.isSelectable = true
        oneLine.allowsEditingTextAttributes = false
        oneLine.maximumNumberOfLines = 2
        oneLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        oneLine.identifier = NSUserInterfaceItemIdentifier("reader.threadLine")
        stack.addArrangedSubview(oneLine)
        oneLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.cornerRadius = theme.radiusSM
        bar.layer?.backgroundColor = theme.bgRowHover.nsColor.cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        oneLinePlaceholder.addSubview(bar)
        oneLinePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            oneLinePlaceholder.widthAnchor.constraint(equalToConstant: 240),
            oneLinePlaceholder.heightAnchor.constraint(equalToConstant: Self.height(ofLines: 1, font: theme.typeBody.font)),
            bar.leadingAnchor.constraint(equalTo: oneLinePlaceholder.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: oneLinePlaceholder.trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: oneLinePlaceholder.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 12),
        ])
        oneLinePlaceholder.setAccessibilityElement(true)
        oneLinePlaceholder.setAccessibilityLabel(String(localized: "Writing a one-line summary"))
        stack.addArrangedSubview(oneLinePlaceholder)

        title.attributedStringValue = Self.sectionTitle(String(localized: "Summary"), theme: theme)
        badge.font = theme.typeCaption.font
        badge.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerRow.orientation = .horizontal
        headerRow.spacing = theme.space3
        headerRow.addArrangedSubview(title)
        headerRow.addArrangedSubview(NSView())
        badgeIcon.translatesAutoresizingMaskIntoConstraints = false
        badgeIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        badgeIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        headerRow.addArrangedSubview(badgeIcon)
        headerRow.setCustomSpacing(4, after: badgeIcon)
        headerRow.addArrangedSubview(badge)
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        textLabel.font = theme.typeReader.font
        textLabel.textColor = theme.textSecondary.nsColor
        textLabel.isSelectable = true
        textLabel.allowsEditingTextAttributes = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textLabel.cell?.truncatesLastVisibleLine = true
        stack.addArrangedSubview(textLabel)
        textLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        textBox = textLabel.heightAnchor.constraint(
            equalToConstant: Self.height(ofLines: SummaryBlockLayout.reservedLines, font: theme.typeReader.font))

        warning.font = theme.typeCaption.font
        warning.textColor = theme.textWarning.nsColor
        warning.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(warning)
        warning.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        retryLink = ReaderButton.link(String(localized: "Try again"), theme: theme) { [weak self] in
            self?.model.summarize(trigger: .user)
        }
        stack.addArrangedSubview(retryLink)

        summarizeLink = ReaderButton.link("✦ " + String(localized: "Summarize"), theme: theme) { [weak self] in
            guard let self else { return }
            self.model.summarize(trigger: .user, messageCount: self.reader.messages.count)
        }
        summarizeLink.attributedTitle = Self.sectionTitle(String(localized: "Summarize"), theme: theme)
        summarizeLink.toolTip = String(localized: "Summarize this conversation")
        stack.addArrangedSubview(summarizeLink)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Summary"))
    }

    static func sectionTitle(_ text: String, theme: ThemeTokens) -> NSAttributedString {
        NSAttributedString(string: "✦ " + text, attributes: [.font: theme.typeLabel.font, .foregroundColor: theme.textAI.nsColor])
    }

    static func height(ofLines lines: Int, font: NSFont) -> CGFloat {
        let probe = NSTextField(wrappingLabelWithString: Array(repeating: "Xg", count: lines).joined(separator: "\n"))
        probe.font = font
        return probe.fittingSize.height
    }

    private func update() {
        if let applyChange { applyChange(render) } else { render() }
    }

    private func render() {
        let count = reader.state == .loaded ? reader.messages.count : 0
        let phase = model.phase
        let generating = phase == .loading || phase == .streaming
        hold(generating: generating)
        let shows = model.showsLine && !holding
        let offers = holding ? !summarizeLink.isHidden : !shows && model.offersSummarize(messageCount: count)
        headerRow.isHidden = !shows
        retryLink.isHidden = true
        warning.isHidden = !(shows && model.isSuspicious)
        summarizeLink.isHidden = !offers
        if let badgeValue = model.badge {
            let color = (badgeValue.leavesMac ? theme.textWarning : theme.textTertiary).nsColor
            badge.stringValue = badgeValue.title
            badge.textColor = color
            badge.toolTip = badgeValue.help
            badgeIcon.image = NSImage(systemSymbolName: badgeValue.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            badgeIcon.contentTintColor = color
            badgeIcon.isHidden = false
            headerRow.setAccessibilityLabel(String(localized: "Summary, \(badgeValue.help)"))
        } else {
            badge.stringValue = ""
            badgeIcon.isHidden = true
        }
        switch phase {
        case .loading:
            textLabel.stringValue = String(localized: "Thinking…")
            textLabel.font = theme.typeCaption.font
            textLabel.textColor = theme.textTertiary.nsColor
        case .failed(let reason):
            textLabel.stringValue = reason
            textLabel.font = theme.typeBody.font
            textLabel.textColor = theme.textDanger.nsColor
            retryLink.isHidden = false
        default:
            textLabel.stringValue = model.text
            textLabel.font = theme.typeReader.font
            textLabel.textColor = theme.textSecondary.nsColor
        }
        textLabel.isHidden = !shows
        textLabel.setAccessibilityLabel(shows ? String(localized: "Summary: \(textLabel.stringValue)") : nil)
        let lines = center.threadLines
        let line = lines.line(for: reader.thread)
        oneLine.stringValue = line ?? ""
        oneLine.isHidden = line == nil
        oneLine.setAccessibilityLabel(line.map { String(localized: "In short: \($0)") })
        oneLinePlaceholder.isHidden = line != nil || !lines.isGenerating(reader.thread)
        let lineShows = !oneLine.isHidden || !oneLinePlaceholder.isHidden
        applyStage(SummaryBlockLayout.stage(showsLine: shows, generating: generating, offersSummarize: offers,
                                            oneLineShows: lineShows))
        isHidden = !shows && !offers && !lineShows
        if count > 0, count != reportedCount {
            reportedCount = count
            let thread = reader.thread
            let center = center
            Task { @MainActor in center.conversationAppeared(thread, messageCount: count) }
        }
        needsLayout = true
    }

    private func applyStage(_ new: SummaryBlockLayout.Stage) {
        let old = stage
        textLabel.maximumNumberOfLines = SummaryBlockLayout.maximumTextLines(stage: new)
        textBox.isActive = SummaryBlockLayout.holdsReservedHeight(new)
        stage = new
        if old != new { onStageChange?(new) }
    }

    private func hold(generating: Bool) {
        guard generating else {
            holdTimer?.cancel()
            holdTimer = nil
            holding = false
            return
        }
        guard holdTimer == nil, stage == .offer || stage == .absent else { return }
        holding = true
        let delay = Duration.seconds(theme.motionSpinnerDelay / 1000)
        holdTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.holding else { return }
            self.holding = false
            self.update()
        }
    }

    override func layout() {
        super.layout()
        for label in [textLabel, warning, oneLine] where label.preferredMaxLayoutWidth != label.frame.width {
            label.preferredMaxLayoutWidth = label.frame.width
            label.invalidateIntrinsicContentSize()
        }
    }
}
