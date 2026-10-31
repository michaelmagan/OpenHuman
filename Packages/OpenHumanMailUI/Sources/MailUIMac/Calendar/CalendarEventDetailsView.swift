import AppKit
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import SwiftUI

struct CalendarEventDetailsOverlay: View {
    let model: CalendarSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme

    var body: some View {
        if let details = model.openedDetails {
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    CalendarEventDetailsView(details: details,
                                             onClose: { byKeyboard in model.closeEvent(keepsFocus: byKeyboard) },
                                             onEdit: details.canOpenEditor ? { edit(details) } : nil)
                }
                .frame(maxHeight: max(proxy.size.height - 2 * theme.space4, 160))
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG))
                .themeShadow(theme.component.popover.shadow)
                .padding(theme.space4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func edit(_ details: CalendarEventDetails) {
        guard let window = router.environment.calendarWindow else { return }
        model.closeEvent()
        Task { await window.openEditor(for: details.event, calendarKey: details.calendarKey) }
    }
}

struct CalendarEventDetailsView: View {
    let details: CalendarEventDetails
    var onClose: (_ byKeyboard: Bool) -> Void = { _ in }
    var onEdit: (() -> Void)?
    @Environment(\.theme) private var theme
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            header
            CalendarEventDetailRows(details: details, colorIndex: details.colorIndex, idPrefix: "calendar.details",
                                    compact: true)
            if let answer = details.answerText {
                Text(verbatim: answer).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
                    .padding(.leading, CalendarDraftEditor.iconColumn)
                    .accessibilityIdentifier("calendar.details.answer")
            }
            if let organizer = details.organizerText {
                Text(verbatim: organizer).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, CalendarDraftEditor.iconColumn)
                    .accessibilityIdentifier("calendar.details.organizer")
            }
            if let onEdit {
                Button("Edit in Calendar", action: onEdit)
                    .help("Opens this event in Calendar to change it")
                    .padding(.leading, CalendarDraftEditor.iconColumn)
                    .accessibilityIdentifier("calendar.details.edit")
            }
        }
        .padding(theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
            .strokeBorder(theme.component.popover.border.color, lineWidth: theme.borderWidthHairline))
        .onExitCommand { onClose(true) }
        .onAppear { titleFocused = true }
        .onChange(of: details.event.id) { titleFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details of \(details.title)")
        .accessibilityIdentifier("calendar.details")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            RoundedRectangle(cornerRadius: theme.radiusXS)
                .fill(CalendarDayView.calendarColor(details.colorIndex, theme: theme))
                .frame(width: 10, height: 10)
                .frame(width: CalendarDraftEditor.iconColumn - theme.space2, alignment: .leading)
                .accessibilityHidden(true)
            Text(verbatim: details.title).themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .accessibilityIdentifier("calendar.details.title")
            Spacer(minLength: 0)
            Button { onClose(false) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary.color)
            .help("Close  Esc")
            .accessibilityLabel("Close event details")
            .accessibilityIdentifier("calendar.details.close")
        }
    }

    static func shortLink(_ url: URL) -> String {
        let text = url.absoluteString
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            return String(text.dropFirst(scheme.count))
        }
        return text
    }
}

struct CalendarEventDetailRows: View {
    let details: CalendarEventDetails
    let colorIndex: Int
    let idPrefix: String
    var compact = false
    var showsZone = true
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var showsAllGuests = false
    @State private var showsAllNotes = false

