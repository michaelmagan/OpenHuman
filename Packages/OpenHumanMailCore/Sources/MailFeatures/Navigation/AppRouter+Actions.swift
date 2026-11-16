import Foundation
import MailActions
import MailModel
import OpenHumanCore

extension AppRouter {
    @discardableResult
    public func perform(_ action: ActionID, source: ActionSource = .keyboard) -> Bool {
        environment.actions.perform(action, source: source, host: self)
    }

    public func isEnabled(_ action: ActionID) -> Bool {
        environment.actions.availability(action, host: self).isEnabled
    }

    @discardableResult
    public func performClick(_ action: ActionID, source: ActionSource = .toolbar) -> Bool {
        environment.actions.perform(action, source: source, host: self, context: contentContext())
    }

    public func isEnabledForClick(_ action: ActionID) -> Bool {
        environment.actions.availability(action, host: self, context: contentContext()).isEnabled
    }

    func performShellAction(_ action: ActionID) -> Bool {
        if let position = action.accountPosition { return switchAccount(position: position) }
        switch action {
        case .toggleLabelSidebar:
            isLabelSidebarVisible.toggle()
            return true
        case .focusLabelSidebar:
            return focusSidebar()
        default:
            break
        }
        guard let active else { return false }
        if action == .backToList, let compose = environment.composeIfStarted, compose.shownSendingID != nil {
            compose.closeSendingView()
            return true
        }
        if action == .reviewLeave {
            guard active.mode == .list, case .reviewQueue? = active.location else { return false }
            goToInbox()
            return true
        }
        if let location = Self.goLocation(action) {
            go(to: location)
            return true
        }
        if action == .goInbox {
            goToInbox()
            return true
        }
        if action == .goMuted { return goToMuted(active) }
        switch (active.mode, action) {
        case (.list, .nextThread): return moveCursor(active, by: 1)
        case (.list, .previousThread): return moveCursor(active, by: -1)
        case (.list, .openThread):
            if opensDraftRow(active) { return true }
            let opened = active.openCursor()
            if opened { setNeedsPersist() }
            return opened
        case (.list, .nextSplit): return active.cycleTab(by: 1) && persisting()
        case (.list, .previousSplit): return active.cycleTab(by: -1) && persisting()
        case (.reader, .nextThread):
            active.openAdjacent(by: 1)
            return true
        case (.reader, .previousThread):
            active.openAdjacent(by: -1)
            return true
        case (.reader, .backToList):
            if environment.ai?.inlineReplies.current?.dismissIfEngaged() == true { return true }
            closeReader()
            return true
        default:
            return false
        }
    }

    func shellIsEnabled(_ action: ActionID) -> Bool {
        if let position = action.accountPosition { return showsAccountSwitcher && position <= accounts.count }
        if action == .toggleLabelSidebar || action == .focusLabelSidebar { return true }
        guard let active else { return false }
        if action == .reviewLeave {
            guard active.mode == .list, case .reviewQueue? = active.location else { return false }
            return true
        }
        if Self.goLocation(action) != nil || action == .goInbox || action == .goMuted { return true }
        let hasRows = !(active.list?.rows.isEmpty ?? true)
        switch action {
        case .nextThread, .previousThread: return hasRows
        case .openThread: return active.mode == .list && active.list?.cursor != nil
        case .backToList: return active.mode == .reader || environment.composeIfStarted?.shownSendingID != nil
        case .nextSplit, .previousSplit: return active.mode == .list && (active.tabs.count > 1 || !active.splitsLoaded)
        default: return false
        }
    }

    static func goLocation(_ action: ActionID) -> MailLocation? {
        switch action {
        case .goStarred: .system(.starred)
        case .goDrafts: .system(.drafts)
        case .goSent: .system(.sent)
        case .goAllMail: .system(.allMail)
        case .goDone: .system(.done)
        case .goWaiting: .system(.waiting)
        case .goReview: .reviewQueue(nil)
        case .goSnoozed: .system(.snoozed)
        case .goReminders: .system(.reminders)
        case .goScheduled: .system(.scheduled)
        default: nil
        }
    }

    private func goToMuted(_ state: AccountState) -> Bool {
        guard let label = state.mutedLabel else {
            environment.notices.post("Nothing is muted yet. Press ⇧M on a conversation to mute it.", style: .info,
                                     duration: NoticeCenter.infoDuration)
            return true
        }
        go(to: .label(label.labelID))
        return true
    }

    private func moveCursor(_ state: AccountState, by delta: Int) -> Bool {
        guard let list = state.list else { return false }
        list.moveCursor(by: delta)
        return true
    }

    private func persisting() -> Bool {
        setNeedsPersist()
        return true
    }

    func undone(_ entry: UndoCoordinator.Entry) {
        let touched = undoTargets.removeValue(forKey: entry.id)
            ?? entry.threads.first.map { (account: $0.account, threads: entry.threads) }
        guard let (account, threads) = touched, let first = threads.first,
              let state = accounts.first(where: { $0.id == account }), let list = state.list else { return }
        list.clearOptimistic(for: Set(threads))
        state.restoreCursor(first, in: list, updates: 3)
        if let reopen = entry.reopens { self.reopen(reopen, in: state) }
    }

    func reopen(_ reopen: UndoCoordinator.Entry.Reopen, in state: AccountState) {
        guard reopen.thread.account == state.id, state.reader?.thread == reopen.shown else { return }
        state.reopenAfterUndo(reopen.thread)
        setNeedsPersist()
    }
}

extension NoticeCenter {
    public static let infoDuration: Duration = .seconds(4)
}
