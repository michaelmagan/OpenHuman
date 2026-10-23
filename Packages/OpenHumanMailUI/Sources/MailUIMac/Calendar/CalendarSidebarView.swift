import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI

public struct CalendarSidebarView: View {
    static let followDelay: Duration = .milliseconds(300)
    static let composerDelay: Duration = .milliseconds(500)

    struct ComposerFollow: Equatable {
        let session: UUID
        let revision: Int
    }

    @Bindable var model: CalendarSidebarModel
    let router: AppRouter
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var dayKeys = CalendarDayKeyFocus()
    @State private var viewportHeight: CGFloat = 0

    public init(model: CalendarSidebarModel, router: AppRouter) {
        self.model = model
        self.router = router
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
            ScrollView(.vertical) {
                // The day's hours give up height, down to their minimum, so the free times under them stay in view
                CalendarFitColumn(room: viewportHeight - 2 * theme.space5, spacing: theme.space5) {
                    summary
                    if let day = model.dayViewDay {
                        CalendarDayView(model: model, day: day, takeKeys: { dayKeys.take() })
                            .calendarFitsRoom(givingUp: CalendarDayView.hoursGiveUp)
                        if model.showsPickedTime { pickedConflicts(model.timeline(for: day)) }
                        otherDays(besides: day)
                        freeTimes(day)
                    }
                }
                .padding(theme.space5)
                // Why: at one width a scroll bar coming and going cannot re-wrap the content
                .calendarScrollContent(width: theme.component.sidebar.width)
            }
            // The scroll view's own height, which does not depend on what it scrolls; whole points, so a fraction of
            // a point is not another pass
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { viewportHeight = $0 }
            .task(id: availabilityFollow) {
                guard let live = availabilityFollow else { return }
                if model.isForAnotherConversation(live) { return model.clearSuggestion() }
                guard model.staleReason(for: live) != nil else { return }
                try? await Task.sleep(for: Self.staleDelay)
                guard !Task.isCancelled else { return }
                await model.followAvailability(live)
            }
            .overlay(alignment: .top) { CalendarEventDetailsOverlay(model: model, router: router) }
            .overlay(alignment: .top) { CalendarDraftOverlay(model: model, takeKeys: { dayKeys.take() }) }
            CalendarSidebarBottomBar(model: model, router: router)
        }
        .frame(width: theme.component.sidebar.width)
        .frame(maxHeight: .infinity)
        .background(CalendarDayKeys(model: model, focus: dayKeys))
        .background(theme.component.sidebar.bg.color)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.borderHairline.color).frame(width: theme.borderWidthHairline)
        }
        .task(id: router.reader?.thread) {
            model.activeAccount = { [weak router = self.router] in router?.activeAccountID }
            try? await Task.sleep(for: Self.followDelay)
            guard !Task.isCancelled else { return }
            await model.show(thread: router.reader?.thread)
        }
        .task(id: composerFollow) {
            guard let follow = composerFollow else { return }
            try? await Task.sleep(for: Self.composerDelay)
            guard !Task.isCancelled, let session = router.environment.composeIfStarted?.session(id: follow.session) else {
                return
            }
            await model.follow(typed: session.plainText)
        }
        .onChange(of: router.environment.pendingEvents.returnRequest) {
            dayKeys.view?.window?.makeFirstResponder(nil)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: model.refreshInterval)
                guard !Task.isCancelled else { return }
                await model.tick()
            }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                await model.appBecameActive()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Calendar")
        .accessibilityIdentifier("calendar.sidebar")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
                let contact = router.environment.actions.superhumanCore?.contextSidebar
                if let contact {
                    let title = router.reader == nil ? ListSidePanelView.panel(for: router).title : "Contact"
                    Button(title) { contact.setVisible(true) }
                        .buttonStyle(.borderless)
                        .themeFont(theme.typeHeadline).foregroundStyle(theme.textSecondary.color)
                        .shortcutTip(.toggleContextSidebar, title: "Show \(title.lowercased())")
                }
                Text("Calendar").themeFont(theme.typeHeadline).foregroundStyle(theme.textPrimary.color)
                    .overlay(alignment: .bottom) {
                        if contact != nil {
                            Rectangle().fill(theme.component.row.cursorBar.color)
                                .frame(height: theme.component.row.cursorBarWidth)
                                .offset(y: theme.space2)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityAddTraits(contact != nil ? [.isHeader, .isSelected] : .isHeader)
                if model.isSample {
                    Text("Sample").themeFont(theme.typeCaption).foregroundStyle(theme.textSecondary.color)
                        .padding(.horizontal, theme.space2)
                        .background(Capsule().fill(theme.bgSunken.color))
                        .overlay(Capsule().strokeBorder(theme.borderControl.color, lineWidth: theme.borderWidthHairline))
                }
                Spacer(minLength: 0)
                if model.state == .loading { ProgressView().controlSize(.small) }
                CalendarHeaderGlyph(symbol: "arrow.clockwise", help: "Refresh", label: "Refresh calendar") {
                    Task { await model.refresh() }
                }
                CalendarHeaderGlyph(symbol: "xmark", help: "Hide calendar", label: "Hide calendar",
                                    shortcut: .calendarToggleSidebar) {
                    model.setVisible(false)
                }
            }
            Text(model.zonesText).themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
            dayNavigation
            if model.routesByAccount {
                Toggle("Show all calendars", isOn: Binding(get: { model.showAllSetting.value },
                                                           set: { on in Task { await model.setShowAll(on) } }))
                    .toggleStyle(.checkbox)
                    .themeFont(theme.typeMeta)
                    .accessibilityIdentifier("calendar.showAll")
            }
        }
        .padding(.horizontal, theme.space5)
        .padding(.vertical, theme.space4)
    }

    @ViewBuilder
    private var dayNavigation: some View {
        if model.dayViewDay == nil {
            dayNavigationRow
        }
    }

    private var dayNavigationRow: some View {
        HStack(spacing: theme.space2) {
            Button { dayKeys.take(); model.moveDayInstantly(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).dayKeyTip(.previousDay)
                .accessibilityLabel("Previous day")
            Button("Today") { dayKeys.take(); model.goToTodayInstantly() }
                .buttonStyle(.borderless).dayKeyTip(.today)
            Button { dayKeys.take(); model.moveDayInstantly(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).dayKeyTip(.nextDay)
                .accessibilityLabel("Next day")
            Spacer(minLength: 0)
        }
        .themeFont(theme.typeMeta)
        .accessibilityIdentifier("calendar.dayNavigation")
    }

    private var availabilityFollow: CalendarSidebarModel.AvailabilityContext? {
        model.suggestion == nil ? nil : model.availabilityContext(for: availabilityComposer)
    }

    private var summaryLine: String? {
        if model.showsPickedTime {
            return model.pickedTime?.key == nil
                ? String(localized: "The time from the message is on the calendar. Click it to create an event.")
                : String(localized: "The time from your draft is on the calendar. Click it to create an event.")
        }
        if model.followsDraft { return String(localized: "Days your draft mentions:") }
        if model.isBrowsing || model.thread == nil { return nil }
        return model.mentionCount == 0 ? String(localized: "This conversation mentions no dates. Today:")
                                       : String(localized: "Days this conversation mentions:")
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: theme.space2) {
            if let line = summaryLine {
                Text(line).themeFont(theme.typeMeta).foregroundStyle(theme.textSecondary.color)
            }
            if let note = model.calendarNote {
                Text(note).themeFont(theme.typeMeta)
                    .foregroundStyle(model.connectIsReconnect ? theme.textWarning.color : theme.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("calendar.notConnected")
            }
            if let title = model.connectTitle {
                HStack(spacing: theme.space2) {
                    Button(title) { Task { await model.connectShownCalendar() } }
                        .disabled(model.isConnecting)
                        .accessibilityIdentifier("calendar.connect")
                    if model.isConnecting { ProgressView().controlSize(.small) }
                }
            }
            if let error = model.connectError {
                Text(error).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.thread != nil {
                Button("Create event from email…") { Task { await model.beginDraft(for: nil) } }
                    .disabled(model.draft != nil)
                    .accessibilityIdentifier("calendar.createDraft")
            }
            Button("Suggest times") {
                let live = model.availabilityContext(for: availabilityComposer)
                Task { await model.suggestTimes(for: live) }
            }
                .disabled(model.isSuggesting)
                .help("Up to 3 free 30-minute times in the next five working days, as text. Nothing is added to your calendar.")
                .accessibilityIdentifier("calendar.suggestTimes")
        }
        if let suggestion = model.suggestion,
           !model.isForAnotherConversation(model.availabilityContext(for: availabilityComposer)) {
            suggestionBox(suggestion)
        } else if let note = model.suggestionNote {
            Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
        }
        if case .failed(let message) = model.state {
            Text(message).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
        }
    }

    private var availabilityComposer: ComposeSession? {
        guard let session = router.environment.composeIfStarted?.windowSession, session.isOpen else { return nil }
        return session
    }

    private func suggestionBox(_ suggestion: CalendarAvailability) -> some View {
        let text = model.suggestionText(suggestion) ?? ""
        let composer = availabilityComposer
        let live = model.availabilityContext(for: composer)
        let stale = model.staleReason(for: live)
        let inserted = model.hasInsertedAvailability(in: composer)
        return VStack(alignment: .leading, spacing: theme.space3) {
            HStack(alignment: .center, spacing: theme.space2) {
                Text("Suggested times").themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
                Spacer(minLength: 0)
                if model.isSuggesting { ProgressView().controlSize(.mini) }
                CalendarHeaderGlyph(symbol: "xmark", help: "Clear the suggested times", label: "Clear the suggested times") {
                    model.clearSuggestion()
                }
                .accessibilityIdentifier("calendar.suggestion.clear")
            }
            Text(text).themeFont(theme.typeMeta).foregroundStyle(theme.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .opacity(stale == nil ? 1 : 0.45)
                .animation(.easeOut(duration: 0.2), value: stale)
                .accessibilityIdentifier("calendar.suggestion.text")
            if let stale { staleLine(stale, live: live) }
            Toggle("Ignore conflicts", isOn: Binding(
                get: { model.ignoreConflictsSetting.value },
                set: { on in Task { await model.ignoreConflictsSetting.set(on); await model.suggestTimes(for: live) } }))
                .accessibilityIdentifier("calendar.ignoreConflicts")
            if let note = model.suggestionNote {
                Text(note).themeFont(theme.typeCaption).foregroundStyle(theme.textWarning.color)
            }
            if inserted, let composer { insertedLine(composer, stale: stale != nil) }
            HStack(spacing: theme.space3) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if let composer, !inserted {
                    Button("Insert in draft") { Task { await model.insertAvailability(into: composer) } }
                        .help("Puts the times in the open draft  ⇧⌘A")
                        .accessibilityIdentifier("calendar.insertAvailability")
                }
                Button("Other times") { Task { await model.suggestTimes(for: live, others: true) } }
                    .disabled(model.isSuggesting)
                    .help("Skips these times and offers the next free ones")
                    .accessibilityIdentifier("calendar.suggestion.other")
            }
            Text("Text only: nothing is added to your calendar.")
                .themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
        .padding(theme.space4)
        .background(RoundedRectangle(cornerRadius: theme.radiusLG).fill(theme.bgWindow.color))
        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG)
            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.suggestion")
    }

    static let staleDelay: Duration = .milliseconds(450)

    private func staleLine(_ stale: CalendarSidebarModel.StaleReason,
                           live: CalendarSidebarModel.AvailabilityContext) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space2) {
            Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
            Text(model.isSuggesting ? String(localized: "Finding times again…") : stale.text)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isSuggesting {
                Button("Update") { Task { await model.suggestTimes(for: live) } }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("calendar.suggestion.update")
            }
        }
        .themeFont(theme.typeCaption)
        .foregroundStyle(theme.textWarning.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.suggestion.stale")
    }

    private func insertedLine(_ composer: ComposeSession, stale: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space3) {
            Label("In your draft", systemImage: "checkmark.circle.fill")
                .foregroundStyle(theme.textSuccess.color)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
            Button("Replace") { Task { await model.insertAvailability(into: composer) } }
                .buttonStyle(.link)
                .help(stale ? "Puts the new times in place of the ones in the draft"
                            : "Puts these times in place of the ones in the draft")
                .accessibilityIdentifier("calendar.suggestion.replace")
            Button("Remove") { model.removeInsertedAvailability(from: composer) }
                .buttonStyle(.link)
                .help("Takes the times out of the draft. ⌘Z in the draft puts them back.")
                .accessibilityIdentifier("calendar.suggestion.remove")
        }
        .themeFont(theme.typeMeta)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.suggestion.inserted")
    }

    @ViewBuilder
    private func pickedConflicts(_ timeline: CalendarDayTimeline) -> some View {
        let found = timeline.conflicts
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(found) { event in
                    Label {
                        Text("Busy then: \(event.title) · \(model.timeText(event.start, event.end))")
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textWarning.color)
                }
            }
            .accessibilityIdentifier("calendar.dayView.pickedTime.conflicts")
        }
    }

    private var composerFollow: ComposerFollow? {
        guard let session = router.environment.composeIfStarted?.keySession else { return nil }
        return ComposerFollow(session: session.id, revision: session.documentRevision)
    }

    @ViewBuilder
    private func otherDays(besides shown: CalendarSidebarModel.Day) -> some View {
        let others = model.days.filter { $0.start != shown.start }
        if !others.isEmpty {
            HStack(spacing: theme.space2) {
                Text("Also mentioned:").themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                ForEach(others) { day in
                    Button(model.dayHeader(day)) { dayKeys.take(); Task { await model.show(day: day.start) } }
                        .buttonStyle(.link)
                        .themeFont(theme.typeCaption)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.otherDays")
        }
    }

    @ViewBuilder
    private func freeTimes(_ day: CalendarSidebarModel.Day) -> some View {
        if !day.free.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Free (\(model.workdayText(day)))")
                    .themeFont(theme.typeLabel).foregroundStyle(theme.textTertiary.color)
                ForEach(day.free, id: \.start) { gap in
                    timeLines(gap.start, gap.end, allDay: false, style: theme.typeMeta, color: theme.textSuccess)
                }
            }
            .accessibilityElement(children: .combine)
        } else if !day.busy.isEmpty {
            Text("No free time \(model.workdayText(day))")
                .themeFont(theme.typeMeta).foregroundStyle(theme.textTertiary.color)
        }
    }

    @ViewBuilder
    private func timeLines(_ start: Date, _ end: Date, allDay: Bool, style: TypeStyle, color: ThemeColor) -> some View {
        Text(model.timeText(start, end, allDay: allDay)).themeFont(style).foregroundStyle(color.color)
        if let second = model.secondTimeText(start, end, allDay: allDay) {
            Text(second).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
        }
    }
}

