import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore

public struct SchedulingReplyContext: Sendable, Hashable {
    public let thread: ThreadKey
    public let message: MessageKey
    public let proposal: SchedulingProposal
    public let option: SchedulingOption
    public let conflicts: [CalendarEvent]
    public let moves: [SchedulingMove]?
    public let title: String
}

public struct SchedulingMessage: Sendable, Hashable {
    public var key: MessageKey
    public var subject: String
    public var senderName: String?
    public var sentAt: Date
    public var text: String
    public var isFromMe: Bool

    public init(key: MessageKey, subject: String, senderName: String?, sentAt: Date, text: String, isFromMe: Bool) {
        self.key = key
        self.subject = subject
        self.senderName = senderName
        self.sentAt = sentAt
        self.text = text
        self.isFromMe = isFromMe
    }
}

public protocol SchedulingLanguageModel: Sendable {
    func extractTimes(_ input: SchedulingExtractInput) async throws -> [SchedulingExtractedTime]
    func draftReply(_ input: SchedulingDraftInput) async throws -> SchedulingDraftResult
}

struct AISchedulingLanguage: SchedulingLanguageModel {
    let features: any AIFeatures

    func extractTimes(_ input: SchedulingExtractInput) async throws -> [SchedulingExtractedTime] {
        try await features.extractSchedulingTimes(input)
    }

    func draftReply(_ input: SchedulingDraftInput) async throws -> SchedulingDraftResult {
        try await features.draftSchedulingReply(input)
    }
}

@MainActor @Observable
public final class SchedulingAssistant {
    public enum Status: Equatable, Sendable { case checking, ready, failed(String) }

