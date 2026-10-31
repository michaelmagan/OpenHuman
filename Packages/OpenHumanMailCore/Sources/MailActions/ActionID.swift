public struct ActionID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum ActionScope: String, Hashable, Sendable, Codable, CaseIterable {
    case global, list, reader, composer, palette
    case review
    case calendar
}

extension ActionID {
    public static let nextThread = ActionID("nav.nextThread")
    public static let previousThread = ActionID("nav.previousThread")
    public static let openThread = ActionID("nav.openThread")
    public static let backToList = ActionID("nav.back")
    public static let nextSplit = ActionID("nav.nextSplit")
    public static let previousSplit = ActionID("nav.previousSplit")
    public static let goInbox = ActionID("nav.goInbox")
    public static let goStarred = ActionID("nav.goStarred")
    public static let goDrafts = ActionID("nav.goDrafts")
    public static let goSent = ActionID("nav.goSent")
    public static let goAllMail = ActionID("nav.goAllMail")
    public static let goReview = ActionID("nav.goReview")
    public static let goSnoozed = ActionID("nav.goSnoozed")
    public static let goReminders = ActionID("nav.goReminders")
    public static let goScheduled = ActionID("nav.goScheduled")
    public static let goLabel = ActionID("nav.goLabel")
    public static let search = ActionID("nav.search")
    public static let saveSearch = ActionID("search.save")
    public static let deleteSavedSearch = ActionID("search.deleteSaved")
    public static let goSavedSearch = ActionID("nav.goSavedSearch")
    public static let searchGmail = ActionID("nav.searchGmail")
    public static let toggleLabelSidebar = ActionID("view.toggleLabelSidebar")

    public static let themeLight = ActionID("theme.light")
    public static let themeDark = ActionID("theme.dark")
    public static let themeSystem = ActionID("theme.system")
    public static func themeAccent(_ name: String) -> ActionID { ActionID("theme.accent.\(name)") }

    public var themeAccentName: String? {
        let prefix = "theme.accent."
        guard rawValue.hasPrefix(prefix), rawValue.count > prefix.count else { return nil }
        return String(rawValue.dropFirst(prefix.count))
    }

    public static func switchToAccount(_ position: Int) -> ActionID { ActionID("account.switch\(position)") }

    public var accountPosition: Int? {
        guard rawValue.hasPrefix("account.switch"), let n = Int(rawValue.dropFirst("account.switch".count)),
              (1...9).contains(n) else { return nil }
        return n
    }
}

extension ActionID {
    public static let nextMessage = ActionID("message.next")
    public static let previousMessage = ActionID("message.previous")
    public static let toggleMessage = ActionID("message.toggle")
    public static let expandAllMessages = ActionID("message.expandAll")
    public static let toggleQuotedText = ActionID("message.toggleQuotes")
    public static let showImages = ActionID("message.showImages")
    public static let showNewMessages = ActionID("message.showNew")
    public static let findInConversation = ActionID("message.find")
}

extension ActionID {
    public static let markDone = ActionID("thread.done")
    public static let moveToInbox = ActionID("thread.moveToInbox")
    public static let trash = ActionID("thread.trash")
    public static let spam = ActionID("thread.spam")
    public static let notSpam = ActionID("thread.notSpam")
    public static let toggleStar = ActionID("thread.toggleStar")
    public static let toggleRead = ActionID("thread.toggleRead")
    public static let label = ActionID("thread.label")
    public static let move = ActionID("thread.move")
    public static let removeLabel = ActionID("thread.removeLabel")
    public static let createLabel = ActionID("label.create")
}

extension ActionID {
    public static let toggleCheck = ActionID("selection.toggle")
    public static let extendSelectionDown = ActionID("selection.extendDown")
    public static let extendSelectionUp = ActionID("selection.extendUp")
    public static let checkAll = ActionID("selection.all")
    public static let clearChecks = ActionID("selection.clear")
}

extension ActionID {
    public static let snooze = ActionID("thread.snooze")
    public static let unsnooze = ActionID("thread.unsnooze")
    public static let remind = ActionID("reminders.set")
    public static let clearReminder = ActionID("reminders.clear")
    public static let unsubscribe = ActionID("thread.unsubscribe")
}

extension ActionID {
    public static let toggleMute = ActionID("thread.toggleMute")
    public static let goMuted = ActionID("nav.goMuted")
    public static let goSnippets = ActionID("nav.goSnippets")
}

