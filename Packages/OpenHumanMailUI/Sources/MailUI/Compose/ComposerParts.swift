import MailActions
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct FromLine: View {
    let session: ComposeSession
    let manager: ComposeManager
    var rowHeight: CGFloat = ComposerMetrics.fieldHeight
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            FieldLabel(title: "From")
            HStack(alignment: .center, spacing: theme.space3) {
                address
                    .layoutPriority(1)
                if session.from.needsVerification {
                    Label("Not verified in Gmail", systemImage: "exclamationmark.triangle.fill")
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(Self.color(.warning, theme: theme).color)
                        .symbolRenderingMode(.hierarchical)
                        .lineLimit(1)
                }
                if session.showsFromReason {
                    Text(reasonLine)
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(Self.color(.quiet, theme: theme).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(reasonLine)
                        .accessibilityLabel(reasonLine)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: rowHeight)
        .help(session.showsFromReason ? "" : reasonLine)
        .modifier(FromLineAccessibility(picker: session.offersFromPicker,
                                        label: "From \(session.from.display). \(reasonLine)"))
    }

    @ViewBuilder
    private var address: some View {
        if session.offersFromPicker {
            #if os(macOS)
            FromMenuButton(session: session, rows: FromMenu.rows(session.fromChoices, current: session.from),
                           isOpen: session.isFromPickerOpen)
                .shortcutTip(.chooseFrom, title: "Change the From address", alignment: .leading)
            #else
            Menu {
                ForEach(session.fromChoices) { identity in
                    Button(identity.display) { session.chooseFrom(identity) }
                }
            } label: {
                plainAddress
            }
            #endif
        } else {
            plainAddress
        }
    }

    private var plainAddress: some View {
        Text(session.from.display)
            .font(theme.typeBody.swiftUIFont)
            .foregroundStyle(theme.textPrimary.color)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // Why this address was picked is context, so it reads as secondary text; only an address Gmail may refuse warns
    enum Tone: Equatable {
        case quiet
        case warning
    }

    static func color(_ tone: Tone, theme: ResolvedTheme) -> ThemeColor {
        switch tone {
        case .quiet: theme.textSecondary
        case .warning: theme.textWarning
        }
    }

    private var reasonLine: String {
        var parts = [session.fromReason.text]
        if session.isFromNonDefault { parts.append(String(localized: "not your default address")) }
        return parts.joined(separator: " · ")
    }
}

private struct FromLineAccessibility: ViewModifier {
    let picker: Bool
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if picker {
            content.accessibilityElement(children: .contain)
        } else {
            content.accessibilityElement(children: .combine).accessibilityLabel(label)
        }
    }
}

enum FromMenu {
    struct Row: Equatable {
        let title: String
        let subtitle: String?
        let isCurrent: Bool
        let needsVerification: Bool
    }

    static func rows(_ choices: [FromIdentity], current: FromIdentity) -> [Row] {
        choices.map { identity in
            Row(title: identity.display, subtitle: subtitle(identity), isCurrent: identity == current,
                needsVerification: identity.needsVerification)
        }
    }

    static func subtitle(_ identity: FromIdentity) -> String? {
        if identity.needsVerification { return String(localized: "Not verified in Gmail: sending may fail") }
        return identity.isGmailDefault ? String(localized: "Gmail default") : nil
    }
}

#if os(macOS)
struct FromMenuButton: NSViewRepresentable {
    let session: ComposeSession
    let rows: [FromMenu.Row]
    let isOpen: Bool

    static let isBordered = false

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Borderless like the From field of the Mac's Mail: the address and the pop-up arrows, no bezel in the row
        button.isBordered = Self.isBordered
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel(String(localized: "From"))
        button.setAccessibilityIdentifier("composer.from")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.session = session
        coordinator.choices = session.fromChoices
        if coordinator.rows != rows {
            coordinator.rows = rows
            button.removeAllItems()
            for row in rows {
                let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                item.subtitle = row.subtitle
                button.menu?.addItem(item)
            }
        }
        if let index = rows.firstIndex(where: \.isCurrent), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        if isOpen { coordinator.open(button) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        let width = proposal.width.map { min(natural.width, max($0, 0)) } ?? natural.width
        return CGSize(width: width, height: natural.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var session: ComposeSession
        var choices: [FromIdentity] = []
        var rows: [FromMenu.Row] = []
        private var opening = false

        init(session: ComposeSession) {
            self.session = session
        }

        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard choices.indices.contains(index) else { return }
            session.chooseFrom(choices[index])
        }

        // Why: ⇧⌘F asks for the picker through the session; the menu opens once, after this update pass
        func open(_ button: NSPopUpButton) {
            guard !opening else { return }
            opening = true
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self else { return }
                defer {
                    self.opening = false
                    if self.session.isFromPickerOpen { self.session.isFromPickerOpen = false }
                }
                guard let button, let window = button.window, window.isKeyWindow, !button.isHiddenOrHasHiddenAncestor
                else { return }
                button.performClick(nil)
            }
        }
    }
}
#endif

