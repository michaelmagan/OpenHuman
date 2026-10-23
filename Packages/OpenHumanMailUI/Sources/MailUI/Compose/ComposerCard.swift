import MailActions
import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct ComposerCard<Editor: View>: View {
    let session: ComposeSession
    let manager: ComposeManager
    let editor: Editor
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.composerReveal) private var reveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.floatingCompletion) private var floating

    public init(session: ComposeSession, manager: ComposeManager, onClose: @escaping () -> Void,
                @ViewBuilder editor: () -> Editor) {
        self.session = session
        self.manager = manager
        self.onClose = onClose
        self.editor = editor()
    }

    private var fieldRule: some View {
        Divider().overlay(theme.borderHairline.color)
    }

    private var isDocked: Bool {
        if case .docked = session.placement { true } else { false }
    }

    private var isFloatingCard: Bool { session.placement == .modal }

    private var rowHeight: CGFloat { isDocked ? ComposerMetrics.dockedFieldHeight : ComposerMetrics.fieldHeight }

    public var body: some View {
        let compose = theme.component.compose
        VStack(alignment: .leading, spacing: 0) {
            if isDocked { draftLine } else { titleRow }
            ComposerBanners(session: session, manager: manager)
            let recentMail = manager.recentMailLookup(for: session)
            RecipientRow(field: session.to, session: session, rowHeight: rowHeight, inlinePopovers: isDocked,
                         recentMailLookup: recentMail,
                         historyLookup: manager.recipientHistoryLookup(for: session),
                         openConversations: { address in manager.searchConversations(with: address, from: session) },
                         autofocus: (session.mode == .new || session.mode == .forward) && session.to.tokens.isEmpty) {
                fieldButtons
            }
            if session.isRecipientRowShown(.cc) {
                fieldRule
                RecipientRow(field: session.cc, session: session, rowHeight: rowHeight, inlinePopovers: isDocked,
                             recentMailLookup: recentMail, autofocus: false) { EmptyView() }
            }
            if session.isRecipientRowShown(.bcc) {
                fieldRule
                RecipientRow(field: session.bcc, session: session, rowHeight: rowHeight, inlinePopovers: isDocked,
                             recentMailLookup: recentMail, autofocus: false) { EmptyView() }
            }
            fieldRule
            FromLine(session: session, manager: manager, rowHeight: rowHeight)
            if session.showsSubject {
                fieldRule
                subjectRow
            }
            fieldRule
            if Self.drawsQuickReplies(session, manager: manager), let strip = manager.instantReply(for: session) {
                InstantReplyStrip(model: strip)
                    .padding(.top, theme.space3)
            }
            editor
                .padding(.top, ComposerMetrics.bodyTopInset)
                .overlay(alignment: .bottomLeading) {
                    if !isDocked, let picker = session.snippetPicker {
                        SnippetPickerView(picker: picker, showsSearchField: session.snippetTriggerRange == nil)
                            .offset(y: 8)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let floating, let mention = session.mentionPicker {
                        FloatingMentionList(picker: mention, floating: floating)
                    }
                }
            if floating == nil, let mention = session.mentionPicker {
                MentionPickerView(picker: mention)
                    .padding(.bottom, theme.space3)
            }
            if isDocked, let picker = session.snippetPicker {
                SnippetPickerView(picker: picker, showsSearchField: session.snippetTriggerRange == nil)
                    .padding(.bottom, theme.space3)
            }
            SignatureAndQuote(session: session, inline: isDocked)
            if !session.fileAttachments.isEmpty { AttachmentChips(session: session) }
            if manager.showsFormatBar, !session.isPlainText {
                HStack(spacing: 0) {
                    FormatBarView(state: session.formatState, style: .inline) { session.applyFormat($0) }
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.bottom, theme.space3)
            }
            dockedAIPanel
            fieldRule
            ComposerActionBar(session: session, manager: manager)
                .overlay(alignment: .top) { floatingNotice }
                .id(ComposerReveal.sendBarID)
        }
        .animation(aiMotion, value: session.aiPanel?.id)
        .padding(isDocked ? EdgeInsets(top: theme.space4, leading: 0, bottom: theme.space1, trailing: 0)
                          : EdgeInsets(top: compose.padding, leading: compose.padding, bottom: compose.padding,
                                       trailing: compose.padding))
        .frame(maxWidth: compose.maxWidth)
        .composerSurface(isFloatingCard)
        .overlay {
            Group {
                if session.isLinkConfirmationShown {
                    LinkConfirmationCard(session: session, manager: manager)
                } else if let card = session.sendConfirmation {
                    SendConfirmationCard(session: session, manager: manager, card: card)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isFloatingCard ? ComposerSurface.radius(token: compose.radius) : 0,
                                        style: .continuous))
        }
        .alert(session.preSendWarning?.title ?? "",
               isPresented: Binding(get: { session.preSendWarning != nil },
                                    set: { if !$0 { session.preSendWarning = nil } }),
               presenting: session.preSendWarning) { warning in
            Button(PreSendWarning.keepWritingTitle, role: .cancel) { session.cancelPreSendWarning() }
                .keyboardShortcut(.defaultAction)
            Button(warning.confirmTitle) { manager.confirmPreSendWarning(warning, in: session) }
        } message: { warning in
            Text(warning.message)
        }
        .background(ComposerShortcuts(session: session, manager: manager, onClose: onClose))
        .background {
            if isDocked, session.aiPanel == nil, let strip = manager.instantReply(for: session), strip.showsRow,
               strip.phase == .ready {
                InstantReplyShortcuts(model: strip)
            }
        }
        .environment(\.actionDescriptors, manager.actionDescriptors)
        .onAppear { manager.attachInstantReply(session) }
        .onKeyPress(.escape) {
            if session.mentionPicker != nil { session.dismissMention(); return .handled }
            if session.snippetPicker != nil { session.closeSnippetPicker(); return .handled }
            if let panel = session.aiPanel { panel.close(); return .handled }
            if session.isLinkConfirmationShown { session.editLinkRecipients(); return .handled }
            if session.sendConfirmation != nil { session.cancelSendConfirmation(); return .handled }
            if manager.instantReply(for: session)?.handle(.clear) == true { return .handled }
            onClose()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.title)
        .coordinateSpace(name: ComposerReveal.space)
        .onPreferenceChange(ComposerPanelFrameKey.self) { frame in
            guard let frame else { return }
            MainActor.assumeIsolated { reveal?.action(frame) }
        }
    }

    // A notice floats just above the Send bar, so showing or dismissing it moves neither the text nor the bar
    @ViewBuilder
    private var floatingNotice: some View {
        if let notice = session.notice {
            NoticeLine(notice: notice, floating: true, sendAgain: { manager.perform(.send, in: session) }) {
                session.notice = nil
            }
            .alignmentGuide(.top) { $0[.bottom] + theme.space2 }
            .transition(.opacity)
        }
    }

    // The AI panel has one place: in the card, right above the Send bar, under the text it works on, so it never
    // covers what is being edited. The card grows by the panel while it is open and shrinks back when it closes.
    @ViewBuilder
    private var dockedAIPanel: some View {
        if let panel = session.aiPanel {
            AIComposerPanel(model: panel, center: manager.aiCenter)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ComposerPanelFrameKey.self,
                                               value: geometry.frame(in: .named(ComposerReveal.space)))
                    }
                }
                .padding(.top, theme.space3)
                .padding(.bottom, theme.space4)
                .id(ComposerReveal.panelID)
                .transition(reduceMotion ? AnyTransition.opacity
                                         : AnyTransition.opacity.combined(with: .offset(y: 8)))
        }
    }

    private var aiMotion: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22)
    }

    private var draftLine: some View {
        let isAuto = isAutoDraft
        let parts = DraftLine.parts(isAuto: isAuto, names: session.recipientSummary)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: parts.lead)
                    .foregroundStyle(theme.textSuccess.color)
                    .fixedSize()
                if let rest = parts.rest {
                    Text(verbatim: " " + rest)
                        .foregroundStyle(theme.textPrimary.color)
                        .truncationMode(.tail)
                }
            }
            .lineLimit(1)
            .font(theme.typeReader.swiftUIFont)
            .fontWeight(.medium)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DraftLine.spoken(isAuto: isAuto, names: session.recipientSummary))
            .accessibilityIdentifier("composer.draftLine")
            Spacer(minLength: theme.space3)
            IconButton(symbol: "macwindow.on.rectangle", help: "Pop out", size: ComposerMetrics.lineBand,
                       shortcut: .popOutComposer, tipTitle: "Pop out") {
                manager.perform(.popOutComposer, in: session)
            }
        }
        .frame(height: ComposerMetrics.lineBand)
        .padding(.bottom, theme.space3)
    }

    public static func drawsQuickReplies(_ session: ComposeSession, manager: ComposeManager) -> Bool {
        if case .docked = session.placement { return false }
        guard session.aiPanel == nil, let strip = manager.instantReply(for: session) else { return false }
        return strip.showsRow
    }

    private var isAutoDraft: Bool {
        session.isAutoDraft || manager.instantReply(for: session)?.insertedUntouched == true
    }

    private var titleRow: some View {
        HStack(spacing: theme.space1) {
            Text(session.title)
                .font(theme.typeSubject.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.space5)
            if session.placement != .window {
                IconButton(symbol: "macwindow.on.rectangle", help: "Pop out", shortcut: .popOutComposer, tipTitle: "Pop out") {
                    manager.perform(.popOutComposer, in: session)
                }
            }
            IconButton(symbol: "xmark", help: "Close and keep the draft", shortcut: .closeComposer,
                       tipTitle: "Close and keep the draft", action: onClose)
        }
        .frame(minHeight: ComposerMetrics.iconButton)
        .padding(.bottom, theme.space5)
    }

    private var fieldButtons: some View {
        HStack(spacing: 0) {
            if isDocked, !session.showsSubject {
                FieldRevealButton(title: "Subject", help: "Edit the subject") { session.showsSubject = true }
            }
            if !session.showsCc {
                FieldRevealButton(title: "Cc", help: "Add Cc", shortcut: .showCc) { session.showCc() }
            }
            if !session.showsBcc {
                FieldRevealButton(title: "Bcc", help: "Add Bcc", shortcut: .showBcc) { session.showBcc() }
            }
        }
    }

    private var subjectRow: some View {
        HStack(alignment: .center, spacing: 0) {
            FieldLabel(title: "Subject")
            TextField("", text: Binding(get: { session.subject }, set: { session.subject = $0 }))
                .textFieldStyle(.plain)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(theme.textPrimary.color)
                .autocorrectionDisabled(!manager.textSettings.flags(for: session.account).autocorrect)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: ComposerMetrics.lineBand)
                .accessibilityLabel("Subject")
        }
        .padding(.vertical, (rowHeight - ComposerMetrics.lineBand) / 2)
        .frame(minHeight: rowHeight)
    }
}

