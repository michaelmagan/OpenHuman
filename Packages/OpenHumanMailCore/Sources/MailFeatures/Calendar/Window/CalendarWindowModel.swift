import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class CalendarWindowModel {
    public enum LoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public struct Source: Identifiable, Hashable, Sendable {
        public let key: String
        public var id: String { key }
        public let title: String
        public let colorIndex: Int
        public let isVisible: Bool
    }

    public enum Tip: String, Sendable {
        case open = "2"
        case back = "1"

        public var message: String {
            switch self {
            case .open: String(localized: "Next time, hit 2 to go to Calendar instantly!")
            case .back: String(localized: "Next time, hit 1 to go back to your mail.")
            }
        }
    }

    public private(set) var isOpen = false
    public private(set) var kind: CalendarViewKind = .week
    public private(set) var period: CalendarPeriod
    public private(set) var focusDay: Date
    public private(set) var events: [CalendarEvent] = []
    public private(set) var sources: [Source] = []
    public private(set) var state: LoadState = .idle
    public private(set) var progress: CalendarLoadProgress?
    public private(set) var note: String?
    public private(set) var lastRead: Date?
    public internal(set) var selectedEventID: String?
    public var card: CalendarEventCard?
    public internal(set) var scopeQuestion: CalendarScopeQuestion?
    public internal(set) var removeQuestion: CalendarRemoveQuestion?
    public private(set) var meetNote: String?
    public private(set) var hiddenKeys: Set<String> = []

    var overlays: [UUID: Overlay] = [:]

    @ObservationIgnored public var timeZone: TimeZone
    @ObservationIgnored public var now: @MainActor () -> Date
    @ObservationIgnored public var confirmsMovesOverride: Bool?
    @ObservationIgnored public var holdWindow: Duration = NoticeCenter.toastDuration
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored public var schedule = CalendarRefreshSchedule()

    @ObservationIgnored unowned let environment: AppEnvironment
    @ObservationIgnored public let sidebar: CalendarSidebarModel
    @ObservationIgnored var providers: [String: any CalendarProviding] = [:]
    @ObservationIgnored var storeKeys: [String: CalendarCacheKey] = [:]
    @ObservationIgnored private var storeObserver: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var slotKeys: Set<PendingEventKey> = []
    @ObservationIgnored var held: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var undoable: [UUID: @MainActor () async throws -> Void] = [:]
    @ObservationIgnored var undoerStorage: CalendarWindowUndoer?

    public let eventStore: CalendarEventStore

    public init(environment: AppEnvironment, sidebar: CalendarSidebarModel, timeZone: TimeZone = .current,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.environment = environment
        self.sidebar = sidebar
        eventStore = environment.calendarEvents
        self.timeZone = timeZone
        self.now = now
        let calendar = CalendarDateMentions.calendar(timeZone)
        let today = calendar.startOfDay(for: now())
        focusDay = today
        period = CalendarPeriod.containing(today, kind: .week, calendar: calendar)
        sidebar.didWrite = { [weak self] in
            guard let self, self.isOpen else { return }
            Task { await self.load(force: true) }
        }
        storeObserver = eventStore.observe { [weak self] change in self?.cacheChanged(change) }
    }

    var calendar: Calendar { CalendarDateMentions.calendar(timeZone) }

    public func open(_ requested: CalendarViewKind? = nil, source: ActionSource? = nil, around day: Date? = nil) async {
        let wasOpen = isOpen
        isOpen = true
        if !wasOpen {
            sidebar.activeAccount = { [weak router = environment.router] in router?.activeAccountID }
            hiddenKeys = Set(await read(AppSettings.calendarHiddenCalendars))
        }
        let stored = wasOpen ? kind : await read(AppSettings.calendarWindowView)
        let chosen = requested ?? stored
        let anchor = day ?? sidebar.draft?.start ?? (wasOpen ? focusDay : now())
        show(chosen, around: anchor)
        paint()
        if requested != nil, requested != stored { await write(AppSettings.calendarWindowView, chosen) }
        if !wasOpen, let source { await tip(.open, source: source) }
        await load(force: false)
    }

    public func openEditor(for event: CalendarEvent, calendarKey: String) async {
        await open(around: event.start)
        let key = calendarKey.lowercased()
        let shown = shownEvents.first { $0.id == event.id && ($0.account ?? "").lowercased() == key }
        var target = shown ?? event
        if shown == nil, target.account == nil, !key.isEmpty { target.account = key }
        openEvent(target)
    }

    public func close(source: ActionSource? = nil) async {
        guard isOpen else { return }
        stepAside()
        if let source { await tip(.back, source: source) }
    }

    public func stepAside() {
        guard isOpen else { return }
        isOpen = false
        noteUnsavedMove()
        card = nil
        scopeQuestion = nil
        removeQuestion = nil
        meetNote = nil
    }

    public func escape() async {
        if removeQuestion != nil {
            removeQuestion = nil
        } else if scopeQuestion != nil {
            scopeQuestion = nil
        } else if card != nil {
            closeCard()
        } else if sidebar.draft != nil {
            await cancelPending()
        } else {
            await close()
        }
    }

    public func cycleView() async {
        switch kind {
        case .day:
            await setKind(.week)
        default:
            sidebar.setVisible(true)
            await close()
        }
    }

    public func setKind(_ newKind: CalendarViewKind) async {
        show(newKind, around: focusDay)
        paint()
        await write(AppSettings.calendarWindowView, newKind)
        await load(force: false)
    }

    public func move(by delta: Int) async {
        period = period.moved(by: delta, calendar: calendar)
        let today = calendar.startOfDay(for: now())
        focusDay = period.contains(today) ? today : (period.month ?? period.start)
        paint()
        await load(force: false)
    }

    public func goToToday() async {
        show(kind, around: now())
        paint()
        await load(force: false)
    }

    public func show(day: Date) async {
        show(kind, around: day)
        paint()
        await load(force: false)
    }

    private func show(_ newKind: CalendarViewKind, around date: Date) {
        kind = newKind
        focusDay = calendar.startOfDay(for: date)
        period = CalendarPeriod.containing(focusDay, kind: newKind, calendar: calendar)
    }

    func calendarSources() async -> [(key: String, title: String, provider: any CalendarProviding)] {
        if let connections = environment.calendarConnections, connections.routesByAccount {
            let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
            eventStore.learnAddresses(of: accounts)
            return accounts.compactMap { owner in
                connections.calendarProvider(for: owner).map { (owner.email.lowercased(), owner.email, $0) }
            }
        }
        let provider = sidebar.provider
        return [((provider.info.account ?? "").lowercased(), provider.info.account ?? provider.info.name, provider)]
    }

    public func load(force: Bool) async {
        generation += 1
        let mine = generation
        let all = await calendarSources()
        guard mine == generation, !Task.isCancelled else { return }
        let store = eventStore
        await store.restore(now: now())
        guard mine == generation, !Task.isCancelled else { return }
        providers = Dictionary(all.map { ($0.key, $0.provider) }, uniquingKeysWith: { first, _ in first })
        storeKeys = Dictionary(all.map { ($0.key, CalendarEventStore.key(for: $0.provider)) },
                               uniquingKeysWith: { first, _ in first })
        sources = all.enumerated().map { position, item in
            Source(key: item.key, title: item.title, colorIndex: Self.colorIndex(atPosition: position),
                   isVisible: !hiddenKeys.contains(item.key))
        }
        let visible = all.filter { !hiddenKeys.contains($0.key) }
        let shown = period
        let calendar = calendar
        let current = now()
        if !paint(), events.isEmpty { state = .loading }
        let due = visible.filter { item in
            let key = CalendarEventStore.key(for: item.provider)
            return force || !store.covers(key, from: shown.start, to: shown.end) || store.isDue(key, now: current)
        }
        if !due.isEmpty { progress = CalendarLoadProgress(done: 0, total: due.count) }
        defer { if mine == generation { progress = nil } }
        for (index, item) in due.enumerated() {
            if Task.isCancelled { return }
            if mine == generation { progress?.done = index + 1 }
            let key = CalendarEventStore.key(for: item.provider)
            if store.covers(key, from: shown.start, to: shown.end) {
                await store.revalidate(key, provider: item.provider, visible: DateInterval(start: shown.start, end: shown.end),
                                       today: current, calendar: calendar, now: current, force: force)
            } else {
                await store.ensure(key, provider: item.provider, from: shown.start, to: shown.end, today: current,
                                   calendar: calendar, now: current)
            }
            guard mine == generation, !Task.isCancelled else { return }
        }
        guard mine == generation, !Task.isCancelled else { return }
        for item in visible {
            let key = CalendarEventStore.key(for: item.provider)
            for day in [shown.start, shown.days.last ?? shown.start] {
                store.prefetchAdjacent(key, provider: item.provider, around: day, calendar: calendar, now: current)
            }
        }
        let complete = paint()
        schedule.lastRead = now()
        var failures: [String] = []
        var staleSince: Date?
        for item in visible {
            let key = CalendarEventStore.key(for: item.provider)
            guard let error = store.lastError(key), !store.isUpdating(key) else { continue }
            if store.covers(key, from: shown.start, to: shown.end) {
                let read = store.ranges(key).filter { $0.start < shown.end && $0.end > shown.start }.map(\.fetchedAt).min()
                staleSince = min(staleSince ?? read ?? current, read ?? current)
            } else {
                failures.append(visible.count > 1
                    ? String(localized: "Couldn't read the calendar of \(item.title). \(error)")
                    : String(localized: "Couldn't read the calendar. \(error)"))
            }
        }
        if failures.isEmpty && staleSince == nil { lastRead = now() }
        let text: String?
        if let staleSince {
            let time = staleSince.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
            text = String(localized: "Offline: showing your calendar as of \(time). Mail tries again in a minute.")
        } else {
            text = failures.first
        }
        if note != text { note = text }
        state = !visible.isEmpty && !complete && failures.count == visible.count && events.isEmpty ? .failed(failures[0])
            : .loaded
    }

    @discardableResult
    func paint() -> Bool {
        let store = eventStore
        let routed = environment.calendarConnections?.routesByAccount == true
        var merged: [CalendarEvent] = []
        var complete = true
        var any = false
        for source in sources where source.isVisible {
            any = true
            guard let key = storeKeys[source.key],
                  let found = store.events(key, from: period.start, to: period.end, includeDeclined: true) else {
                complete = false
                continue
            }
            merged += found.map { event in
                guard routed || event.account == nil, !source.key.isEmpty else { return event }
                var tagged = event
                tagged.account = source.key
                return tagged
            }
        }
        let sorted = merged.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        if events != sorted { events = sorted }
        if any, complete, state != .loaded { state = .loaded }
        return complete
    }

    private func cacheChanged(_ change: CalendarEventStoreChange) {
        guard isOpen, storeKeys.values.contains(change.key) else { return }
        paint()
    }

    public func windowDidBecomeKey() async {
        guard isOpen, schedule.refreshesOnFocus(now: now()) else { return }
        await load(force: true)
    }

    public func tick() async {
        guard isOpen, schedule.isDue(now: now()) else { return }
        await load(force: false)
    }

    public func refresh() async {
        await load(force: true)
    }

    func storeKey(for event: CalendarEvent) -> CalendarCacheKey? {
        let (key, found) = provider(for: event)
        return storeKeys[key] ?? found.map { CalendarEventStore.key(for: $0) }
    }

    static func untagged(_ event: CalendarEvent) -> CalendarEvent {
        var clean = event
        clean.account = nil
        return clean
    }

    public func setVisible(_ key: String, _ visible: Bool) async {
        if visible { hiddenKeys.remove(key) } else { hiddenKeys.insert(key) }
        sources = sources.map {
            Source(key: $0.key, title: $0.title, colorIndex: $0.colorIndex, isVisible: !hiddenKeys.contains($0.key))
        }
        paint()
        await write(AppSettings.calendarHiddenCalendars, hiddenKeys.sorted())
        await load(force: false)
    }

    public var shownEvents: [CalendarEvent] {
        var out = events
        for overlay in overlays.values {
            switch overlay {
            case .times(let id, let start, let end):
                if let index = out.firstIndex(where: { $0.id == id }) {
                    let old = out[index]
                    out[index] = old.with(start: start, end: end)
                }
            case .removed(let id):
                out.removeAll { $0.id == id }
            case .response(let id, let response):
                if let index = out.firstIndex(where: { $0.id == id }) { out[index].myResponse = response }
            }
        }
        if let card, card.pendingMove != nil, let index = out.firstIndex(where: { $0.id == card.event.id }) {
            out[index] = out[index].with(start: card.form?.start ?? card.start, end: card.form?.end ?? card.end)
        }
        return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    public var timeGrid: CalendarTimeGrid {
        let sources = sources
        return CalendarTimeGrid(days: period.days, events: shownEvents, timeZone: timeZone, now: now(),
                                colorIndex: { Self.colorIndex(of: $0, in: sources) })
    }

    public static let colorOrder = [0, 2, 3, 4, 1, 5]

    public static func colorIndex(atPosition position: Int) -> Int { colorOrder[position % colorOrder.count] }

    public func colorIndex(for event: CalendarEvent) -> Int { Self.colorIndex(of: event, in: sources) }

    static func colorIndex(of event: CalendarEvent, in sources: [Source]) -> Int {
        let key = (event.account ?? "").lowercased()
        return (sources.first { $0.key == key } ?? sources.first)?.colorIndex ?? Self.colorIndex(atPosition: 0)
    }

    public var monthGrid: CalendarMonthGrid {
        CalendarMonthGrid(period: period, events: shownEvents, timeZone: timeZone, now: now())
    }

    public var miniMonth: CalendarMiniMonth { CalendarMiniMonth(containing: focusDay, timeZone: timeZone) }

    public var pendingSlot: DateInterval? {
        guard card == nil, let draft = sidebar.draft, draft.end > draft.start else { return nil }
        return DateInterval(start: draft.start, end: draft.end)
    }

    public var showsPendingCard: Bool { card == nil && sidebar.draft != nil }

    public var pendingPlacement: (dayIndex: Int, top: Double, height: Double)? {
        guard let slot = pendingSlot else { return nil }
        for (index, day) in period.days.enumerated() {
            let next = CalendarTimeGrid.nextMidnight(after: day, calendar: calendar)
            guard slot.end > day, slot.start < next else { continue }
            let top = CalendarTimeGrid.offset(slot.start, day: day, next: next, calendar: calendar)
            let bottom = CalendarTimeGrid.offset(slot.end, day: day, next: next, calendar: calendar)
            return (index, top, max(bottom - top, CalendarTimeGrid.minimumHeight))
        }
        return nil
    }

    public func show(day: Date, as newKind: CalendarViewKind) async {
        let changed = newKind != kind
        show(newKind, around: day)
        paint()
        if changed { await write(AppSettings.calendarWindowView, newKind) }
        await load(force: false)
    }

    public func account(forCalendar key: String) async -> AccountID? {
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        return accounts.first { $0.email.lowercased() == key }?.id
    }

    public func newEvent(start: Date, end: Date) async {
        noteUnsavedMove()
        card = nil
        selectedEventID = nil
        if sidebar.draft != nil {
            sidebar.draft?.start = start
            sidebar.draft?.end = max(end, start.addingTimeInterval(CalendarDragMath.step))
            return
        }
        let key = PendingEventKey.draft(UUID())
        slotKeys.insert(key)
        await sidebar.beginDraft(start: start, end: end, key: key)
    }

    // Dragging the event being prepared keeps its length; only a timed draft moves on the grid
    public func movePending(to start: Date) {
        guard card == nil, var made = sidebar.draft, !made.isAllDay else { return }
        let moved = CalendarDragMath.moved(from: made.start, until: made.end, to: start)
        guard moved.start != made.start || moved.end != made.end else { return }
        made.start = moved.start
        made.end = moved.end
        sidebar.draft = made
    }

    public func resizePending(to end: Date) {
        guard card == nil, var made = sidebar.draft, !made.isAllDay else { return }
        let resized = CalendarDragMath.resized(from: made.start, to: end)
        guard resized.end != made.end else { return }
        made.end = resized.end
        sidebar.draft = made
    }

    public func newEvent() async {
        let start: Date
        let current = now()
        if period.contains(current) {
            let minute = calendar.component(.minute, from: current)
            let hourStart = calendar.date(bySettingHour: calendar.component(.hour, from: current), minute: 0, second: 0,
                                          of: current) ?? current
            start = hourStart.addingTimeInterval(minute < 30 ? 30 * 60 : 60 * 60)
        } else {
            start = calendar.date(bySettingHour: CalendarEventDraftBuilder.defaultHour, minute: 0, second: 0,
                                  of: focusDay) ?? focusDay
        }
        await newEvent(start: start, end: start.addingTimeInterval(CalendarEventDraftBuilder.defaultDuration))
    }

    public func cancelPending() async {
        guard let key = sidebar.draftKey else { return }
        if slotKeys.contains(key) {
            slotKeys.remove(key)
            sidebar.dropDraft()
        } else {
            sidebar.cancelDraft()
            await close()
        }
    }

    public var pendingIsFromCalendar: Bool { sidebar.draftKey.map(slotKeys.contains) ?? false }

    @discardableResult
    public func meet(with text: String) async -> String? {
        guard let person = Self.address(text) else {
            meetNote = String(localized: "Type an email address.")
            return meetNote
        }
        meetNote = nil
        guard let slot = firstFreeSlot() else {
            meetNote = String(localized: "No free half hour in these days. Pick a time on the grid.")
            return meetNote
        }
        await newEvent(start: slot.start, end: slot.end)
        if let people = sidebar.draft?.attendees, !people.contains(where: { $0.email.lowercased() == person.email.lowercased() }) {
            sidebar.draft?.setAttendees(people + [person])
        }
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let me = accounts.first { $0.id == environment.router.activeAccountID } ?? accounts.first
        if pendingIsFromCalendar, let attendees = sidebar.draft?.attendees,
           let title = CalendarEventDraftBuilder.peopleTitle(me: me, others: attendees) {
            sidebar.draft?.title = title
        }
        return nil
    }

    func firstFreeSlot() -> DateInterval? {
        let busy = shownEvents.filter { !CalendarTimeGrid.belongsInAllDayRow($0) && $0.myResponse != .declined }
        let current = now()
        for day in period.days {
            guard let open = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  let close = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) else { continue }
            var cursor = open
            while cursor.addingTimeInterval(30 * 60) <= close {
                let slot = DateInterval(start: cursor, duration: 30 * 60)
                if cursor >= current, !busy.contains(where: { $0.overlaps(from: slot.start, to: slot.end) }) {
                    return slot
                }
                cursor = cursor.addingTimeInterval(30 * 60)
            }
        }
        return nil
    }

    static func address(_ text: String) -> EmailAddress? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var name: String?
        var email = typed
        if let open = typed.lastIndex(of: "<"), let close = typed.lastIndex(of: ">"), open < close {
            email = String(typed[typed.index(after: open)..<close])
            let before = typed[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            name = before.isEmpty ? nil : before
        }
        email = email.trimmingCharacters(in: .whitespaces)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !email.contains(" ") else { return nil }
        return EmailAddress(name: name, email: email)
    }

    public var title: String {
        period.titleDay.formatted(Date.FormatStyle(timeZone: timeZone).month(.wide).year())
    }

    public func dayHeader(_ day: Date) -> (weekday: String, number: String) {
        let style = Date.FormatStyle(timeZone: timeZone)
        return (day.formatted(style.weekday(.abbreviated)).uppercased(), day.formatted(style.day()))
    }

    public func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now()) }

    public func timeText(_ event: CalendarEvent) -> String {
        event.isAllDay ? String(localized: "All day") : CalendarSidebarModel.range(event.start, event.end, timeZone)
    }

    public var updatedText: String? {
        lastRead.map { String(localized: "Updated \($0.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)))") }
    }

    func tip(_ tip: Tip, source: ActionSource) async {
        var shown = await read(AppSettings.calendarTipsShown)
        guard !shown.contains(tip.rawValue) else { return }
        shown.append(tip.rawValue)
        await write(AppSettings.calendarTipsShown, shown)
        guard source != .keyboard else { return }
        environment.notices.post(tip.message, duration: NoticeCenter.infoDuration)
    }

    func read<V>(_ key: AppSettingKey<V>) async -> V {
        guard let settings = environment.settings, let stored = try? await settings.get(key) else { return key.defaultValue }
        return stored
    }

    func write<V>(_ key: AppSettingKey<V>, _ value: V) async {
        try? await environment.settings?.set(key, value)
    }
}

