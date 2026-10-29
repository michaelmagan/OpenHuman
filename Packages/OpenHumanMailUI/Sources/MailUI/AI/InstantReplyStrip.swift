import MailFeatures
import MailTheme
import SwiftUI

public struct InstantReplyStrip: View {
    let model: InstantReplyModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var placeholdersShownAt: ContinuousClock.Instant?
    @State private var holdsPlaceholders = false
    @State private var rowHovered = false

    public init(model: InstantReplyModel) {
        self.model = model
    }

    public var body: some View {
        row
        .frame(height: InstantReplyMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { rowHovered = $0 }
        .background {
            if model.phase == .ready { InstantReplyShortcuts(model: model) }
        }
        .animation(change, value: model.selection)
        .animation(change, value: shown)
        .task(id: model.phase == .waiting) { await followWaiting() }
        .task(id: model.isLive) { model.applyPendingPreview() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityIdentifier("composer.quickReplies")
    }

    private var shown: InstantReplyModel.Phase {
        holdsPlaceholders ? .waiting : model.phase
    }

    private var change: Animation? {
        guard !reduceMotion, theme.motionInstant.durationMs > 0 else { return nil }
        return .linear(duration: theme.motionInstant.seconds)
    }

    private var row: some View {
        let showsHint = revealsHint && !model.hint.isEmpty
        return InstantReplyRowLayout(spacing: theme.space3, showsHint: showsHint) {
            Image(systemName: "sparkle")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary.color)
                .accessibilityLabel(String(localized: "Quick replies"))
            Text(String(localized: "Quick replies"))
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize()
            HStack(spacing: 0) { content }
            hint
                .opacity(showsHint ? 1 : 0)
                .allowsHitTesting(showsHint)
                .animation(Self.hintMotion(revealing: showsHint, reduceMotion: reduceMotion || theme.reduceMotion,
                                           reveal: theme.tokens.motion(theme.motionReveal, transform: false)).animation,
                           value: showsHint)
            if let badge = model.badge {
                AIProviderBadgeView(badge: badge, short: true)
                    .fixedSize()
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
            hideButton
        }
    }

    @ViewBuilder private var content: some View {
        switch shown {
        case .waiting:
            waiting
        case .ready:
            chips
        case .quiet(let text, let canRetry):
            quiet(text, canRetry: canRetry)
        case .used, .hidden:
            EmptyView()
        }
    }

    private var chips: some View {
        HStack(spacing: theme.space3) {
            ChipRowLayout(spacing: theme.space3, maxWidth: InstantReplyMetrics.chipMaxWidth,
                          floor: InstantReplyMetrics.narrowChipMinWidth) {
                ForEach(Array(model.options.prefix(3).enumerated()), id: \.element.id) { index, option in
                    chip(option, index: index)
                }
            }
            if model.isSuspicious {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: InstantReplyMetrics.suspiciousGlyph))
                    .foregroundStyle(theme.textWarning.color)
                    .help(AIWording.suspicious)
                    .accessibilityLabel(AIWording.suspicious)
            }
        }
    }