struct RecipientRow<Trailing: View>: View {
    let field: RecipientFieldModel
    let session: ComposeSession
    var rowHeight: CGFloat = ComposerMetrics.fieldHeight
    var inlinePopovers = false
    var recentMailLookup: (@Sendable (String) async -> ThreadRow?)? = nil
    var historyLookup: (@Sendable (String) async -> Int?)? = nil
    var openConversations: ((EmailAddress) -> Void)? = nil
    let autofocus: Bool
    @ViewBuilder let trailing: Trailing
    @Environment(\.theme) private var theme
    @Environment(\.undoManager) private var undoManager
    @Environment(\.floatingCompletion) private var floating
    @FocusState private var focused: Bool
    @State private var floatingList = CompletionListModel()
    @State private var recentMail = RecentMailDetails()
    @State private var history = RecipientHistory()
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                FieldLabel(title: field.title)
                TokenFlowLayout(spacing: ComposerMetrics.chipSpacing) {
                    ForEach(field.tokens, id: \.self) { address in
                        RecipientToken(address: address, expanded: session.linkRecipients?.contains(address) == true,
                                       moves: moves(for: address),
                                       dragged: session.recipientDrag == RecipientDrag(address: address, from: field.kind)) {
                            field.remove(address)
                        }
                        .onDrag {
                            session.beginRecipientDrag(address, from: field.kind)
                            return NSItemProvider(object: RecipientMove.dragText(address) as NSString)
                        }
                    }
                    if field.tokens.isEmpty, isDropZone {
                        Text("Drop here")
                            .font(theme.typeBody.swiftUIFont)
                            .foregroundStyle(theme.textTertiary.color)
                            .frame(height: ComposerMetrics.lineBand)
                            .accessibilityHidden(true)
                    }
                    TextField("", text: Binding(get: { field.text }, set: { field.text = $0 }))
                        .textFieldStyle(.plain)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textPrimary.color)
                        .autocorrectionDisabled(true)
                        // Why: SwiftUI sized the AppKit field to its line or to the whole band between passes, jittering the text
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 120, minHeight: ComposerMetrics.lineBand, maxHeight: ComposerMetrics.lineBand)
                        .focused($focused)
                        .onSubmit { field.commit() }
                        .onKeyPress(.downArrow) { field.suggestions.isEmpty ? .ignored : (field.moveSuggestion(by: 1), .handled).1 }
                        .onKeyPress(.upArrow) { field.suggestions.isEmpty ? .ignored : (field.moveSuggestion(by: -1), .handled).1 }
                        .onKeyPress(.tab) { field.suggestions.isEmpty ? .ignored : (field.commit(), .handled).1 }
                        .onKeyPress(.escape) {
                            field.suggestions.isEmpty ? .ignored : (field.dismissSuggestions(), .handled).1
                        }
                        .onKeyPress(.delete) { field.text.isEmpty && !field.tokens.isEmpty ? (field.removeLast(), .handled).1 : .ignored }
                        .onChange(of: focused) { _, isFocused in if !isFocused { field.commitText() } }
                        .accessibilityLabel(field.title)
                }
                trailing.frame(height: ComposerMetrics.lineBand)
            }
            .padding(.vertical, (rowHeight - ComposerMetrics.lineBand) / 2)
            .background(alignment: .topLeading) { floatingSuggestions }
            .background {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgRowSelected.color)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(of: [.plainText], delegate: RecipientDropTarget(session: session, kind: field.kind,
                                                                    undoManager: undoManager, targeted: $dropTargeted))
            .onDragSessionUpdated { drag in
                switch drag.phase {
                case .ended, .dataTransferCompleted: session.endRecipientDrag()
                default: break
                }
            }
            historyLine
            if floating == nil, inlinePopovers, focused, !field.suggestions.isEmpty {
                SuggestionList(field: field, detail: recentMailDetail)
                    .padding(.leading, ComposerMetrics.labelWidth)
                    .padding(.bottom, theme.space3)
            }
        }
        .frame(minHeight: rowHeight)
        .overlay(alignment: .bottomLeading) {
            if floating == nil, !inlinePopovers, focused, !field.suggestions.isEmpty {
                SuggestionList(field: field, detail: recentMailDetail)
                    .offset(x: ComposerMetrics.labelWidth, y: CGFloat(field.suggestions.count) * ComposerMetrics.suggestionRowHeight + 8)
                    .zIndex(10)
            }
        }
        .onChange(of: field.suggestions) { _, _ in mirrorSuggestions() }
        .onChange(of: field.suggestionCursor) { _, _ in mirrorSuggestions() }
        .onChange(of: field.text) { _, _ in mirrorSuggestions() }
        .onChange(of: floatingList.cursor) { _, index in
            if floating != nil { field.selectSuggestion(index) }
        }
        .onChange(of: highlightedSuggestion) { _, email in
            guard let recentMailLookup else { return }
            recentMail.lookup = recentMailLookup
            recentMail.highlight(focused ? email : nil)
        }
        .zIndex(focused ? 5 : 0)
        .onAppear {
            if autofocus || field.focusRequest != field.focusHandled { focused = true }
            field.focusHandled = field.focusRequest
            loadHistory()
        }
        .onChange(of: field.tokens) { _, _ in loadHistory() }
        .onChange(of: field.focusRequest) { _, request in
            field.focusHandled = request
            focused = true
        }
    }

    @ViewBuilder
    private var historyLine: some View {
        if historyLookup != nil, let openConversations, let address = history.shown(in: field.tokens),
           let line = history.line(for: address) {
            Button(line) { openConversations(address) }
                .ohLinkButtonStyle()
                .font(theme.typeCaption.swiftUIFont)
                .lineLimit(1)
                .help("Search every conversation with \(address.email)")
                .frame(height: theme.typeCaption.lineHeight, alignment: .leading)
                .padding(.leading, ComposerMetrics.labelWidth)
                .padding(.bottom, theme.space2)
                .accessibilityIdentifier("compose.recipientHistory")
        } else if historyLookup != nil, history.isPending(in: field.tokens) {
            Color.clear
                .frame(height: theme.typeCaption.lineHeight)
                .padding(.bottom, theme.space2)
                .accessibilityHidden(true)
        }
    }

    private func loadHistory() {
        guard field.kind == .to, let historyLookup else { return }
        history.lookup = historyLookup
        for token in field.tokens { history.load(token.email) }
    }

    // Floats under the chips, aligned with them, so opening the list moves nothing in the card
    @ViewBuilder
    private var floatingSuggestions: some View {
        if let floating {
            floating.anchor(FloatingCompletion.Request(
                list: floatingList, isPresented: focused && !field.suggestions.isEmpty, theme: theme,
                label: String(localized: "Suggested recipients"),
                identifier: "compose.recipientSuggestions.\(field.kind.rawValue)",
                accessory: floatingDetail,
                accept: { address in field.accept(address) }))
                .frame(maxWidth: ComposerMetrics.suggestionsWidth)
                .padding(.leading, ComposerMetrics.labelWidth)
                .accessibilityHidden(true)
        }
    }

    private var floatingDetail: (@MainActor (EmailAddress) -> String?)? {
        guard recentMailLookup != nil else { return nil }
        let details = recentMail
        return { address in details.detail(for: address.email) }
    }

    private func mirrorSuggestions() {
        guard floating != nil else { return }
        floatingList.mirror(query: field.text, items: field.suggestions, cursor: field.suggestionCursor)
    }

    private var highlightedSuggestion: String? {
        field.suggestions.indices.contains(field.suggestionCursor) ? field.suggestions[field.suggestionCursor].email : nil
    }

    private var isDropZone: Bool {
        guard let drag = session.recipientDrag else { return false }
        return drag.from != field.kind
    }

    private func moves(for address: EmailAddress) -> [RecipientTokenMove] {
        let source = field.kind
        return session.moveTargets(from: source).map { target in
            RecipientTokenMove(title: RecipientMove.title(movingTo: target)) {
                _ = session.moveRecipient(address, from: source, to: target, undoManager: undoManager)
            }
        }
    }

    private var recentMailDetail: ((EmailAddress) -> String?)? {
        guard recentMailLookup != nil else { return nil }
        return { address in recentMail.detail(for: address.email) }
    }
}

