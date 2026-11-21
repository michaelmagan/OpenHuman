import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct QuickReplyMessageRow: View {
    let row: InlineReplyRow
    let environment: AppEnvironment
    let thread: ThreadKey
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?

    public init(center: AICenter, environment: AppEnvironment, thread: ThreadKey, message: MessageKey) {
        self.environment = environment
        self.thread = thread
        row = center.inlineReplies.row(for: thread, message: message)
    }

    private var openReply: ComposeSession? {
        environment.composeIfStarted?.sessions.last {
            $0.thread == thread && $0.isOpen && ($0.mode == .reply || $0.mode == .replyAll)
        }
    }

    private var dockedReply: ComposeSession? {
        guard let reply = openReply, case .docked = reply.placement else { return nil }
        return reply
    }

    var shown: InlineReplyRow.State {
        if openReply != nil, dockedReply == nil { return .none }
        return row.state
    }

    public var body: some View {
        Group {
            switch shown {
            case .writing, .ready:
                content
            case .undecided, .none:
                Color.clear.frame(height: 0)
            }
        }
        .onAppear { row.appear() }
        .accessibilityIdentifier("reader.quickReplies")
    }

    private var content: some View {
        let reply = dockedReply
        return VStack(alignment: .leading, spacing: theme.space2) {
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            HStack(spacing: theme.space2) {
                if shown == .writing { writing } else { chips(reply) }
                Spacer(minLength: theme.space3)
                if shown == .ready, reply == nil, row.preview != nil { useButton }
            }
            .frame(height: theme.component.chipAI.height)
            if reply == nil { preview }
        }
        .padding(.top, theme.space2)
        .padding(.bottom, reply == nil ? 0 : theme.space2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private var writing: some View {
        HStack(spacing: theme.space2) {
            spinner
            Text("Writing replies…")
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .padding(.horizontal, theme.space3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Writing suggested replies"))
        .accessibilityIdentifier("reader.quickReplies.writing")
    }

    @ViewBuilder private var spinner: some View {
        if reduceMotion {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary.color)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(theme.textSecondary.color)
        }
    }

    private func chips(_ reply: ComposeSession?) -> some View {
        let items = row.items
        let outlined = outlinedID(items, reply: reply)
        return HStack(spacing: theme.space2) {
            ChipRowLayout(spacing: theme.space2, maxWidth: InstantReplyMetrics.chipMaxWidth,
                          floor: InstantReplyMetrics.chipMinWidth) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    chip(item, index: index, outlined: item.id == outlined, docked: reply != nil)
                }
            }
            if row.isSuspicious, items.contains(where: { $0.kind == .quickReply }) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: InstantReplyMetrics.suspiciousGlyph))
                    .foregroundStyle(theme.textWarning.color)
                    .help(AIWording.suspicious)
                    .accessibilityLabel(AIWording.suspicious)
            }
            if row.isWritingMore {
                HStack(spacing: theme.space1) {
                    spinner
                    Text("Writing replies…")
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Writing suggested replies"))
            }
        }
    }

    private func outlinedID(_ items: [ReplySuggestion], reply: ComposeSession?) -> String? {
        guard let reply else { return row.preview?.id }
        if let strip = environment.composeIfStarted?.instantReply(for: reply), let id = strip.selectedSuggestionID {
            return id
        }
        guard let inBody = reply.suggestionInBody else { return nil }
        return items.first { item in item.body.map { ReplySuggestions.same($0, inBody) } ?? false }?.id
    }

    private func chip(_ item: ReplySuggestion, index: Int, outlined: Bool, docked: Bool) -> some View {
        let hot = hovered == item.id
        let shape = RoundedRectangle(cornerRadius: InstantReplyMetrics.chipCorner, style: .continuous)
        let ink: ThemeColor = item.isWarning ? theme.textWarning : (outlined || hot ? theme.textPrimary : theme.textSecondary)
        return Button { row.select(index) } label: {
            HStack(spacing: theme.space1) {
                if item.kind == .createEvent || item.kind == .suggestTimes {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary.color)
                        .accessibilityHidden(true)
                }
                Text(verbatim: item.label)
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(ink.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, theme.space3)
            .frame(height: theme.component.chipAI.height)
            .background(shape.fill(hot && !outlined ? theme.bgRowHover.color : Color.clear))
            .overlay(shape.strokeBorder(outlined ? theme.borderControl.color : Color.clear,
                                        lineWidth: CGFloat(theme.borderWidthHairline)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        .help(item.help)
        .accessibilityLabel(Text(verbatim: item.label))
        .accessibilityValue(Text(verbatim: item.body ?? ""))
        .accessibilityHint(Self.hint(item, outlined: outlined, docked: docked))
        .accessibilityAddTraits(outlined ? .isSelected : [])
        .accessibilityIdentifier("reader.suggestion.\(item.id)")
    }

    static func hint(_ item: ReplySuggestion, outlined: Bool, docked: Bool) -> String {
        switch item.kind {
        case .busy: return String(localized: "Shows the meeting at that time.")
        case .createEvent: return String(localized: "Opens a new event at that time.")
        case .suggestTimes: return String(localized: "Offers times you're free.")
        case .quickReply, .scheduling:
            if docked { return String(localized: "Puts this reply into your draft. Nothing is sent.") }
            return outlined ? String(localized: "Puts this reply into a new draft. Nothing is sent.")
                            : String(localized: "Previews this reply.")
        }
    }

    private var useButton: some View {
        Button { Task { _ = await row.accept() } } label: {
            HStack(spacing: theme.space1) {
                Text("Use")
                    .font(theme.typeLabel.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                KeycapView(text: "⇥")
            }
            .padding(.horizontal, theme.space2)
            .frame(height: theme.component.chipAI.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Use this reply  ⇥"))
        .accessibilityLabel(String(localized: "Use this reply"))
        .accessibilityHint(String(localized: "Puts the previewed reply into a new draft. Nothing is sent."))
        .accessibilityIdentifier("reader.quickReplies.use")
    }

    private var preview: some View {
        let lines = InlineReplyMetrics.previewLines
        let height = CGFloat(theme.typeReader.lineHeight) * CGFloat(lines)
        return Group {
            if let reply = row.preview, let text = reply.body {
                Text(verbatim: text)
                    .font(theme.typeReader.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(lines)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .accessibilityLabel(String(localized: "Suggested reply"))
                    .accessibilityValue(Text(verbatim: text))
                    .accessibilityIdentifier("reader.quickReplies.preview")
            } else {
                Color.clear
            }
        }
        .padding(.horizontal, theme.space3)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
    }
}

public enum InlineReplyMetrics {
    public static let previewLines = 2
}