public enum ComposerMetrics {
    /// The label column: labels sit right-aligned in it, `labelGap` before the field, like the Mac's own forms.
    static let labelWidth: CGFloat = 64
    static let labelGap: CGFloat = 10
    static let fieldHeight: CGFloat = 40
    static let dockedFieldHeight: CGFloat = 34
    static let lineBand: CGFloat = 22
    static let iconButton: CGFloat = 28
    static let toolGlyph: CGFloat = 15
    static let chipSpacing: CGFloat = 6
    static let chipLeading: CGFloat = 8
    static let bodyTopInset: CGFloat = 10
    static let actionBarHeight: CGFloat = 44
    static let toolGroupHeight: CGFloat = 32
    static let toolGroupPadding: CGFloat = 2
    static let sendShortcutOpacity: Double = 0.7
    static let minimumCardRadius: CGFloat = 12
    static let attachmentTileHeight: CGFloat = 44
    static let attachmentTileMaxWidth: CGFloat = 280
    static let attachmentIcon: CGFloat = 30
    static let compactBannerHeight: CGFloat = 24
    static let snippetPopoverWidth: CGFloat = 520
    static let snippetRowHeight: CGFloat = 36
    static let snippetNameWidth: CGFloat = 160
    static let suggestionsWidth: CGFloat = 360
    static let suggestionRowHeight: CGFloat = 40
    static let bannerHeight: CGFloat = 32
    public static let editorMinDocked: CGFloat = 96
    public static let editorMinModal: CGFloat = 240
    public static let dockedMaxFraction: CGFloat = 0.6
}