struct RecipientTokenMove {
    let title: String
    let action: () -> Void
}

struct RecipientDropTarget: DropDelegate {
    let session: ComposeSession
    let kind: RecipientFieldModel.Kind
    let undoManager: UndoManager?
    let targeted: Binding<Bool>

    private var accepts: Bool {
        guard let drag = session.recipientDrag else { return false }
        return drag.from != kind
    }

    func validateDrop(info: DropInfo) -> Bool {
        session.recipientDrag != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        targeted.wrappedValue = accepts
    }

    func dropExited(info: DropInfo) {
        targeted.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: accepts ? .move : .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        guard accepts else {
            session.endRecipientDrag()
            return false
        }
        return session.dropRecipient(on: kind, undoManager: undoManager)
    }
}

struct RecipientToken: View {
    let address: EmailAddress
    let expanded: Bool
    var moves: [RecipientTokenMove] = []
    var dragged = false
    let remove: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false
    @State private var removeHovered = false

    static let removeHitWidth: CGFloat = 20
    static let removeGlyphSize: CGFloat = 8
    static let removePlateSize: CGFloat = 14

    struct RemoveStyle: Equatable {
        let opacity: Double
        let emphasized: Bool
        let plate: Bool
    }

    // The x stays visible at rest, brightens while the chip is under the pointer and gets its own plate under it
    static func removeStyle(hovered: Bool, chipHovered: Bool = false) -> RemoveStyle {
        RemoveStyle(opacity: 1, emphasized: hovered || chipHovered, plate: hovered)
    }

    // Tokens are rounded rectangles with the theme's token corner, like the Mac's token fields
    static func cornerRadius(token: CGFloat, height: CGFloat) -> CGFloat {
        min(max(token, 4), height / 2)
    }

    enum Look: Equatable {
        case resting
        case dragged
        case invalid
    }

    static func look(valid: Bool, dragged: Bool) -> Look {
        if dragged { return .dragged }
        return valid ? .resting : .invalid
    }

