import Foundation
import MailModel
import OpenHumanAI
import OpenHumanCore

public struct FollowUpNote: Codable, Hashable, Sendable {
    public var thread: String
    public var sentAt: Date
    public var needsFollowUp: Bool
    public var reason: String
    public var dueAt: Date?

    public init(thread: String, sentAt: Date, needsFollowUp: Bool, reason: String = "", dueAt: Date? = nil) {
        self.thread = thread
        self.sentAt = sentAt
        self.needsFollowUp = needsFollowUp
        self.reason = needsFollowUp ? reason : ""
        self.dueAt = needsFollowUp ? dueAt : nil
    }
}

@MainActor
public final class FollowUpReminders {
    public struct CatchUpResult: Sendable, Hashable {
        public var checked: Int
        public var remindersSet: Int
    }

    public enum CatchUpError: Error, Sendable, Hashable {
        case scopeOff
        case unavailable(String)
        case busy
    }

    public static func notesKey(_ account: AccountID) -> AppSettingKey<[FollowUpNote]> {
        AppSettingKey(name: "reminders.follow_up_checks", scope: .account(account), defaultValue: [])
    }

    public static let maxNotes = 500
    public static let catchUpDays = 7
    public static let catchUpLimit = 60
    static let sentCopyWindow: TimeInterval = 600

    public var timeout: Duration = .seconds(30)
    public var calendar: Calendar = .current
    public var now: @Sendable () -> Date = { Date() }
    public private(set) var isCatchingUp = false

    private weak var environment: AppEnvironment?
    private var notes: [AccountID: [FollowUpNote]] = [:]
    private var loading: Set<AccountID> = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func availability() async -> (available: Bool, reason: String?) {
        guard let center = environment?.ai else {
            return (false, String(localized: "AI isn't set up in this version of Mail"))
        }
        let status = await center.features.status(for: .followUp, accountKey: nil)
        if status.availability.isAvailable, status.dataLocation == .onDevice { return (true, nil) }
        switch status.availability.unavailableReason {
        case .onDeviceOnly?, nil:
            return (false, String(localized: "No on-device model is ready on this Mac"))
        case let reason?:
            return (false, AIWording.reason(reason, providerName: status.providerName))
        }
    }

    func sendCommitted(_ session: ComposeSession, draft key: DraftKey, rule: SentMailReminderRule, sentAt: Date) async {
        await sendCommitted(draft: key, account: session.account, recipients: session.allRecipients.map(\.email),
                            subject: session.subject, text: session.plainText,
                            thread: session.thread ?? session.draftThread, rule: rule, sentAt: sentAt)
    }

    func sendCommitted(draft key: DraftKey, account: Account, recipients: [String], subject: String, text: String,
                       thread known: ThreadKey?, rule: SentMailReminderRule, sentAt: Date) async {
        guard let environment, let center = environment.ai else { return }
        guard SentMailReminderRule.mayNeedFollowUp(recipients, myAddresses: account.myAddresses) else { return }
        var thread = known
        let accountKey = AICenter.policyKey(email: account.email)
        var context: [AIMessageInput] = []
        if let thread { context = await contextMessages(thread, account: account, accountKey: accountKey, before: sentAt) }
        let input = FollowUpInput(
            messageKey: "\(account.id.rawValue).draft.\(key.rawValue)", threadKey: thread.map(AIThreadLoader.threadKey),
            subject: subject, from: AIThreadLoader.sender(EmailAddress(name: account.displayName, email: account.email),
                                                          account: account),
            text: text, sentAt: sentAt, context: context, accountKey: accountKey)
        guard let answer = await check(input, center: center) else { return }
        if thread == nil { thread = try? await environment.data.sentConversation(key) }
        guard let thread else { return }
        guard answer.needsFollowUp else {
            await remember(FollowUpNote(thread: thread.gmailThreadID.rawValue, sentAt: sentAt, needsFollowUp: false),
                           account: account.id)
            return
        }
        guard let due = rule.dueDate(after: sentAt, days: rule.followUpDays(suggested: answer.suggestedDays),
                                     calendar: calendar) else { return }
        await setReminder(thread, due: due, sentAt: sentAt, reason: answer.reason)
    }

