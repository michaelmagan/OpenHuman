import Foundation
import MailActions
import MailModel

extension AppRouter: ActionHost {
    public func actionContext() -> ActionContext {
        if var composer = composerContext?() {
            composer.togglesOn = togglesOn()
            return composer
        }
        return contentContext()
    }

    public func contentContext() -> ActionContext {
        var c = ActionContext(accountCount: accounts.count, canWrite: environment.commands != nil, canUndo: environment.undo?.canUndo ?? false,
                              canRedo: environment.undo?.canRedo ?? false, togglesOn: togglesOn())
        c.accountTitles = accounts.map { $0.account.alias ?? $0.account.displayName ?? $0.account.email }
        guard let active else { return c }
        c.account = active.id
        if environment.calendarWindowIfStarted?.isOpen == true {
            c.scope = .calendar
            return c
        }
        c.location = active.location
        c.searchOpen = active.searchOpen
        let list = active.list
        let rows = list?.rows ?? []
        c.hasRows = !rows.isEmpty
        c.checkedCount = active.selection.checked.count
        switch active.mode {
        case .reader:
            c.scope = .reader
            if let reader = active.reader {
                c.focusedThread = reader.thread
                c.selection = [reader.thread]
                c.focusedMessage = reader.replyTarget
                c.sender = reader.messages.last { !active.account.isMe($0.summary.from?.email ?? "") }?
                    .summary.from?.email.lowercased()
            }
        case .list:
            c.scope = active.location.map { if case .reviewQueue = $0 { true } else { false } } == true ? .review : .list
            c.focusedThread = list?.cursor
            c.selection = active.selection.targets(cursor: list?.cursor, order: rows.map(\.id))
        }
        if c.sender == nil, let focused = c.focusedThread, let row = list?.row(for: focused) {
            c.sender = row.participants.first { !$0.isMe }?.email.lowercased()
        }
        let muted = active.mutedLabel?.id
        var targets = TargetState(allStarred: !c.selection.isEmpty, allMuted: muted != nil && !c.selection.isEmpty)
        for key in c.selection {
            guard let row = list?.row(for: key) else {
                targets.allStarred = false
                if let muted, active.mode == .reader, active.reader?.thread == key {
                    if active.reader?.userLabelIDs.contains(muted) != true { targets.allMuted = false }
                } else {
                    targets.allMuted = false
                }
                continue
            }
            if row.isUnread { targets.anyUnread = true }
            if !row.isStarred { targets.allStarred = false }
            if let muted, !row.userLabelIDs.contains(muted) { targets.allMuted = false }
            if row.snoozedUntil != nil { targets.anySnoozed = true }
            if row.reminderAt != nil { targets.anyReminder = true }
            if row.draftCount > 0 { targets.anyDraft = true }
            if row.scheduledSendAt != nil { targets.anyScheduled = true }
        }
        if active.mode == .reader, let detail = active.reader {
            let shownUnread = detail.messages.contains { $0.summary.isUnread }
            if detail.state == .loaded, !detail.pendingMessages.isEmpty {
                targets.anyUnread = shownUnread
            } else if shownUnread {
                targets.anyUnread = true
            }
        }
        if let focused = c.focusedThread, let list, let row = list.row(for: focused), let center = environment.autoLabels {
            targets.autoLabel = center.title(for: row, labels: list.labels)
        }
        c.targets = targets
        return c
    }

    private func togglesOn() -> Set<ActionID> {
        environment.ai?.settings.instantReplyStrip == true ? [.aiToggleInstantReply] : []
    }
}