    var body: some View {
        let token = theme.component.token
        let valid = RecipientParser.isValid(address.email)
        let style = Self.removeStyle(hovered: removeHovered, chipHovered: hovered)
        let look = Self.look(valid: valid, dragged: dragged)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius(token: token.radius, height: token.height),
                                     style: .continuous)
        HStack(spacing: 0) {
            Text(label)
                .font(theme.typeBody.swiftUIFont)
                .foregroundStyle(textColor(look).color)
                .underline(!valid, pattern: .dot, color: theme.textDanger.color)
                .lineLimit(1)
                .padding(.leading, ComposerMetrics.chipLeading)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: Self.removeGlyphSize, weight: .bold))
                    .foregroundStyle(removeColor(look, emphasized: style.emphasized).color)
                    .frame(width: Self.removePlateSize, height: Self.removePlateSize)
                    .background {
                        if style.plate, let plate = removePlate(look) { Circle().fill(plate.color) }
                    }
                    .frame(width: Self.removeHitWidth, height: token.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(style.opacity)
            .onHover { removeHovered = $0 }
            .help("Remove \(address.email)")
            .accessibilityHidden(true)
        }
        .padding(.trailing, 2)
        .frame(height: token.height)
        .background(shape.fill(fill(look).color))
        .overlay {
            if look == .invalid {
                shape.strokeBorder(theme.textDanger.color.opacity(0.35), lineWidth: theme.borderWidthHairline)
            }
        }
        .contentShape(shape)
        .onHover { hovered = $0 }
        .help(valid ? address.email : "Not a valid address")
        .contextMenu {
            ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                Button(move.title, action: move.action)
            }
            Button("Remove", action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(valid ? label : "\(label), not a valid address")
        .accessibilityAction(named: Text("Remove \(label)"), remove)
        .accessibilityActions {
            ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                Button(move.title, action: move.action)
            }
        }
    }

    private func fill(_ look: Look) -> ThemeColor {
        switch look {
        case .resting: theme.accentSubtle
        case .dragged: theme.accentFill
        case .invalid: theme.bgDangerSubtle
        }
    }

    private func textColor(_ look: Look) -> ThemeColor {
        switch look {
        case .resting: theme.textPrimary
        case .dragged: theme.accentOnFill
        case .invalid: theme.textDanger
        }
    }

    private func removeColor(_ look: Look, emphasized: Bool) -> ThemeColor {
        switch look {
        case .dragged: theme.accentOnFill
        case .invalid: theme.textDanger
        case .resting: emphasized ? theme.textPrimary : theme.textSecondary
        }
    }

    private func removePlate(_ look: Look) -> ThemeColor? {
        look == .dragged ? nil : theme.bgRowSelected
    }

    private var label: String {
        if expanded, let name = address.name, !name.isEmpty { return "\(name) <\(address.email)>" }
        if expanded { return address.email }
        return RecipientParser.displayName(address)
    }
}

struct SuggestionList: View {
    let field: RecipientFieldModel
    var detail: ((EmailAddress) -> String?)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(field.suggestions.enumerated()), id: \.offset) { index, address in
                let last = index == field.suggestionCursor ? detail?(address) : nil
                Button { field.accept(address) } label: {
                    HStack(spacing: theme.space3) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(RecipientParser.displayName(address))
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textPrimary.color)
                            if address.name != nil {
                                Text(address.email)
                                    .font(theme.typeMeta.swiftUIFont)
                                    .foregroundStyle(theme.textSecondary.color)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        if let last {
                            Text(last)
                                .font(theme.typeMeta.swiftUIFont)
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary.color)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, theme.space4)
                    .frame(width: ComposerMetrics.suggestionsWidth, height: ComposerMetrics.suggestionRowHeight, alignment: .leading)
                    .background(index == field.suggestionCursor ? theme.bgRowSelected.color : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(RecipientParser.displayName(address))
                .accessibilityValue(last ?? "")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous))
        .background(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous)
            .fill(theme.component.popover.bg.color))
        .overlay(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous)
            .strokeBorder(theme.component.popover.border.color, lineWidth: theme.borderWidthHairline))
        .themeShadow(theme.shadow2)
    }
}

struct TokenFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if x > 0, x + w > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += w + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            let isLast = index == subviews.count - 1
            if x > bounds.minX, x + min(size.width, bounds.width) > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            if isLast { size.width = max(size.width, bounds.maxX - x) }
            size.width = min(size.width, bounds.maxX - x)
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

struct ComposerBanners: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            if case .localOnly(let why) = session.saveState {
                CompactBanner(symbol: "lock", text: shortLocalOnlyText(why), help: localOnlyText(why))
            }
            if let link = session.linkBanner {
                Banner(symbol: "exclamationmark.triangle", text: link)
                if session.linkTriedBcc {
                    Text("This link tried to add a Bcc recipient; it was ignored.")
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(theme.textTertiary.color)
                }
            }
            if session.draftStatus == .failed, let error = session.draftError {
                HStack(spacing: theme.space3) {
                    Banner(symbol: "exclamationmark.triangle", text: String(localized: "Not sent: \(error)."))
                    TextButton(title: "Send now", help: "Send it now", strong: true, shortcut: .send, tipTitle: "Send it now") {
                        manager.perform(.send, in: session)
                    }
                    TextButton(title: "Reschedule", help: "Pick a new time", shortcut: .sendLater, tipTitle: "Pick a new time") {
                        manager.perform(.sendLater, in: session)
                    }
                }
            } else if let sendAt = session.sendAt {
                HStack(spacing: theme.space3) {
                    Label(String(localized: "Sends at \(manager.formatSendAt(sendAt))"), systemImage: "paperplane")
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.accentText.color)
                    TextButton(title: "Cancel", help: "Cancel send later", shortcut: .cancelSendLater) {
                        manager.perform(.cancelSendLater, in: session)
                    }
                    TextButton(title: "Reschedule", help: "Pick a new time", shortcut: .sendLater, tipTitle: "Pick a new time") {
                        manager.perform(.sendLater, in: session)
                    }
                }
            }
            if session.source != .user, session.review == .pending {
                Banner(symbol: "sparkles", text: String(localized: "An agent wrote this draft. Review it before sending or scheduling."))
            }
        }
        .padding(.bottom, hasContent ? theme.space3 : 0)
    }

    private var hasContent: Bool {
        if case .localOnly = session.saveState { return true }
        return session.linkBanner != nil || session.sendAt != nil || session.draftStatus == .failed
            || (session.source != .user && session.review == .pending)
    }

    private func localOnlyText(_ why: String) -> String {
        manager.canSendInThisProcess
            ? why
            : String(localized: "\(why). Sending is off: Send is refused and nothing is queued.")
    }

    private func shortLocalOnlyText(_ why: String) -> String {
        manager.canSendInThisProcess ? why : String(localized: "\(why) · Sending is off")
    }
}

