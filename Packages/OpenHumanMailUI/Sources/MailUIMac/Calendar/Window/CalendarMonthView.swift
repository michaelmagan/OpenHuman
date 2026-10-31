import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarMonthView: View {
    @Bindable var model: CalendarWindowModel
    @Environment(\.theme) private var theme

    var body: some View {
        let grid = model.monthGrid
        VStack(spacing: 0) {
            weekdayNames(grid)
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            GeometryReader { geometry in
                let rowHeight = geometry.size.height / CGFloat(max(grid.weeks.count, 1))
                VStack(spacing: 0) {
                    ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                        HStack(spacing: 0) {
                            ForEach(week) { cell in
                                cellView(cell)
                                    .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .top)
                                    .overlay(alignment: .trailing) {
                                        Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
                                    }
                            }
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.window.month")
    }

    private func weekdayNames(_ grid: CalendarMonthGrid) -> some View {
        HStack(spacing: 0) {
            ForEach(grid.weeks.first ?? [], id: \.day) { cell in
                Text(verbatim: model.dayHeader(cell.day).weekday)
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, theme.space2)
    }

    private func cellView(_ cell: CalendarMonthGrid.Cell) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { Task { await model.show(day: cell.day, as: .day) } } label: {
                    Text(verbatim: model.dayHeader(cell.day).number)
                        .themeFont(theme.typeMeta)
                        .foregroundStyle((cell.isToday ? theme.accentOnFill
                                          : cell.isInMonth ? theme.textPrimary : theme.textTertiary).color)
                        .frame(minWidth: 22, minHeight: 22)
                        .background { if cell.isToday { Circle().fill(theme.accentFill.color) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this day")
                Spacer(minLength: 0)
            }
            ForEach(cell.events, id: \.copyKey) { event in
                Button { model.openEvent(event) } label: { chip(event) }
                    .buttonStyle(.plain)
                    .calendarEventContextMenu(model, event)
                    .calendarPopoverAnchor(!event.id.isEmpty && model.card?.event.copyKey == event.copyKey)
            }
            if cell.more > 0 {
                Button { Task { await model.show(day: cell.day, as: .day) } } label: {
                    Text("+\(cell.more) more").themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("calendar.window.month.more")
            }
            Spacer(minLength: 0)
        }
        .padding(theme.space1)
        .background(cell.isInMonth ? Color.clear : theme.bgSunken.color.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            let calendar = CalendarDateMentions.calendar(model.timeZone)
            let start = calendar.date(bySettingHour: CalendarEventDraftBuilder.defaultHour, minute: 0, second: 0,
                                      of: cell.day) ?? cell.day
            Task { await model.newEvent(start: start, end: start.addingTimeInterval(CalendarEventDraftBuilder.defaultDuration)) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cell.day.formatted(Date.FormatStyle(timeZone: model.timeZone).weekday(.wide).month(.wide).day()))
    }

    private func chip(_ event: CalendarEvent) -> some View {
        let index = model.colorIndex(for: event)
        let selected = model.selectedEventID == event.copyKey
        let filled = event.isAllDay || CalendarTimeGrid.belongsInAllDayRow(event)
        let colors = CalendarPalette.block(index, state: selected ? .selected : .normal, tokens: theme.tokens)
        let declined = event.myResponse == .declined
        return HStack(spacing: theme.space1) {
            if !filled {
                Circle().fill(colors.bar.color).frame(width: 6, height: 6)
                Text(event.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.timeZone)))
                    .themeFont(theme.typeCaption).fontWeight(.regular)
                    .foregroundStyle((selected ? colors.text : theme.textTertiary).color)
                    .lineLimit(1).fixedSize()
            }
            Text(event.title).themeFont(theme.typeCaption).fontWeight(filled ? .semibold : .medium)
                .foregroundStyle((filled || selected ? colors.text : declined ? theme.textTertiary : theme.textPrimary).color)
                .strikethrough(declined)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space1 + 1)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: CalendarTimeGridView.blockRadius, style: .continuous)
            .fill(filled || selected ? colors.fill.color : Color.clear))
        .contentShape(Rectangle())
        .help(event.title + "\n" + model.timeText(event))
        .accessibilityLabel("\(event.title), \(model.timeText(event))")
    }
}
