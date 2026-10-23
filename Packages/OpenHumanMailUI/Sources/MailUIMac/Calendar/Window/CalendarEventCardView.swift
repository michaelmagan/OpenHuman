import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarEventCardView: View {
    @Bindable var model: CalendarWindowModel
    let width: CGFloat
    var maxHeight: CGFloat = 640
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var editing = false
    @FocusState private var notesFocused: Bool

    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 52

    var body: some View {
        if let card = model.card {
            let mode = CalendarCardMode.make(card, userAskedToEdit: editing)
            let footer = hasFooter(card, mode)
            VStack(alignment: .leading, spacing: 0) {
                header(card, mode)
                CalendarCardScroll(width: width) {
                    content(card, mode)
                        .padding(.horizontal, mode == .form ? theme.space4 : theme.space5)
                        .padding(.top, mode == .detail ? theme.space1 : theme.space2)
                        .padding(.bottom, theme.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: max(maxHeight - Self.headerHeight - (footer ? Self.footerHeight : 0), 120))
                .fixedSize(horizontal: false, vertical: true)
                if footer { footerBar(card, mode) }
            }
            .onExitCommand { model.closeCard() }
            .onChange(of: card.event.id) { editing = false }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(card.event.title)
            .accessibilityHint(mode == .detail ? (card.reason ?? "") : "")
            .accessibilityIdentifier("calendar.card")
        }
    }

    private func color(_ card: CalendarEventCard) -> Color {
        CalendarDayView.calendarColor(model.colorIndex(for: card.event), theme: theme)
    }

    private func header(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> some View {
        HStack(alignment: .center, spacing: theme.space3) {
            Circle().fill(color(card)).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(verbatim: headerTitle(card, mode))
                .themeFont(theme.typeLabel).foregroundStyle(theme.textSecondary.color)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: theme.space2)
            moreMenu(card, mode)
            Button { model.closeCard() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.textPrimary.color.opacity(CalendarFormMetrics.sectionFillOpacity * 2)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary.color)
            .help("Close  Esc")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("calendar.card.close")
        }
        .padding(.leading, theme.space5)
        .padding(.trailing, theme.space3)
        .frame(height: Self.headerHeight)
    }

    private func headerTitle(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> String {
        if card.pendingMove != nil { return String(localized: "Move event") }
        let calendar = card.calendarKey.isEmpty ? model.sidebar.providerName : card.calendarKey
        switch mode {
        case .detail: return calendar
        case .form, .legacyEdit: return card.event.id.isEmpty ? String(localized: "New event") : calendar
        }
    }

    @ViewBuilder
    private func moreMenu(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> some View {
        let offersEdit = CalendarCardMode.offersEdit(card, mode: mode)
        let duplicates = mode == .form && !card.event.id.isEmpty && card.rights.hasAnyEditable && card.pendingMove == nil
        let link = card.event.meetLink
        let removal = removal(card, mode)
        if offersEdit || duplicates || link != nil || removal != nil {
            Menu {
                if offersEdit {
                    Button("Edit…") { editing = true }.accessibilityIdentifier("calendar.card.edit")
                }
                if duplicates {
                    Button("Duplicate") { Task { await model.duplicateCardEvent() } }
                        .accessibilityIdentifier("calendar.card.duplicate")
                }
                if let link {
                    Button("Copy Meet link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                }
                if let removal {
                    Divider()
                    removalItem(removal)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .tint(theme.textSecondary.color)
            .foregroundStyle(theme.textSecondary.color)
            .help("More")
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("calendar.card.more")
        }
    }

    private func removal(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> CalendarDeleteRight? {
        guard card.pendingMove == nil, !card.event.id.isEmpty else { return nil }
        if card.form != nil { return card.rights.delete }
        return card.canRemove ? .delete : nil
    }

    @ViewBuilder
    private func removalItem(_ removal: CalendarDeleteRight) -> some View {
        switch removal {
        case .delete:
            Button("Delete…", role: .destructive) { model.askToRemoveCardEvent() }
                .accessibilityIdentifier("calendar.card.delete")
        case .declineInstead(let why):
            Button("Decline") { Task { await model.declineInsteadOfDelete() } }
                .help(why).accessibilityIdentifier("calendar.card.decline")
        case .unavailable(let why):
            Button("Delete") {}.disabled(true).help(why)
                .accessibilityLabel("Delete unavailable: \(why)").accessibilityIdentifier("calendar.card.deleteDisabled")
        }
    }

    @ViewBuilder
    private func content(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> some View {
        switch mode {
        case .detail: detail(card)
        case .form: formBody(card)
        case .legacyEdit: legacyBody(card)
        }
    }

    private func detail(_ card: CalendarEventCard) -> some View {
        let details = CalendarEventDetails(event: card.event, timeZone: model.cardTimeZone,
                                           calendarName: card.calendarKey.isEmpty ? model.sidebar.providerName : card.calendarKey,
                                           calendarKey: card.calendarKey,
                                           myAddresses: card.calendarKey.isEmpty ? [] : [card.calendarKey],
                                           myResponse: card.response)
        return VStack(alignment: .leading, spacing: theme.space4) {
            Text(verbatim: details.title).themeFont(theme.typeTitle).foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar.card.title")
            CalendarEventDetailRows(details: details, colorIndex: model.colorIndex(for: card.event), idPrefix: "calendar.card",
                                    showsZone: false)
            if card.event.hidesMyResponse {
                Text(verbatim: CalendarEvent.responseNotShown).themeFont(theme.typeMeta)
                    .foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.card.responseNotShown")
            }
            note(card)
        }
    }

    @ViewBuilder
    private func note(_ card: CalendarEventCard) -> some View {
        if let note = card.note, note != card.reason, note != card.rights.summary {
            Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("calendar.card.note")
        }
    }

    private func formBody(_ card: CalendarEventCard) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            if let move = card.pendingMove { pendingHeader(move, card) }
            CalendarEventFormView(
                form: Binding(get: { model.card?.form ?? card.form! }, set: { model.card?.form = $0 }),
                rights: card.rights, timeZone: model.cardTimeZone, idPrefix: "calendar.card",
                meetLink: card.event.meetLink,
                calendarChoices: model.sources.map { (key: $0.key, title: $0.title) },
                asksSendUpdates: model.asksSendUpdates(for: card),
                sendUpdates: Binding(get: { model.sendUpdates(for: model.card ?? card) },
                                     set: { model.chooseSendUpdates($0) }),
                calendarName: card.calendarKey.isEmpty ? model.sidebar.providerName : card.calendarKey,
                suggestGuests: { [sidebar = model.sidebar] prefix in await sidebar.guestSuggestions(prefix) },
                pendingGuest: Binding(get: { model.card?.pendingGuest ?? "" }, set: { model.card?.pendingGuest = $0 }),
                pendingGuestNote: card.pendingGuestNote)
                .id(card.event.id)
            note(card)
        }
    }

    private func pendingHeader(_ move: CalendarPendingMove, _ card: CalendarEventCard) -> some View {
        let shown = card.form
        return VStack(alignment: .leading, spacing: theme.space1) {
            Text(move.kind == .resized ? "Change the length?" : "Move this event?")
                .themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
            Grid(alignment: .leading, horizontalSpacing: theme.space3, verticalSpacing: 2) {
                GridRow {
                    Text("From").foregroundStyle(theme.textTertiary.color)
                    Text(CalendarPendingMove.line(move.originalStart, move.originalEnd, zone: model.cardTimeZone))
                        .foregroundStyle(theme.textSecondary.color).strikethrough(true, color: theme.textTertiary.color)
                }
                GridRow {
                    Text("To").foregroundStyle(theme.textTertiary.color)
                    Text(CalendarPendingMove.line(shown?.start ?? move.proposedStart, shown?.end ?? move.proposedEnd,
                                                  zone: model.cardTimeZone))
                        .foregroundStyle(theme.textPrimary.color)
                }
            }
            .themeFont(theme.typeMeta)
            Text("Nothing changes until you accept.")
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
        .padding(.horizontal, CalendarFormMetrics.rowPaddingX)
        .padding(.vertical, theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CalendarFormMetrics.sectionRadius, style: .continuous)
            .fill(theme.accentSubtle.color))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.card.pendingMove")
    }

    private func legacyBody(_ card: CalendarEventCard) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            title(card)
            timeRow(card)
            attendees(card)
            if let link = card.event.meetLink {
                fieldRow(symbol: "video") {
                    Button("Join Google Meet") { openURL(link) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("calendar.card.meet")
                }
            }
            place(card)
            notes(card)
            note(card)
        }
    }

    @ViewBuilder
    private func title(_ card: CalendarEventCard) -> some View {
        if card.canEditDetails {
            TextField("Title", text: binding(\.title, card))
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("calendar.card.title")
        } else {
            Text(card.event.title).themeFont(theme.typeTitle).foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lockedReason(card.reason)
                .accessibilityIdentifier("calendar.card.title")
        }
    }

    private func timeRow(_ card: CalendarEventCard) -> some View {
        fieldRow(symbol: "clock") {
            if card.canMove {
                VStack(alignment: .leading, spacing: theme.space1) {
                    DatePicker("Day", selection: startBinding(card), displayedComponents: .date).labelsHidden()
                    HStack(spacing: theme.space2) {
                        DatePicker("Starts", selection: startBinding(card), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Text(verbatim: "–").foregroundStyle(theme.textTertiary.color)
                        DatePicker("Ends", selection: binding(\.end, card), in: card.start...,
                                   displayedComponents: .hourAndMinute).labelsHidden()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.event.start.formatted(Date.FormatStyle(timeZone: model.timeZone)
                        .weekday(.wide).month(.wide).day()))
                        .themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
                    Text(model.timeText(card.event)).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                }
                .lockedReason(card.reason)
            }
        }
        .accessibilityIdentifier("calendar.card.time")
    }

    @ViewBuilder
    private func attendees(_ card: CalendarEventCard) -> some View {
        if !card.event.attendees.isEmpty {
            fieldRow(symbol: "person.2") {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(card.event.attendees, id: \.email) { person in
                        Text(person.name.map { "\($0) <\(person.email)>" } ?? person.email)
                            .themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .accessibilityIdentifier("calendar.card.attendees")
        }
    }

    @ViewBuilder
    private func place(_ card: CalendarEventCard) -> some View {
        if card.canEditDetails {
            fieldRow(symbol: "mappin.and.ellipse") {
                TextField("Location", text: binding(\.location, card)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("calendar.card.location")
            }
        } else if let location = card.event.location {
            fieldRow(symbol: "mappin.and.ellipse") {
                Text(location).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func notes(_ card: CalendarEventCard) -> some View {
        if card.canEditDetails {
            fieldRow(symbol: "text.alignleft") {
                TextEditor(text: binding(\.notes, card))
                    .focused($notesFocused)
                    .calendarTextArea(text: (model.card ?? card).notes, prompt: "Agenda or notes", focused: notesFocused)
                    .accessibilityLabel("Agenda or notes")
                    .accessibilityIdentifier("calendar.card.notes")
            }
        } else if let notes = card.event.notes {
            fieldRow(symbol: "text.alignleft") {
                Text(notes).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    .lineLimit(8).textSelection(.enabled)
            }
        }
    }

    private func hasFooter(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> Bool {
        card.event.canRespond || mode == .form || mode == .legacyEdit
    }

    private func footerBar(_ card: CalendarEventCard, _ mode: CalendarCardMode) -> some View {
        HStack(spacing: theme.space2) {
            if card.event.canRespond { answers(card) }
            Spacer(minLength: theme.space2)
            switch mode {
            case .form: formActions(card)
            case .legacyEdit: legacyActions(card)
            case .detail: EmptyView()
            }
        }
        .padding(.horizontal, theme.space5)
        .frame(height: Self.footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
        }
    }

    private func answers(_ card: CalendarEventCard) -> some View {
        HStack(spacing: theme.space2) {
            Text("Going?").themeFont(theme.typeLabel).foregroundStyle(theme.textSecondary.color)
                .padding(.trailing, theme.space1)
            ForEach(CalendarCardMode.rsvpOrder, id: \.self) { choice in
                CalendarAnswerPill(title: choice.title, chosen: card.response == choice) {
                    Task { await model.respond(choice) }
                }
                .disabled(!card.canRespond)
                .accessibilityIdentifier("calendar.card.rsvp.\(choice.rawValue)")
            }
        }
        .help(card.canRespond ? String(localized: "Google tells the organizer after a few seconds (Undo ⌘Z stops it).")
                              : (card.reason ?? ""))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Going?")
    }

    @ViewBuilder
    private func formActions(_ card: CalendarEventCard) -> some View {
        let editable = card.rights.hasAnyEditable
        let accepting = card.pendingMove != nil
        Button(editable ? "Cancel" : "Close") { model.closeCard() }
            .help(editable ? "Cancel the changes  Esc" : "Close  Esc")
            .accessibilityIdentifier("calendar.card.cancel")
        if editable {
            // Why: Return types a new line in the notes and adds a guest, so Save takes Command-Return
            Button(accepting ? "Accept" : "Save") { Task { await model.saveCard() } }
                .buttonStyle(.borderedProminent).tint(theme.accentFill.color)
                .keyboardShortcut(accepting ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
                .disabled(!card.hasChanges)
                .help(accepting ? "Accept the change  ↵" : "Save the changes  ⌘↵")
                .accessibilityHint(accepting ? "" : String(localized: "Command-Return"))
                .accessibilityIdentifier(accepting ? "calendar.card.accept" : "calendar.card.save")
        }
    }

    @ViewBuilder
    private func legacyActions(_ card: CalendarEventCard) -> some View {
        Button("Cancel") { model.closeCard() }
            .help("Cancel the changes  Esc").accessibilityIdentifier("calendar.card.cancel")
        Button("Save") { Task { await model.saveCard() } }
            .buttonStyle(.borderedProminent)
            .tint(theme.accentFill.color)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!card.hasChanges)
            .help("Save the changes  ⌘↵")
            .accessibilityIdentifier("calendar.card.save")
    }

    private func fieldRow<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.textTertiary.color)
                .frame(width: CalendarDraftEditor.iconColumn - theme.space2, alignment: .leading)
                .accessibilityHidden(true)
            content()
        }
        .themeFont(theme.typeMeta)
    }

    private func binding<Value>(_ path: WritableKeyPath<CalendarEventCard, Value>,
                                _ shown: CalendarEventCard) -> Binding<Value> {
        Binding(get: { (model.card ?? shown)[keyPath: path] }, set: { model.card?[keyPath: path] = $0 })
    }

    private func startBinding(_ shown: CalendarEventCard) -> Binding<Date> {
        Binding(get: { (model.card ?? shown).start }, set: { start in
            guard var card = model.card else { return }
            let length = max(card.end.timeIntervalSince(card.start), CalendarDragMath.step)
            card.start = start
            card.end = start.addingTimeInterval(length)
            model.card = card
        })
    }
}

struct CalendarAnswerPill: View {
    let title: String
    let chosen: Bool
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .themeFont(chosen ? theme.typeBodyStrong : theme.typeBody)
                .foregroundStyle(textColor.color)
                .padding(.horizontal, theme.space4)
                .frame(minWidth: 52, minHeight: 28)
                .background(Capsule().fill(fillColor))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var textColor: ThemeColor {
        if !isEnabled { return chosen ? theme.textSecondary : theme.textDisabled }
        return chosen ? theme.accentOnFill : theme.textPrimary
    }

    private var fillColor: Color {
        if chosen { return (isEnabled ? theme.accentFill : theme.bgSunken).color }
        return (hovered && isEnabled ? theme.bgRowHover : theme.bgSunken).color
    }
}

extension View {
    @ViewBuilder
    func lockedReason(_ reason: String?) -> some View {
        if let reason, !reason.isEmpty {
            self.help(reason).accessibilityHint(reason)
        } else {
            self
        }
    }
}
