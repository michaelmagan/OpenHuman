import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor
@Observable
public final class InviteCenter {
    public enum Entry: Sendable, Hashable {
        case loading
        case card(InviteCard)
        case unavailable
    }

    public private(set) var entries: [MessageKey: Entry] = [:]
    public private(set) var originals: Set<MessageKey> = []
    public private(set) var connectPrompt: MessageKey?
    public private(set) var notes: [MessageKey: String] = [:]
    public private(set) var calendarRefusals: [MessageKey: String] = [:]
    public private(set) var expandedNotes: Set<MessageKey> = []
    public private(set) var expandedGuests: Set<MessageKey> = []

    @ObservationIgnored public var timeZone: TimeZone = .current
    @ObservationIgnored public var locale: Locale = .current
    @ObservationIgnored public var now: @MainActor () -> Date = Date.init
    @ObservationIgnored public var holdWindow: Duration = NoticeCenter.toastDuration
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var readFile: @Sendable (URL) throws -> String = InviteCenter.readText

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var loads: [MessageKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var threads: [MessageKey: ThreadKey] = [:]
    @ObservationIgnored private var newest: [ThreadKey: [String: Int]] = [:]
    @ObservationIgnored private var answered: [String: CalendarResponse] = [:]
    @ObservationIgnored private var records: [UUID: Record] = [:]
    @ObservationIgnored private var held: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var undoerStorage: InviteRSVPUndoer?

    struct Record {
        enum Stage { case held, sent(CalendarEvent), failed }
        let message: MessageKey
        let thread: ThreadKey
        let invite: CalendarInvite
        let title: String
        var provider: any CalendarProviding
        let response: CalendarResponse
        var previous: CalendarResponse?
        let wholeSeries: Bool
        let doneToken: UndoToken?
        var stage: Stage
    }

    init(environment: AppEnvironment) {
        self.environment = environment
    }


    public func card(for key: MessageKey) -> InviteCard? {
        if case .card(let card)? = entries[key] { return card }
        return nil
    }

    public func showsCard(_ key: MessageKey) -> Bool { card(for: key) != nil && !originals.contains(key) }

    public nonisolated static func calendarPart(of attachments: [AttachmentInfo]) -> AttachmentInfo? {
        attachments.first { $0.mimeType.lowercased() == "text/calendar" }
            ?? attachments.first { $0.mimeType.lowercased() == "application/ics" }
            ?? attachments.first { $0.filename.lowercased().hasSuffix(".ics") }
    }

    public nonisolated static func mayHaveCard(_ message: MessageSummary) -> Bool {
        calendarPart(of: message.attachments) != nil
    }

    public func load(_ message: MessageSummary, in thread: ThreadKey, force: Bool = false) {
        let key = message.id
        threads[key] = thread
        guard force || entries[key] == nil else { return }
        guard let part = Self.calendarPart(of: message.attachments) else {
            entries[key] = .unavailable
            return
        }
        if entries[key] == nil { entries[key] = .loading }
        loads[key]?.cancel()
        let data = environment.data
        let read = readFile
        let zone = timeZone
        loads[key] = Task { [weak self] in
            let invite: CalendarInvite?
            do {
                let url = try await data.attachmentData(key, attachment: part)
                invite = try await Task.detached(priority: .userInitiated) {
                    ICSParser.parse(try read(url), defaultZone: zone)
                }.value
            } catch {
                invite = nil
            }
            guard !Task.isCancelled, let self else { return }
            self.loads[key] = nil
            guard let invite else {
                self.entries[key] = .unavailable
                return
            }
            await self.build(invite, message: message, thread: thread)
        }
    }

    private func build(_ invite: CalendarInvite, message: MessageSummary, thread: ThreadKey) async {
        let addresses = await myAddresses(thread.account)
        var seen = newest[thread] ?? [:]
        seen[invite.uid] = max(seen[invite.uid] ?? invite.sequence, invite.sequence)
        newest[thread] = seen
        var known = answered[Self.answerKey(invite)]
        var conflicts: [CalendarEvent] = []
        let provider = invite.method == .request && !invite.isCancelled ? await calendar(for: thread.account) : nil
        calendarRefusals[message.id] = provider.flatMap(Self.answerRefusal)
        if !invite.isAllDay, let provider {
            let key = CalendarEventStore.key(for: provider)
            let store = environment.calendarEvents
            let to = max(invite.end, invite.start.addingTimeInterval(60))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            await store.ensure(key, provider: provider, from: invite.start, to: to, today: now(), calendar: calendar,
                               now: now())
            if let events = store.events(key, from: invite.start, to: to, includeDeclined: true) {
                let title = invite.title ?? ""
                if known == nil, let same = events.first(where: { $0.title == title && $0.start == invite.start }) {
                    known = same.myResponse
                }
                conflicts = events
            }
        }
        let card = InviteCardBuilder.card(invite, message: message.id, myAddresses: addresses, timeZone: timeZone,
                                          locale: locale, known: known, conflicts: conflicts,
                                          newestSequence: newest[thread]?[invite.uid])
        entries[message.id] = .card(card)
        for (key, entry) in entries where key != message.id && threads[key] == thread {
            guard case .card(var other) = entry, other.invite.uid == invite.uid,
                  other.invite.sequence < (newest[thread]?[invite.uid] ?? 0), !other.isOutdated else { continue }
            other.isOutdated = true
            entries[key] = .card(other)
        }
    }

    private func myAddresses(_ account: AccountID) async -> Set<String> {
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        return accounts.first { $0.id == account }?.myAddresses ?? []
    }

    func calendar(for account: AccountID) async -> (any CalendarProviding)? {
        guard environment.calendar != nil, let sidebar = environment.calendarSidebar else { return nil }
        return await sidebar.calendarOf(account).provider
    }

    nonisolated static func answerRefusal(_ provider: any CalendarProviding) -> String? {
        if let refusal = provider.info.createRefusal { return refusal }
        guard provider.abilities.contains(.respond) else { return cannotAnswer }
        return nil
    }

    nonisolated static var cannotAnswer: String {
        String(localized: "This calendar can't answer invitations from Mail. Answer it in your calendar.")
    }

    nonisolated static var notInvited: String {
        String(localized: "You aren't on this invitation's guest list. Answer it in your calendar.")
    }

    nonisolated static func readText(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: ICSParser.maxBytes) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func answerKey(_ invite: CalendarInvite) -> String {
        "\(invite.uid)|\(invite.occurrence.timeIntervalSince1970)"
    }


    public func toggleOriginal(_ key: MessageKey) {
        if originals.contains(key) { originals.remove(key) } else { originals.insert(key) }
    }

    public func toggleNotes(_ key: MessageKey) {
        if expandedNotes.contains(key) { expandedNotes.remove(key) } else { expandedNotes.insert(key) }
    }

    public func toggleGuests(_ key: MessageKey) {
        if expandedGuests.contains(key) { expandedGuests.remove(key) } else { expandedGuests.insert(key) }
    }

    public func openCalendarSettings() {
        connectPrompt = nil
        _ = environment.actions.perform(.settingsPage("calendar"), source: .toolbar, host: environment.router)
    }

    public func dismissConnectPrompt() {
        connectPrompt = nil
    }

    public func answerBlock(for key: MessageKey) -> String? {
        guard let card = card(for: key), card.offersRSVP else { return nil }
        if !card.isInvited { return Self.notInvited }
        return calendarRefusals[key]
    }

    public func target(focused: MessageKey?, in thread: ThreadKey?, shown: [MessageKey]) -> MessageKey? {
        if let focused, card(for: focused)?.offersRSVP == true, !originals.contains(focused) { return focused }
        return shown.reversed().first { card(for: $0)?.offersRSVP == true && !originals.contains($0) }
    }

    public func respond(_ response: CalendarResponse, to key: MessageKey, wholeSeries: Bool = false) async {
        guard response != .needsAction, var card = card(for: key), card.offersRSVP else { return }
        notes[key] = nil
        guard let provider = await calendar(for: key.account) else {
            connectPrompt = key
            return
        }
        connectPrompt = nil
        if let refusal = Self.answerRefusal(provider) {
            notes[key] = refusal
            return
        }
        guard card.isInvited else {
            notes[key] = Self.notInvited
            return
        }
        guard let thread = threads[key] else { return }
        let previous = card.response
        card.response = response
        entries[key] = .card(card)
        answered[Self.answerKey(card.invite)] = response
        let (token, reopens) = await markDone(thread)
        let id = UUID()
        records[id] = Record(message: key, thread: thread, invite: card.invite, title: card.title, provider: provider,
                             response: response, previous: previous, wholeSeries: wholeSeries, doneToken: token,
                             stage: .held)
        let window = holdWindow
        let sleep = self.sleep
        held[id] = Task { [weak self] in
            do { try await sleep(window) } catch { return }
            guard let self, self.held.removeValue(forKey: id) != nil else { return }
            await self.send(id)
        }
        pushUndo(id, title: Self.doneTitle(response, wholeSeries: wholeSeries, done: token != nil), thread: thread,
                 reopens: reopens)
    }

    static func doneTitle(_ response: CalendarResponse, wholeSeries: Bool, done: Bool) -> String {
        let answer: String = switch (response, wholeSeries) {
        case (.accepted, false): String(localized: "Accepted")
        case (.accepted, true): String(localized: "Accepted all events")
        case (.declined, false): String(localized: "Declined")
        case (.declined, true): String(localized: "Declined all events")
        case (_, false): String(localized: "Maybe")
        case (_, true): String(localized: "Maybe to all events")
        }
        return done ? String(localized: "\(answer) — Done") : answer
    }

    private func markDone(_ thread: ThreadKey) async -> (UndoToken?, UndoCoordinator.Entry.Reopen?) {
        guard let commands = environment.commands else { return (nil, nil) }
        let router = environment.router
        let state = router.accounts.first { $0.id == thread.account } ?? router.active
        var reopens: UndoCoordinator.Entry.Reopen?
        if let state { reopens = ThreadActionHandler.advance(past: [thread], in: state, router: router) }
        let command = MailCommand.markDone([thread])
        let list = state?.list
        let ticket = list?.applyOptimistic(command)
        do {
            return (try await commands.apply(command), reopens)
        } catch {
            if let ticket { list?.revertOptimistic(ticket) }
            environment.notices.post(String(localized: "Couldn't mark the conversation done."), style: .error)
            return (nil, reopens)
        }
    }

    private struct NotOnCalendar: Error {}

    private func send(_ id: UUID) async {
        guard var record = records[id] else { return }
        let invite = record.invite
        do {
            let query = CalendarInviteQuery(uid: invite.uid, title: invite.title ?? "", start: invite.start,
                                            end: invite.end, organizer: invite.organizer?.email,
                                            recurrenceID: invite.recurrenceID, repeats: invite.repeats)
            guard let found = try await locate(query, for: record) else { throw NotOnCalendar() }
            record.provider = found.provider
            let event = found.event.resolvingMyResponse(addresses: found.addresses)
            try Self.checkScope(event, for: invite, wholeSeries: record.wholeSeries)
            if let current = event.myResponse, current != .needsAction { record.previous = current }
            let answer = try await record.provider.respond(to: event, with: record.response, sendUpdates: .all)
            record.stage = .sent(answer)
            records[id] = record
            let key = CalendarEventStore.key(for: record.provider)
            if record.wholeSeries {
                environment.calendarEvents.applyLocalResponse(key, series: event.id, response: record.response)
            } else {
                environment.calendarEvents.applyLocal(key, upsert: answer)
            }
            environment.notices.post(String(localized: "Answered \(record.response.title) to \(record.title)."),
                                     duration: NoticeCenter.infoDuration)
        } catch {
            record.stage = .failed
            records[id] = record
            answered[Self.answerKey(invite)] = nil
            show(record.previous, on: record.message)
            if error is NotOnCalendar {
                postNotFound(record)
            } else {
                environment.notices.post(String(localized: "Couldn't answer \(record.title). \(CalendarSidebarModel.message(error))"),
                                         style: .error)
            }
        }
    }

    // Why: an invitation sent to another connected account's address can sit only on that account's calendar; there
    // only an iCalUID match counts, never a look-alike
    private func locate(_ query: CalendarInviteQuery, for record: Record) async throws
        -> (event: CalendarEvent, provider: any CalendarProviding, addresses: Set<String>)? {
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let own = accounts.first { $0.id == record.thread.account }?.myAddresses ?? []
        if let event = try await record.provider.invitedEvent(query, wholeSeries: record.wholeSeries) {
            return (event, record.provider, own)
        }
        guard let connections = environment.calendarConnections, connections.routesByAccount else { return nil }
        let guests = Set(record.invite.attendees.map { $0.email.lowercased() })
        var strict = query
        strict.matchesTitle = false
        for other in accounts where other.id != record.thread.account && guests.contains(other.email.lowercased()) {
            guard let provider = connections.calendarProvider(for: other), Self.answerRefusal(provider) == nil,
                  let event = try? await provider.invitedEvent(strict, wholeSeries: record.wholeSeries) else { continue }
            Log(.calendar).notice("invitation found on another account's calendar")
            return (event, provider, other.myAddresses)
        }
        return nil
    }

    private func postNotFound(_ record: Record) {
        let account = record.provider.info.account ?? ""
        let message = account.isEmpty
            ? String(localized: "Couldn't answer \(record.title). Mail couldn't find it on your calendar; it may have moved. Open it in Calendar to answer.")
            : String(localized: "Couldn't answer \(record.title). Mail couldn't find it on the calendar of \(account); it may have moved. Open it in Calendar to answer.")
        let day = record.invite.occurrence
        environment.notices.post(message, style: .error, actionTitle: String(localized: "Open in Calendar")) { [weak self] in
            await self?.environment.calendarWindow?.open(around: day)
        }
    }

    nonisolated static func checkScope(_ event: CalendarEvent, for invite: CalendarInvite, wholeSeries: Bool) throws {
        let isSeries = invite.repeats || invite.recurrenceID != nil
        if wholeSeries, event.isRecurring {
            throw CalendarError.refused(String(localized: "Mail couldn't tell which event is the series. Answer it in your calendar."))
        }
        if isSeries, !wholeSeries, !event.isRecurring {
            throw CalendarError.refused(String(localized: "Mail couldn't find this one event of the series. Answer it in your calendar."))
        }
    }

    private func show(_ response: CalendarResponse?, on key: MessageKey) {
        guard var card = card(for: key) else { return }
        card.response = response == .needsAction ? nil : response
        entries[key] = .card(card)
    }


    private func pushUndo(_ id: UUID, title: String, thread: ThreadKey, reopens: UndoCoordinator.Entry.Reopen?) {
        guard let undo = environment.undo else {
            environment.notices.post(title, duration: holdWindow)
            return
        }
        if undoerStorage == nil { undoerStorage = InviteRSVPUndoer(center: self) }
        guard let undoer = undoerStorage else { return }
        undo.push(UndoCoordinator.Entry(title: LocalizedStringResource(stringLiteral: title),
                                        token: UndoToken(payload: Data(id.uuidString.utf8)), threads: [thread],
                                        undoer: undoer, reopens: reopens))
    }

    func undo(_ id: UUID) async {
        guard let record = records.removeValue(forKey: id) else { return }
        let key = Self.answerKey(record.invite)
        if let task = held.removeValue(forKey: id) {
            task.cancel()
            answered[key] = nil
            show(record.previous, on: record.message)
        } else if case .sent(let event) = record.stage {
            if let previous = record.previous, previous != .needsAction, previous != record.response {
                do {
                    let back = try await record.provider.respond(to: event, with: previous, sendUpdates: .all)
                    answered[key] = previous
                    show(previous, on: record.message)
                    let calendarKey = CalendarEventStore.key(for: record.provider)
                    if record.wholeSeries {
                        environment.calendarEvents.applyLocalResponse(calendarKey, series: event.id, response: previous)
                    } else {
                        environment.calendarEvents.applyLocal(calendarKey, upsert: back)
                    }
                } catch {
                    environment.notices.post(String(localized: "Couldn't change your answer back: \(CalendarSidebarModel.message(error)) Check your calendar."),
                                             style: .error)
                }
            } else if record.previous != record.response {
                notes[record.message] = String(localized: "Your answer was already sent. You can change it here, but not take it back.")
            }
        }
        if let token = record.doneToken, !token.changesNothing, let commands = environment.commands {
            do {
                _ = try await commands.undo(token)
            } catch {
                environment.notices.post(String(localized: "Couldn't move the conversation back to the Inbox."), style: .error)
            }
        }
    }

    public var hasQuitWork: Bool { !held.isEmpty }

    public func prepareForQuit() async {
        for id in Array(held.keys) {
            guard let task = held.removeValue(forKey: id) else { continue }
            task.cancel()
            await send(id)
        }
    }

    var heldCount: Int { held.count }
    var recordCount: Int { records.count }
    func pendingLoad(_ key: MessageKey) -> Task<Void, Never>? { loads[key] }
    var heldTasks: [Task<Void, Never>] { Array(held.values) }
}

@MainActor
final class InviteRSVPUndoer: MailUndoing {
    private weak var center: InviteCenter?

    init(center: InviteCenter) {
        self.center = center
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        guard let id = UUID(uuidString: String(decoding: token.payload, as: UTF8.self)) else { return nil }
        await undo(id)
        return nil
    }

    private func undo(_ id: UUID) async { await center?.undo(id) }
}
