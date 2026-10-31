import MailFeatures
import MailModel
import MailTheme
import SwiftUI

public struct InviteCardView: View {
    let center: InviteCenter
    let message: MessageKey
    let openLink: (URL) -> Void
    @Environment(\.theme) private var theme

    public init(center: InviteCenter, message: MessageKey, openLink: @escaping (URL) -> Void) {
        self.center = center
        self.message = message
        self.openLink = openLink
    }

    public var body: some View {
        if let card = center.card(for: message) {
            VStack(alignment: .leading, spacing: theme.space3) {
                if center.originals.contains(message) {
                    originalToggle(showingOriginal: true)
                } else {
                    switch card.kind {
                    case .reply, .counter: compact(card)
                    default: full(card)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reader.invite")
        }
    }


    private func full(_ card: InviteCard) -> some View {
        VStack(alignment: .leading, spacing: theme.space4) {
            if card.kind == .cancelled {
                cancelledRow
            } else if card.offersRSVP, let state = center.removalStates[message] {
                removalStateRow(state)
                if let note = center.notes[message] {
                    Text(note).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("invite.note")
                }
            } else if card.offersRSVP {
                let block = center.answerBlock(for: message)
                rsvpRow(card, block: block)
                if let question = center.removalQuestion, question.message == message {
                    removalQuestion(question)
                }
                if let block {
                    Label(block, systemImage: "lock.fill")
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(theme.textWarning.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("invite.reason")
                }
                if center.connectPrompt == message { connectPrompt }
                if let note = center.notes[message], note != block {
                    Text(note).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                        .accessibilityIdentifier("invite.note")
                }
            } else if card.isOutdated {
                Text("This invitation was updated. Answer the newest one.")
                    .font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
            }
            VStack(alignment: .leading, spacing: theme.space3) {
                HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                    Text(card.title)
                        .font(theme.typeBodyStrong.swiftUIFont)
                        .foregroundStyle((card.kind == .cancelled ? theme.textTertiary : theme.textPrimary).color)
                        .strikethrough(card.kind == .cancelled)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    if card.isUpdate {
                        Text("Updated").font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                            .padding(.horizontal, theme.space2).padding(.vertical, 1)
                            .background(Capsule().fill(theme.bgSunken.color))
                    }
                }
                row("When") {
                    VStack(alignment: .leading, spacing: theme.space1) {
                        Text(card.when).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color)
                            .textSelection(.enabled)
                        if let repeats = card.repeats {
                            Text(repeats).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                        }
                        if let note = card.whenNote {
                            Text(note).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                        }
                        if let conflict = card.conflict, card.kind == .request {
                            Text(conflict).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textWarning.color)
                                .accessibilityIdentifier("invite.conflict")
                        }
                    }
                }
                if let location = card.location { row("Where") { place(location, link: card.locationLink) } }
                if !card.guests.isEmpty { row("Who") { guests(card) } }
                if let notes = card.notes { row("About") { about(notes) } }
                if let join = card.join, card.kind != .cancelled { joinButton(join) }
            }
            originalToggle(showingOriginal: false)
        }
        .padding(theme.space5)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgSunken.color))
    }

    private var cancelledRow: some View {
        Text("Cancelled")
            .font(theme.typeLabel.swiftUIFont)
            .foregroundStyle(theme.textDanger.color)
            .accessibilityLabel("This event was cancelled")
            .accessibilityIdentifier("invite.cancelled")
    }


    private func rsvpRow(_ card: InviteCard, block: String?) -> some View {
        HStack(spacing: theme.space2) {
            Text("RSVP").font(theme.typeLabel.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                .padding(.trailing, theme.space2)
                .accessibilityHidden(true)
            ForEach([CalendarResponse.accepted, .tentative, .declined], id: \.self) { response in
                rsvpButton(response, selected: card.response == response, block: block)
            }
            Spacer(minLength: theme.space2)
            if card.invite.repeats, block == nil {
                Menu {
                    Button("Yes to all events") { answer(.accepted, wholeSeries: true) }
                    Button("Maybe to all events") { answer(.tentative, wholeSeries: true) }
                    Button("No to all events") { answer(.declined, wholeSeries: true) }
                } label: {
                    Text("More options").font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                }
                .ohBorderlessMenuStyle()
                .fixedSize()
                .help("Answer every event of the series. Yes, Maybe and No answer this event only.")
                .accessibilityLabel("More answers for the whole series")
                .accessibilityIdentifier("invite.moreOptions")
            }
            if block == nil, center.offersRemoval(message), center.removalQuestion?.message != message {
                removeButton
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer the invitation")
        .accessibilityIdentifier("invite.rsvp")
    }

    private func rsvpButton(_ response: CalendarResponse, selected: Bool, block: String?) -> some View {
        let (title, key, spoken) = Self.rsvpText(response)
        return Button { answer(response, wholeSeries: false) } label: {
            Text(title)
                .font(theme.typeLabel.swiftUIFont.weight(selected ? .semibold : .medium))
                .tracking(0.6)
                .foregroundStyle((selected ? theme.accentText : theme.textPrimary).color)
                .padding(.horizontal, theme.space3)
                .padding(.vertical, theme.space1)
                .background(Capsule().fill((selected ? theme.bgRowSelected : theme.bgWindow).color))
                .overlay(Capsule().strokeBorder((selected ? theme.accentFill : theme.borderControl).color,
                                                lineWidth: theme.borderWidthHairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(block != nil)
        .help(block ?? "\(spoken) (\(key)). Google tells the organizer after a few seconds; Undo (⌘Z) stops it. The conversation is marked done.")
        .accessibilityLabel(spoken)
        .accessibilityValue(selected ? "Current answer" : "")
        .accessibilityHint(block ?? "Answers the invitation and marks the conversation done. Shortcut \(key).")
        .accessibilityIdentifier("invite.rsvp.\(response.rawValue)")
    }

    static func rsvpText(_ response: CalendarResponse) -> (String, String, String) {
        switch response {
        case .accepted: ("YES", "⇧A", "Yes, I'll attend")
        case .declined: ("NO", "⇧D", "No, I won't attend")
        default: ("MAYBE", "⇧T", "Maybe")
        }
    }

    private func answer(_ response: CalendarResponse, wholeSeries: Bool) {
        let center = center
        let message = message
        Task { await center.respond(response, to: message, wholeSeries: wholeSeries) }
    }

    // Next to the answers, quieter than them: removing is the uncommon choice and is confirmed first.
    private var removeButton: some View {
        Button { center.askToRemove(message) } label: {
            Label("Remove", systemImage: "calendar.badge.minus")
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
        }
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Remove it from your calendar without answering (⇧X). Mail sends no reply.")
        .accessibilityLabel("Remove from calendar")
        .accessibilityHint("Asks first. Removes your copy of the event without answering. Shortcut ⇧X.")
        .accessibilityIdentifier("invite.remove")
    }

    // A system group box sets the question apart from the card without drawing its own chrome.
    private func removalQuestion(_ question: InviteRemovalQuestion) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: theme.space3) {
                Text(question.text)
                    .font(theme.typeMeta.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("invite.remove.text")
                HStack(spacing: theme.space2) {
                    ForEach(question.scopes, id: \.self) { scope in
                        Button(role: .destructive) {
                            let center = center
                            Task { await center.confirmRemoval(scope, question: question.id) }
                        } label: {
                            Text(question.buttonTitle(scope)).font(theme.typeLabel.swiftUIFont)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("invite.remove.\(scope.rawValue)")
                    }
                    Button("Cancel") { center.cancelRemoval() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("invite.remove.cancel")
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Remove from calendar")
        .accessibilityIdentifier("invite.removeQuestion")
    }

    @ViewBuilder
    private func removalStateRow(_ state: InviteRemovalState) -> some View {
        switch state {
        case .pending:
            Label("Removing from your calendar… Undo (⌘Z) keeps it.", systemImage: "calendar.badge.minus")
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("invite.removing")
        case .removed:
            Label("Removed from your calendar. It stays on the organizer's calendar.", systemImage: "calendar.badge.minus")
                .font(theme.typeMeta.swiftUIFont)
                .foregroundStyle(theme.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("invite.removed")
        }
    }

    private var connectPrompt: some View {
        HStack(spacing: theme.space2) {
            Button("Connect calendar to respond") { center.openCalendarSettings() }
                .ohLinkButtonStyle()
                .font(theme.typeMeta.swiftUIFont)
                .help("Opens Settings › Calendar, where this account's calendar connects.")
                .accessibilityIdentifier("invite.connect")
            Button { center.dismissConnectPrompt() } label: {
                Image(systemName: "xmark").font(theme.typeCaption.swiftUIFont).foregroundStyle(theme.textTertiary.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }


    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space4) {
            Text(label)
                .font(theme.typeCaption.swiftUIFont.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(theme.textTertiary.color)
                .frame(width: 52, alignment: .leading)
            content()
        }
        .accessibilityElement(children: .combine)
    }

    private func place(_ location: String, link: URL?) -> some View {
        Group {
            if let link {
                Button { openLink(link) } label: {
                    Text(location).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.accentText.color)
                        .multilineTextAlignment(.leading).lineLimit(3)
                }
                .buttonStyle(.plain)
                .help(link.host(percentEncoded: false) == "maps.apple.com" ? "Show in Maps" : link.absoluteString)
                .accessibilityLabel("\(location), show in Maps")
                .accessibilityIdentifier("invite.where")
            } else {
                Text(location).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color)
            }
        }
    }

    private func guests(_ card: InviteCard) -> some View {
        let all = card.guests
        let expanded = center.expandedGuests.contains(message)
        let shown = expanded ? all : Array(all.prefix(InviteCardBuilder.visibleGuests))
        return VStack(alignment: .leading, spacing: theme.space1) {
            ForEach(shown) { guest in
                HStack(spacing: theme.space2) {
                    Image(systemName: Self.symbol(guest.response))
                        .font(theme.typeCaption.swiftUIFont)
                        .foregroundStyle(Self.tint(guest.response, theme).color)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(guest.title).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1).truncationMode(.middle)
                    if guest.isOrganizer {
                        Text("organizer").font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                    } else if guest.isOptional {
                        Text("optional").font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textTertiary.color)
                    }
                }
                .help(guest.email)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(guest))
            }
            if all.count > shown.count {
                Button("and \(all.count - shown.count) more") { center.toggleGuests(message) }
                    .ohLinkButtonStyle().font(theme.typeMeta.swiftUIFont)
            }
        }
    }

    static func symbol(_ response: CalendarResponse?) -> String {
        switch response {
        case .accepted?: "checkmark.circle.fill"
        case .declined?: "xmark.circle.fill"
        case .tentative?: "questionmark.circle.fill"
        default: "circle"
        }
    }

    static func tint(_ response: CalendarResponse?, _ theme: ResolvedTheme) -> ThemeColor {
        switch response {
        case .accepted?: theme.textSuccess
        case .declined?: theme.textDanger
        case .tentative?: theme.textWarning
        default: theme.textTertiary
        }
    }

    static func spoken(_ guest: InviteCard.Guest) -> String {
        var parts = [guest.isMe ? "You" : guest.title]
        if guest.isOrganizer { parts.append("organizer") }
        if guest.isOptional { parts.append("optional") }
        switch guest.response {
        case .accepted?: parts.append("accepted")
        case .declined?: parts.append("declined")
        case .tentative?: parts.append("maybe")
        default: parts.append("no answer yet")
        }
        return parts.joined(separator: ", ")
    }

    private func about(_ notes: String) -> some View {
        let open = center.expandedNotes.contains(message)
        let long = notes.count > 240 || notes.split(separator: "\n").count > 3
        return VStack(alignment: .leading, spacing: theme.space1) {
            Text(notes).font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textPrimary.color)
                .lineLimit(open || !long ? nil : 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if long {
                Button(open ? "Show less" : "Show more") { center.toggleNotes(message) }
                    .ohLinkButtonStyle().font(theme.typeMeta.swiftUIFont)
                    .accessibilityIdentifier("invite.showMore")
            }
        }
    }

    private func joinButton(_ join: InviteCard.Join) -> some View {
        Button { openLink(join.url) } label: {
            Label(join.title, systemImage: "video.fill")
                .font(theme.typeLabel.swiftUIFont)
                .foregroundStyle(theme.accentOnFill.color)
                .padding(.horizontal, theme.space4)
                .padding(.vertical, theme.space2)
                .background(Capsule().fill(theme.accentFill.color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(join.url.host(percentEncoded: false) ?? join.title)
        .accessibilityLabel(join.title)
        .accessibilityIdentifier("invite.join")
    }

    private func originalToggle(showingOriginal: Bool) -> some View {
        Button(showingOriginal ? "Show invitation" : "Show original") { center.toggleOriginal(message) }
            .ohLinkButtonStyle()
            .font(theme.typeMeta.swiftUIFont)
            .help(showingOriginal ? "Back to the invitation card." : "Shows the email as the sender wrote it.")
            .accessibilityIdentifier("invite.showOriginal")
    }


    private func compact(_ card: InviteCard) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                Image(systemName: card.kind == .counter ? "clock.arrow.circlepath"
                      : Self.symbol(card.invite.attendees.first?.response))
                    .foregroundStyle((card.kind == .counter ? theme.textSecondary
                                      : Self.tint(card.invite.attendees.first?.response, theme)).color)
                    .accessibilityHidden(true)
                Text(card.compactLine ?? card.title).font(theme.typeBodyStrong.swiftUIFont)
                    .foregroundStyle(theme.textPrimary.color)
                Text("· \(card.title)").font(theme.typeBody.swiftUIFont).foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("invite.reply")
            Text(card.when).font(theme.typeMeta.swiftUIFont).foregroundStyle(theme.textSecondary.color)
            originalToggle(showingOriginal: false)
        }
    }
}