struct CompactBanner: View {
    let symbol: String
    let text: String
    let help: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space2 + 2) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            Text(text)
                .font(theme.typeMeta.swiftUIFont)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textSecondary.color)
        .padding(.horizontal, theme.space3)
        .frame(height: ComposerMetrics.compactBannerHeight)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgSunken.color))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: symbol).font(.system(size: 14))
            Text(text).font(theme.typeBody.swiftUIFont).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textWarning.color)
        .padding(.horizontal, theme.space4)
        .frame(minHeight: ComposerMetrics.bannerHeight)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD).fill(theme.bgWarningSubtle.color))
        .accessibilityElement(children: .combine)
    }
}

struct SignatureAndQuote: View {
    let session: ComposeSession
    var inline = false
    @Environment(\.theme) private var theme
    @State private var signatureHovered = false

    // The signature reads as part of the letter but quieter than it; its toggle stays faint until the pointer is near
    static func toggleColor(hovered: Bool, theme: ResolvedTheme) -> ThemeColor {
        hovered ? theme.textSecondary : theme.textTertiary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let preview = session.signaturePreview {
                HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                    Text(session.includesSignature ? preview : String(localized: "Signature removed for this message"))
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle((session.includesSignature ? theme.textSecondary : theme.textTertiary).color)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(session.includesSignature ? "Remove signature" : "Add signature") {
                        session.includesSignature.toggle()
                    }
                    .ohAccessoryBarButtonStyle()
                    .controlSize(.small)
                    .foregroundStyle(Self.toggleColor(hovered: signatureHovered, theme: theme).color)
                    .help("The signature of the From address")
                    .accessibilityHint("The signature of the From address")
                }
                .contentShape(Rectangle())
                .onHover { signatureHovered = $0 }
            }
            if !session.quotedHTML.isEmpty {
                VStack(alignment: .leading, spacing: theme.space2) {
                    Button {
                        session.isQuoteExpanded.toggle()
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .foregroundStyle(theme.textSecondary.color)
                    .help(session.isQuoteExpanded ? "Hide the quoted message" : "Show the quoted message")
                    .accessibilityLabel(session.isQuoteExpanded ? "Hide the quoted message" : "Show the quoted message")
                    .accessibilityIdentifier("composer.quoteToggle")
                    if session.isQuoteExpanded {
                        if inline {
                            quote
                        } else {
                            ScrollView { quote }.frame(maxHeight: 240)
                        }
                    }
                }
            }
        }
        .padding(.bottom, theme.space4)
    }

    private var quote: some View {
        let preview = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML)
        return VStack(alignment: .leading, spacing: theme.space2) {
            if !preview.header.isEmpty {
                Text(preview.header)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .accessibilityIdentifier("composer.quoteAttribution")
            }
            if !preview.body.isEmpty {
                HStack(alignment: .top, spacing: theme.space4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.borderControl.color)
                        .frame(width: 2)
                    Text(preview.body)
                        .font(theme.typeMeta.swiftUIFont)
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, theme.space1)
    }
}

struct AttachmentChips: View {
    let session: ComposeSession
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            TokenFlowLayout(spacing: theme.space3) {
                ForEach(session.fileAttachments, id: \.self) { attachment in
                    AttachmentTile(attachment: attachment) { session.removeAttachment(attachment) }
                }
            }
            Text(Self.summary(count: session.fileAttachments.count, bytes: session.attachmentBytes))
                .font(theme.typeCaption.swiftUIFont)
                .foregroundStyle(theme.textTertiary.color)
                .accessibilityIdentifier("composer.attachments.total")
        }
        .padding(.top, theme.space2)
        .padding(.bottom, theme.space4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments")
    }

    nonisolated static func summary(count: Int, bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return count == 1 ? String(localized: "1 attachment · \(size)") : String(localized: "\(count) attachments · \(size)")
    }

    nonisolated static func symbol(filename: String, mimeType: String) -> String {
        let fileExtension = (filename as NSString).pathExtension
        let candidates = [fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension), UTType(mimeType: mimeType)]
        guard let type = candidates.compactMap({ $0 }).first(where: { $0 != .data && !$0.isDynamic }) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .calendarEvent) { return "calendar" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

struct AttachmentTile: View {
    let attachment: DraftAttachmentInfo
    let remove: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(theme.radiusXL), style: .continuous)
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
        HStack(spacing: theme.space3) {
            Image(systemName: AttachmentChips.symbol(filename: attachment.filename, mimeType: attachment.mimeType))
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(theme.accentText.color)
                .frame(width: ComposerMetrics.attachmentIcon, height: ComposerMetrics.attachmentIcon)
                .background(RoundedRectangle(cornerRadius: CGFloat(theme.radiusLG), style: .continuous)
                    .fill(theme.accentSubtle.color))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(size)
                    .font(theme.typeCaption.swiftUIFont)
                    .foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle((hovered ? theme.textSecondary : theme.textTertiary).color)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.filename)")
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.leading, 7)
        .padding(.trailing, theme.space2)
        .frame(height: ComposerMetrics.attachmentTileHeight)
        .frame(maxWidth: ComposerMetrics.attachmentTileMaxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(shape.fill((hovered ? theme.bgRowHover : theme.bgSunken).color))
        .overlay(shape.strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        .contentShape(shape)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(attachment.filename), \(size)")
    }
}

