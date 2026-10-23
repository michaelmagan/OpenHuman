import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarRightPanel: View {
    @Bindable var model: CalendarWindowModel
    let router: AppRouter
    @Environment(\.theme) private var theme
    @State private var meetText = ""
    @State private var meetList = CompletionListModel()
    @FocusState private var meetFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: theme.space7) {
                    miniMonth
                    meetRow
                    calendars
                    status
                }
                .padding(theme.space5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            bottomBar
        }
        .frame(width: theme.component.sidebar.width)
        .frame(maxHeight: .infinity)
        .background(theme.component.sidebar.bg.color)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.window.panel")
    }

    private var miniMonth: some View {
        let mini = model.miniMonth
        let calendar = CalendarDateMentions.calendar(model.timeZone)
        let names = Self.weekdayInitials(calendar)
        return VStack(alignment: .leading, spacing: theme.space2) {
            HStack {
                Text(mini.month.formatted(Date.FormatStyle(timeZone: model.timeZone).month(.wide).year()))
                    .themeFont(theme.typeBodyStrong).foregroundStyle(theme.textPrimary.color)
                Spacer(minLength: 0)
                monthChevron("chevron.left", label: "Previous month", month: mini.month, delta: -1, calendar: calendar)
                monthChevron("chevron.right", label: "Next month", month: mini.month, delta: 1, calendar: calendar)
            }
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                        Text(verbatim: name).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(mini.weeks.enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { day in dayCell(day, month: mini.month, calendar: calendar) }
                    }
                    .background {
                        if model.kind == .week || model.kind == .month, week.contains(where: { model.period.contains($0) }) {
                            RoundedRectangle(cornerRadius: theme.radiusSM).fill(theme.bgRowSelected.color.opacity(0.6))
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.window.miniMonth")
    }

    private func dayCell(_ day: Date, month: Date, calendar: Calendar) -> some View {
        let today = model.isToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let shown = model.period.contains(day)
        return Button { Task { await model.show(day: day) } } label: {
            Text(verbatim: model.dayHeader(day).number)
                .themeFont(shown ? theme.typeBodyStrong : theme.typeMeta)
                .foregroundStyle((today ? theme.accentText : inMonth ? theme.textPrimary : theme.textTertiary).color)
                .frame(width: 24, height: 24)
                .overlay { if today { Circle().strokeBorder(theme.accentFill.color, lineWidth: 1.5) } }
                .frame(maxWidth: .infinity)
                .background {
                    if shown, model.kind == .day || model.kind == .threeDays {
                        RoundedRectangle(cornerRadius: theme.radiusSM).fill(theme.bgRowSelected.color.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(Date.FormatStyle(timeZone: model.timeZone).weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(today ? .isSelected : [])
    }

    private func monthChevron(_ symbol: String, label: String, month: Date, delta: Int, calendar: Calendar) -> some View {
        Button {
            let target = calendar.date(byAdding: .month, value: delta, to: month) ?? month
            Task { await model.show(day: target) }
        } label: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textSecondary.color)
        .help(label)
        .accessibilityLabel(label)
    }

    static func weekdayInitials(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        let first = CalendarPeriod.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var meetRow: some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            sectionHeading("Meet")
            TextField("Name or email", text: $meetText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .autocorrectionDisabled(true)
                .focused($meetFocused)
                .onChange(of: meetText) { _, typed in meetList.update(query: typed) }
                .onSubmit {
                    if case .accepted(let person) = meetList.handle(.accept) {
                        meet(person)
                    } else {
                        meet(typed: meetText)
                    }
                }
                .completionKeys(meetList) { meet($0) }
                .completionPanel(meetList, isActive: meetFocused, label: String(localized: "Suggested people"),
                                 identifier: "calendar.window.meetSuggestions") { meet($0) }
                .onChange(of: meetFocused) { _, now in if !now { meetList.clear() } }
                .onAppear {
                    meetList.suggest = { [sidebar = model.sidebar] prefix in await sidebar.guestSuggestions(prefix) }
                }
                .help("Finds a free half hour on your calendars and opens the event with them.")
                .accessibilityLabel("Meet")
                .accessibilityHint("Finds a free half hour on your calendars and opens the event with them.")
                .accessibilityIdentifier("calendar.window.meet")
            if let note = model.meetNote {
                Text(note).font(.subheadline).foregroundStyle(theme.textWarning.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Finds a free half hour and opens the event.")
                    .font(.subheadline).foregroundStyle(theme.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func meet(_ person: EmailAddress) {
        meetList.clear()
        meet(typed: CompletionListModel.typed(person))
    }

    private func meet(typed: String) {
        meetList.clear()
        Task {
            if await model.meet(with: typed) == nil { meetText = "" }
        }
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.textSecondary.color)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var calendars: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            sectionHeading("Calendars")
            if model.sources.isEmpty, model.state != .loading {
                Text("No calendar is connected. Connect one in Settings › Calendar.")
                    .font(.subheadline).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.sources) { source in
                    CalendarSourceRow(title: source.title,
                                      color: CalendarPalette.ink(source.colorIndex, tokens: theme.tokens),
                                      isOn: Binding(get: { source.isVisible },
                                                    set: { on in Task { await model.setVisible(source.key, on) } }))
                }
            }
            .padding(.horizontal, -theme.space2)
        }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let progress = model.progress {
                Text(progress.text).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
            }
            if let note = model.note {
                Text(note).themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.window.note")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("calendar.window.status")
    }

    private var bottomBar: some View {
        HStack(spacing: theme.space3) {
            Image(systemName: "calendar").foregroundStyle(theme.textSecondary.color).accessibilityHidden(true)
            Text("Google Calendar").themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                .help(model.updatedText ?? "")
                .accessibilityValue(model.updatedText ?? "")
            Spacer(minLength: 0)
            Button {
                _ = router.environment.actions.perform(.settingsPage("calendar"), source: .toolbar, host: router)
            } label: {
                Image(systemName: "gearshape").foregroundStyle(theme.textSecondary.color).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Calendar settings")
            .accessibilityLabel("Calendar settings")
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space3)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
        }
    }
}

struct CalendarSourceRow: View {
    let title: String
    let color: ThemeColor
    @Binding var isOn: Bool
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: title)
                .font(.body)
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1).truncationMode(.middle)
        }
        .toggleStyle(CalendarColorCheckboxStyle(color: color))
        .padding(.horizontal, theme.space2)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: theme.radiusMD, style: .continuous)
            .fill(hovered ? theme.bgRowHover.color : Color.clear))
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityIdentifier("calendar.window.calendar")
    }
}