// Refresh on window focus only if the last read is stale, to stay inside Google's per-minute quota
public struct CalendarRefreshSchedule: Sendable, Hashable {
    public static let interval: TimeInterval = 60
    public static let focusGap: TimeInterval = 10

    public var lastRead: Date?

    public init(lastRead: Date? = nil) {
        self.lastRead = lastRead
    }

    public func isDue(now: Date) -> Bool {
        guard let lastRead else { return true }
        let age = now.timeIntervalSince(lastRead)
        return age < 0 || age >= Self.interval
    }

    public func refreshesOnFocus(now: Date) -> Bool {
        guard let lastRead else { return true }
        let age = now.timeIntervalSince(lastRead)
        return age < 0 || age >= Self.focusGap
    }
}

extension CalendarEvent {
    func with(start: Date, end: Date) -> CalendarEvent {
        var moved = CalendarEvent(id: id, title: title, start: start, end: end, isAllDay: isAllDay, timeZone: timeZone,
                                  attendees: attendees, calendarName: calendarName, meetLink: meetLink,
                                  organizerIsMe: organizerIsMe, account: account, location: location, notes: notes,
                                  myResponse: myResponse, recurringEventID: recurringEventID, extras: extras)
        moved.respondsAs = respondsAs
        return moved
    }
}