struct NoticeLine: View {
    let notice: ComposeSession.Notice
    var floating = false
    var sendAgain: (() -> Void)? = nil
    let dismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: notice.kind == .info ? "info.circle" : "exclamationmark.triangle").font(.system(size: 13))
            Text(notice.text).font(theme.typeBody.swiftUIFont).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if notice.offersSendAgain, let sendAgain {
                TextButton(title: "Send again", help: "Send it again", strong: true, compact: true, shortcut: .send,
                           tipTitle: "Send it again", action: sendAgain)
                    .accessibilityIdentifier("composer.notice.sendAgain")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(color.color)
        .padding(.horizontal, theme.space4)
        .padding(.vertical, theme.space2)
        .background {
            // A floating notice sits on the card's own colour first, so the text under it never shows through the tint
            let shape = RoundedRectangle(cornerRadius: theme.radiusLG, style: .continuous)
            if floating {
                shape.fill(theme.component.compose.bg.color)
                    .themeShadow(theme.shadow2)
            }
            shape.fill((notice.kind == .error ? theme.bgDangerSubtle : theme.bgWarningSubtle).color)
        }
        .padding(.vertical, floating ? 0 : theme.space2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var color: ThemeColor {
        switch notice.kind {
        case .info: theme.textSecondary
        case .warning: theme.textWarning
        case .error: theme.textDanger
        }
    }
}

struct ComposerActionBar: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme
    @State private var marksDone: StoredSetting<Bool>?

    private var showsMarkDone: Bool {
        (marksDone?.value ?? true) && manager.archivesOnSend(session)
    }

    var body: some View {
        HStack(spacing: theme.space3) {
            ViewThatFits(in: .horizontal) {
                actions(.full)
                actions(.compact)
            }
            .layoutPriority(1)
            Spacer(minLength: theme.space4)
            if session.saveState.text != nil, !isLocalOnly {
                SaveStatusText(state: session.saveState)
                    .padding(.trailing, theme.space1)
            }
            tools
        }
        .frame(minHeight: ComposerMetrics.actionBarHeight)
        .padding(.top, theme.space3)
        .task {
            guard marksDone == nil else { return }
            let setting = manager.makeSendMarksDoneSetting()
            setting.start()
            marksDone = setting
        }
    }

    enum Fit: CaseIterable {
        case full
        case compact

        var controlSize: ControlSize { self == .compact ? .regular : .large }
    }

    private func actions(_ fit: Fit) -> some View {
        HStack(spacing: theme.space2) {
            SendButton(enabled: manager.canSendInThisProcess, marksDone: showsMarkDone, tipHint: sendTipHint) {
                manager.perform(.send, in: session)
            }
            if manager.offersSendLater {
                ComposerBarButton(title: "Send later", help: "Send later", enabled: manager.canSendInThisProcess,
                                  shortcut: .sendLater, tipTitle: "Send later") {
                    manager.perform(.sendLater, in: session)
                }
            }
            if let remind = manager.remindButton(for: session) {
                ComposerBarButton(title: manager.remindTitle(session), help: remind.help, enabled: remind.isEnabled,
                                  shortcut: .composeRemind, tipTitle: manager.remindTitle(session),
                                  tipHint: remind.isEnabled ? nil : remind.help) {
                    manager.remind(from: session)
                }
                .accessibilityIdentifier("composer.remindMe")
                if session.pendingReminder != nil {
                    IconButton(symbol: "xmark", help: "Don't remind me", size: ComposerMetrics.lineBand) {
                        session.clearPendingReminder()
                    }
                    .accessibilityIdentifier("composer.remindMe.clear")
                }
            }
        }
        .controlSize(fit.controlSize)
        .fixedSize()
    }

    // Grouped like the window's toolbar: the writing tools in one capsule, Discard on its own
    private var tools: some View {
        HStack(spacing: theme.space3) {
            ComposerToolGroup {
                if manager.aiCenter != nil {
                    AIWordButton { manager.perform(.aiRewrite, in: session) }
                }
                if manager.calendarSidebar != nil {
                    IconButton(symbol: "calendar", help: "Insert free times", shortcut: .calendarInsertAvailability) {
                        manager.perform(.calendarInsertAvailability, in: session)
                    }
                    .accessibilityIdentifier("composer.calendar")
                }
                IconButton(symbol: "curlybraces", help: "Snippets", shortcut: .insertSnippet, tipTitle: "Snippets") {
                    manager.perform(.insertSnippet, in: session)
                }
                IconButton(symbol: session.isPlainText ? "text.alignleft" : "textformat",
                           help: session.isPlainText ? "Plain text: sends without formatting. Click for rich text"
                                                     : "Rich text. Click to send as plain text") {
                    session.setPlainText(!session.isPlainText)
                }
                .accessibilityIdentifier("composer.plainText")
                .accessibilityValue(session.isPlainText ? "Plain text" : "Rich text")
                if manager.chooseFiles != nil {
                    IconButton(symbol: "paperclip", help: "Attach", shortcut: .attachFiles, tipTitle: "Attach",
                               tipHint: String(localized: "(or drag ’n’ drop files)")) {
                        manager.perform(.attachFiles, in: session)
                    }
                }
            }
            ComposerToolGroup {
                IconButton(symbol: "trash", help: "Discard", shortcut: .discardDraft, tipTitle: "Discard") {
                    manager.perform(.discardDraft, in: session)
                }
            }
        }
        .fixedSize()
    }

    private var isLocalOnly: Bool {
        if case .localOnly = session.saveState { true } else { false }
    }

    private var sendHelp: String {
        guard manager.canSendInThisProcess else { return String(localized: "Sending isn't available here") }
        let seconds = manager.undoSendSeconds
        return seconds > 0 ? String(localized: "Send  ⌘↵. Undo is there for \(seconds) s after sending.")
                           : String(localized: "Send  ⌘↵")
    }

    private var sendTipHint: String? {
        guard manager.canSendInThisProcess else { return sendHelp }
        let seconds = manager.undoSendSeconds
        return seconds > 0 ? String(localized: "Undo is there for \(seconds) s after sending.") : nil
    }
}