    static let guestPreview = 6
    static let notesPreviewLines = 10

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? theme.space3 : theme.space4) {
            when
            if let link = details.joinLink { join(link) }
            if let place = details.location {
                row(symbol: "mappin.and.ellipse") {
                    Text(verbatim: place).foregroundStyle(theme.textPrimary.color)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location: \(place)")
                .accessibilityIdentifier("\(idPrefix).location")
            }
            guests
            notes
            calendarRow
        }
        .onChange(of: details.event.id) {
            showsAllGuests = false
            showsAllNotes = false
        }
    }

    private var when: some View {
        row(symbol: "clock") {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: [details.dayText, details.timeText].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(theme.textPrimary.color)
                ForEach([showsZone ? details.zoneText : nil, details.eventZoneText, details.repeatText].compactMap { $0 },
                        id: \.self) { line in
                    Text(verbatim: line).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([details.spokenTime, details.repeatText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("\(idPrefix).time")
    }

    private func join(_ link: URL) -> some View {
        row(symbol: "video") {
            HStack(alignment: .center, spacing: theme.space3) {
                Button("Join Google Meet") { openURL(link) }
                    .buttonStyle(CalendarJoinButtonStyle())
                    .help(link.absoluteString)
                    .accessibilityIdentifier(idPrefix == "calendar.card" ? "calendar.card.meet" : "\(idPrefix).join")
                Text(verbatim: CalendarEventDetailsView.shortLink(link))
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var guests: some View {
        if let summary = details.guestSummary {
            let shown = showsAllGuests ? details.guests : Array(details.guests.prefix(Self.guestPreview))
            row(symbol: "person.2") {
                VStack(alignment: .leading, spacing: theme.space2) {
                    Text(verbatim: summary).foregroundStyle(theme.textPrimary.color)
                    ForEach(shown) { guest in CalendarGuestRow(guest: guest) }
                    if details.guests.count > shown.count {
                        Button("Show all \(details.guests.count) guests") { showsAllGuests = true }
                            .buttonStyle(.link)
                            .themeFont(theme.typeMeta)
                            .accessibilityIdentifier("\(idPrefix).allGuests")
                    }
                    if let note = details.guestListNote {
                        Text(verbatim: note).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(idPrefix).guestListNote")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(summary)
            .accessibilityIdentifier(idPrefix == "calendar.card" ? "calendar.card.attendees" : "\(idPrefix).guests")
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let parsed = details.notes {
            row(symbol: "text.alignleft") {
                VStack(alignment: .leading, spacing: theme.space1) {
                    Text(CalendarDescription.attributed(parsed.document))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(showsAllNotes ? nil : Self.notesPreviewLines)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let safe = CalendarDescription.openableURL(url) else { return .discarded }
                            openURL(safe)
                            return .handled
                        })
                    if !showsAllNotes, parsed.editableText.split(separator: "\n", omittingEmptySubsequences: false).count
                        > Self.notesPreviewLines || parsed.editableText.count > Self.notesPreviewLines * 60 {
                        Button("Show more") { showsAllNotes = true }
                            .buttonStyle(.link)
                            .themeFont(theme.typeMeta)
                            .accessibilityIdentifier("\(idPrefix).moreNotes")
                    }
                }
            }
            .accessibilityIdentifier("\(idPrefix).notes")
        }
    }

    private var calendarRow: some View {
        row(symbol: "calendar") {
            HStack(spacing: theme.space2) {
                Circle().fill(CalendarDayView.calendarColor(colorIndex, theme: theme))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: details.calendarName).foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calendar: \(details.calendarName)")
        .accessibilityIdentifier("\(idPrefix).calendar")
    }

    private func row<Content: View>(symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(theme.textTertiary.color)
                .frame(width: CalendarDraftEditor.iconColumn - theme.space2, alignment: .leading)
                .accessibilityHidden(true)
            content()
        }
        .themeFont(compact ? theme.typeMeta : theme.typeBody)
    }
}

struct CalendarGuestRow: View {
    let guest: CalendarEventDetails.Guest
    @Environment(\.theme) private var theme

    static let avatarSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .center, spacing: theme.space2) {
            avatar
            Text(verbatim: guest.name ?? guest.email).foregroundStyle(theme.textPrimary.color)
                .lineLimit(1).truncationMode(.middle)
            if let marker {
                Text(verbatim: marker).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 0)
        }
        .help(guest.email)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(guest.isOrganizer ? String(localized: "\(guest.spokenText), organizer") : guest.spokenText)
    }

    private var marker: String? {
        let parts = [guest.isOrganizer ? String(localized: "organizer") : nil, guest.isMe ? String(localized: "you") : nil,
                     guest.isOptional ? String(localized: "optional") : nil]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var avatar: some View {
        let initials = ThreadRowFormatting().initials(name: guest.name, email: guest.email)
        return Text(verbatim: initials)
            .themeFont(theme.typeCaption)
            .minimumScaleFactor(0.7)
            .foregroundStyle(theme.component.avatar.text.color)
            .frame(width: Self.avatarSize, height: Self.avatarSize)
            .background(Circle().fill(theme.component.avatar.bg.color))
            .overlay(Circle().strokeBorder(theme.component.avatar.ring.color, lineWidth: theme.borderWidthHairline))
            .overlay(alignment: .bottomTrailing) { badge.offset(x: 3, y: 3) }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        if let style = badgeStyle {
            Image(systemName: style.symbol).font(.system(size: 6, weight: .heavy)).foregroundStyle(theme.bgWindow.color)
                .frame(width: 12, height: 12)
                .background(Circle().fill(style.color.color))
                .overlay(Circle().strokeBorder(theme.bgWindow.color, lineWidth: 1.5))
        }
    }

    private var badgeStyle: (symbol: String, color: ThemeColor)? {
        switch guest.response {
        case .accepted: ("checkmark", theme.textSuccess)
        case .tentative: ("questionmark", theme.textWarning)
        case .declined: ("xmark", theme.textDanger)
        case .needsAction, nil: nil
        }
    }
}

struct CalendarJoinButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .themeFont(theme.typeLabel)
            .fontWeight(.semibold)
            .foregroundStyle(theme.accentOnFill.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, theme.space4)
            .frame(height: 26)
            .background(Capsule().fill((configuration.isPressed ? theme.accentFillHover : theme.accentFill).color))
            .contentShape(Capsule())
    }
}