// The new event floats over the calendar as a card, so nothing under it moves; the day stays in place under it and
// is there as it was when the card closes. The card fits the panel's width, scrolls its fields when they are taller
// than the panel, and always shows Save and Cancel.
struct CalendarDraftOverlay: View {
    @Bindable var model: CalendarSidebarModel
    var takeKeys: () -> Void = {}
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if model.draft != nil {
                theme.component.sidebar.bg.color.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                    .accessibilityHidden(true)
                GeometryReader { proxy in
                    let inset = theme.space3
                    let width = max(proxy.size.width - 2 * inset, 0)
                    CalendarDraftEditor(model: model, showsDay: false, showsConflicts: true, width: width,
                                        maxHeight: max(proxy.size.height - 2 * inset, 160), takeKeys: takeKeys)
                        .frame(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: theme.radiusLG, style: .continuous))
                        .themeShadow(theme.component.popover.shadow)
                        .padding(inset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .transition(reduceMotion ? AnyTransition.opacity
                                         : AnyTransition.offset(y: -8).combined(with: .opacity))
                .accessibilityIdentifier("calendar.draftCard")
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.24), value: model.draft != nil)
    }
}

struct CalendarDraftEditor: View {
    @Bindable var model: CalendarSidebarModel
    var showsDay = true
    var showsConflicts: Bool?
    // The card's width, and its tallest height when its fields scroll inside it
    var width: CGFloat
    var maxHeight: CGFloat?
    var onCancel: (() -> Void)?
    var takeKeys: () -> Void = {}
    var title: String?
    var drawsBackground = true
    @Environment(\.theme) private var theme
    @State private var feedback: PendingEventStore.Feedback?
    @State private var calendarChoices: [CalendarSidebarModel.DraftCalendarChoice] = []