struct SaveStatusText: View {
    let state: ComposeSession.SaveState
    @Environment(\.theme) private var theme
    @State private var shown: String?
    @State private var savingSince: Date?

    var body: some View {
        HStack(spacing: theme.space3) {
            if let shown {
                Text(shown)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("composer.saveStatus")
            }
        }
        .task(id: state) { await follow(state) }
    }

    private func follow(_ state: ComposeSession.SaveState) async {
        if state == .saving {
            try? await Task.sleep(for: .milliseconds(Int(theme.motionSpinnerDelay)))
            guard !Task.isCancelled else { return }
            shown = state.text
            savingSince = Date()
            return
        }
        if let since = savingSince {
            let left = theme.motionSpinnerMinVisible / 1000 - Date().timeIntervalSince(since)
            if left > 0 {
                try? await Task.sleep(for: .milliseconds(Int(left * 1000)))
                guard !Task.isCancelled else { return }
            }
        }
        savingSince = nil
        shown = state.text
    }
}

struct SendButton: View {
    let enabled: Bool
    var marksDone = false
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.actionDescriptors) private var descriptors

    enum Look: Equatable {
        case prominent
        case unavailable
    }

    static func look(enabled: Bool) -> Look {
        enabled ? .prominent : .unavailable
    }

    // The shortcut written the way the menus write it, so the button teaches it: ⌘↵, ⇧⌘↵
    static func shortcutText(_ keycaps: [String]) -> String? {
        guard !keycaps.isEmpty else { return nil }
        let glyphs = keycaps.map { $0 == "shift" ? "⇧" : $0 }
        let modifiers = menuModifierOrder.filter(glyphs.contains)
        return (modifiers + glyphs.filter { !menuModifierOrder.contains($0) }).joined()
    }

    private static let menuModifierOrder = ["⌃", "⌥", "⇧", "⌘"]

    var body: some View {
        let keys = Self.shortcutText(descriptors.first { $0.id == .send }.map(ShortcutTip.keycaps) ?? [])
        Button(action: action) {
            HStack(spacing: theme.space2) {
                HStack(spacing: theme.space1 + 1) {
                    Text("Send")
                    if marksDone {
                        Text(verbatim: "+").font(.system(size: NativeMetrics.Text.caption)).opacity(0.8)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    }
                }
                .fontWeight(.semibold)
                if let keys {
                    Text(verbatim: keys)
                        .font(.system(size: NativeMetrics.Text.secondary, weight: .regular))
                        .opacity(ComposerMetrics.sendShortcutOpacity)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, theme.space1)
        }
        .modifier(SendButtonLook(look: Self.look(enabled: enabled)))
        .buttonBorderShape(.capsule)
        .shortcutTip(.send, title: marksDone ? String(localized: "Send and mark done") : String(localized: "Send"),
                     hint: tipHint)
        .accessibilityLabel(marksDone ? String(localized: "Send and mark done") : String(localized: "Send"))
        .accessibilityIdentifier("composer.send")
    }
}

private struct SendButtonLook: ViewModifier {
    let look: SendButton.Look
    @Environment(\.theme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        switch look {
        case .prominent:
            content.buttonStyle(.borderedProminent).tint(theme.accentFill.color)
        case .unavailable:
            content.buttonStyle(.bordered).foregroundStyle(theme.textDisabled.color)
        }
    }
}