    /// Records that the person chose no reminder for this send, so a later catch-up never asks about it.
    func noteNoReminderWanted(_ thread: ThreadKey, sentAt: Date) async {
        await remember(FollowUpNote(thread: thread.gmailThreadID.rawValue, sentAt: sentAt, needsFollowUp: false),
                       account: thread.account)
    }

    public func catchUp() async throws(CatchUpError) -> CatchUpResult {
        guard !isCatchingUp else { throw .busy }
        guard let environment, let center = environment.ai else { throw .unavailable(String(localized: "AI isn't set up")) }
        let rule = await SentMailReminderRule.load(from: environment.settings)
        guard rule.scope == .needsFollowUp else { throw .scopeOff }
        guard environment.commands != nil else { throw .unavailable(String(localized: "Reminders can't be set here")) }
        let status = await availability()
        guard status.available else { throw .unavailable(status.reason ?? "") }
        isCatchingUp = true
        defer { isCatchingUp = false }
        let now = self.now()
        let cutoff = now.addingTimeInterval(-Double(Self.catchUpDays) * 86_400)
        var result = CatchUpResult(checked: 0, remindersSet: 0)
        for account in environment.router.accounts.map(\.account) {
            guard let rows = try? await environment.data.threadPage(.system(.sent), account: account.id, after: nil,
                                                                    limit: Self.catchUpLimit).rows else { continue }
            let accountKey = AICenter.policyKey(email: account.email)
            for row in rows where row.lastMessageAt >= cutoff && row.reminderAt == nil {
                guard !Task.isCancelled else { return result }
                guard let detail = await AIThreadLoader.first(environment.data.threadDetail(row.id)) ?? nil,
                      detail.reminder == nil, let newest = detail.messages.last, newest.date >= cutoff,
                      account.isMe(newest.from?.email ?? "") else { continue }
                let recipients = (newest.to + newest.cc + newest.bcc).map(\.email)
                guard SentMailReminderRule.mayNeedFollowUp(recipients, myAddresses: account.myAddresses) else { continue }
                let checkedBefore = await wasChecked(row.id, sentAt: newest.date)
                guard !checkedBefore else { continue }
                let loader = AIThreadLoader(data: environment.data, bodyTimeout: center.bodyTimeout)
                let loaded = await loader.load(row.id, account: account, accountKey: accountKey, trigger: .automatic,
                                               bodies: .readerDefault)
                let input = Self.input(for: newest, thread: row.id, subject: detail.subject, account: account,
                                       accountKey: accountKey, loaded: loaded?.input.messages ?? [])
                result.checked += 1
                guard let answer = await check(input, center: center) else { continue }
                guard answer.needsFollowUp else {
                    await remember(FollowUpNote(thread: row.id.gmailThreadID.rawValue, sentAt: newest.date,
                                                needsFollowUp: false), account: account.id)
                    continue
                }
                var due = rule.dueDate(after: newest.date, days: rule.followUpDays(suggested: answer.suggestedDays),
                                       calendar: calendar)
                if let passed = due, passed <= now { due = rule.nextSlot(after: now, calendar: calendar) }
                guard let due else { continue }
                if await setReminder(row.id, due: due, sentAt: newest.date, reason: answer.reason) { result.remindersSet += 1 }
            }
        }
        return result
    }

    public func reason(for row: ThreadRow) -> String? {
        guard let due = row.reminderAt else { return nil }
        guard let list = notes[row.id.account] else {
            startLoading(row.id.account)
            return nil
        }
        let thread = row.id.gmailThreadID.rawValue
        guard let note = list.last(where: { $0.thread == thread && $0.needsFollowUp }), let noted = note.dueAt,
              abs(noted.timeIntervalSince(due)) < 60, !note.reason.isEmpty else { return nil }
        return note.reason
    }