    var body: some View {
        if let draft = model.draft {
            Group {
                if let maxHeight {
                    CalendarCardColumn(maxHeight: maxHeight) {
                        if let title { header(title) }
                        CalendarCardScroll(width: width) {
                            fields(draft).padding(theme.space4)
                        }
                        .calendarCardScrolls()
                        Rectangle().fill(theme.borderHairline.color).frame(height: theme.borderWidthHairline)
                        actions
                            .padding(.horizontal, theme.space4)
                            .padding(.vertical, theme.space3)
                    }
                } else {
                    VStack(alignment: .leading, spacing: theme.space3) {
                        fields(draft)
                        actions
                    }
                    .padding(theme.space4)
                }
            }
            .environment(\.timeZone, model.timeZone)
            .task { calendarChoices = await model.draftCalendarChoices() }
            .onExitCommand { cancel() }
            .background {
                if drawsBackground {
                    RoundedRectangle(cornerRadius: theme.radiusLG, style: .continuous)
                        .fill(theme.component.popover.bg.color)
                        .overlay(RoundedRectangle(cornerRadius: theme.radiusLG, style: .continuous)
                            .strokeBorder(theme.borderHairline.color, lineWidth: theme.borderWidthHairline))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New event")
            .accessibilityIdentifier("calendar.draft")
        }
    }

    @ViewBuilder
    private func fields(_ draft: CalendarEventDraft) -> some View {
        VStack(alignment: .leading, spacing: theme.space3) {
            CalendarEventFormView(
                form: Binding(get: { CalendarEventForm(draft: model.draft ?? draft) },
                              set: { form in
                                  // A focused field commits as the cancelled form goes away; that must not bring the draft back
                                  guard let current = model.draft else { return }
                                  model.draft = form.applying(to: current)
                              }),
                rights: CalendarFieldRights.forNewEvent(refusal: model.createRefusal),
                timeZone: model.timeZone, idPrefix: "calendar.draft", meetLink: nil,
                titleIsSuggested: model.titleIsSuggested, focusesTitle: model.titleIsSuggested,
                asksSendUpdates: !(model.draft ?? draft).attendees.isEmpty,
                sendUpdates: Binding(get: { (model.draft ?? draft).sendUpdates },
                                     set: { choice in model.draft?.sendUpdates = choice }),
                isNewEvent: true,
                calendarName: model.calendarLine, calendarMenu: calendarMenu,
                suggestGuests: { [model] prefix in await model.guestSuggestions(prefix) },
                pendingGuest: $model.pendingGuest, pendingGuestNote: model.pendingGuestNote)
            if !draft.provenance.isEmpty {
                Text(draft.provenance).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .padding(.horizontal, CalendarFormMetrics.rowPaddingX)
                    .accessibilityIdentifier("calendar.draft.provenance")
            }
            if let second = model.secondTimeText(draft.start, draft.end) {
                Text(second).themeFont(theme.typeCaption).foregroundStyle(theme.textTertiary.color)
                    .padding(.horizontal, CalendarFormMetrics.rowPaddingX)
            }
            if let day = model.dayViewDay {
                if showsDay {
                    CalendarDayView(model: model, day: day, strikesConflicts: true, takeKeys: takeKeys, compact: true)
                }
                if showsConflicts ?? showsDay { conflicts(model.timeline(for: day)) }
            }
            status(draft)
        }
    }

    @ViewBuilder
    private func conflicts(_ timeline: CalendarDayTimeline) -> some View {
        let found = timeline.conflicts
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(found) { event in
                    Label {
                        Text("Conflicts with \(event.title) · \(model.timeText(event.start, event.end))")
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                    .themeFont(theme.typeCaption).foregroundStyle(theme.textDanger.color)
                }
            }
            .accessibilityIdentifier("calendar.draft.conflicts")
        }
    }

    private var calendarMenu: CalendarFormCalendarMenu? {
        guard calendarChoices.count > 1 else { return nil }
        let current = (model.draftCalendarAccount ?? "").lowercased()
        return CalendarFormCalendarMenu(
            selected: current,
            choices: calendarChoices.map { (id: $0.id, title: $0.title) },
            choose: { [model, calendarChoices] id in
                guard let choice = calendarChoices.first(where: { $0.id == id }) else { return }
                Task { await model.chooseDraftCalendar(account: choice.account) }
            })
    }

    @ViewBuilder
    private func status(_ draft: CalendarEventDraft) -> some View {
        if model.createRefusal == nil, let problem = draft.problem {
            Text(problem).themeFont(theme.typeMeta).foregroundStyle(theme.textWarning.color)
        }
        if let note = model.draftNote, note != model.createRefusal {
            Text(note).themeFont(theme.typeMeta).foregroundStyle(theme.textDanger.color)
        }
    }

    static let headerHeight: CGFloat = CalendarEventCardView.headerHeight

    private func header(_ title: String) -> some View {
        HStack(spacing: theme.space3) {
            Circle().fill(theme.accentFill.color).frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .themeFont(theme.typeLabel).foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.space2)
            Button { cancel() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.textPrimary.color.opacity(CalendarFormMetrics.sectionFillOpacity * 2)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary.color)
            .help("Close  Esc")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("calendar.draft.close")
        }
        .padding(.leading, theme.space5)
        .padding(.trailing, theme.space3)
        .frame(height: Self.headerHeight)
    }