struct ComposerBarButton: View {
    let title: String
    let help: String
    var enabled = true
    var shortcut: ActionID?
    var tipTitle: String?
    var tipHint: String?
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle((enabled ? theme.textPrimary : theme.textDisabled).color)
                .lineLimit(1)
                .padding(.horizontal, theme.space1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(title)
        .modifier(TextButtonHelp(help: help, shortcut: shortcut, tipTitle: tipTitle, tipHint: tipHint))
    }
}

// A capsule that holds a run of tool buttons, like a group of items in the window's toolbar
struct ComposerToolGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, ComposerMetrics.toolGroupPadding)
            .frame(height: ComposerMetrics.toolGroupHeight)
            .composerToolGroupSurface()
    }
}

struct ComposerToolGroupSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.fill.tertiary, in: Capsule(style: .continuous))
    }
}

extension View {
    func composerToolGroupSurface() -> some View {
        modifier(ComposerToolGroupSurface())
    }
}

struct AIWordButton: View {
    static let pencilSymbol = "pencil"
    static let sparkleSymbol = "sparkle"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                Image(systemName: Self.pencilSymbol)
                    .font(.system(size: ComposerMetrics.toolGlyph, weight: .regular))
                Image(systemName: Self.sparkleSymbol)
                    .font(.system(size: 7, weight: .semibold))
                    .offset(x: -4, y: -3)
            }
        }
        .buttonStyle(ComposerToolStyle())
        .shortcutTip(.aiRewrite, title: "AI")
        .accessibilityLabel("AI")
        .accessibilityIdentifier("composer.ai")
    }
}

struct SnippetPickerView: View {
    let picker: SnippetPickerModel
    let showsSearchField: Bool
    @Environment(\.theme) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSearchField {
                TextField("Search snippets", text: Binding(get: { picker.query }, set: { picker.query = $0 }))
                    .textFieldStyle(.plain)
                    .font(theme.typeBody.swiftUIFont)
                    .padding(.horizontal, theme.space4)
                    .frame(height: ComposerMetrics.snippetRowHeight)
                    .focused($searchFocused)
                    .onSubmit { picker.confirm() }
                    .overlayKeys(up: { picker.moveCursor(by: -1) }, down: { picker.moveCursor(by: 1) },
                                 escape: { picker.close() })
                Divider().overlay(theme.borderHairline.color)
            }
            if picker.isEmpty {
                Text(SnippetPickerModel.emptyText)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .padding(theme.space4)
            } else {
                ForEach(Array(picker.rows.enumerated()), id: \.element.id) { index, row in
                    Button { picker.choose(row.snippet) } label: {
                        HStack(spacing: theme.space4) {
                            Text(row.snippet.name)
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textPrimary.color)
                                .lineLimit(1)
                                .frame(width: ComposerMetrics.snippetNameWidth, alignment: .leading)
                            Text(row.preview)
                                .font(theme.typeBody.swiftUIFont)
                                .foregroundStyle(theme.textSecondary.color)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let shortcut = row.snippet.shortcut { KeycapView(text: ";;" + shortcut) }
                        }
                        .padding(.horizontal, theme.space4)
                        .frame(height: ComposerMetrics.snippetRowHeight)
                        .background(CursorRowBackground(isCursor: index == picker.cursor))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.snippet.name)
                    .accessibilityValue(row.preview)
                }
            }
        }
        .frame(width: ComposerMetrics.snippetPopoverWidth)
        .clipShape(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous))
        .background(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous)
            .fill(theme.component.popover.bg.color))
        .overlay(RoundedRectangle(cornerRadius: CompletionListMetrics.cornerRadius, style: .continuous)
            .strokeBorder(theme.component.popover.border.color, lineWidth: theme.borderWidthHairline))
        .themeShadow(theme.shadow2)
        .onAppear { if showsSearchField { searchFocused = true } }
    }
}

struct LinkConfirmationCard: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bgScrim.color.onTapGesture { session.editLinkRecipients() }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text("Send to these recipients?")
                    .font(theme.typeTitle.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                ForEach(session.linkRecipients ?? [], id: \.self) { address in
                    Text(address.name.map { "\($0) <\(address.email)>" } ?? address.email)
                        .font(theme.typeBody.swiftUIFont)
                        .foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Edit recipients") { session.editLinkRecipients() }
                        .keyboardShortcut(.cancelAction)
                    Button(session.linkScheduleDate == nil ? "Send" : "Schedule") {
                        manager.confirmLinkRecipients(in: session)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(theme.space6)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
            .themeShadow(theme.shadow3)
        }
    }
}

struct SendConfirmationCard: View {
    let session: ComposeSession
    let manager: ComposeManager
    let card: ComposeSession.SendConfirmation
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.bgScrim.color.onTapGesture { session.cancelSendConfirmation() }
            VStack(alignment: .leading, spacing: theme.space4) {
                Text(card.title)
                    .font(theme.typeTitle.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .accessibilityAddTraits(.isHeader)
                Text(card.message)
                    .font(theme.typeBody.swiftUIFont)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Don't ask again") { manager.confirmSend(in: session, stopAsking: true) }
                        .help("Turns off Settings › General › Confirm before sending")
                    Spacer()
                    Button("Cancel") { session.cancelSendConfirmation() }
                        .keyboardShortcut(.cancelAction)
                    Button(card.confirmTitle) { manager.confirmSend(in: session) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(theme.space6)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgElevated.color))
            .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
                .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
            .themeShadow(theme.shadow3)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