struct FieldLabel: View {
    let title: String
    @Environment(\.theme) private var theme

    static let alignment: Alignment = .trailing

    var body: some View {
        Text(title)
            .font(theme.typeBody.swiftUIFont)
            .foregroundStyle(theme.textSecondary.color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: ComposerMetrics.labelWidth - ComposerMetrics.labelGap, height: ComposerMetrics.lineBand,
                   alignment: Self.alignment)
            .padding(.trailing, ComposerMetrics.labelGap)
            .accessibilityHidden(true)
    }
}

// Subject, Cc and Bcc at the end of the To row: plain words that show the system's accessory-bar plate on hover
struct FieldRevealButton: View {
    let title: String
    let help: String
    var shortcut: ActionID?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).lineLimit(1)
        }
        .ohAccessoryBarButtonStyle()
        .foregroundStyle(.secondary)
        .accessibilityLabel(title)
        .modifier(TextButtonHelp(help: help, shortcut: shortcut, tipTitle: nil, tipHint: nil))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: ThemeColor?
    var size: CGFloat = ComposerMetrics.iconButton
    var shortcut: ActionID?
    var tipTitle: String?
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size < ComposerMetrics.iconButton ? 12 : ComposerMetrics.toolGlyph))
        }
        .buttonStyle(ComposerToolStyle(size: size, tint: tint))
        .shortcutTip(shortcut, title: tipTitle, hint: tipHint, orHelp: help)
        .accessibilityLabel(help.components(separatedBy: "  ").first ?? help)
    }
}