    // Feedback on the suggestion at the leading edge, Cancel and Save at the trailing edge, as in a system sheet
    private var actions: some View {
        HStack(spacing: theme.space3) {
            thumb(.up, symbol: "hand.thumbsup", label: "Good suggestion")
            thumb(.down, symbol: "hand.thumbsdown", label: "Bad suggestion")
            Spacer(minLength: 0)
            Button("Cancel") { cancel() }
                .help(onCancel == nil ? "Cancel and go back to the email  Esc" : "Cancel  Esc")
                .accessibilityIdentifier("calendar.draft.cancel")
            // Why: Return types a new line in the notes and adds a guest, so Save takes Command-Return
            Button("Save") { Task { await model.createEvent() } }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentFill.color)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCreate)
                .help(model.createRefusal ?? String(localized: "Save the event  ⌘↵"))
                .accessibilityHint(model.createRefusal ?? String(localized: "Command-Return"))
                .accessibilityIdentifier("calendar.draft.create")
        }
    }

    private func cancel() {
        if let onCancel { onCancel() } else { model.cancelDraft() }
    }

    private func thumb(_ value: PendingEventStore.Feedback, symbol: String, label: String) -> some View {
        Button {
            guard feedback == nil else { return }
            feedback = value
            model.recordFeedback(value)
        } label: {
            Image(systemName: feedback == value ? symbol + ".fill" : symbol)
        }
        .buttonStyle(.borderless)
        .foregroundStyle((feedback == value ? theme.textPrimary : theme.textTertiary).color)
        .help("\(label) (kept on this Mac only)")
        .accessibilityLabel(label)
        .accessibilityAddTraits(feedback == value ? .isSelected : [])
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

    static let iconColumn: CGFloat = 24

    static func address(_ text: String) -> EmailAddress? {
        var name: String?
        var email = text
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            email = String(text[text.index(after: open)..<close])
            let before = text[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            name = before.isEmpty ? nil : before
        }
        email = email.trimmingCharacters(in: .whitespaces)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !email.contains(" ") else { return nil }
        return EmailAddress(name: name, email: email)
    }
}

