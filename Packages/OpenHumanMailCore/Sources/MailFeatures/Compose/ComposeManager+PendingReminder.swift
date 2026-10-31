import Foundation
import MailModel
import OpenHumanCore

public struct PendingSendReminder: Codable, Sendable, Hashable {
    public var draft: DraftKey
    public var thread: ThreadKey?
    public var dueAt: Date
    public var kind: ReminderKind

    public init(draft: DraftKey, thread: ThreadKey?, dueAt: Date, kind: ReminderKind) {
        self.draft = draft
        self.thread = thread
        self.dueAt = dueAt
        self.kind = kind
    }
}

extension ComposeSettings {
    public static let pendingSendReminders = AppSettingKey<[PendingSendReminder]>(name: "compose.pending_send_reminders",
                                                                                  defaultValue: [])
}

extension ComposeManager {
    func rememberSendReminder(of session: ComposeSession, draft key: DraftKey) async {
        let due: (Date, ReminderKind)?
        if let chosen = session.pendingReminder {
            due = (chosen.dueAt, chosen.kind)
        } else {
            let rule = await SentMailReminderRule.load(from: environment.settings)
            if rule.scope == .externalRecipients,
               let date = rule.dueDate(sentAt: timing.now(), recipients: session.allRecipients.map(\.email),
                                       myAddresses: session.account.myAddresses, calendar: calendar) {
                due = (date, .ifNoReply)
            } else {
                due = nil
            }
        }
        guard let (dueAt, kind) = due else { return }
        let intent = PendingSendReminder(draft: key, thread: session.thread ?? session.draftThread, dueAt: dueAt, kind: kind)
        sendReminderDrafts.insert(key)
        updatePendingSendReminders { list in list.filter { $0.draft != key } + [intent] }
    }

    func forgetSendReminder(_ draft: DraftKey) {
        sendReminderDrafts.remove(draft)
        updatePendingSendReminders { list in list.filter { $0.draft != draft } }
    }

    func resumePendingSendReminders() {
        guard canSend else { return }
        updatePendingSendReminders { [weak self] list in
            guard let self else { return list }
            for intent in list where !self.sendReminderDrafts.contains(intent.draft) { self.track(self.follow(intent)) }
            return list
        }
    }

    private func follow(_ intent: PendingSendReminder) -> Task<Void, Never> {
        let stream = environment.data.draft(intent.draft)
        return Task { [weak self] in
            do {
                for try await row in stream {
                    guard let self else { return }
                    switch row?.status {
                    case nil, .sent?:
                        await self.applySendReminder(intent)
                        return
                    case .sending?:
                        continue
                    case .editing?, .failed?, .scheduled?, .discarded?:
                        self.forgetSendReminder(intent.draft)
                        return
                    }
                }
            } catch {}
        }
    }

    func applySendReminder(_ intent: PendingSendReminder) async {
        forgetSendReminder(intent.draft)
        var conversation = intent.thread
        if conversation == nil { conversation = try? await environment.data.sentConversation(intent.draft) }
        guard let thread = conversation, let actions = environment.actions.threadActions else {
            environment.notices.post(String(localized: "Sent. The reminder wasn't set: find the message in Sent and press ⇧H."),
                                     style: .error)
            return
        }
        await actions.remind(thread, at: max(intent.dueAt, timing.now().addingTimeInterval(60)), kind: intent.kind,
                             host: environment.router)?.value
    }

    @discardableResult
    func updatePendingSendReminders(
        _ change: @escaping @MainActor ([PendingSendReminder]) -> [PendingSendReminder]
    ) -> Task<Void, Never> {
        let previous = sendReminderUpdate
        let settings = environment.settings
        let task = Task { @MainActor in
            await previous?.value
            guard let settings else { return }
            let list = (try? await settings.get(ComposeSettings.pendingSendReminders)) ?? []
            let next = change(list)
            if next != list { try? await settings.set(ComposeSettings.pendingSendReminders, next) }
        }
        sendReminderUpdate = task
        track(task)
        return task
    }
}