    static func input(for newest: MessageSummary, thread: ThreadKey, subject: String, account: Account,
                      accountKey: String?, loaded messages: [AIMessageInput]) -> FollowUpInput {
        FollowUpInput(
            messageKey: AIThreadLoader.messageKey(newest.id), threadKey: AIThreadLoader.threadKey(thread),
            subject: subject, from: AIThreadLoader.sender(newest.from, account: account),
            text: messages.last?.bodyText ?? newest.snippet, sentAt: newest.date,
            context: Array(messages.dropLast().suffix(AIPolicy.followUpContextMessages)), accountKey: accountKey)
    }

    func check(_ input: FollowUpInput, center: AICenter) async -> FollowUpResult? {
        let features = center.features
        let timeout = self.timeout
        return await withTaskGroup(of: FollowUpResult?.self) { group in
            group.addTask { try? await features.detectFollowUp(input) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func contextMessages(_ thread: ThreadKey, account: Account, accountKey: String,
                                 before sentAt: Date) async -> [AIMessageInput] {
        guard let data = environment?.data,
              let detail = await AIThreadLoader.first(data.threadDetail(thread)) ?? nil else { return [] }
        let earlier = detail.messages.filter { message in
            !(account.isMe(message.from?.email ?? "") && message.date >= sentAt.addingTimeInterval(-Self.sentCopyWindow))
        }
        return earlier.suffix(AIPolicy.followUpContextMessages).map { message in
            AIMessageInput(messageKey: AIThreadLoader.messageKey(message.id),
                           from: AIThreadLoader.sender(message.from, account: account), date: message.date,
                           bodyText: message.snippet, subject: detail.subject, accountKey: accountKey)
        }
    }

    @discardableResult
    private func setReminder(_ thread: ThreadKey, due: Date, sentAt: Date, reason: String) async -> Bool {
        let note = FollowUpNote(thread: thread.gmailThreadID.rawValue, sentAt: sentAt, needsFollowUp: true,
                                reason: reason, dueAt: due)
        await remember(note, account: thread.account)
        guard let environment, let actions = environment.actions.threadActions,
              let task = actions.remind(thread, at: due, kind: .ifNoReply, host: environment.router) else {
            await forget(note, account: thread.account)
            return false
        }
        await task.value
        return true
    }

    private func wasChecked(_ thread: ThreadKey, sentAt: Date) async -> Bool {
        let list = await loaded(thread.account)
        let id = thread.gmailThreadID.rawValue
        return list.contains { $0.thread == id && abs($0.sentAt.timeIntervalSince(sentAt)) <= Self.sentCopyWindow }
    }

    private func loaded(_ account: AccountID) async -> [FollowUpNote] {
        if let list = notes[account] { return list }
        let stored = (try? await environment?.settings?.get(Self.notesKey(account))) ?? []
        if notes[account] == nil { notes[account] = stored }
        return notes[account] ?? stored
    }

    private func startLoading(_ account: AccountID) {
        guard !loading.contains(account) else { return }
        loading.insert(account)
        Task { [weak self] in
            _ = await self?.loaded(account)
            self?.loading.remove(account)
        }
    }

    private func remember(_ note: FollowUpNote, account: AccountID) async {
        var list = await loaded(account)
        list.append(note)
        if list.count > Self.maxNotes { list.removeFirst(list.count - Self.maxNotes) }
        notes[account] = list
        try? await environment?.settings?.set(Self.notesKey(account), list)
    }

    private func forget(_ note: FollowUpNote, account: AccountID) async {
        var list = await loaded(account)
        guard let index = list.lastIndex(of: note) else { return }
        list.remove(at: index)
        notes[account] = list
        try? await environment?.settings?.set(Self.notesKey(account), list)
    }
}
