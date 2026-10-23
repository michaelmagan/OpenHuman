import MailFeatures
import MailModel
import MailRender
import OpenHumanCore
import SwiftUI

struct ComposeSheet: View {
    let phone: PhoneMail
    @Bindable var session: ComposeSession
    @State private var text = ""
    @State private var pushed: String?
    @FocusState private var focus: Field?
    @Environment(\.touch) private var theme

    enum Field: Hashable { case to, cc, subject, body }

    private var isReply: Bool { session.mode == .reply || session.mode == .replyAll }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            RecipientRow(field: session.to, focus: $focus, focusValue: .to)
            if session.showsCc || !session.cc.tokens.isEmpty {
                divider
                RecipientRow(field: session.cc, focus: $focus, focusValue: .cc)
            }
            if session.showsSubject || !isReply {
                divider
                HStack(spacing: theme.tokens.space3) {
                    Text("Subject")
                        .font(theme.subject)
                        .foregroundStyle(theme.textTertiary)
                    TextField("", text: $session.subject)
                        .font(theme.subject)
                        .foregroundStyle(theme.textPrimary)
                        .focused($focus, equals: .subject)
                        .submitLabel(.next)
                        .onSubmit { focus = .body }
                        .accessibilityLabel("Subject")
                        .accessibilityIdentifier("compose.subject")
                }
                .padding(.horizontal, theme.tokens.space5)
                .frame(minHeight: 50)
            }
            divider
            if let notice = session.notice {
                Text(notice.text)
                    .font(theme.snippet)
                    .foregroundStyle(notice.kind == .error ? theme.textDanger : theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.tokens.space5)
                    .padding(.vertical, theme.tokens.space2)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(isReply ? "Write your reply" : "Write your message")
                        .font(theme.body)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                TextEditor(text: $text)
                    .font(theme.body)
                    .foregroundStyle(theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .accessibilityLabel("Message")
                    .accessibilityIdentifier("compose.body")
            }
            .padding(.horizontal, theme.tokens.space4)
            .padding(.top, theme.tokens.space2)
            toolbar
        }
        .background(theme.card.ignoresSafeArea())
        .presentationBackground(theme.card)
        .presentationDetents([.large])
        .alert(session.preSendWarning?.title ?? "",
               isPresented: Binding(get: { session.preSendWarning != nil },
                                    set: { if !$0 { session.preSendWarning = nil } }),
               presenting: session.preSendWarning) { warning in
            Button(PreSendWarning.keepWritingTitle, role: .cancel) { session.cancelPreSendWarning() }
            Button(warning.confirmTitle) { phone.compose.confirmPreSendWarning(warning, in: session) }
        } message: { warning in
            Text(warning.message)
        }
        .onAppear {
            loadText()
            guard !phone.isRendering else { return }
            focus = session.to.tokens.isEmpty && !isReply ? .to : .body
        }
        .onChange(of: session.documentRevision) { _, _ in loadText() }
        .onChange(of: text) { _, value in
            guard value != pushed else { return }
            pushed = value
            session.updateBody(Self.document(value))
        }
    }

    private var header: some View {
        HStack(spacing: theme.tokens.space3) {
            AvatarView(name: session.from.name, email: session.from.email, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.from.email)
                    .font(theme.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(session.title)
                    .font(theme.snippet)
                    .foregroundStyle(theme.textSecondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let state = session.saveState.text {
                Text(state)
                    .font(theme.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            CircleIconButton(systemImage: "xmark", label: "Close and keep the draft", size: 44) {
                phone.closeComposer(session)
            }
            .accessibilityIdentifier("compose.close")
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.vertical, theme.tokens.space3)
    }

    private var divider: some View {
        Rectangle().fill(theme.hairline).frame(height: theme.tokens.borderWidthHairline)
    }

    private var toolbar: some View {
        HStack(spacing: theme.tokens.space3) {
            PillGroup {
                PillIconButton(systemImage: "trash", label: "Discard draft") { phone.discard(session) }
                    .accessibilityIdentifier("compose.discard")
                if !session.showsCc {
                    PillIconButton(systemImage: "person.2", label: "Add Cc") { session.showCc() }
                }
            }
            Spacer()
            Button { phone.send(session) } label: {
                Image(systemName: "paperplane.fill")
                    .font(theme.icon)
                    .foregroundStyle(theme.onAccent)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(canSend ? theme.accent : theme.accent.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("compose.send")
        }
        .padding(.horizontal, theme.tokens.space4)
        .padding(.vertical, theme.tokens.space3)
    }

    private var canSend: Bool {
        let fields = [session.to, session.cc, session.bcc]
        return fields.contains { !$0.tokens.isEmpty || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func loadText() {
        let current = ComposeSerializer.plainText(session.document, signature: nil)
        guard current != pushed else { return }
        pushed = current
        text = current
    }

    static func document(_ text: String) -> RichTextDocument {
        RichTextDocument(blocks: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map {
            .paragraph($0.isEmpty ? [] : [.text($0, [])])
        })
    }
}

struct RecipientRow: View {
    @Bindable var field: RecipientFieldModel
    var focus: FocusState<ComposeSheet.Field?>.Binding
    let focusValue: ComposeSheet.Field
    @Environment(\.touch) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: theme.tokens.space3) {
                Text(field.title)
                    .font(theme.subject)
                    .foregroundStyle(theme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.tokens.space2) {
                        FlowTokens(field: field)
                        input
                    }
                }
            }
            .padding(.horizontal, theme.tokens.space5)
            .frame(minHeight: 50)
            suggestions
        }
    }

    private var input: some View {
        TextField("", text: $field.text)
            .font(theme.subject)
            .foregroundStyle(theme.textPrimary)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused(focus, equals: focusValue)
            .submitLabel(.next)
            .onSubmit { field.commit() }
            .onChange(of: field.text) { _, value in
                if value.hasSuffix(",") || value.hasSuffix(";") { field.commitText() }
            }
            .accessibilityLabel(field.title)
            .accessibilityIdentifier("compose.\(field.kind.rawValue)")
            .frame(minWidth: 160)
    }

    private var suggestions: some View {
        ForEach(field.suggestions, id: \.email) { suggestion in
            Button { field.accept(suggestion) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.name ?? suggestion.email)
                        .font(theme.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    if suggestion.name != nil {
                        Text(suggestion.email)
                            .font(theme.snippet)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.tokens.space5)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct FlowTokens: View {
    let field: RecipientFieldModel
    @Environment(\.touch) private var theme

    var body: some View {
        if !field.tokens.isEmpty {
            HStack(spacing: theme.tokens.space1) {
                ForEach(field.tokens, id: \.email) { address in
                    Button { field.remove(address) } label: {
                        Text(RecipientParser.displayName(address))
                            .font(theme.subject)
                            .foregroundStyle(RecipientParser.isValid(address.email) ? theme.textPrimary : theme.textDanger)
                            .lineLimit(1)
                            .padding(.horizontal, theme.tokens.space2)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accentSubtle))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(address.email)
                    .accessibilityHint("Removes this recipient")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