struct CalendarDayKeys: NSViewRepresentable {
    let model: CalendarSidebarModel
    let focus: CalendarDayKeyFocus

    func makeNSView(context: Context) -> CalendarDayKeyView {
        let view = CalendarDayKeyView()
        view.model = model
        focus.view = view
        return view
    }

    func updateNSView(_ view: CalendarDayKeyView, context: Context) {
        view.model = model
        focus.view = view
    }
}

@MainActor
final class CalendarDayKeyFocus {
    weak var view: CalendarDayKeyView?

    func take() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

final class CalendarDayKeyView: NSView, TextInputHost {
    weak var model: CalendarSidebarModel?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.keyCode == 53 {
            if let model, model.openedEvent != nil {
                model.closeEvent(keepsFocus: true)
            } else if let model, model.showsPickedTime {
                model.dismissPickedTime()
            } else {
                window?.makeFirstResponder(nil)
            }
            return true
        }
        guard let model else { return false }
        switch event.keyCode {
        case 36, 76:
            if model.openFocusedEvent() { return true }
            guard model.showsPickedTime else { return false }
            Task { await model.createEventAtPickedTime() }
            return true
        case 125: return model.moveEventFocus(by: 1)
        case 126: return model.moveEventFocus(by: -1)
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "-": model.moveDayInstantly(by: -1)
        case "=", "+": model.moveDayInstantly(by: 1)
        case "t", "T": model.goToTodayInstantly()
        default: return false
        }
        return true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        String(localized: "Calendar days. Minus for the day before, equals for the day after, T for today. Up and down arrows choose an event, Return shows its details, Escape closes them.")
    }
}

private struct CalendarHeaderGlyph: View {
    let symbol: String
    let help: String
    let label: String
    var shortcut: ActionID?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle((hovered ? theme.textPrimary : theme.textSecondary).color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .shortcutTip(shortcut, title: help, orHelp: help)
        .accessibilityLabel(label)
    }
}

enum CalendarDayKey {
    case previousDay, today, nextDay

    var tip: ShortcutTip {
        switch self {
        case .previousDay: ShortcutTip(title: String(localized: "Previous day"), keycaps: ["−"])
        case .today: ShortcutTip(title: String(localized: "Today"), keycaps: ["T"])
        case .nextDay: ShortcutTip(title: String(localized: "Next day"), keycaps: ["="])
        }
    }
}

extension View {
    func dayKeyTip(_ key: CalendarDayKey) -> some View {
        let tip = key.tip
        return shortcutTip(tip).accessibilityHint(tip.spokenDetail)
    }
}
