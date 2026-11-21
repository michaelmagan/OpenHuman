import MailActions
import MailFeatures
import MailModel
import OpenHumanCore
import SwiftUI

struct ConversationScreen: View {
    let phone: PhoneMail
    @State private var shown: ReaderModel?
    @Environment(\.touch) private var theme

    var body: some View {
        Group {
            // Why: the reader closes before the pop animation ends; the last one stays on screen while it slides away
            if let reader = phone.reader ?? shown {
                ConversationContent(phone: phone, reader: reader)
                    .id(reader.thread)
            } else {
                theme.window.ignoresSafeArea()
            }
        }
        .background(theme.window)
        .onChange(of: phone.reader.map(ObjectIdentifier.init), initial: true) { _, _ in
            if let reader = phone.reader { shown = reader }
        }
    }
}

struct ConversationContent: View {
    let phone: PhoneMail
    let reader: ReaderModel
    @Environment(\.touch) private var theme

    private var me: Set<String> { reader.myAddresses }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.tokens.space3) {
                Text(subject)
                    .font(theme.title)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.tokens.space2)
                    .padding(.top, theme.tokens.space2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("reader.subject")
                switch reader.state {
                case .loading where reader.messages.isEmpty:
                    ProgressView()
                        .tint(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, theme.tokens.space8)
                case .missing:
                    ReaderNotice(text: ReaderFormatting.missingConversationText)
                case .failed where reader.messages.isEmpty:
                    ReaderNotice(text: ReaderFormatting.failedConversationText)
                default:
                    EmptyView()
                }
                ForEach(reader.items, id: \.self) { item in
                    switch item {
                    case .message(let key):
                        if let message = reader.message(key) {
                            MessageCard(phone: phone, reader: reader, message: message, me: me)
                        }
                    case .olderMessages(let keys):
                        OlderMessagesButton(count: keys.count) { reader.showAllMessages() }
                    }
                }
            }
            .padding(.horizontal, theme.tokens.space3)
            .padding(.bottom, theme.tokens.space6)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { ReaderBottomBars(phone: phone, reader: reader) }
        .background(theme.window)
    }

    private var subject: String {
        let text = reader.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no subject)" : text
    }

    private var counterpart: EmailAddress? {
        let summaries = reader.messages.map(\.summary)
        let isMe = { (address: EmailAddress) in me.contains(address.email.lowercased()) }
        if let other = summaries.reversed().compactMap(\.from).first(where: { !isMe($0) }) { return other }
        return summaries.last?.to.first { !isMe($0) } ?? summaries.last?.from
    }

    private var topBar: some View {
        HStack(spacing: theme.tokens.space3) {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { phone.back() }
                .accessibilityIdentifier("reader.back")
            HStack(spacing: theme.tokens.space3) {
                let other = counterpart
                AvatarView(name: other?.name, email: other?.email ?? "", size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(other.map { $0.name ?? $0.email } ?? " ")
                        .font(theme.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(subject)
                        .font(theme.date)
                        .foregroundStyle(theme.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.tokens.space2)
            .frame(minHeight: 48)
            .background(Capsule().fill(theme.pill))
            .overlay(Capsule().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.top, theme.tokens.space1)
        .padding(.bottom, theme.tokens.space2)
        .topBarBackground(theme.window)
    }
}

struct ReaderNotice: View {
    let text: String
    @Environment(\.touch) private var theme

    var body: some View {
        Text(text)
            .font(theme.body)
            .foregroundStyle(theme.textSecondary)
            .padding(theme.tokens.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

struct OlderMessagesButton: View {
    let count: Int
    let action: () -> Void
    @Environment(\.touch) private var theme

    var body: some View {
        Button(action: action) {
            Text(count == 1 ? "1 older message" : "\(count) older messages")
                .font(theme.subject.weight(.medium))
                .foregroundStyle(theme.textLink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .cardSurface()
        }
        .buttonStyle(.plain)
    }
}

struct ReaderBottomBars: View {
    let phone: PhoneMail
    let reader: ReaderModel
    @Environment(\.touch) private var theme

    var body: some View {
        let thread = reader.thread
        VStack(spacing: theme.tokens.space3) {
            HStack(spacing: theme.tokens.space3) {
                CircleIconButton(systemImage: "square.and.pencil", label: "New message") { phone.newMessage() }
                Button { phone.reply(all: true) } label: {
                    HStack(spacing: theme.tokens.space3) {
                        Image(systemName: "arrowshape.turn.up.left.2")
                            .font(theme.smallIcon)
                        Text("Reply all")
                            .font(theme.subject)
                            .foregroundStyle(theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, theme.tokens.space5)
                    .frame(minHeight: 48)
                    .background(Capsule().fill(theme.pill))
                    .overlay(Capsule().strokeBorder(theme.elevatedBorder, lineWidth: theme.tokens.borderWidthHairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reply all")
                .accessibilityIdentifier("reader.replyAll")
            }
            PillGroup(height: 52) {
                PillIconButton(systemImage: "checkmark", label: "Done") {
                    phone.perform(.markDone, on: thread, source: .toolbar)
                }
                .accessibilityIdentifier("reader.done")
                Spacer(minLength: 0)
                PillIconButton(systemImage: "clock", label: "Remind me") { phone.askReminder(thread, source: .toolbar) }
                Spacer(minLength: 0)
                PillIconButton(systemImage: reader.isStarred ? "star.fill" : "star",
                               label: reader.isStarred ? "Unstar" : "Star", isOn: reader.isStarred) {
                    phone.perform(.toggleStar, on: thread, source: .toolbar)
                }
                Spacer(minLength: 0)
                PillIconButton(systemImage: "envelope.badge", label: "Mark unread") {
                    phone.perform(.toggleRead, on: thread, source: .toolbar)
                    phone.back()
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { phone.reply(all: false) }
                    Button("Forward", systemImage: "arrowshape.turn.up.right") { phone.forward() }
                    Button("Mark as spam", systemImage: "xmark.bin") { phone.perform(.spam, on: thread, source: .toolbar) }
                    Button("Trash", systemImage: "trash", role: .destructive) {
                        phone.perform(.trash, on: thread, source: .toolbar)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(theme.icon)
                        .foregroundStyle(theme.textPrimary)
                        .frame(minWidth: 46, minHeight: 44)
                }
                .accessibilityLabel("More actions")
            }
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.top, theme.tokens.space2)
        .padding(.bottom, theme.tokens.space1)
        .bottomBarBackground(theme.window)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { phone.readerBarHeight = $0 }
    }
}
