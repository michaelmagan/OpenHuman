import AppKit
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

struct CalendarFormCalendarMenu {
    let selected: String
    let choices: [(id: String, title: String)]
    let choose: (String) -> Void
}

// The event editor as a grouped form: the title, then when, who, where and notes, then the settings most events
// keep (calendar, alert, busy, visibility, colour) in a quieter group. Labels sit on the leading side and controls on
// the trailing side, as in a system inspector.
struct CalendarEventFormView: View {
    @Binding var form: CalendarEventForm
    var rights: CalendarFieldRights
    var timeZone: TimeZone
    var idPrefix: String
    var meetLink: URL?
    var calendarChoices: [(key: String, title: String)] = []
    var titleIsSuggested = false
    var focusesTitle = false
    var asksSendUpdates = false
    var sendUpdates: Binding<CalendarSendUpdates>?
    var isNewEvent = false
    var calendarName: String = ""
    var calendarMenu: CalendarFormCalendarMenu?
    var suggestGuests: (@Sendable (String) async -> [EmailAddress])?
    // What is typed in the guest field and not yet added, so Save can add it; the note says why Save stopped
    var pendingGuest: Binding<String>?
    var pendingGuestNote: String?

    enum Field: Hashable { case title, guest, location, notes }

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @FocusState private var focused: Field?
    @State private var guestField: RecipientFieldModel?
    @State private var guestList: CompletionListModel?
    @State private var guestNote: String?
    @State private var firstNotes: CalendarDescription.Parsed?
    @State private var notesText = ""
    @State private var editingNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: CalendarFormMetrics.sectionSpacing) {
            CalendarFormSection(identifier: "\(idPrefix).section.title") { titleRow }
            CalendarFormSection(identifier: "\(idPrefix).section.when") { whenRows }
            CalendarFormSection(identifier: "\(idPrefix).section.people") { peopleRows }
            CalendarFormSection(identifier: "\(idPrefix).section.details") {
                locationRow
                notesRow
            }
            CalendarFormSection(identifier: "\(idPrefix).section.more") {
                calendarRow
                remindersRow
                busyRow
                visibilityRow
                colourRow
            }
            if asksSendUpdates, let sendUpdates {
                CalendarFormSection(identifier: "\(idPrefix).section.updates") { sendUpdatesRow(sendUpdates) }
            }
        }
        .font(.body)
        .environment(\.timeZone, timeZone)
        .onAppear {
            if firstNotes == nil {
                let parsed = CalendarDescription.parse(form.notes)
                firstNotes = parsed
                notesText = parsed.editableText
            }
            if guestField == nil { guestField = makeGuestField() }
            if guestList == nil { guestList = CompletionListModel(suggest: suggestGuests) }
            if focusesTitle { focused = .title }
        }
    }

    private func fieldAccess(_ field: CalendarFormField) -> CalendarFieldAccess { rights.access(field) }


    @ViewBuilder
    private var titleRow: some View {
        let access = fieldAccess(.title)
        if access.reason == nil {
            HStack(spacing: CalendarFormMetrics.iconGap) {
                TextField("Add title", text: $form.title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    // A long title ends in an ellipsis until it is edited
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .focused($focused, equals: .title)
                    .help(titleIsSuggested ? String(localized: "Suggested from the conversation") : "")
                    .accessibilityIdentifier("\(idPrefix).title")
                if titleIsSuggested {
                    Image(systemName: "sparkles")
                        .foregroundStyle(theme.textAI.color)
                        .help("Suggested from the conversation")
                        .accessibilityLabel("Suggested from the conversation")
                        .accessibilityIdentifier("\(idPrefix).titleSuggested")
                }
            }
            .calendarFormRowPadding()
            .padding(.vertical, 2)
        } else {
            Text(form.title).font(.title3.weight(.semibold)).foregroundStyle(theme.textPrimary.color)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .calendarFormRowPadding()
                .padding(.vertical, 2)
                .lockedReason(access.reason)
                .accessibilityIdentifier("\(idPrefix).title")
        }
    }


    @ViewBuilder
    private var whenRows: some View {
        let time = fieldAccess(.time)
        CalendarFormRow(title: String(localized: "All-day")) {
            Toggle("All-day", isOn: Binding(get: { form.isAllDay }, set: { form.setAllDay($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityIdentifier("\(idPrefix).allDay")
        }
        .calendarLocked(time)
        CalendarFormRow(title: String(localized: "Starts")) {
            HStack(spacing: 4) {
                CalendarDateFieldView(date: form.start, zone: timeZone, idPrefix: "\(idPrefix).startDate") { form.setStart($0) }
                if !form.isAllDay {
                    timePicker("Starts", Binding(get: { form.start }, set: { form.setStart($0) }), id: "startTime")
                }
            }
        }
        .calendarLocked(time)
        CalendarFormRow(title: String(localized: "Ends"), detail: durationText) {
            HStack(spacing: 4) {
                CalendarDateFieldView(date: form.isAllDay ? form.lastDay : form.end, zone: timeZone,
                                      idPrefix: "\(idPrefix).endDate") { day in
                    if form.isAllDay { form.setLastDay(day) } else { form.setEnd(day) }
                }
                if !form.isAllDay {
                    timePicker("Ends", Binding(get: { form.end }, set: { form.setEnd($0) }), id: "endTime")
                }
            }
        }
        .calendarLocked(time)
        if !form.isAllDay {
            CalendarFormRow(title: String(localized: "Time zone")) {
                // Why: a menu as wide as its longest zone name is wider than the panel; it shortens the zone instead.
                // One menu at every width, so no copy of it is measured and made again on each layout pass
                CalendarUpToIdealWidth { zoneMenu }
            }
            .calendarLocked(fieldAccess(.timeZone))
        }
        CalendarFormRow(title: String(localized: "Repeat")) { repeatMenu }
            .calendarLocked(fieldAccess(.repeats))
    }

    private func timePicker(_ title: LocalizedStringKey, _ selection: Binding<Date>, id: String) -> some View {
        DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("\(idPrefix).\(id)")
    }

    private var durationText: String? {
        let calendar = form.isAllDay ? form.calendar : CalendarDateMentions.calendar(timeZone)
        return CalendarFormSummary.duration(start: form.start, end: form.end, isAllDay: form.isAllDay, calendar: calendar)
    }

    private var zoneMenu: some View {
        Menu {
            Picker("Time zone", selection: Binding(get: { form.timeZone }, set: { form.setTimeZone($0) })) {
                ForEach(Self.zoneChoices(including: form.timeZone), id: \.self) { Text(Self.zoneTitle($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: Self.zoneTitle(form.timeZone)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .help(String(localized: "The event's time zone"))
        .accessibilityLabel("Time zone")
        .accessibilityValue(Self.zoneTitle(form.timeZone))
        .accessibilityIdentifier("\(idPrefix).timeZone")
    }

    static func zoneChoices(including current: String) -> [String] {
        let all = TimeZone.knownTimeZoneIdentifiers.sorted()
        return all.contains(current) ? all : [current] + all
    }

    static func zoneTitle(_ identifier: String) -> String { identifier.replacingOccurrences(of: "_", with: " ") }

    private var repeatMenu: some View {
        let current = CalendarRepeat.preset(of: form.recurrence)
        let choices = CalendarRepeat.Preset.allCases.filter { $0 != .custom || current == .custom }
        return Menu {
            Picker("Repeat", selection: Binding(get: { current }, set: { preset in
                if preset != .custom { form.recurrence = CalendarRepeat.rules(preset) }
            })) {
                ForEach(choices, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(current.title)
        }
        .calendarQuietMenu()
        .help("How often the event repeats")
        .accessibilityLabel("Repeat")
        .accessibilityValue(current.title)
        .accessibilityIdentifier("\(idPrefix).repeat")
    }


    private func makeGuestField() -> RecipientFieldModel {
        let field = RecipientFieldModel(kind: .to)
        let form = $form
        field.onChange = { [weak field] tokens in
            guard let field else { return }
            var refused = false
            for address in tokens {
                if RecipientParser.isValid(address.email) {
                    form.wrappedValue.addGuest(address)
                } else {
                    refused = true
                }
            }
            guestNote = refused ? String(localized: "Type an email address.") : nil
            field.setTokens([])
            pendingGuest?.wrappedValue = field.text
        }
        return field
    }

    // Text that is not an address stays in the field with a note instead of disappearing
    private func commitTyped(_ field: RecipientFieldModel) {
        if CalendarPendingGuest.addresses(in: field.text) == nil {
            guestNote = String(localized: "Type an email address.")
        } else {
            field.commit()
        }
    }

    private var guestEmails: Set<String> { Set(form.guests.map { $0.email.lowercased() }) }

    private func addGuest(_ address: EmailAddress) {
        guestList?.clear()
        guestField?.accept(address)
    }

    @ViewBuilder
    private var peopleRows: some View {
        let guests = fieldAccess(.guests)
        CalendarFormWideRow(symbol: "person.badge.plus") { guestInput }
            .calendarLocked(guests)
        if let note = shownGuestNote {
            Label(note, systemImage: "exclamationmark.triangle")
                .font(.subheadline).foregroundStyle(theme.textWarning.color)
                .calendarFormRowPadding()
                .accessibilityIdentifier("\(idPrefix).guestNote")
        }
        ForEach(form.guests) { guest in
            guestRow(guest, access: guests)
        }
        if !form.guests.isEmpty {
            guestPermissionsRow
        }
        meetRow
    }

    private var shownGuestNote: String? { pendingGuestNote ?? guestNote }

    @ViewBuilder
    private var guestInput: some View {
        if let field = guestField {
            TextField("Add guests", text: Binding(get: { field.text }, set: { typed in
                field.text = typed
                pendingGuest?.wrappedValue = field.text
                guestList?.update(query: field.text, excluding: guestEmails)
            }))
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .focused($focused, equals: .guest)
                .onSubmit {
                    if let list = guestList, case .accepted(let address) = list.handle(.accept) {
                        addGuest(address)
                    } else {
                        guestList?.clear()
                        commitTyped(field)
                    }
                }
                .completionKeys(guestList) { addGuest($0) }
                .completionPanel(guestList, isActive: focused == .guest, label: String(localized: "Suggested guests"),
                                 identifier: "calendar.guestSuggestions") { addGuest($0) }
                .onChange(of: focused) { _, now in
                    if now != .guest {
                        guestList?.clear()
                        commitTyped(field)
                    }
                }
                .onChange(of: pendingGuest?.wrappedValue ?? "") { _, typed in
                    guard typed != field.text else { return }
                    field.text = typed
                    if typed.isEmpty { guestList?.clear() }
                }
                .onChange(of: pendingGuestNote) { _, note in
                    // Why: Save stopped on what is typed here, so the field takes focus and the reason is spoken
                    guard let note else { return }
                    focused = .guest
                    AccessibilityNotification.Announcement(note).post()
                }
                .help("Type a name or an email address; Return adds the guest")
                .accessibilityLabel("Add guests")
                .accessibilityHint(shownGuestNote ?? "")
                .accessibilityIdentifier("\(idPrefix).addGuest")
        }
    }

    private func guestRow(_ guest: CalendarGuest, access: CalendarFieldAccess) -> some View {
        HStack(spacing: CalendarFormMetrics.iconGap) {
            CalendarGuestAvatar(guest: guest)
                .help(CalendarFormSummary.answer(guest.response) ?? "")
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: guest.name ?? guest.email)
                    .foregroundStyle(theme.textPrimary.color)
                    .lineLimit(1).truncationMode(.middle)
                if let second = Self.secondLine(guest) {
                    Text(verbatim: second).font(.subheadline).foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Toggle("Optional", isOn: Binding(get: { guest.isOptional }, set: { form.setOptional(guest.email, $0) }))
                .toggleStyle(.checkbox).controlSize(.small).font(.subheadline)
                .foregroundStyle(theme.textSecondary.color)
                .disabled(access != .editable)
                .help("An optional guest doesn't have to come")
                .accessibilityIdentifier("\(idPrefix).optional")
            if access == .editable {
                Button { form.removeGuest(guest.email) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).foregroundStyle(theme.textTertiary.color)
                .help("Remove \(guest.email)")
                .accessibilityLabel("Remove \(guest.name ?? guest.email)")
            }
        }
        .calendarFormRowPadding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.spoken(guest))
        .accessibilityIdentifier("\(idPrefix).guest")
    }

    // The address under the name, and the guest's answer once they gave one
    static func secondLine(_ guest: CalendarGuest) -> String? {
        let parts = [guest.name == nil ? nil : guest.email, CalendarFormSummary.answer(guest.response)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func spoken(_ guest: CalendarGuest) -> String {
        let answer = CalendarFormSummary.answer(guest.response)
        return [guest.name ?? guest.email, answer, guest.isOptional ? String(localized: "optional") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    static func initial(of guest: CalendarGuest) -> String {
        let source = (guest.name?.isEmpty == false ? guest.name : nil) ?? guest.email
        return source.first.map { String($0).uppercased() } ?? "?"
    }

    private var guestPermissionsRow: some View {
        CalendarFormRow(title: String(localized: "Guests can"), quiet: true) {
            Menu {
                Toggle("Modify the event", isOn: $form.permissions.canModify)
                Toggle("Invite others", isOn: $form.permissions.canInviteOthers)
                Toggle("See the guest list", isOn: $form.permissions.canSeeGuestList)
            } label: {
                Text(verbatim: CalendarFormSummary.permissions(form.permissions)).lineLimit(1)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .help("What guests can do with this event")
            .accessibilityLabel("Guest permissions")
            .accessibilityValue(CalendarFormSummary.permissions(form.permissions))
            .accessibilityIdentifier("\(idPrefix).guestPermissions")
        }
        .calendarLocked(fieldAccess(.guestPermissions))
    }

    private var meetRow: some View {
        let detail: String? = form.wantsMeet && meetLink == nil ? String(localized: "Link will be added when saved") : nil
        return CalendarFormRow(title: String(localized: "Google Meet"), symbol: "video", detail: detail) {
            HStack(spacing: CalendarFormMetrics.iconGap) {
                if form.wantsMeet, let meetLink {
                    Button("Join") { openURL(meetLink) }
                        .controlSize(.small)
                        .help("Join the Google Meet call")
                        .accessibilityIdentifier("\(idPrefix).joinMeet")
                }
                Toggle("Google Meet", isOn: $form.wantsMeet)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityIdentifier("\(idPrefix).meet")
            }
        }
        .calendarLocked(fieldAccess(.meet))
    }


    private var locationRow: some View {
        CalendarFormWideRow(symbol: "mappin.and.ellipse") {
            TextField("Add location", text: $form.location)
                .textFieldStyle(.plain)
                .focused($focused, equals: .location)
                .accessibilityLabel("Location")
                .accessibilityIdentifier("\(idPrefix).location")
        }
        .calendarLocked(fieldAccess(.location))
    }

    private var showsNotesEditor: Bool {
        editingNotes || (firstNotes ?? CalendarDescription.parse(form.notes)).isEmpty
    }

    private var notesRow: some View {
        CalendarFormWideRow(symbol: "text.alignleft", alignment: .firstTextBaseline) {
            let parsed = firstNotes ?? CalendarDescription.parse(form.notes)
            if showsNotesEditor {
                TextEditor(text: $notesText)
                    .focused($focused, equals: .notes)
                    .calendarTextArea(text: notesText, prompt: "Add agenda or notes", focused: focused == .notes,
                                      framed: false)
                    .onChange(of: notesText) { _, new in
                        form.notes = CalendarDescription.textToWrite(edited: new, from: parsed)
                    }
                    .onAppear { if editingNotes { focused = .notes } }
                    .accessibilityLabel("Agenda or notes")
                    .accessibilityIdentifier("\(idPrefix).notes")
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(CalendarDescription.attributed(CalendarDescription.parse(form.notes).document))
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(12).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let safe = CalendarDescription.openableURL(url) else { return .discarded }
                            openURL(safe)
                            return .handled
                        })
                    Spacer(minLength: 0)
                    Button("Edit") { editingNotes = true }.buttonStyle(.link)
                        .help("Edit the agenda or notes")
                        .accessibilityIdentifier("\(idPrefix).editNotes")
                }
                .accessibilityIdentifier("\(idPrefix).notes")
            }
        }
        .calendarLocked(fieldAccess(.notes))
    }


    @ViewBuilder
    private var calendarRow: some View {
        let title = String(localized: "Calendar")
        if let menu = calendarMenu, menu.choices.count > 1 {
            CalendarFormRow(title: title, symbol: "calendar", quiet: true) {
                let current = menu.choices.first { $0.id == menu.selected }?.title ?? calendarName
                Menu {
                    Picker("Calendar", selection: Binding(get: { menu.selected }, set: { menu.choose($0) })) {
                        ForEach(menu.choices, id: \.id) { Text(verbatim: $0.title).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(verbatim: current).lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.visible)
                .help("The calendar the event is saved to")
                .accessibilityLabel("Calendar")
                .accessibilityValue(current)
                .accessibilityIdentifier("\(idPrefix).calendarPicker")
            }
        } else {
            CalendarFormRow(title: title, symbol: "calendar", quiet: true) {
                if calendarChoices.count > 1, fieldAccess(.calendar).reason == nil {
                    let current = calendarChoices.first { $0.key == form.calendarKey }?.title ?? form.calendarKey
                    Menu {
                        Picker("Calendar", selection: $form.calendarKey) {
                            ForEach(calendarChoices, id: \.key) { Text($0.title).tag($0.key) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text(verbatim: current).lineLimit(1).truncationMode(.middle)
                    }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.visible)
                    .help("The calendar the event is saved to")
                    .accessibilityLabel("Calendar")
                    .accessibilityValue(current)
                    .accessibilityIdentifier("\(idPrefix).calendarPicker")
                } else {
                    Text(verbatim: calendarName.isEmpty ? form.calendarKey : calendarName)
                        .foregroundStyle(theme.textSecondary.color)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityIdentifier("\(idPrefix).calendar")
                }
            }
            .calendarLocked(fieldAccess(.calendar))
        }
    }

    private var remindersRow: some View {
        CalendarFormRow(title: String(localized: "Alert"), symbol: "bell", quiet: true) {
            Menu {
                Toggle("Calendar default", isOn: Binding(get: { form.reminders == .calendarDefault },
                                                         set: { on in if on { form.reminders = .calendarDefault } }))
                Toggle("None", isOn: Binding(get: { form.reminders == .custom([]) },
                                             set: { on in if on { form.reminders = .custom([]) } }))
                Divider()
                ForEach(CalendarReminderMenu.items(form.reminders)) { item in
                    Toggle(item.title, isOn: Binding(get: { item.isOn }, set: { _ in
                        form.reminders = CalendarReminderMenu.toggling(item.reminder, in: form.reminders)
                    }))
                    .disabled(!item.isEnabled)
                }
            } label: {
                Text(CalendarReminderMenu.title(form.reminders)).lineLimit(1)
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.visible)
            .help("Reminders for this event")
            .accessibilityLabel("Reminders")
            .accessibilityValue(CalendarReminderMenu.title(form.reminders))
            .accessibilityIdentifier("\(idPrefix).reminders")
        }
        .calendarLocked(fieldAccess(.reminders))
    }

    private var busyRow: some View {
        CalendarFormRow(title: String(localized: "Show as"), symbol: "circle.lefthalf.filled", quiet: true) {
            Menu {
                Picker("Show as", selection: $form.busy) {
                    ForEach(CalendarBusyStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(form.busy.title)
            }
            .calendarQuietMenu()
            .help("Whether others see you as busy then")
            .accessibilityLabel("Show as")
            .accessibilityValue(form.busy.title)
            .accessibilityIdentifier("\(idPrefix).busy")
        }
        .calendarLocked(fieldAccess(.busy))
    }

    private var visibilityRow: some View {
        CalendarFormRow(title: String(localized: "Visibility"), symbol: "eye", quiet: true) {
            Menu {
                Picker("Visibility", selection: $form.visibility) {
                    ForEach(CalendarVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(form.visibility.title).lineLimit(1)
            }
            .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.visible)
            .help("Who can see the event's details")
            .accessibilityLabel("Visibility")
            .accessibilityValue(form.visibility.title)
            .accessibilityIdentifier("\(idPrefix).visibility")
        }
        .calendarLocked(fieldAccess(.visibility))
    }

    private var colourRow: some View {
        CalendarFormRow(title: String(localized: "Colour"), symbol: "paintpalette", quiet: true) {
            Menu {
                Picker("Colour", selection: $form.colorID) {
                    ForEach(CalendarColourMenu.choices(including: form.colorID), id: \.self) { id in
                        Label {
                            Text(CalendarColourMenu.title(id))
                        } icon: {
                            Image(nsImage: swatch(id))
                        }
                        .tag(id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label {
                    Text(CalendarColourMenu.title(form.colorID))
                } icon: {
                    Image(nsImage: swatch(form.colorID))
                }
            }
            .calendarQuietMenu()
            .help("The event's colour; Calendar colour follows the calendar")
            .accessibilityLabel("Colour")
            .accessibilityValue(CalendarColourMenu.title(form.colorID))
            .accessibilityIdentifier("\(idPrefix).color")
        }
        .calendarLocked(fieldAccess(.color))
    }

    private func swatch(_ id: String?) -> NSImage {
        CalendarColourMenu.swatch(CalendarColourMenu.ink(id, theme: theme), ring: theme.textTertiary)
    }


    // One menu at every width. Why: segments where they fit and a menu where they did not swapped controls of
    // different heights on the form's own width, and measuring the copy not shown made a new AppKit control on each
    // layout pass; both kept the window asking for another constraint pass
    private func sendUpdatesRow(_ choice: Binding<CalendarSendUpdates>) -> some View {
        CalendarFormRow(title: String(localized: "Email guests"), symbol: "envelope") {
            Menu {
                Picker("Email guests", selection: choice) {
                    ForEach(CalendarSendUpdatesPolicy.options, id: \.self) {
                        Text(CalendarSendUpdatesPolicy.title($0)).tag($0)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(CalendarSendUpdatesPolicy.title(choice.wrappedValue))
            }
            .calendarQuietMenu()
            .help(isNewEvent ? String(localized: "Whether Google sends invitations to the guests")
                             : String(localized: "Whether Google emails the guests about this change"))
            .accessibilityLabel("Email the guests")
            .accessibilityValue(CalendarSendUpdatesPolicy.title(choice.wrappedValue))
            .accessibilityIdentifier("\(idPrefix).sendUpdates")
        }
    }
}

extension View {
    func calendarLocked(_ access: CalendarFieldAccess) -> some View {
        disabled(access.reason != nil).lockedReason(access.reason)
    }
}

// The day as typed text in the locale's order with two-digit days and months, so it reads like the grid's column
// headers. Up and Down step a day; a complete date commits as it is typed, so saving straight from the field keeps it.
struct CalendarDateFieldView: View {
    var date: Date
    var zone: TimeZone
    var idPrefix: String
    var set: (Date) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool
    private let locale = Locale.current

    var body: some View {
        TextField("Date", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: CalendarFormMetrics.dateFieldWidth)
            .focused($focused)
            .onSubmit(commit)
            .onKeyPress(.upArrow) { step(1); return .handled }
            .onKeyPress(.downArrow) { step(-1); return .handled }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: text) { _, typed in commitIfComplete(typed) }
            .help("Type a date; Up and Down change it by a day")
            .accessibilityIdentifier(idPrefix)
            .onAppear { text = shown }
            .onChange(of: date) { _, _ in if text != shown { text = shown } }
            .onChange(of: zone) { _, _ in text = shown }
    }

    private var shown: String { CalendarDateField.text(date, zone: zone, locale: locale) }

    private func commit() {
        if let parsed = CalendarDateField.parse(text, keepingTimeOf: date, zone: zone, locale: locale) {
            if parsed != date { set(parsed) }
        }
        text = shown
    }

    // Only a date written out in full, as the field shows it, commits while typing; a half-typed day waits for Return
    private func commitIfComplete(_ typed: String) {
        guard focused, let parsed = Self.complete(typed, keepingTimeOf: date, zone: zone, locale: locale),
              parsed != date else { return }
        set(parsed)
    }

    static func complete(_ typed: String, keepingTimeOf reference: Date, zone: TimeZone, locale: Locale) -> Date? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard let parsed = CalendarDateField.parse(trimmed, keepingTimeOf: reference, zone: zone, locale: locale),
              CalendarDateField.text(parsed, zone: zone, locale: locale) == trimmed else { return nil }
        return parsed
    }

    private func step(_ days: Int) {
        set(CalendarDateField.stepped(date, byDays: days, zone: zone))
    }
}