extension ActionID {
    public static let compose = ActionID("compose.new")
    public static let composeInWindow = ActionID("compose.newWindow")
    public static let reply = ActionID("compose.reply")
    public static let replyAll = ActionID("compose.replyAll")
    public static let forward = ActionID("compose.forward")
    public static let send = ActionID("compose.send")
    public static let sendLater = ActionID("compose.sendLater")
    public static let cancelSendLater = ActionID("compose.cancelSendLater")
    public static let discardDraft = ActionID("compose.discard")
    public static let chooseFrom = ActionID("compose.chooseFrom")
    public static let attachFiles = ActionID("compose.attach")
    public static let popOutComposer = ActionID("compose.popOut")
    public static let toggleFormatBar = ActionID("compose.toggleFormatBar")
    public static let composeRemind = ActionID("compose.remind")
    public static let insertSnippet = ActionID("snippet.insert")
    public static let saveSnippet = ActionID("snippet.saveDraft")
    public static let showCc = ActionID("compose.showCc")
    public static let showBcc = ActionID("compose.showBcc")
    public static let focusTo = ActionID("compose.focusTo")
    public static let closeComposer = ActionID("compose.close")

    public static let openDraft = ActionID("draft.open")
    public static let sendDrafts = ActionID("draft.sendChecked")
    public static let rescheduleSend = ActionID("scheduledSend.reschedule")
    public static let cancelScheduledSend = ActionID("scheduledSend.cancel")

    public static let reviewSend = ActionID("review.send")
    public static let reviewKeep = ActionID("review.keep")
    public static let reviewDiscard = ActionID("review.discard")
    public static let reviewSkip = ActionID("review.skip")
    public static let reviewNext = ActionID("review.next")
    public static let reviewPrevious = ActionID("review.previous")
    public static let reviewEdit = ActionID("review.edit")
    public static let reviewLeave = ActionID("review.leave")
}

extension ActionID {
    public static let formatBold = ActionID("format.bold")
    public static let formatItalic = ActionID("format.italic")
    public static let formatUnderline = ActionID("format.underline")
    public static let formatStrikethrough = ActionID("format.strike")
    public static let formatNumberedList = ActionID("format.numbered")
    public static let formatBulletedList = ActionID("format.bullets")
    public static let formatQuote = ActionID("format.quote")
    public static let formatLink = ActionID("format.link")
    public static let clearFormatting = ActionID("format.clear")
}

extension ActionID {
    public static let alwaysImportantSender = ActionID("importance.alwaysSender")
    public static let alwaysImportantDomain = ActionID("importance.alwaysDomain")
    public static let neverImportant = ActionID("importance.never")
    public static let neverImportantDomain = ActionID("importance.neverDomain")
    public static let removeFromSplit = ActionID("importance.removeFromSplit")
    public static let notAPitch = ActionID("importance.notPitch")
    public static let explainPlacement = ActionID("importance.explain")
}

extension ActionID {
    public static let aiRewrite = ActionID("ai.rewrite")
    public static let aiReplyOptions = ActionID("ai.replyOptions")
    public static let aiSummarize = ActionID("ai.summarize")
    public static let aiAskInbox = ActionID("ai.askInbox")
    public static let aiToggleInstantReply = ActionID("ai.toggleInstantReply")
    public static let aiHideInstantReply = ActionID("ai.hideInstantReply")
    public static let aiUseInlineReply = ActionID("ai.useInlineReply")
    public static let aiNextInlineReply = ActionID("ai.nextInlineReply")
    public static let aiPreviousInlineReply = ActionID("ai.previousInlineReply")
}

extension ActionID {
    public static let calendarToggleSidebar = ActionID("calendar.toggleSidebar")
    public static let calendarCreateEvent = ActionID("calendar.createEvent")
    public static let calendarPreviousDay = ActionID("calendar.previousDay")
    public static let calendarNextDay = ActionID("calendar.nextDay")
    public static let calendarToday = ActionID("calendar.goToday")
    public static let calendarInsertAvailability = ActionID("calendar.insertAvailability")
    public static let calendarSuggestReplyTimes = ActionID("calendar.suggestReplyTimes")
    public static let calendarComposerPreviousDay = ActionID("calendar.composerPreviousDay")
    public static let calendarComposerNextDay = ActionID("calendar.composerNextDay")
}

extension ActionID {
    public static let commandPalette = ActionID("app.commandPalette")
    public static let shortcutHelp = ActionID("app.shortcuts")
    public static let undo = ActionID("app.undo")
    public static let redo = ActionID("app.redo")
}

extension ActionID {
    public static let refresh = ActionID("app.refresh")
    public static let addAccount = ActionID("account.add")
    public static let importSuperhumanLabels = ActionID("labels.importSuperhuman")
    public static let sendFeedback = ActionID("feedback.send")

    public static func settingsPage(_ page: String) -> ActionID { ActionID("settings.\(page)") }

    public var settingsPageID: String? {
        let prefix = "settings."
        guard rawValue.hasPrefix(prefix), rawValue.count > prefix.count else { return nil }
        return String(rawValue.dropFirst(prefix.count))
    }
}

extension ActionID {
    public static var viewOnly: Set<ActionID> { Set(ActionCatalog.all.filter { !$0.changesMail }.map(\.id)) }

    public var isViewOnly: Bool { ActionCatalog.descriptor(self).map { !$0.changesMail } ?? false }
}