    public struct Chip: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case createEvent, busy, counterPropose, askForOtherTimes, suggestTimes }
        public let kind: Kind
        public let title: String
        public let help: String
        public var id: Kind { kind }
    }

    public struct Analysis: Sendable, Hashable {
        public let message: MessageKey
        public let proposal: SchedulingProposal
        public let calendarRead: Bool
        public let conflicts: [CalendarEvent]
        public let today: [SchedulingSlot]
        public let nextDay: SchedulingSlot?
        public let moves: [SchedulingMove]?
        public let title: String
        public let senderName: String?
        public let bookingLink: String?
    }

    public struct FollowUp: Identifiable, Sendable, Hashable {
        public let id = UUID()
        public let context: SchedulingReplyContext
        public let moves: [SchedulingMove]
        public var note: String?
    }

    public let provider: any CalendarProviding
    public private(set) var status: [ThreadKey: Status] = [:]
    public private(set) var analyses: [ThreadKey: Analysis] = [:]
    public var pickerThread: ThreadKey?
    public var conflictThread: ThreadKey?
    public private(set) var followUp: FollowUp?
    public private(set) var isDrafting = false
    @ObservationIgnored public var timeZone: TimeZone = .current
    @ObservationIgnored public var now: @MainActor () -> Date = Date.init
    @ObservationIgnored public var holdWindow: Duration = NoticeCenter.toastDuration
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var loadMessage: (ThreadKey) async -> SchedulingMessage?
    @ObservationIgnored public var language: (any SchedulingLanguageModel)?

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var generation: [ThreadKey: Int] = [:]
    @ObservationIgnored private var analyzedAt: [ThreadKey: Date] = [:]
    @ObservationIgnored private var held: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var undoable: [UUID: (moved: [(CalendarEvent, Date, Date)], created: CalendarEvent?,
                                                      calendar: any CalendarProviding)] = [:]
    @ObservationIgnored private var calendars: [ThreadKey: any CalendarProviding] = [:]
    @ObservationIgnored private var undoerStorage: SchedulingUndoer?

    public static let freshFor: TimeInterval = 60

    init(environment: AppEnvironment, provider: any CalendarProviding) {
        self.environment = environment
        self.provider = provider
        let data = environment.data
        loadMessage = { thread in await Self.newestMessage(thread, data: data) }
        if let center = environment.ai { language = AISchedulingLanguage(features: center.features) }
    }

    public var writeRefusal: String? { provider.info.createRefusal }

    func calendar(for thread: ThreadKey) -> any CalendarProviding { calendars[thread] ?? provider }

    private func resolveCalendar(for thread: ThreadKey) async -> (any CalendarProviding)? {
        guard let sidebar = environment.calendarSidebar, sidebar.routesByAccount else { return provider }
        return await sidebar.calendarOf(thread.account).provider
    }

    public func analyze(_ thread: ThreadKey, force: Bool = false) async {
        if !force, let at = analyzedAt[thread], now().timeIntervalSince(at) < Self.freshFor, status[thread] != nil { return }
        let mine = (generation[thread] ?? 0) + 1
        generation[thread] = mine
        guard await read(AppSettings.calendarSuggestReplyTimes) else { return forget(thread) }
        status[thread] = .checking
        guard let message = await loadMessage(thread), !message.isFromMe else { return forget(thread) }
        let workday = await self.workday()
        let current = now()
        var proposals = SchedulingProposalParser.find(in: message.text, sentAt: message.sentAt, authorZone: timeZone,
                                                      now: current, workday: workday.hours)
        if proposals.isEmpty, SchedulingProposalParser.asksAboutTime(message.text) {
            proposals = await modelProposals(message, thread: thread, workday: workday)
        }
        guard generation[thread] == mine else { return }
        guard let proposal = proposals.first else { return forget(thread) }
        let calendar = CalendarDateMentions.calendar(timeZone)
        let from = calendar.startOfDay(for: min(current, proposal.start))
        let lastDay = SchedulingAlternatives.nextWorkingDay(
            after: max(calendar.startOfDay(for: proposal.end), calendar.startOfDay(for: current)), calendar: calendar)
        let to = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        let title = CalendarEventDraftBuilder.title(message.subject)
        let link = await bookingLink()
        guard let provider = await resolveCalendar(for: thread) else {
            guard generation[thread] == mine else { return }
            return forget(thread)
        }
        guard generation[thread] == mine else { return }
        calendars[thread] = provider
        do {
            let key = CalendarEventStore.key(for: provider)
            let store = environment.calendarEvents
            let answer: (events: [CalendarEvent], freeBusy: CalendarFreeBusy)
            if let cached = store.events(key, from: from, to: to), let blocks = store.busy(key, from: from, to: to) {
                answer = (cached, CalendarFreeBusy(busy: blocks))
            } else {
                async let readEvents = provider.events(from: from, to: to)
                async let readBusy = provider.freeBusy(from: from, to: to)
                answer = try await (readEvents, readBusy)
            }
            let (events, freeBusy) = answer
            guard generation[thread] == mine else { return }
            let conflicts = proposal.precision == .time ? SchedulingAlternatives.conflicts(proposal, events: events) : []
            let length = proposal.precision == .time ? proposal.length : SchedulingProposalParser.defaultLength
            let today = SchedulingAlternatives.today(now: current, busy: freeBusy.busy, workday: workday,
                                                     calendar: calendar, length: length)
            let next = SchedulingAlternatives.nextWorkingDay(after: current, calendar: calendar)
            let block = SchedulingAlternatives.dayBlock(next, now: current, busy: freeBusy.busy, workday: workday,
                                                        calendar: calendar, length: length)
            let moves = await read(AppSettings.calendarOfferMoves)
                ? SchedulingAlternatives.moves(for: conflicts, proposal: proposal, busy: freeBusy.busy, now: current,
                                               workday: workday, calendar: calendar)
                : nil
            analyses[thread] = Analysis(message: message.key, proposal: proposal, calendarRead: true, conflicts: conflicts,
                                        today: today, nextDay: block, moves: moves, title: title,
                                        senderName: message.senderName, bookingLink: link)
            status[thread] = .ready
        } catch CalendarError.notConfigured {
            guard generation[thread] == mine else { return }
            return forget(thread)
        } catch {
            guard generation[thread] == mine else { return }
            analyses[thread] = Analysis(message: message.key, proposal: proposal, calendarRead: false, conflicts: [],
                                        today: [], nextDay: nil, moves: nil, title: title, senderName: message.senderName,
                                        bookingLink: link)
            status[thread] = .failed(String(localized: "Couldn't read your calendar. \(CalendarSidebarModel.message(error))"))
        }
        analyzedAt[thread] = now()
    }

    private func forget(_ thread: ThreadKey) {
        status[thread] = nil
        analyses[thread] = nil
        analyzedAt[thread] = now()
    }

    private func modelProposals(_ message: SchedulingMessage, thread: ThreadKey,
                                workday: SchedulingWorkday) async -> [SchedulingProposal] {
        guard let language else { return [] }
        let input = SchedulingExtractInput(messageKey: AIThreadLoader.messageKey(message.key),
                                           threadKey: AIThreadLoader.threadKey(thread), subject: message.subject,
                                           from: message.senderName ?? "", text: message.text, sentAt: message.sentAt,
                                           accountKey: environment.ai?.policyKey(thread.account))
        guard let times = try? await language.extractTimes(input) else { return [] }
        let phrases = times.map { time -> String in
            var words = "how about " + time.day
            if !time.start.isEmpty { words += " " + time.start + (time.end.isEmpty ? "" : " - " + time.end) }
            if !time.zone.isEmpty { words += " " + time.zone }
            return words + "?"
        }
        return phrases.flatMap {
            SchedulingProposalParser.find(in: $0, sentAt: message.sentAt, authorZone: timeZone, now: now(),
                                          workday: workday.hours)
        }.map { proposal in
            var copy = proposal
            copy.fromModel = true
            return copy
        }
    }

    public func suggestions(for thread: ThreadKey, message: MessageKey? = nil) -> [ReplySuggestion] {
        guard let analysis = analyses[thread], status[thread] != .checking else { return [] }
        if let message, analysis.message != message { return [] }
        let proposal = analysis.proposal
        let theirs = SchedulingSlot(start: proposal.start, end: proposal.end)
        var out: [ReplySuggestion] = []
        if proposal.precision == .time, analysis.calendarRead {
            if let conflict = analysis.conflicts.first {
                out.append(ReplySuggestion(id: "calendar.busy", kind: .busy,
                                           label: String(localized: "\(clockText(proposal.start)) is busy — \(Self.truncated(conflict.title))"),
                                           body: nil,
                                           help: String(localized: "Your calendar has \(conflict.title) then. Show it.")))
            } else {
                out.append(reply(.accept, analysis, id: "calendar.accept",
                                 label: String(localized: "Accept \(clockText(proposal.start))"),
                                 help: String(localized: "\(slotText(theirs)) is free. Reply that it works; after you send it, Mail offers to add it to your calendar.")))
                out.append(ReplySuggestion(id: "calendar.create", kind: .createEvent, label: String(localized: "Create event"),
                                           body: nil,
                                           help: String(localized: "\(slotText(theirs)) is free. Add it to your calendar.")))
            }
        } else {
            out.append(ReplySuggestion(id: "calendar.suggest", kind: .suggestTimes, label: String(localized: "Suggest times"),
                                       body: nil, help: String(localized: "Offer times you're free, from your calendar.")))
        }
        if let block = analysis.nextDay {
            out.append(reply(.nextDay(block), analysis, id: "calendar.counter",
                             label: String(localized: "Counter-propose \(weekday(block.start))"),
                             help: String(localized: "Offer \(slotText(block)) in a draft.")))
        }
        out.append(reply(.askForOtherTimes, analysis, id: "calendar.ask", label: String(localized: "Ask for other times"),
                         help: String(localized: "Draft a reply asking for other times.")))
        return out
    }

    private func reply(_ option: SchedulingOption, _ analysis: Analysis, id: String, label: String,
                       help: String) -> ReplySuggestion {
        ReplySuggestion(id: id, kind: .scheduling(option), label: label,
                        body: fallbackBody(option, analysis, lines: timeLines(option, analysis), link: analysis.bookingLink),
                        help: help)
    }

    public func replyContext(_ option: SchedulingOption, in thread: ThreadKey) -> SchedulingReplyContext? {
        guard let analysis = analyses[thread] else { return nil }
        return SchedulingReplyContext(thread: thread, message: analysis.message, proposal: analysis.proposal,
                                      option: option, conflicts: analysis.conflicts, moves: analysis.moves,
                                      title: analysis.title)
    }

    @discardableResult
    public func use(_ suggestion: ReplySuggestion, in thread: ThreadKey) async -> ComposeSession? {
        switch suggestion.kind {
        case .busy:
            conflictThread = conflictThread == thread ? nil : thread
            pickerThread = nil
            return nil
        case .createEvent:
            await perform(.createEvent, in: thread)
            return nil
        case .suggestTimes:
            await perform(.suggestTimes, in: thread)
            return nil
        case .quickReply:
            return nil
        case .scheduling(let option):
            guard let body = suggestion.body, let analysis = analyses[thread] else { return nil }
            pickerThread = nil
            conflictThread = nil
            return await environment.compose.useSuggestion(body, thread: thread, message: analysis.message, auto: false,
                                                           scheduling: replyContext(option, in: thread))
        }
    }

    public func options(for thread: ThreadKey) -> [SchedulingOption] {
        guard let analysis = analyses[thread] else { return [] }
        var out: [SchedulingOption] = []
        if !analysis.today.isEmpty { out.append(.today(analysis.today)) }
        if let block = analysis.nextDay { out.append(.nextDay(block)) }
        if analysis.proposal.precision == .time, analysis.calendarRead {
            if analysis.conflicts.isEmpty {
                out.append(.accept)
            } else if let moves = analysis.moves {
                out.append(.acceptAndMove(moves))
            }
        }
        out.append(.askForOtherTimes)
        return out
    }

    public func title(of option: SchedulingOption, in thread: ThreadKey) -> String {
        let proposal = analyses[thread]?.proposal
        switch option {
        case .today(let slots):
            return String(localized: "Today: \(slots.map(shortSlot).joined(separator: " or "))")
        case .nextDay(let slot):
            return String(localized: "\(weekday(slot.start)): \(shortSlot(slot))")
        case .acceptAndMove(let moves):
            let names = moves.map { Self.truncated($0.event.title) }.joined(separator: ", ")
            let notify = moves.flatMap(\.notifies).isEmpty ? "" : String(localized: " (notifies attendees)")
            return String(localized: "Accept \(proposal.map { clockText($0.start) } ?? "") and move \(names)\(notify)")
        case .accept:
            return String(localized: "Accept \(proposal.map { clockText($0.start) } ?? "their time")")
        case .askForOtherTimes:
            return String(localized: "Ask them for other times")
        }
    }

    public func perform(_ chip: Chip.Kind, in thread: ThreadKey) async {
        switch chip {
        case .createEvent:
            guard let sidebar = environment.calendarSidebar, let proposal = analyses[thread]?.proposal else { return }
            await sidebar.beginDraft(for: thread)
            sidebar.draft?.start = proposal.start
            sidebar.draft?.end = proposal.end
        case .busy:
            conflictThread = thread
        case .counterPropose:
            if let block = analyses[thread]?.nextDay { await draft(.nextDay(block), in: thread) }
        case .askForOtherTimes:
            await draft(.askForOtherTimes, in: thread)
        case .suggestTimes:
            await openOptions(for: thread)
        }
    }

    public func openOptions(for thread: ThreadKey) async {
        if analyses[thread] == nil { await analyze(thread, force: true) }
        guard analyses[thread] != nil else {
            environment.notices.post(String(localized: "This message doesn't propose a time."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        conflictThread = nil
        pickerThread = thread
    }

    @discardableResult
    public func draft(_ option: SchedulingOption, in thread: ThreadKey) async -> ComposeSession? {
        guard let analysis = analyses[thread], !isDrafting else { return nil }
        pickerThread = nil
        conflictThread = nil
        isDrafting = true
        defer { isDrafting = false }
        let lines = timeLines(option, analysis)
        let link = analysis.bookingLink
        var body = fallbackBody(option, analysis, lines: lines, link: link)
        var auto = false
        if let language, let input = await threadInput(thread, message: analysis.message),
           let result = try? await language.draftReply(SchedulingDraftInput(
               thread: input, instruction: instruction(option, analysis, lines: lines), timeLines: lines,
               bookingLink: link)),
           !result.suspicious, let checked = Self.checked(result.body, lines: lines, link: link) {
            body = checked
            auto = true
        }
        return await environment.compose.useSuggestion(body, thread: thread, message: analysis.message, auto: auto,
                                                       scheduling: replyContext(option, in: thread))
    }

    static func checked(_ body: String, lines: [String], link: String?) -> String? {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let urls = SchedulingProposalParser.matches(#"https?://[^\s<>()]+"#, in: text).compactMap { $0.groups[0] }
        for url in urls where url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")) != link { return nil }
        let missing = lines.filter { !text.contains(String($0.dropFirst(2))) }
        if !missing.isEmpty { text += "\n\n" + lines.joined(separator: "\n") }
        return text
    }

    func timeLines(_ option: SchedulingOption, _ analysis: Analysis) -> [String] {
        let proposal = SchedulingSlot(start: analysis.proposal.start, end: analysis.proposal.end)
        switch option {
        case .today(let slots): return slots.map { "- " + slotText($0) }
        case .nextDay(let slot): return ["- " + slotText(slot)]
        case .accept, .acceptAndMove: return ["- " + slotText(proposal)]
        case .askForOtherTimes: return []
        }
    }

    private func instruction(_ option: SchedulingOption, _ analysis: Analysis, lines: [String]) -> String {
        let name = Self.firstName(analysis.senderName)
        let theirs = slotText(SchedulingSlot(start: analysis.proposal.start, end: analysis.proposal.end))
        let prompt: PromptName = switch option {
        case .today, .nextDay: analysis.conflicts.isEmpty ? .schedulingOffer : .schedulingBusy
        case .accept: .schedulingAccept
        case .acceptAndMove: .schedulingAcceptMove
        case .askForOtherTimes: .schedulingOtherTimes
        }
        let library = PromptLibraryProvider.shared.current
        var text = (try? library.instruction(prompt, values: ["name": name, "proposed": theirs])) ?? ""
        if !lines.isEmpty,
           let times = try? library.instruction(.schedulingTimes, values: ["times": lines.joined(separator: "\n")]) {
            text += "\n" + times
        }
        return text
    }

    func fallbackBody(_ option: SchedulingOption, _ analysis: Analysis, lines: [String], link: String?) -> String {
        let greeting = "Hi \(Self.firstName(analysis.senderName)),"
        let theirs = slotText(SchedulingSlot(start: analysis.proposal.start, end: analysis.proposal.end))
        var parts = [greeting]
        switch option {
        case .today, .nextDay:
            parts.append((analysis.conflicts.isEmpty ? "Thanks for suggesting \(theirs). Could one of these work instead?"
                                                     : "I'm tied up at \(theirs). Could one of these work instead?")
                         + "\n" + lines.joined(separator: "\n"))
        case .accept:
            parts.append("\(theirs) works for me. See you then.")
        case .acceptAndMove:
            parts.append("I'll move things around so \(theirs) works. See you then.")
        case .askForOtherTimes:
            parts.append("Unfortunately \(theirs) doesn't work for me. Could you send a few other times that suit you?")
        }
        if let link { parts.append("You can also book a time here: \(link)") }
        return parts.joined(separator: "\n\n")
    }

    func replySent(_ session: ComposeSession) {
        guard let context = session.scheduling else { return }
        let moves = context.moves ?? []
        switch context.option {
        case .accept:
            followUp = FollowUp(context: context, moves: [])
        case .today, .nextDay, .acceptAndMove, .askForOtherTimes:
            guard !context.conflicts.isEmpty else { return }
            followUp = FollowUp(context: context, moves: moves)
        }
    }

    public func dismissFollowUp() { followUp = nil }

    public func followUpAskForOtherTimes() async {
        guard let context = followUp?.context else { return }
        followUp = nil
        if analyses[context.thread] == nil { await analyze(context.thread, force: true) }
        await draft(.askForOtherTimes, in: context.thread)
    }

    public func notifyLine(_ moves: [SchedulingMove]) -> String? {
        let people = moves.flatMap(\.notifies)
        guard !people.isEmpty else { return nil }
        let names = people.map { $0.name ?? $0.email }.joined(separator: ", ")
        return String(localized: "Google emails \(names) about the move.")
    }

    public func moveConflicts() async {
        guard var card = followUp, !card.moves.isEmpty else { return }
        if let refusal = calendar(for: card.context.thread).info.createRefusal {
            card.note = refusal
            followUp = card
            environment.notices.post(refusal, duration: NoticeCenter.infoDuration)
            return
        }
        followUp = nil
        let id = UUID()
        let window = holdWindow
        let sleep = self.sleep
        held[id] = Task { [weak self] in
            do { try await sleep(window) } catch { return }
            guard let self, self.held.removeValue(forKey: id) != nil else { return }
            await self.commit(card.moves, context: card.context)
        }
        let first = card.moves[0]
        var title = String(localized: "Moving \(first.event.title) to \(clockText(first.to.start))…")
        if let notify = notifyLine(card.moves) { title += " " + notify }
        pushUndo(id, title: title, threads: [card.context.thread])
    }

    private func commit(_ moves: [SchedulingMove], context: SchedulingReplyContext) async {
        let provider = calendar(for: context.thread)
        if let refusal = provider.info.createRefusal {
            environment.notices.post(String(localized: "Nothing was moved. \(refusal)"), style: .error)
            return
        }
        var moved: [(CalendarEvent, Date, Date)] = []
        for move in moves {
            do {
                let after = try await provider.moveEvent(move.event, to: move.to.start, end: move.to.end,
                                                         sendUpdates: move.notifies.isEmpty ? .none : .all)
                environment.calendarEvents.applyLocal(CalendarEventStore.key(for: provider), upsert: after)
                moved.append((move.event, move.event.start, move.event.end))
            } catch CalendarError.unclear {
                environment.notices.post(String(localized: "Google may have moved \(move.event.title). Check your calendar."),
                                         style: .error)
                return
            } catch {
                environment.notices.post(String(localized: "Couldn't move \(move.event.title). \(CalendarSidebarModel.message(error))"),
                                         style: .error)
                return
            }
        }
        let created = await createAccepted(context)
        if let sidebar = environment.calendarSidebar { Task { await sidebar.refresh() } }
        let first = moves[0]
        let line = String(localized: "Moved \(first.event.title) to \(clockText(first.to.start)).")
        if moves.allSatisfy({ $0.notifies.isEmpty }) {
            let id = UUID()
            undoable[id] = (moved, created, provider)
            pushUndo(id, title: line, threads: [context.thread])
        } else {
            environment.notices.post(line + " " + String(localized: "Google emailed the attendees."),
                                     duration: NoticeCenter.infoDuration)
        }
    }

    public func acceptConflict() async {
        guard var card = followUp else { return }
        let target = calendar(for: card.context.thread)
        if let refusal = target.info.createRefusal {
            card.note = refusal
            followUp = card
            environment.notices.post(refusal, duration: NoticeCenter.infoDuration)
            return
        }
        followUp = nil
        let id = UUID()
        let window = holdWindow
        let sleep = self.sleep
        let context = card.context
        held[id] = Task { [weak self] in
            do { try await sleep(window) } catch { return }
            guard let self, self.held.removeValue(forKey: id) != nil else { return }
            let created = await self.createAccepted(context)
            guard let created else { return }
            let overlap = context.conflicts.first.map { String(localized: " It overlaps \($0.title); both stay on your calendar.") } ?? ""
            let undoID = UUID()
            self.undoable[undoID] = ([], created, target)
            self.pushUndo(undoID, title: String(localized: "Added \(self.clockText(created.start)).") + overlap,
                          threads: [context.thread])
        }
        pushUndo(id, title: String(localized: "Adding \(clockText(context.proposal.start)) to your calendar…"),
                 threads: [context.thread])
    }

    private func createAccepted(_ context: SchedulingReplyContext) async -> CalendarEvent? {
        let provider = calendar(for: context.thread)
        let kind = await read(AppSettings.calendarAcceptedHoldKind)
        let title = kind == .tentative ? String(localized: "Tentative: \(context.title)") : context.title
        let draft = CalendarEventDraft(title: title, start: context.proposal.start, end: context.proposal.end,
                                       timeZone: timeZone.identifier, attendees: [], sendUpdates: .none,
                                       addMeetLink: await read(AppSettings.calendarAddMeetLink))
        do {
            let created = try await provider.createEvent(draft)
            environment.calendarEvents.applyLocal(CalendarEventStore.key(for: provider), upsert: created)
            return created
        } catch {
            environment.notices.post(String(localized: "Couldn't add \(clockText(context.proposal.start)) to your calendar. \(CalendarSidebarModel.message(error))"),
                                     style: .error)
            return nil
        }
    }

    var heldIDs: [UUID] { Array(held.keys) }
    var undoableIDs: [UUID] { Array(undoable.keys) }

    private func pushUndo(_ id: UUID, title: String, threads: [ThreadKey]) {
        guard let undo = environment.undo else {
            environment.notices.post(title, duration: holdWindow)
            return
        }
        if undoerStorage == nil { undoerStorage = SchedulingUndoer(model: self) }
        guard let undoer = undoerStorage else { return }
        undo.push(UndoCoordinator.Entry(title: LocalizedStringResource(stringLiteral: title),
                                        token: UndoToken(payload: Data(id.uuidString.utf8)),
                                        expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(holdWindow)),
                                        threads: threads, undoer: undoer))
    }

    func undo(_ id: UUID) async {
        if let task = held.removeValue(forKey: id) {
            task.cancel()
            environment.notices.post(String(localized: "Canceled. Nothing on your calendar changed."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        guard let done = undoable.removeValue(forKey: id) else {
            environment.notices.post(String(localized: "Too late to undo: your calendar already changed."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        let provider = done.calendar
        do {
            let key = CalendarEventStore.key(for: provider)
            for (event, start, end) in done.moved {
                let back = try await provider.moveEvent(event, to: start, end: end, sendUpdates: .none)
                environment.calendarEvents.applyLocal(key, upsert: back)
            }
            if let created = done.created {
                try await provider.deleteEvent(created)
                environment.calendarEvents.removeLocal(key, id: created.id)
            }
        } catch {
            environment.notices.post(String(localized: "Couldn't undo it: \(CalendarSidebarModel.message(error)) Check your calendar."),
                                     style: .error)
            return
        }
        environment.notices.post(String(localized: "Undone. Your calendar is as it was."), duration: NoticeCenter.infoDuration)
    }

    public func clockText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
    }

    public func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.wide))
    }

    public func slotText(_ slot: SchedulingSlot) -> String {
        let day = slot.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day())
        var text = day + ", " + CalendarSidebarModel.range(slot.start, slot.end, timeZone) + " "
            + (timeZone.abbreviation(for: slot.start) ?? CalendarSidebarModel.city(timeZone))
        if let second = environment.calendarSidebar?.secondTimeZone, second.identifier != timeZone.identifier {
            text += " (" + CalendarSidebarModel.range(slot.start, slot.end, second) + " " + CalendarSidebarModel.city(second) + ")"
        }
        return text
    }

    public func shortSlot(_ slot: SchedulingSlot) -> String {
        CalendarSidebarModel.range(slot.start, slot.end, timeZone)
    }

    static func truncated(_ title: String, limit: Int = 24) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func firstName(_ sender: String?) -> String {
        let name = (sender ?? "").components(separatedBy: "<").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty || first.contains("@") ? String(localized: "there") : first
    }

    private func read<Value>(_ key: AppSettingKey<Value>) async -> Value {
        guard let settings = environment.settings, let value = try? await settings.get(key) else { return key.defaultValue }
        return value
    }

    private func workday() async -> SchedulingWorkday {
        SchedulingWorkday(startHour: await read(AppSettings.calendarWorkdayStartHour),
                          endHour: await read(AppSettings.calendarWorkdayEndHour),
                          buffer: TimeInterval(await read(AppSettings.calendarBufferMinutes) * 60))
    }

    private func bookingLink() async -> String? {
        guard let text = await read(AppSettings.calendarSchedulingLink)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return text
    }

    private func threadInput(_ thread: ThreadKey, message: MessageKey) async -> AIThreadInput? {
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let account = accounts.first { $0.id == thread.account }
        let loader = AIThreadLoader(data: environment.data, bodyTimeout: .seconds(3))
        guard var input = await loader.load(thread, upTo: message, account: account,
                                            accountKey: environment.ai?.policyKey(thread.account), trigger: .user,
                                            bodies: .readerDefault)?.input else { return nil }
        if let account, let center = environment.ai { input.styleExamples = await center.styleExamples(for: account) }
        return input
    }

    static func newestMessage(_ thread: ThreadKey, data: any MailDataSource) async -> SchedulingMessage? {
        let accounts = await AIThreadLoader.first(data.accounts()) ?? []
        let account = accounts.first { $0.id == thread.account }
        let loader = AIThreadLoader(data: data, bodyTimeout: .seconds(3))
        guard let context = await loader.load(thread, account: account, accountKey: nil, trigger: .automatic,
                                              bodies: .readerDefault),
              let last = context.input.messages.last, let key = context.messageKeys.last else { return nil }
        return SchedulingMessage(key: key, subject: context.input.subject, senderName: last.from, sentAt: last.date,
                                 text: last.bodyText, isFromMe: context.lastIsFromMe)
    }
}

@MainActor
final class SchedulingUndoer: MailUndoing {
    private weak var model: SchedulingAssistant?

    init(model: SchedulingAssistant) {
        self.model = model
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        guard let id = UUID(uuidString: String(decoding: token.payload, as: UTF8.self)) else { return nil }
        await run(id)
        return nil
    }

    private func run(_ id: UUID) async { await model?.undo(id) }
}