    private func chip(_ option: QuickReply, index: Int) -> some View {
        let selected = model.isLive && model.selection == index
        let hovered = model.isLive && model.hovered == index
        let chip = theme.component.chipAI
        let shape = RoundedRectangle(cornerRadius: InstantReplyMetrics.chipCorner, style: .continuous)
        return HStack(spacing: theme.space1) {
            Button { model.use(index, via: .click) } label: {
                Text(verbatim: option.label)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle((selected || hovered ? theme.textPrimary : theme.textSecondary).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if selected, model.options.count > 1 {
                Menu {
                    ForEach(Array(model.options.prefix(3).enumerated()), id: \.element.id) { other, reply in
                        if other != index {
                            Button { model.preview(other) } label: { Text(verbatim: reply.label) }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.textTertiary.color)
                }
                .ohBorderlessMenuStyle()
                .menuIndicator(.hidden)
                .tint(theme.textTertiary.color)
                .fixedSize()
                .accessibilityLabel(String(localized: "Other quick replies"))
            }
        }
        .padding(.horizontal, theme.space3)
        .frame(height: chip.height)
        .background(shape.fill(hovered && !selected ? theme.bgRowHover.color : Color.clear))
        .overlay(shape.strokeBorder(selected ? theme.borderControl.color : Color.clear,
                                    lineWidth: CGFloat(theme.borderWidthHairline)))
        .contentShape(shape)
        .onHover { inside in model.hover(inside ? index : (model.hovered == index ? nil : model.hovered)) }
        .help(Self.tooltip(option.body))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: option.label))
        .accessibilityValue(Text(verbatim: option.body))
        .accessibilityHint(String(localized: "Puts this reply into the draft. Nothing is sent."))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var revealsHint: Bool {
        Self.revealsHint(rowHovered: rowHovered, selection: model.selection, hovered: model.hovered,
                         isLive: model.isLive, phase: shown)
    }

    static func revealsHint(rowHovered: Bool, selection: Int?, hovered: Int?, isLive: Bool,
                            phase: InstantReplyModel.Phase) -> Bool {
        guard phase == .ready else { return false }
        return rowHovered || hovered != nil || (selection != nil && isLive)
    }

    static func hintMotion(revealing: Bool, reduceMotion: Bool, reveal: MotionSpec) -> MotionSpec {
        guard revealing, !reduceMotion else { return .instant }
        return reveal
    }

    private var hint: some View {
        HStack(spacing: theme.space2) {
            ForEach(Array(model.hint.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text(verbatim: "·").font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                }
                HStack(spacing: theme.space1) {
                    KeycapView(text: item.key)
                    Text(item.title).font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                }
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var waiting: some View {
        HStack(spacing: theme.space3) {
            if placeholdersShownAt != nil || holdsPlaceholders {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(theme.bgRowSelected.color)
                        .frame(minWidth: InstantReplyMetrics.chipMinWidth, idealWidth: InstantReplyMetrics.placeholderWidth,
                               maxWidth: InstantReplyMetrics.placeholderWidth)
                        .frame(height: theme.component.chipAI.height)
                }
                Text(model.waitingText)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Writing quick replies"))
    }

    private func quiet(_ text: String, canRetry: Bool) -> some View {
        HStack(spacing: theme.space3) {
            Text(verbatim: text)
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            if canRetry {
                Button(String(localized: "Try again")) { model.retry() }
                    .ohLinkButtonStyle()
                    .font(theme.typeLabel.swiftUIFont)
                    .fixedSize()
            }
        }
    }

    private var hideButton: some View {
        Button { model.hideForConversation() } label: {
            Image(systemName: "xmark")
                .font(.system(size: InstantReplyMetrics.hideGlyph, weight: .semibold))
                .foregroundStyle(theme.textTertiary.color)
                .frame(width: InstantReplyMetrics.hideTarget, height: InstantReplyMetrics.hideTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Hide quick replies for this conversation"))
        .accessibilityLabel(String(localized: "Hide quick replies for this conversation"))
        .accessibilityIdentifier("composer.quickReplies.hide")
    }

    private func followWaiting() async {
        if model.phase == .waiting {
            holdsPlaceholders = false
            guard placeholdersShownAt == nil else { return }
            try? await Task.sleep(for: .milliseconds(theme.motionSpinnerDelay))
            guard !Task.isCancelled else { return }
            placeholdersShownAt = .now
        } else if let shownAt = placeholdersShownAt {
            let rest: Duration = .milliseconds(theme.motionSpinnerMinVisible) - (ContinuousClock.now - shownAt)
            if rest > .zero {
                holdsPlaceholders = true
                try? await Task.sleep(for: rest)
                guard !Task.isCancelled else { return }
                holdsPlaceholders = false
            }
            placeholdersShownAt = nil
        }
    }

    static func tooltip(_ body: String) -> String {
        body.split(whereSeparator: \.isNewline).prefix(2).joined(separator: "\n")
    }
}

public enum InstantReplyMetrics {
    public static let rowHeight: CGFloat = 32
    static let chipMaxWidth: CGFloat = 180
    static let chipMinWidth: CGFloat = 40
    static let narrowChipMinWidth: CGFloat = 32
    static let placeholderWidth: CGFloat = 96
    static let selectedBorder: CGFloat = 1.5
    static let chipCorner: CGFloat = 4
    static let hideGlyph: CGFloat = 10
    static let hideTarget: CGFloat = 24
    static let suspiciousGlyph: CGFloat = 12
}

struct ChipShape: InsettableShape {
    let radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: inset, dy: inset)
        guard frame.width > 0, frame.height > 0 else { return Path() }
        if radius >= min(rect.width, rect.height) / 2 {
            return Capsule(style: .circular).path(in: frame)
        }
        return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .circular).path(in: frame)
    }

    func inset(by amount: CGFloat) -> ChipShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

struct InstantReplyRowLayout: Layout {
    let spacing: CGFloat
    let showsHint: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let shown = [0, 1, 2, 4, 5] + (showsHint ? [3] : [])
        let ideal = shown.reduce(CGFloat.zero) { $0 + sizes[$1].width }
            + spacing * CGFloat(shown.count - 1)
        return CGSize(width: proposal.width ?? ideal, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let icon = sizes[0].width
        let label = sizes[1].width
        let content = sizes[2].width
        let hint = sizes[3].width
        let badge = sizes[4].width
        let hide = sizes[5].width
        let badgeGap = badge > 0 ? spacing : 0
        let hideX = bounds.maxX - hide
        let badgeX = hideX - badgeGap - badge
        let contentEnd = badgeX - spacing
        let contentStart = bounds.minX + icon + spacing
        let room = max(0, contentEnd - contentStart)
        let chipFloor = min(content, 3 * InstantReplyMetrics.narrowChipMinWidth + 2 * spacing)
        let labelFits = room >= chipFloor + spacing + label
        let hintFits = showsHint && room >= chipFloor + (labelFits ? label + spacing : 0) + hint + spacing
        let textWidth = labelFits ? label + spacing : 0
        let hintWidth = hintFits ? hint + spacing : 0
        let contentWidth = min(content, max(0, room - textWidth - hintWidth))

        func place(_ index: Int, x: CGFloat, width: CGFloat) {
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                                  proposal: ProposedViewSize(width: width, height: bounds.height))
        }
        place(0, x: bounds.minX, width: icon)
        if labelFits { place(1, x: contentStart, width: label) }
        let chipsX = contentStart + textWidth
        place(2, x: chipsX, width: contentWidth)
        if hintFits { place(3, x: chipsX + contentWidth + spacing, width: hint) }
        if badge > 0 { place(4, x: badgeX, width: badge) }
        place(5, x: hideX, width: hide)
    }
}

struct ChipRowLayout: Layout {
    let spacing: CGFloat
    let maxWidth: CGFloat
    let floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + gaps(subviews.count), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func gaps(_ count: Int) -> CGFloat {
        spacing * CGFloat(max(0, count - 1))
    }

    private func widths(for available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { min($0.sizeThatFits(.unspecified).width, maxWidth) }
        guard let available else { return ideal }
        return Self.fitted(ideal, into: available - gaps(subviews.count), floor: floor)
    }

    static func fitted(_ ideal: [CGFloat], into room: CGFloat, floor: CGFloat) -> [CGFloat] {
        guard !ideal.isEmpty, ideal.reduce(0, +) > room else { return ideal }
        var used: CGFloat = 0
        var cap = floor
        for (index, width) in ideal.sorted().enumerated() {
            let share = (room - used) / CGFloat(ideal.count - index)
            guard width <= share else {
                cap = share
                break
            }
            used += width
        }
        let limit = max(floor, cap)
        return ideal.map { min($0, limit) }
    }
}

struct InstantReplyShortcuts: View {
    let model: InstantReplyModel

    var body: some View {
        ZStack {
            ForEach(0..<min(3, model.options.count), id: \.self) { index in
                Button("") { model.use(index, via: .command) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