struct TextButton: View {
    let title: String
    let help: String
    var strong = false
    var enabled = true
    var compact = false
    var shortcut: ActionID?
    var tipTitle: String?
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(strong ? theme.typeBodyStrong.swiftUIFont : theme.typeBody.swiftUIFont)
                .foregroundStyle((enabled ? (strong ? theme.textPrimary : theme.textSecondary) : theme.textDisabled).color)
                .padding(.vertical, compact ? 0 : 6)
                .padding(.horizontal, compact ? 6 : 10)
                .frame(minHeight: compact ? ComposerMetrics.lineBand : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .modifier(TextButtonHelp(help: help, shortcut: shortcut, tipTitle: tipTitle, tipHint: tipHint))
    }
}

struct TextButtonHelp: ViewModifier {
    let help: String
    let shortcut: ActionID?
    let tipTitle: String?
    let tipHint: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.shortcutTip(shortcut, title: tipTitle, hint: tipHint)
        } else {
            content.help(help).accessibilityHint(help)
        }
    }
}

struct ComposerToolStyle: ButtonStyle {
    var size: CGFloat = ComposerMetrics.iconButton
    var tint: ThemeColor?

    func makeBody(configuration: Configuration) -> some View {
        ToolBody(configuration: configuration, size: size, tint: tint)
    }

    static func plate(hovered: Bool, pressed: Bool, enabled: Bool) -> ToolPlate {
        guard enabled else { return .none }
        if pressed { return .pressed }
        return hovered ? .hovered : .none
    }

    enum ToolPlate: Equatable {
        case none
        case hovered
        case pressed
    }

    private struct ToolBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let tint: ThemeColor?
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let plate = ComposerToolStyle.plate(hovered: hovered, pressed: configuration.isPressed, enabled: isEnabled)
            configuration.label
                .foregroundStyle(glyph(plate).color)
                .frame(width: size, height: size)
                .background {
                    switch plate {
                    case .none: Color.clear
                    case .hovered: Circle().fill(theme.bgRowHover.color)
                    case .pressed: Circle().fill(theme.bgRowSelected.color)
                    }
                }
                .contentShape(Circle())
                .onHover { hovered = $0 }
        }

        private func glyph(_ plate: ToolPlate) -> ThemeColor {
            guard isEnabled else { return theme.textDisabled }
            if let tint { return tint }
            return plate == .none ? theme.textSecondary : theme.textPrimary
        }
    }
}

struct ComposerSurface: ViewModifier {
    let isCard: Bool
    @Environment(\.theme) private var theme

    static func radius(token: CGFloat) -> CGFloat {
        max(token, ComposerMetrics.minimumCardRadius)
    }

    func body(content: Content) -> some View {
        let compose = theme.component.compose
        let shape = RoundedRectangle(cornerRadius: Self.radius(token: compose.radius), style: .continuous)
        content
            .background {
                if isCard { shape.fill(compose.bg.color).themeShadow(compose.shadow) }
            }
            .overlay {
                if isCard { shape.strokeBorder(theme.borderElevated.color, lineWidth: theme.borderWidthHairline) }
            }
    }
}

extension View {
    func composerSurface(_ isCard: Bool) -> some View {
        modifier(ComposerSurface(isCard: isCard))
    }
}

public struct ComposerReveal: @unchecked Sendable {
    public static let space = "composer.card"
    public static let panelID = "composer.ai.panel"
    public static let sendBarID = "composer.sendBar"
    public let action: @MainActor (CGRect) -> Void

    public init(action: @escaping @MainActor (CGRect) -> Void) {
        self.action = action
    }
}

extension EnvironmentValues {
    @Entry public var composerReveal: ComposerReveal? = nil
}

struct ComposerPanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

enum DraftLine {
    static func parts(isAuto: Bool, names: String?) -> (lead: String, rest: String?) {
        (isAuto ? String(localized: "Auto Draft") : String(localized: "Draft"), names.map { String(localized: "to \($0)") })
    }

    static func spoken(isAuto: Bool, names: String?) -> String {
        guard let names else { return isAuto ? String(localized: "Auto Draft") : String(localized: "Draft") }
        return isAuto ? String(localized: "Auto Draft to \(names)") : String(localized: "Draft to \(names)")
    }
}
