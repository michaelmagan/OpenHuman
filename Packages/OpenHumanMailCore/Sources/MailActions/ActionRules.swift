import MailModel

public enum ActionRules {
    public static func availability(_ descriptor: ActionDescriptor, in context: ActionContext) -> ActionAvailability {
        guard isInScope(descriptor, context.scope) else { return .hidden }
        let state = stateRule(descriptor.id, context)
        if state == .hidden { return .hidden }
        if descriptor.changesMail, !context.canWrite { return .disabled(.unavailable(descriptor.title)) }
        switch descriptor.target {
        case .none:
            break
        case .threads:
            if context.selection.isEmpty { return .disabled(.noSelection) }
        case .focusedThread:
            if context.focusedThread == nil { return .disabled(.noSelection) }
        case .focusedMessage:
            if context.focusedMessage == nil { return .disabled(.other("Open the conversation first")) }
        }
        return state ?? .enabled
    }

    public static func isInScope(_ descriptor: ActionDescriptor, _ scope: ActionScope) -> Bool {
        descriptor.scopes.contains(scope) || descriptor.scopes.contains(.global)
    }

    public static func title(for descriptor: ActionDescriptor, in context: ActionContext) -> String {
        switch descriptor.id {
        case .toggleStar: context.targets.allStarred ? "Unstar" : "Star"
        case .toggleRead: context.targets.anyUnread ? "Mark read" : "Mark unread"
        case .toggleMute: context.targets.allMuted ? "Unmute" : "Mute"
        case .toggleWaiting: context.location == .system(.sent) ? "Wait for reply" : "Not waiting"
        case .autoLabelWrong: context.targets.autoLabel.map { "Wrong label (not \($0))" } ?? descriptor.title
        case .clearChecks:
            context.checkedCount == 0 && (context.searchOpen || isSearch(context.location)) ? "Close search" : descriptor.title
        case .sendDrafts: context.selection.count > 1 ? "Send \(context.selection.count) drafts…" : "Send draft…"
        case .aiToggleInstantReply:
            context.togglesOn.contains(.aiToggleInstantReply) ? "Stop showing quick replies when replying"
                                                              : "Show quick replies when replying"
        default:
            descriptor.id.accountPosition.flatMap(context.accountTitle(at:)).map { "Switch to \($0)" } ?? descriptor.title
        }
    }

    static func isSearch(_ location: MailLocation?) -> Bool {
        if case .search? = location { return true }
        return false
    }

    static func stateRule(_ id: ActionID, _ c: ActionContext) -> ActionAvailability? {
        switch id {
        case .instantIntro:
            return c.scope == .composer ? nil
                : .disabled(.needs(action: "Instant Intro", context: "you are writing a reply to an introduction"))
        case .undo: return c.canUndo ? nil : .disabled(.nothingToUndo)
        case .redo: return c.canRedo ? nil : .disabled(.nothingToRedo)
        case .moveToInbox: return c.isInInbox ? .hidden : nil
        case .spam: return c.location == .system(.spam) ? .hidden : nil
        case .notSpam: return c.location == .system(.spam) ? nil : .hidden
        case .toggleMute: return c.location == .system(.trash) || c.location == .system(.spam) ? .hidden : nil
        case .toggleWaiting: return c.location == .system(.waiting) || c.location == .system(.sent) ? nil : .hidden
        case .autoLabelWrong: return c.targets.autoLabel == nil ? .hidden : nil
        case .unsnooze: return c.targets.anySnoozed || c.location == .system(.snoozed) ? nil : .hidden
        case .clearReminder: return c.targets.anyReminder || c.location == .system(.reminders) ? nil : .hidden
        case .openDraft:
            return c.targets.anyDraft || c.targets.anyScheduled || c.location == .system(.drafts)
                || c.location == .system(.scheduled) ? nil : .hidden
        case .sendDrafts: return c.location == .system(.drafts) ? nil : .hidden
        case .rescheduleSend, .cancelScheduledSend:
            return c.targets.anyScheduled || c.location == .system(.scheduled) ? nil : .hidden
        case .removeLabel, .removeLabelAndDone:
            if case .label = c.location { return nil }
            return .hidden
        case .splitFromSearch: return isSearch(c.location) ? nil : .hidden
        case .removeFromSplit:
            if case .split = c.location { return nil }
            return .hidden
        case .alwaysImportantSender, .neverImportant, .notAPitch:
            return c.sender == nil && c.focusedThread != nil ? .disabled(.other("No sender address")) : nil
        case .blockSender, .blockDomain:
            switch c.location {
            case .system(.sent), .system(.drafts), .system(.scheduled), .system(.trash), .system(.spam): return .hidden
            default: break
            }
            if id == .blockSender { return c.sender == nil && c.focusedThread != nil ? .disabled(.other("No sender address")) : nil }
            return c.senderDomain == nil && c.focusedThread != nil ? .disabled(.other("No sender domain")) : nil
        case .alwaysImportantDomain, .neverImportantDomain:
            return c.senderDomain == nil && c.focusedThread != nil ? .disabled(.other("No sender domain")) : nil
        case .clearChecks: return c.checkedCount > 0 || c.searchOpen || isSearch(c.location) ? nil : .hidden
        case .toggleCheck, .extendSelectionDown, .extendSelectionUp, .checkAll, .checkFromHere:
            return c.hasRows ? nil : .disabled(.noSelection)
        default:
            if let position = id.accountPosition {
                return c.accountCount >= 2 && position <= c.accountCount ? nil : .hidden
            }
            return nil
        }
    }
}
