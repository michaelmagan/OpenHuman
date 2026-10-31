public enum ActionCatalog {
    private static let byID: [ActionID: ActionDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func descriptor(_ id: ActionID) -> ActionDescriptor? { byID[id] }

    public static func descriptors(in category: ActionCategory) -> [ActionDescriptor] {
        all.filter { $0.category == category }
    }

    public static func descriptors(module: FeatureModuleID?) -> [ActionDescriptor] {
        all.filter { $0.module == module }
    }

    private static let listAndReader: Set<ActionScope> = [.list, .reader]

    public static let returnRepliesAll = true
    public static let remindOnH = true

    private static let replyReturn: KeyBinding.Modifiers = returnRepliesAll ? [.shift] : []
    private static let replyAllReturn: KeyBinding.Modifiers = returnRepliesAll ? [] : [.shift]

    static let thread: [ActionDescriptor] = [
        ActionDescriptor(.markDone, "Mark done", category: .thread, bindings: [.key("e")], scopes: listAndReader,
                         changesMail: true, target: .threads, cliCommand: ["gmail", "done"],
                         keywords: ["archive", "done and next", "remove from inbox", "clear"]),
        ActionDescriptor(.moveToInbox, "Move to Inbox", category: .thread, bindings: [.key("E")], scopes: listAndReader,
                         changesMail: true, target: .threads, cliCommand: ["gmail", "move-to-inbox"],
                         keywords: ["unarchive", "back to inbox", "not done", "untrash"]),
        ActionDescriptor(.trash, "Trash", category: .thread, bindings: [.key("#"), .named(.delete)],
                         scopes: listAndReader, changesMail: true, target: .threads, isDestructive: true,
                         cliCommand: ["gmail", "trash"], keywords: ["delete", "bin", "remove"]),
        ActionDescriptor(.spam, "Mark as spam", category: .thread, bindings: [.key("!")], scopes: listAndReader,
                         changesMail: true, target: .threads, isDestructive: true, cliCommand: ["gmail", "spam"],
                         keywords: ["junk", "report spam"]),
        ActionDescriptor(.notSpam, "Not spam", category: .thread, scopes: listAndReader, changesMail: true,
                         target: .threads, cliCommand: ["gmail", "not-spam"], keywords: ["not junk", "move to inbox"]),
        ActionDescriptor(.toggleStar, "Star or unstar", category: .thread, bindings: [.key("s")], scopes: listAndReader,
                         changesMail: true, target: .threads, cliCommand: ["gmail", "star"],
                         keywords: ["star", "unstar", "flag", "favorite"]),
        ActionDescriptor(.toggleRead, "Mark read or unread", category: .thread, bindings: [.key("u")],
                         scopes: listAndReader, changesMail: true, target: .threads, cliCommand: ["gmail", "read"],
                         keywords: ["read", "unread", "seen", "new"]),
        ActionDescriptor(.toggleMute, "Mute or unmute", category: .thread, bindings: [.key("M"), .key("m")],
                         scopes: listAndReader, changesMail: true, target: .threads,
                         keywords: ["mute", "unmute", "silence", "ignore conversation", "stop replies"], module: .mute),
        ActionDescriptor(.label, "Label…", category: .thread, bindings: [.key("l")], scopes: listAndReader,
                         changesMail: true, target: .threads, cliCommand: ["gmail", "thread", "modify"],
                         keywords: ["add label", "tag", "unlabel", "remove label"]),
        ActionDescriptor(.move, "Move to…", category: .thread, bindings: [.key("v")], scopes: listAndReader,
                         changesMail: true, target: .threads,
                         keywords: ["folder", "file", "move to label", "split", "important", "other", "inbox"]),
        ActionDescriptor(.removeLabel, "Remove label", category: .thread, scopes: listAndReader, changesMail: true,
                         target: .threads, cliCommand: ["gmail", "thread", "modify"], keywords: ["unlabel", "untag"]),
        ActionDescriptor(.createLabel, "Create label…", category: .thread, scopes: listAndReader, changesMail: true,
                         target: .threads, cliCommand: ["gmail", "labels", "create"], keywords: ["new label", "add label"]),
        ActionDescriptor(.snooze, "Snooze…", category: .thread, bindings: [.key(remindOnH ? "H" : "h")],
                         scopes: listAndReader, changesMail: true, target: .threads, cliCommand: ["gmail", "snooze"],
                         keywords: ["later", "defer", "hide until"], module: .snooze),
        ActionDescriptor(.unsnooze, "Wake now", category: .thread, scopes: listAndReader, changesMail: true,
                         target: .threads, cliCommand: ["gmail", "unsnooze"], keywords: ["unsnooze", "back now"],
                         module: .snooze),
        ActionDescriptor(.remind, "Remind me…", category: .thread, bindings: [.key(remindOnH ? "h" : "H")],
                         scopes: listAndReader, changesMail: true, target: .focusedThread, cliCommand: ["gmail", "remind"],
                         keywords: ["reminder", "follow up", "nudge", "if no reply"], module: .reminders),
        ActionDescriptor(.clearReminder, "Clear reminder", category: .thread, scopes: listAndReader, changesMail: true,
                         target: .focusedThread, cliCommand: ["gmail", "unremind"], keywords: ["remove reminder", "unremind"],
                         module: .reminders),
        // Why: no menu key equivalent, so a focused composer keeps ⌘U as Underline; the key router handles it elsewhere
        ActionDescriptor(.unsubscribe, "Unsubscribe…", category: .thread, bindings: [.chord("u", .command)],
                         scopes: listAndReader, effect: .external, target: .focusedMessage,
                         keywords: ["stop emails", "mailing list", "opt out"], module: .unsubscribe,
                         allowsMenuKeyEquivalent: false),
    ]

    static let drafts: [ActionDescriptor] = [
        ActionDescriptor(.openDraft, "Open draft", category: .thread, scopes: listAndReader, target: .focusedThread,
                         keywords: ["resume draft", "continue draft", "edit draft", "drafts"]),
        ActionDescriptor(.sendDrafts, "Send drafts…", category: .thread, bindings: [.named(.enter, .command)],
                         scopes: [.list], effect: .external, target: .threads,
                         keywords: ["batch send", "send all drafts", "send selected drafts", "send checked", "outbox"]),
        ActionDescriptor(.rescheduleSend, "Reschedule send…", category: .thread, scopes: listAndReader,
                         effect: .external, target: .focusedThread,
                         keywords: ["send later", "change send time", "scheduled", "move send"], module: .sendLater),
        ActionDescriptor(.cancelScheduledSend, "Cancel scheduled send", category: .thread, scopes: listAndReader,
                         changesMail: true, target: .focusedThread,
                         keywords: ["unschedule", "cancel send later", "don't send", "scheduled"], module: .sendLater),
    ]

    static let selection: [ActionDescriptor] = [
        ActionDescriptor(.toggleCheck, "Check or uncheck", category: .thread, bindings: [.key("x")], scopes: [.list],
                         keywords: ["select", "multi-select"]),
        ActionDescriptor(.extendSelectionDown, "Check next", category: .thread, bindings: [.key("J")], scopes: [.list],
                         keywords: ["select down", "extend selection"], allowsKeyRepeat: true),
        ActionDescriptor(.extendSelectionUp, "Check previous", category: .thread, bindings: [.key("K")], scopes: [.list],
                         keywords: ["select up", "extend selection"], allowsKeyRepeat: true),
        ActionDescriptor(.checkAll, "Check all", category: .thread, bindings: SelectAllShortcuts.bindings(for: .checkAll),
                         scopes: [.list],
                         keywords: ["select all"], allowsMenuKeyEquivalent: false),
        ActionDescriptor(.clearChecks, "Clear checks", category: .thread, bindings: [.named(.escape)], scopes: [.list],
                         keywords: ["deselect", "select none", "close search", "leave search"]),
    ]

    static let importance: [ActionDescriptor] = [
        ActionDescriptor(.alwaysImportantSender, "Always important from this sender", category: .thread,
                         bindings: [.key("+")], scopes: listAndReader, changesMail: true, target: .focusedThread,
                         keywords: ["important", "vip", "keep in primary", "priority"], module: .importance),
        ActionDescriptor(.alwaysImportantDomain, "Always important from this domain", category: .thread,
                         scopes: listAndReader, changesMail: true, target: .focusedThread,
                         keywords: ["important", "company", "keep in primary"], module: .importance),
        ActionDescriptor(.neverImportant, "Never important from this sender", category: .thread, scopes: listAndReader,
                         changesMail: true, target: .focusedThread, keywords: ["not important", "unimportant", "demote"],
                         module: .importance),
        ActionDescriptor(.neverImportantDomain, "Never important from this domain", category: .thread,
                         bindings: [.key("-")], scopes: listAndReader, changesMail: true, target: .focusedThread,
                         keywords: ["not important", "unimportant", "demote", "company", "whole domain"],
                         module: .importance),
        ActionDescriptor(.removeFromSplit, "Remove from this split", category: .thread, scopes: listAndReader,
                         changesMail: true, target: .focusedThread, keywords: ["wrong split", "not this split", "move out"],
                         module: .importance),
        ActionDescriptor(.notAPitch, "Not a pitch", category: .thread, scopes: listAndReader, changesMail: true,
                         target: .focusedThread, keywords: ["not a pitch", "not sales", "not marketing"],
                         module: .importance),
        ActionDescriptor(.explainPlacement, "Why is this here?", category: .thread, scopes: listAndReader,
                         target: .focusedThread, keywords: ["explain", "which rule", "why important", "reason"],
                         module: .importance),
    ]

    static let compose: [ActionDescriptor] = [
        ActionDescriptor(.compose, "New message", category: .compose, bindings: [.key("c"), .chord("n", .command)],
                         keywords: ["compose", "write"]),
        ActionDescriptor(.composeInWindow, "New message in window", category: .compose, bindings: [.key("C")],
                         keywords: ["compose", "pop out"]),
        ActionDescriptor(.reply, "Reply", category: .compose,
                         bindings: [.key("r"), .named(.enter, replyReturn, onlyIn: [.reader])], scopes: listAndReader,
                         target: .focusedThread, keywords: ["respond", "answer"]),
        ActionDescriptor(.replyAll, "Reply all", category: .compose,
                         bindings: [.key("a"), .named(.enter, replyAllReturn, onlyIn: [.reader])], scopes: listAndReader,
                         target: .focusedThread, keywords: ["respond to all"]),
        ActionDescriptor(.forward, "Forward", category: .compose, bindings: [.key("f")], scopes: listAndReader,
                         target: .focusedThread, keywords: ["fwd", "share"]),
        ActionDescriptor(.send, "Send", category: .compose, bindings: [.named(.enter, .command)], scopes: [.composer],
                         effect: .external, appearsInPalette: false, appearsInMenu: false),
        ActionDescriptor(.sendLater, "Send later…", category: .compose, bindings: [.chord("L", .command)],
                         scopes: [.composer], effect: .external, keywords: ["schedule send"], appearsInMenu: false,
                         module: .sendLater),
        ActionDescriptor(.cancelSendLater, "Cancel send later", category: .compose, scopes: [.composer],
                         changesMail: true, keywords: ["unschedule"], appearsInMenu: false, module: .sendLater),
        ActionDescriptor(.discardDraft, "Discard draft", shortTitle: "Discard", category: .compose,
                         bindings: [.named(.delete, .command)], scopes: [.composer], changesMail: true,
                         isDestructive: true, appearsInMenu: false),
        ActionDescriptor(.chooseFrom, "Change From address…", category: .compose,
                         bindings: [.chord("F", .command), .chord("E", .command)], scopes: [.composer],
                         keywords: ["from", "send as", "alias", "sender address"], appearsInMenu: false),
        ActionDescriptor(.attachFiles, "Attach files…", shortTitle: "Attach", category: .compose,
                         bindings: [.chord("U", .command)], scopes: [.composer],
                         keywords: ["attachment", "add file", "paperclip"], appearsInMenu: false),
        ActionDescriptor(.popOutComposer, "Pop out composer", category: .compose, scopes: [.composer],
                         keywords: ["new window", "detach"], appearsInMenu: false),
        ActionDescriptor(.toggleFormatBar, "Show or hide formatting bar", category: .compose,
                         bindings: [.chord("f", [.option, .command])], scopes: [.composer],
                         keywords: ["format", "formatting", "bold", "italic", "underline", "list", "rich text", "toolbar"],
                         appearsInMenu: false),
        ActionDescriptor(.composeRemind, "Remind me after sending…", category: .compose,
                         bindings: [.chord("H", .command)], scopes: [.composer], changesMail: true,
                         keywords: ["remind me", "reminder", "follow up", "if no reply", "nudge"], appearsInMenu: false,
                         module: .reminders),
        ActionDescriptor(.insertSnippet, "Insert snippet…", category: .compose, bindings: [.chord(";", .command)],
                         scopes: [.composer], keywords: ["snippet", "template", "use snippet", ";;"],
                         appearsInMenu: false),
        ActionDescriptor(.saveSnippet, "Save draft as snippet", category: .compose, scopes: [.composer],
                         changesMail: true, keywords: ["new snippet", "template", "create snippet"],
                         appearsInMenu: false),
        ActionDescriptor(.showCc, "Add Cc", category: .compose, bindings: [.chord("C", .command)], scopes: [.composer],
                         keywords: ["cc", "carbon copy", "copy someone"], appearsInMenu: false),
        ActionDescriptor(.showBcc, "Add Bcc", category: .compose, bindings: [.chord("B", .command)], scopes: [.composer],
                         keywords: ["bcc", "blind copy"], appearsInMenu: false),
        ActionDescriptor(.focusTo, "Go to To field", category: .compose, bindings: [.chord("T", .command)],
                         scopes: [.composer], keywords: ["to", "recipients", "address"], appearsInMenu: false),
        ActionDescriptor(.closeComposer, "Close and keep draft", category: .compose, bindings: [.named(.escape)],
                         scopes: [.composer], keywords: ["close", "dismiss", "keep draft", "save draft"],
                         appearsInMenu: false),
    ]

    static let format: [ActionDescriptor] = [
        formatting(.formatBold, "Bold", .chord("b", .command), ["strong", "heavy"]),
        formatting(.formatItalic, "Italic", .chord("i", .command), ["emphasis", "slanted"]),
        formatting(.formatUnderline, "Underline", .chord("u", .command), ["underscore"]),
        formatting(.formatStrikethrough, "Strikethrough", .chord("X", .command), ["strike", "cross out"]),
        formatting(.formatNumberedList, "Numbered list", .chord("7", [.command, .shift]), ["ordered list", "numbers"]),
        formatting(.formatBulletedList, "Bulleted list", .chord("8", [.command, .shift]), ["bullets", "unordered list"]),
        formatting(.formatIndent, "Indent list item", .chord("]", .command), ["indent", "nest", "list level", "sub-bullet"]),
        formatting(.formatOutdent, "Outdent list item", .chord("[", .command), ["outdent", "unindent", "list level"]),
        formatting(.formatQuote, "Quote", .chord("9", [.command, .shift]), ["blockquote", "quotation"]),
        formatting(.formatLink, "Add link…", .chord("K", .command), ["hyperlink", "url", "web address"]),
        formatting(.clearFormatting, "Clear formatting", .chord("\\", .command), ["plain text", "remove formatting"]),
    ]

    public static let formatIDs: [ActionID] = format.map(\.id)

    private static func formatting(_ id: ActionID, _ title: String, _ binding: KeyBinding,
                                   _ keywords: [String]) -> ActionDescriptor {
        ActionDescriptor(id, title, category: .compose, bindings: [binding], scopes: [.composer],
                         keywords: ["format"] + keywords, allowsMenuKeyEquivalent: false)
    }

    static let review: [ActionDescriptor] = [
        ActionDescriptor(.reviewSend, "Send draft", category: .compose, bindings: [.named(.enter, .command)],
                         scopes: [.review], effect: .external, appearsInPalette: false, appearsInMenu: false,
                         module: .review),
        ActionDescriptor(.reviewKeep, "Keep as draft", category: .compose, bindings: [.key("a")], scopes: [.review],
                         changesMail: true, cliCommand: ["gmail", "review", "approve"], keywords: ["approve"],
                         appearsInMenu: false, module: .review),
        ActionDescriptor(.reviewDiscard, "Discard draft", category: .compose, bindings: [.key("#"), .named(.delete)],
                         scopes: [.review], changesMail: true, isDestructive: true,
                         cliCommand: ["gmail", "review", "reject"], keywords: ["reject"], appearsInMenu: false,
                         module: .review),
        ActionDescriptor(.reviewSkip, "Skip draft", category: .compose, bindings: [.key("s")], scopes: [.review],
                         appearsInMenu: false, module: .review),
        ActionDescriptor(.reviewNext, "Next draft", category: .compose, bindings: [.key("j"), .named(.down)],
                         scopes: [.review], appearsInMenu: false, module: .review, allowsKeyRepeat: true),
        ActionDescriptor(.reviewPrevious, "Previous draft", category: .compose, bindings: [.key("k"), .named(.up)],
                         scopes: [.review], appearsInMenu: false, module: .review, allowsKeyRepeat: true),
        ActionDescriptor(.reviewEdit, "Edit draft", category: .compose, bindings: [.named(.enter), .key("e")],
                         scopes: [.review], appearsInMenu: false, module: .review),
        ActionDescriptor(.reviewLeave, "Leave Review queue", category: .navigation, bindings: [.named(.escape)],
                         scopes: [.review], keywords: ["exit review", "back to inbox", "close review"],
                         appearsInMenu: false, module: .review),
    ]

    static let ai: [ActionDescriptor] = [
        ActionDescriptor(.aiRewrite, "AI: rewrite or write…", category: .ai, bindings: [.chord("j", .command)],
                         scopes: [.composer],
                         keywords: ["ai", "rewrite", "write for me", "shorter", "friendlier", "fix spelling", "translate"],
                         appearsInMenu: false, module: .ai),
        ActionDescriptor(.aiReplyOptions, "Quick replies", category: .ai, scopes: [.reader, .composer],
                         target: .focusedThread, keywords: ["ai", "suggested replies", "reply options", "smart reply"],
                         appearsInMenu: false, module: .ai),
        ActionDescriptor(.aiSummarize, "Summarize conversation", category: .ai, bindings: [.key("i")],
                         scopes: listAndReader, target: .focusedThread,
                         keywords: ["ai", "summary", "tl;dr", "what is this about"], appearsInMenu: false, module: .ai),
        ActionDescriptor(.aiAskInbox, "Ask AI…", category: .ai, bindings: [.chord("j", .command)], scopes: listAndReader,
                         keywords: ["ai", "ask", "question", "ask your inbox", "find out", "answer"],
                         appearsInMenu: false, module: .ai),
        ActionDescriptor(.aiToggleInstantReply, "Show or stop showing quick replies when replying", category: .ai,
                         keywords: ["ai", "instant reply", "quick replies", "suggested replies", "tab", "reply strip"],
                         appearsInMenu: false, module: .instantReply),
        ActionDescriptor(.aiHideInstantReply, "Hide quick replies for this conversation", category: .ai,
                         scopes: [.composer], keywords: ["ai", "instant reply", "quick replies", "dismiss", "hide"],
                         appearsInMenu: false, module: .instantReply),
        ActionDescriptor(.aiUseInlineReply, "Use the suggested reply", category: .ai, bindings: [.named(.tab)],
                         scopes: [.reader], target: .focusedThread,
                         keywords: ["ai", "suggested reply", "quick reply", "auto draft", "use"], appearsInMenu: false,
                         module: .ai),
        ActionDescriptor(.aiNextInlineReply, "Next suggested reply", category: .ai, bindings: [.named(.right)],
                         scopes: [.reader], keywords: ["ai", "suggested reply", "quick reply", "next"],
                         appearsInMenu: false, module: .ai),
        ActionDescriptor(.aiPreviousInlineReply, "Previous suggested reply", category: .ai, bindings: [.named(.left)],
                         scopes: [.reader], keywords: ["ai", "suggested reply", "quick reply", "previous"],
                         appearsInMenu: false, module: .ai),
    ]

    static let navigation: [ActionDescriptor] = [
        ActionDescriptor(.nextThread, "Next conversation", category: .navigation,
                         bindings: [.key("j"), .named(.down, onlyIn: [.list])], scopes: listAndReader,
                         allowsKeyRepeat: true),
        ActionDescriptor(.previousThread, "Previous conversation", category: .navigation,
                         bindings: [.key("k"), .named(.up, onlyIn: [.list])], scopes: listAndReader,
                         allowsKeyRepeat: true),
        ActionDescriptor(.openThread, "Open conversation", shortTitle: "Open", category: .navigation,
                         bindings: [.named(.enter), .key("o")], scopes: [.list]),
        ActionDescriptor(.backToList, "Back to list", category: .navigation, bindings: [.named(.escape)],
                         scopes: [.reader]),
        ActionDescriptor(.nextSplit, "Next split", category: .navigation, bindings: [.named(.tab)], scopes: [.list],
                         allowsKeyRepeat: true),
        ActionDescriptor(.previousSplit, "Previous split", category: .navigation, bindings: [.named(.tab, .shift)],
                         scopes: [.list], allowsKeyRepeat: true),
        ActionDescriptor(.search, "Search", category: .navigation,
                         bindings: [.key("/"), .chord("f", .command, onlyIn: [.list])], scopes: [.global, .list],
                         cliCommand: ["gmail", "search"], keywords: ["find", "look up"]),
        ActionDescriptor(.searchGmail, "Search Gmail", category: .navigation, scopes: [.global, .list],
                         keywords: ["gmail", "older mail", "server", "incomplete results", "search online"],
                         appearsInMenu: false),
    ]

    static let goTo: [ActionDescriptor] = [
        ActionDescriptor(.goInbox, "Go to Inbox", category: .navigation, bindings: [.sequence("g", "i")]),
        ActionDescriptor(.goStarred, "Go to Starred", category: .navigation, bindings: [.sequence("g", "s")]),
        ActionDescriptor(.goDrafts, "Go to Drafts", category: .navigation, bindings: [.sequence("g", "d")]),
        ActionDescriptor(.goSent, "Go to Sent", category: .navigation, bindings: [.sequence("g", "t")]),
        ActionDescriptor(.goAllMail, "Go to All mail", category: .navigation, bindings: [.sequence("g", "a")]),
        ActionDescriptor(.goReview, "Go to Review queue", category: .navigation, bindings: [.sequence("g", "r")],
                         cliCommand: ["gmail", "review", "open"], module: .review),
        ActionDescriptor(.goSnoozed, "Go to Snoozed", category: .navigation, bindings: [.sequence("g", "z")],
                         module: .snooze),
        ActionDescriptor(.goReminders, "Go to Reminders", category: .navigation, bindings: [.sequence("g", "h")],
                         module: .reminders),
        ActionDescriptor(.goScheduled, "Go to Scheduled", category: .navigation, bindings: [.sequence("g", "y")],
                         module: .sendLater),
        ActionDescriptor(.goLabel, "Go to label…", category: .navigation, bindings: [.sequence("g", "l")],
                         keywords: ["open label", "folder"]),
        ActionDescriptor(.goMuted, "Go to Muted", category: .navigation, bindings: [.sequence("g", "m")],
                         keywords: ["muted", "silenced", "unmute"], module: .mute),
        ActionDescriptor(.goSnippets, "Go to Snippets", category: .navigation, bindings: [.sequence("g", ";")],
                         keywords: ["snippets", "templates", "snippet list", "edit snippets"], appearsInMenu: false),
        ActionDescriptor(.goSavedSearch, "Go to saved search…", category: .navigation,
                         keywords: ["saved search", "bookmark"], appearsInMenu: false, module: .smartSearch),
        ActionDescriptor(.saveSearch, "Save this search", category: .navigation, keywords: ["save search", "bookmark"],
                         appearsInMenu: false, module: .smartSearch),
        ActionDescriptor(.deleteSavedSearch, "Delete saved search", category: .navigation,
                         keywords: ["remove saved search"], appearsInMenu: false, module: .smartSearch),
    ]

    static let accounts: [ActionDescriptor] = (1...9).map { position in
        ActionDescriptor(.switchToAccount(position), "Account \(position)", category: .account,
                         bindings: [.chord("\(position)", .control)], keywords: ["switch account"])
    } + [
        ActionDescriptor(.addAccount, "Add account…", category: .account,
                         keywords: ["new account", "sign in", "another account", "connect gmail"], appearsInMenu: false),
        ActionDescriptor(.importSuperhumanLabels, "Import Superhuman labels…", category: .account,
                         keywords: ["superhuman", "migrate", "auto labels", "categories", "move from superhuman"],
                         appearsInMenu: false),
    ]

    static let view: [ActionDescriptor] = [
        ActionDescriptor(.toggleLabelSidebar, "Label Sidebar", category: .view,
                         bindings: [.chord("s", [.control, .command]), .named(.left, onlyIn: [.list])],
                         scopes: [.global, .list]),
        ActionDescriptor(.refresh, "Refresh", category: .view, bindings: [.chord("r", .command)],
                         keywords: ["sync now", "check mail", "get new mail", "reload", "fetch mail", "update"]),
    ] + theme

    static let theme: [ActionDescriptor] = [
        ActionDescriptor(.themeLight, "Appearance: Light", category: .view, keywords: ["theme", "light mode", "appearance"],
                         appearsInMenu: false),
        ActionDescriptor(.themeDark, "Appearance: Dark", category: .view, keywords: ["theme", "dark mode", "night", "appearance"],
                         appearsInMenu: false),
        ActionDescriptor(.themeSystem, "Appearance: System", category: .view,
                         keywords: ["theme", "auto", "follow system", "appearance"], appearsInMenu: false),
    ] + builtInAccents.map(accentDescriptor)

    public static let builtInAccents = ["periwinkle", "blue", "iris", "pine", "graphite", "system"]

    public static func accentDescriptor(_ name: String) -> ActionDescriptor {
        ActionDescriptor(.themeAccent(name), "Accent: \(name.prefix(1).uppercased() + name.dropFirst())", category: .view,
                         keywords: ["theme", "color", "colour", "accent", name], appearsInMenu: false)
    }

    static let calendar: [ActionDescriptor] = [
        ActionDescriptor(.calendarToggleSidebar, "Calendar Sidebar", category: .view,
                         bindings: [.key("0", onlyIn: [.list, .reader]), .chord("c", [.control, .command])],
                         scopes: [.global, .list, .reader],
                         keywords: ["calendar", "events", "agenda", "free busy", "availability", "schedule", "time zone"],
                         module: .calendar),
        ActionDescriptor(.calendarCreateEvent, "Create event from email…", category: .thread, bindings: [.key("b")],
                         scopes: listAndReader, target: .focusedThread,
                         keywords: ["event", "meeting", "invite", "calendar", "schedule", "add to calendar"],
                         module: .calendar),
        ActionDescriptor(.calendarPreviousDay, "Calendar: Previous day", category: .view,
                         keywords: ["calendar", "day before", "yesterday", "back"], appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarNextDay, "Calendar: Next day", category: .view,
                         keywords: ["calendar", "day after", "tomorrow", "forward"], appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarToday, "Calendar: Today", category: .view,
                         keywords: ["calendar", "today", "agenda"], appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarInsertAvailability, "Insert free times", category: .compose,
                         bindings: [.chord("A", .command)], scopes: [.composer],
                         keywords: ["availability", "free times", "share availability", "suggest times", "schedule",
                                    "calendar", "when are you free"],
                         appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarSuggestReplyTimes, "Suggest times", category: .view,
                         keywords: ["schedule", "propose", "counter-propose", "reschedule", "meeting time", "availability",
                                    "busy", "conflict", "calendar"],
                         appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarComposerPreviousDay, "Previous Day (draft date)", category: .compose,
                         bindings: [.chord("_", .command)], scopes: [.composer],
                         keywords: ["calendar", "day before", "previous day", "date"], appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarComposerNextDay, "Next Day (draft date)", category: .compose,
                         bindings: [.chord("+", .command)], scopes: [.composer],
                         keywords: ["calendar", "day after", "next day", "date"], appearsInMenu: false,
                         module: .calendar),
    ]

    static let message: [ActionDescriptor] = [
        ActionDescriptor(.nextMessage, "Next message", category: .view, bindings: [.key("n"), .named(.down)],
                         scopes: [.reader], keywords: ["down", "newer message", "focus message", "select message"],
                         allowsKeyRepeat: true),
        ActionDescriptor(.previousMessage, "Previous message", category: .view, bindings: [.key("p"), .named(.up)],
                         scopes: [.reader], keywords: ["up", "older message", "focus message", "select message"],
                         allowsKeyRepeat: true),
        ActionDescriptor(.toggleMessage, "Expand or collapse message", category: .view, bindings: [.key("o")],
                         scopes: [.reader], keywords: ["open message", "close message", "fold"]),
        ActionDescriptor(.expandAllMessages, "Expand all messages", category: .view, bindings: [.key("O")],
                         scopes: [.reader], keywords: ["show all", "older messages", "open all"]),
        ActionDescriptor(.toggleQuotedText, "Show or hide quoted text", category: .view, bindings: [.key(".")],
                         scopes: [.reader], keywords: ["quote", "signature", "history", "trimmed content"]),
        ActionDescriptor(.showImages, "Show remote images", category: .view, bindings: [.key("I")], scopes: [.reader],
                         keywords: ["load images", "pictures", "remote content"]),
        ActionDescriptor(.showNewMessages, "Show new messages", category: .view, bindings: [.key("N")],
                         scopes: [.reader], keywords: ["new mail", "arrived", "latest", "newest", "pill"]),
        ActionDescriptor(.findInConversation, "Find in conversation", category: .view, bindings: [.chord("f", .command)],
                         scopes: [.reader], keywords: ["find", "search this conversation", "look for text"],
                         allowsMenuKeyEquivalent: false),
    ]

    static let app: [ActionDescriptor] = [
        ActionDescriptor(.commandPalette, "Command palette", shortTitle: "Commands", category: .app,
                         bindings: [.chord("k", .command)],
                         keywords: ["commands", "actions", "go to anything"], appearsInPalette: false,
                         activeWhileTyping: true),
        ActionDescriptor(.shortcutHelp, "Keyboard shortcuts", shortTitle: "Shortcuts", category: .app,
                         bindings: [.key("?")],
                         keywords: ["cheat sheet", "help", "keys"]),
        ActionDescriptor(.undo, "Undo Last Action", category: .app,
                         bindings: [.chord("z", .command), .key("z", onlyIn: [.list, .reader])],
                         scopes: [.global, .list, .reader], changesMail: true, keywords: ["undo"],
                         allowsMenuKeyEquivalent: false),
        ActionDescriptor(.redo, "Redo Last Action", category: .app, bindings: [.chord("Z", .command)], changesMail: true,
                         keywords: ["redo"], allowsMenuKeyEquivalent: false),
        ActionDescriptor(.sendFeedback, "Send feedback to another device…", category: .app,
                         keywords: ["feedback", "bug", "report", "taildrop", "tailscale", "send diagnostics"],
                         appearsInMenu: false),
    ]

    public static let settingsPages: [ActionDescriptor] = [
        settingsPage("general", "General", ["preferences", "undo send", "send later", "snooze", "hint bar"]),
        settingsPage("accounts", "Accounts", ["sign out", "alias", "short name", "send as", "from address"]),
        settingsPage("appearance", "Appearance", ["theme", "dark mode", "light mode", "accent", "font", "density"]),
        settingsPage("splitInbox", "Split inbox", ["splits", "tabs", "presets"]),
        settingsPage("sidebar", "Sidebar", ["folders", "hide folders", "all mail", "all inboxes", "unified inbox"]),
        settingsPage("shortcuts", "Shortcuts", ["keyboard shortcuts", "keys", "cheat sheet"]),
        settingsPage("snippets", "Snippets", ["templates"]),
        settingsPage("search", "Search", ["sort", "most relevant", "most recent", "ranking", "search learning"]),
        settingsPage("ai", "AI", ["quick replies", "summary", "models"]),
        settingsPage("notifications", "Notifications", ["alerts", "previews", "sounds"]),
        settingsPage("calendar", "Calendar", ["time zone", "timezone", "meeting link"]),
        settingsPage("privacy", "Privacy", ["remote images", "tracking pixels"]),
        settingsPage("advanced", "Advanced", ["features", "modules", "export settings", "import settings"]),
        settingsPage("platform", "Platform features", ["spotlight", "menu bar", "global shortcut"]),
        settingsPage("importance", "Importance & labels", ["important rules", "vip", "labels", "auto labels", "classifier",
                                                          "rules", "categories"]),
        settingsPage("blocked", "Blocked", ["block", "blocked senders", "blocked domains", "unblock"]),
    ]

    private static func settingsPage(_ page: String, _ title: String, _ keywords: [String]) -> ActionDescriptor {
        ActionDescriptor(.settingsPage(page), "Settings: \(title)", category: .app,
                         keywords: ["settings", "preferences"] + keywords, appearsInMenu: false)
    }
}
