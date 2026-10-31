import MailFeatures
import MailModel
import MailTheme
import SwiftUI

// One meeting on several connected calendars: which account holds which copy, where changes are saved, and an answer
// on each copy the user was invited on
struct CalendarEventCardCopiesView: View {
    let card: CalendarEventCard
    let model: CalendarWindowModel
    @Environment(\.theme) private var theme

    static let dotSize: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            Text("On \(card.copies.count) of your calendars")
                .themeFont(theme.typeLabel).foregroundStyle(theme.textSecondary.color)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(card.copies.enumerated()), id: \.element.id) { index, row in
                copyRow(row, index: index)
            }
            if let note = card.copiesNote {
                HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 11))
                        .foregroundStyle(theme.textWarning.color)
                        .accessibilityHidden(true)
                    Text(verbatim: note).themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("calendar.card.copies.timeNote")
            }
        }
        .padding(.horizontal, CalendarFormMetrics.rowPaddingX)
        .padding(.vertical, theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: CalendarFormMetrics.sectionRadius, style: .continuous)
            .fill(theme.textPrimary.color.opacity(CalendarFormMetrics.sectionFillOpacity)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On \(card.copies.count) of your calendars")
        .accessibilityIdentifier("calendar.card.copies")
    }

    private func copyRow(_ row: CalendarCopyRow, index: Int) -> some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
                Circle().fill(CalendarDayView.calendarColor(model.colorIndex(for: row.event), theme: theme))
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.account).themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
                        .lineLimit(1).truncationMode(.middle)
                        .help(row.account)
                    Text(verbatim: Self.statusLine(row)).themeFont(theme.typeCaption)
                        .foregroundStyle(theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("calendar.card.copy.\(index)")
            if row.canRespond {
                HStack(spacing: theme.space2) {
                    ForEach(CalendarCardMode.rsvpOrder, id: \.self) { choice in
                        CalendarAnswerPill(title: choice.title, chosen: row.response == choice) {
                            Task { await model.respond(choice, onCopy: row.id) }
                        }
                        .accessibilityIdentifier("calendar.card.copy.\(index).rsvp.\(choice.rawValue)")
                    }
                }
                .padding(.leading, Self.dotSize + theme.space2)
                .help(String(localized: "Answers as \(row.account). Google tells the organizer after a few seconds (Undo ⌘Z stops it)."))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Going? Answer as \(row.account)")
            }
        }
    }

    static func statusLine(_ row: CalendarCopyRow) -> String {
        var parts = [row.status]
        if let time = row.timeText { parts.append(String(localized: "shows \(time)")) }
        if row.receivesChanges { parts.append(String(localized: "changes are saved here")) }
        return parts.joined(separator: " · ")
    }
}
