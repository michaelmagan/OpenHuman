import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

public enum PaletteGroup: String, Sendable, Hashable, CaseIterable {
    case top = "Top result"
    case ask = "Ask AI"
    case actions = "Actions"
    case goTo = "Go to"
    case mail = "Mail"
    case recent = "Recent"
    case suggested = "Suggested"
    case unavailable = "Not available"
}

public struct PaletteEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case action(ActionID)
        case goTo(MailLocation)
        case account(AccountID)
        case snooze(Date)
        case remind(Date, ReminderKind)
        case label(LabelInfo)
        case mail(ThreadKey)
        case searchMail(String)
        case askAI(String)
        case addToSplit(SplitRuleChoice, SplitKey?)
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let keycaps: [String]
    public let group: PaletteGroup
    public let matched: [Int]
    public let isDestructive: Bool
    public let symbol: String
    let score: Int
    public var unavailableReason: String? = nil

    public var isAvailable: Bool { unavailableReason == nil }

    func with(group: PaletteGroup) -> PaletteEntry {
        PaletteEntry(id: id, kind: kind, title: title, detail: detail, keycaps: keycaps, group: group, matched: matched,
                     isDestructive: isDestructive, symbol: symbol, score: score, unavailableReason: unavailableReason)
    }
}

@MainActor @Observable
public final class PaletteController {
    public static let maxActions = CommandPaletteModel.maxActions
    public static let maxGoTo = 4
    public static let maxMail = 5
    public static let maxUnavailable = 3

    public private(set) var entries: [PaletteEntry] = []
    public private(set) var cursor = 0
    public private(set) var mailTotal = 0

    @ObservationIgnored let model: CommandPaletteModel
    @ObservationIgnored private weak var router: AppRouter?
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let timeDefaults: TimeDefaults
    @ObservationIgnored private var mailRows: [ThreadRow] = []
    @ObservationIgnored private var mailQuery = ""
    @ObservationIgnored private var closeOverlay: (@MainActor () -> Void)?

    init(model: CommandPaletteModel, router: AppRouter, timeZone: TimeZone = .current, locale: Locale = .current,
         now: @escaping @Sendable () -> Date = { Date() }, timeDefaults: TimeDefaults = TimeDefaults(),
         onClose: (@MainActor () -> Void)? = nil) {
        self.model = model
        self.router = router
        self.timeZone = timeZone
        self.locale = locale
        self.now = now
        self.timeDefaults = timeDefaults
        self.closeOverlay = onClose
        recompute()
    }

    public var isOpen: Bool { model.isOpen }
    public var context: ActionContext? { model.context }

    public var scopeSummary: String? {
        guard let context, !context.selection.isEmpty else { return nil }
        if context.selection.count > 1 || context.checkedCount > 1 { return "\(context.selection.count) selected" }
        let key = context.selection[0]
        let subject = router?.accounts.lazy.compactMap { $0.list?.row(for: key)?.subject }.first
            ?? (router?.reader?.thread == key ? router?.reader?.subject : nil)
        guard let subject else { return "1 selected" }
        return subject.isEmpty ? "(no subject)" : subject
    }

    public var selectionCount: Int { context?.selection.count ?? 0 }

    public var query: String {
        get { model.query }
        set {
            guard model.query != newValue else { return }
            model.query = newValue
            mailRows = []
            mailTotal = 0
            recompute()
        }
    }

    public var isEmptyResult: Bool {
        !query.isEmpty && entries.allSatisfy { if case .searchMail = $0.kind { true } else { false } }
    }

    public func close() {
        model.close()
        closeOverlay?()
    }

    public func moveCursor(by delta: Int) {
        let selectable = entries.indices.filter { entries[$0].isAvailable }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: cursor) ?? 0
        let count = selectable.count
        cursor = selectable[((position + delta) % count + count) % count]
    }

    public func moveCursor(to index: Int) {
        guard entries.indices.contains(index), entries[index].isAvailable else { return }
        cursor = index
    }

    private func recompute() {
        guard model.isOpen, let context = model.context else {
            entries = []
            cursor = 0
            return
        }
        let text = model.query.trimmingCharacters(in: .whitespaces)
        var result: [PaletteEntry] = model.rows.map(Self.entry)
        if !text.isEmpty {
            let matcher = FuzzyMatcher(text)
            let extras = presetEntries(matcher, context) + labelEntries(matcher, context) + splitEntries(matcher, context)
            var pool = result.map { ($0, $0.score) } + extras.map { ($0, $0.score) }
            pool = pool.enumerated().sorted { a, b in
                a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
            }.map(\.element)
            var ordered: [PaletteEntry] = []
            if let first = pool.first { ordered.append(first.0.with(group: .top)) }
            ordered += pool.dropFirst().prefix(Self.maxActions).map { $0.0.with(group: .actions) }
            ordered += goToEntries(matcher, context).prefix(Self.maxGoTo)
            ordered += mailEntries(text)
            result = ordered.isEmpty ? [Self.searchEntry(text)] : ordered
            if let ask = askEntry(text, context) { result.insert(ask, at: result.first?.group == .top ? 1 : 0) }
            result += unavailableEntries(matcher, context)
        }
        var seen = Set<String>()
        entries = result.filter { seen.insert($0.id).inserted }
        cursor = entries.firstIndex(where: \.isAvailable) ?? 0
    }

    private func askEntry(_ text: String, _ context: ActionContext) -> PaletteEntry? {
        guard Self.looksLikeQuestion(text), let router,
              router.environment.actions.availability(.aiAskInbox, host: router, context: context).isEnabled else {
            return nil
        }
        return PaletteEntry(id: "ask.\(text)", kind: .askAI(text), title: AskWording.paletteRow(text), detail: nil,
                            keycaps: [], group: .ask, matched: [], isDestructive: false, symbol: "sparkle", score: 0)
    }

    static func looksLikeQuestion(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count >= 3 || (text.hasSuffix("?") && text.contains { $0.isLetter })
    }

    static func entry(_ row: CommandPaletteModel.Row) -> PaletteEntry {
        let group: PaletteGroup = switch row.group {
        case .top: .top
        case .actions: .actions
        case .recent: .recent
        case .suggested: .suggested
        }
        return PaletteEntry(id: "action.\(row.action.rawValue)", kind: .action(row.action), title: row.title, detail: nil,
                            keycaps: row.keycaps, group: group, matched: row.matched, isDestructive: row.isDestructive,
                            symbol: Self.symbol(for: row.action), score: row.score)
    }

    static func symbol(for action: ActionID) -> String {
        if action.themeAccentName != nil { return "paintpalette" }
        if action.accountPosition != nil { return "person.crop.circle" }
        if action.settingsPageID != nil { return "gearshape" }
        if action.classificationSetLabelCategory != nil { return "tag" }
        return symbols[action] ?? ""
    }

    private static let symbols: [ActionID: String] = [
        .markDone: "checkmark", .moveToInbox: "tray.and.arrow.down", .trash: "trash", .spam: "xmark.octagon",
        .notSpam: "checkmark.shield", .toggleStar: "star", .toggleRead: "envelope.badge", .label: "tag",
        .removeLabel: "tag.slash", .removeLabelAndDone: "tag.slash", .move: "folder", .createLabel: "plus",
        .snooze: "clock", .unsnooze: "clock.arrow.circlepath", .remind: "bell", .clearReminder: "bell.slash",
        .unsubscribe: "envelope.badge", .unsubscribeAndDone: "envelope.badge", .unsubscribeAndTrash: "envelope.badge",
        .toggleMute: "speaker.slash", .printConversation: "printer", .getMeToZero: "tray",
        .undoBulkArchive: "arrow.uturn.backward", .suggestCleanup: "tray.full", .archiveSuggested: "archivebox",
        .goAllInboxes: "tray.2", .toggleWaiting: "hourglass", .autoLabelWrong: "tag.slash",
        .instantIntro: "person.2",
        .blockSender: "nosign", .blockDomain: "nosign", .goBlocked: "nosign",
        .copyConversationDebug: "doc.on.clipboard", .saveConversationDebug: "square.and.arrow.down",
        .inviteYes: "checkmark.circle", .inviteMaybe: "questionmark.circle", .inviteNo: "xmark.circle",
        .inviteShowOriginal: "envelope.open", .inviteRemove: "calendar.badge.minus",
        .toggleCheck: "checkmark.square", .extendSelectionDown: "checkmark.square", .extendSelectionUp: "checkmark.square",
        .checkFromHere: "checkmark.square", .checkAll: "checklist", .clearChecks: "square",
        .goInbox: "tray", .goStarred: "star", .goDrafts: "doc", .goSent: "paperplane", .goAllMail: "archivebox",
        .goDone: "checkmark.circle", .goWaiting: "hourglass", .goReview: "doc.badge.ellipsis", .goSnoozed: "clock", .goReminders: "bell",
        .goScheduled: "calendar.badge.clock", .goMuted: "speaker.slash", .goLabel: "tag", .goSavedSearch: "bookmark",
        .goSnippets: "text.insert",
        .nextSplit: "line.3.horizontal", .previousSplit: "line.3.horizontal", .nextThread: "chevron.down",
        .previousThread: "chevron.up", .openThread: "arrow.right", .backToList: "arrow.left",
        .toggleLabelSidebar: "sidebar.left", .toggleContextSidebar: "sidebar.right", .search: "magnifyingglass",
        .searchGmail: "magnifyingglass", .saveSearch: "bookmark", .deleteSavedSearch: "bookmark.slash",
        .addToSplit: "rectangle.split.3x1", .splitFromSearch: "rectangle.split.3x1",
        .addEventsTab: "calendar.badge.plus", .rescanEvents: "calendar.badge.clock",
        .addNewslettersSplit: "newspaper",
        .zoomIn: "plus.magnifyingglass", .zoomOut: "minus.magnifyingglass", .zoomReset: "1.magnifyingglass",
        .themeLight: "sun.max", .themeDark: "moon", .themeSystem: "circle.lefthalf.filled",
        .addAccount: "person.crop.circle.badge.plus", .refresh: "arrow.clockwise", .commandPalette: "command",
        .importSuperhumanLabels: "square.and.arrow.down", .sendFeedback: "paperplane.circle",
        .shortcutHelp: "keyboard", .undo: "arrow.uturn.backward", .redo: "arrow.uturn.forward",
        .resetShortcutHints: "arrow.counterclockwise", .checkForUpdates: "arrow.down.circle",
        .resetSearchLearning: "arrow.counterclockwise", .toggleSearchSort: "arrow.up.arrow.down",
        .copySearchRanking: "list.number",
        .nextMessage: "chevron.down", .previousMessage: "chevron.up", .toggleMessage: "rectangle.expand.vertical",
        .expandAllMessages: "rectangle.expand.vertical", .toggleQuotedText: "ellipsis", .showImages: "photo",
        .showNewMessages: "arrow.down.circle", .findInConversation: "text.magnifyingglass",
        .compose: "square.and.pencil", .composeInWindow: "square.and.pencil", .reply: "arrowshape.turn.up.left",
        .replyAll: "arrowshape.turn.up.left.2", .forward: "arrowshape.turn.up.right", .send: "paperplane",
        .sendLater: "calendar.badge.clock", .cancelSendLater: "calendar.badge.minus", .discardDraft: "trash",
        .showSending: "paperplane.circle",
        .chooseFrom: "person", .attachFiles: "paperclip", .includeOriginalAttachments: "paperclip",
        .popOutComposer: "arrow.up.forward.app", .toggleFormatBar: "textformat", .insertSnippet: "text.insert",
        .composeRemind: "bell",
        .saveSnippet: "text.badge.plus", .saveMessageAsSnippet: "text.badge.plus", .showCc: "person.2",
        .showBcc: "person.2", .focusTo: "person", .closeComposer: "xmark", .openDraft: "pencil",
        .sendDrafts: "paperplane",
        .rescheduleSend: "calendar.badge.clock", .cancelScheduledSend: "calendar.badge.minus",
        .sendScheduledNow: "paperplane.circle",
        .reviewSend: "paperplane", .reviewKeep: "checkmark", .reviewDiscard: "trash", .reviewSkip: "forward",
        .reviewNext: "chevron.down", .reviewPrevious: "chevron.up", .reviewEdit: "pencil", .reviewLeave: "arrow.left",
        .formatBold: "bold", .formatItalic: "italic", .formatUnderline: "underline", .formatStrikethrough: "strikethrough",
        .formatNumberedList: "list.number", .formatBulletedList: "list.bullet", .formatQuote: "text.quote",
        .formatLink: "link", .clearFormatting: "textformat", .formatIndent: "increase.indent",
        .formatOutdent: "decrease.indent",
        .alwaysImportantSender: "exclamationmark.circle", .alwaysImportantDomain: "exclamationmark.circle",
        .neverImportant: "circle.slash", .neverImportantDomain: "circle.slash", .removeFromSplit: "rectangle.split.3x1",
        .notAPitch: "megaphone", .explainPlacement: "questionmark.circle", .moveToImportant: "exclamationmark.circle",
        .moveToOther: "tray",
        .classificationNotImportant: "arrow.down.circle", .classificationMarkImportant: "exclamationmark.circle",
        .classificationRuleFromThread: "line.3.horizontal.decrease.circle",
        .aiAskInbox: "sparkle", .aiRewrite: "sparkle", .aiReplyOptions: "sparkle", .aiSummarize: "sparkle",
        .aiToggleInstantReply: "sparkle", .aiHideInstantReply: "sparkle",
        .aiUseInlineReply: "arrowshape.turn.up.left", .aiNextInlineReply: "chevron.right",
        .aiPreviousInlineReply: "chevron.left",
        .calendarToggleSidebar: "calendar", .calendarCreateEvent: "calendar.badge.plus",
        .calendarPreviousDay: "chevron.left", .calendarNextDay: "chevron.right", .calendarToday: "calendar.circle",
        .calendarInsertAvailability: "calendar.badge.clock", .calendarSuggestReplyTimes: "calendar.badge.clock",
        .calendarComposerPreviousDay: "chevron.left", .calendarComposerNextDay: "chevron.right",
        .calendarOpen: "calendar", .calendarBackToMail: "envelope", .calendarCycleView: "arrow.triangle.2.circlepath",
        .calendarClose: "xmark", .calendarShowToday: "calendar.circle", .calendarPreviousPeriod: "chevron.left",
        .calendarNextPeriod: "chevron.right", .calendarShowDay: "1.square", .calendarShowThreeDays: "3.square",
        .calendarShowWeek: "7.square", .calendarShowMonth: "calendar", .calendarNewEvent: "calendar.badge.plus",
        .calendarRefresh: "arrow.clockwise", .calendarRemoveEvent: "trash",
    ]

    private func unavailableEntries(_ matcher: FuzzyMatcher, _ context: ActionContext) -> [PaletteEntry] {
        guard let router else { return [] }
        let registry = router.environment.actions
        var scored: [PaletteEntry] = []
        for descriptor in registry.descriptors where descriptor.appearsInPalette {
            guard let reason = registry.availability(descriptor.id, host: router, context: context).reason,
                  let text = Self.unavailableText(reason) else { continue }
            let title = ActionRules.title(for: descriptor, in: context)
            guard let match = matcher.match(title: title, keywords: descriptor.paletteKeywords + [descriptor.title]) else {
                continue
            }
            scored.append(PaletteEntry(id: "unavailable.\(descriptor.id.rawValue)", kind: .action(descriptor.id),
                                       title: title, detail: text, keycaps: [], group: .unavailable,
                                       matched: match.positions, isDestructive: false,
                                       symbol: Self.symbol(for: descriptor.id), score: match.score, unavailableReason: text))
        }
        return scored.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.prefix(Self.maxUnavailable).map(\.element)
    }

    public static func unavailableText(_ reason: DisabledReason) -> String? {
        switch reason {
        case .unavailable: "Not available with this mail source yet"
        case .noSelection: "Select a conversation first"
        case .needs(_, let context): "Only works when \(context)"
        case .notBuilt: "Not built yet"
        case .nothingToUndo, .nothingToRedo, .other: nil
        }
    }

    private static func searchEntry(_ text: String) -> PaletteEntry {
        PaletteEntry(id: "search.\(text)", kind: .searchMail(text), title: "Search mail for “\(text)”", detail: nil, keycaps: ["↵"],
                     group: .mail, matched: [], isDestructive: false, symbol: "magnifyingglass", score: 0)
    }

    private func presetEntries(_ matcher: FuzzyMatcher, _ context: ActionContext) -> [PaletteEntry] {
        guard let router else { return [] }
        let registry = router.environment.actions
        let current = now()
        let presets = TimePresets(timeZone: timeZone, defaults: timeDefaults)
        let formatter = TimePickerModel(kind: .snooze, targets: [], presets: presets, locale: locale, now: now) { _ in }
        var result: [PaletteEntry] = []
        func add(_ id: String, kind: PaletteEntry.Kind, title: String, keywords: [String], date: Date) {
            guard let match = matcher.match(title: title, keywords: keywords) else { return }
            result.append(PaletteEntry(id: id, kind: kind, title: title, detail: formatter.shortFormat(date, now: current),
                                       keycaps: [], group: .actions, matched: match.positions, isDestructive: false,
                                       symbol: id.hasPrefix("remind") ? "bell" : "clock", score: match.score))
        }
        if registry.availability(.snooze, host: router, context: context).isEnabled {
            for preset in presets.presets(for: .snooze, now: current) {
                guard let date = preset.date else { continue }
                add("snooze.\(preset.id)", kind: .snooze(date), title: "Snooze until \(preset.title.lowercased())",
                    keywords: ["snooze", "later", "defer"], date: date)
            }
        }
        if registry.availability(.remind, host: router, context: context).isEnabled {
            for preset in presets.presets(for: .remind, now: current) {
                guard let date = preset.date else { continue }
                add("remind.\(preset.id)", kind: .remind(date, .always), title: "Remind me \(preset.title.lowercased())",
                    keywords: ["reminder", "follow up"], date: date)
                add("remind.\(preset.id).ifNoReply", kind: .remind(date, .ifNoReply),
                    title: "Remind me \(preset.title.lowercased()) if no reply", keywords: ["reminder", "follow up"], date: date)
            }
        }
        return result
    }

    private func userLabels() -> [LabelInfo] {
        let labels = (router?.active?.labels ?? [])
            .filter { $0.kind == .user && !$0.isHidden && !$0.name.hasPrefix(OHGmailLabels.root + "/") }
        return router?.environment.superhumanLabels.visible(labels) ?? labels
    }

    private func labelEntries(_ matcher: FuzzyMatcher, _ context: ActionContext) -> [PaletteEntry] {
        guard let router, router.environment.actions.availability(.label, host: router, context: context).isEnabled else {
            return []
        }
        return userLabels().compactMap { label in
            let title = "Label: \(label.displayName)"
            guard let match = matcher.match(title: title, keywords: ["label", label.name]) else { return nil }
            return PaletteEntry(id: "label.\(label.id)", kind: .label(label), title: title, detail: nil, keycaps: [],
                                group: .actions, matched: match.positions, isDestructive: false, symbol: "tag",
                                score: match.score)
        }
    }

    private func splitEntries(_ matcher: FuzzyMatcher, _ context: ActionContext) -> [PaletteEntry] {
        guard model.query.lowercased().contains("split"),
              let router, let thread = context.focusedThread, let active = router.active, active.id == thread.account,
              let descriptor = router.environment.actions.descriptor(.addToSplit),
              ActionRules.availability(descriptor, in: context) == .enabled else { return [] }
        let choices = AddToSplit.choices(for: thread, router: router)
        let targets = AddToSplit.targets(active.splits)
        var result: [PaletteEntry] = []
        func add(_ id: String, _ kind: PaletteEntry.Kind, title: String, keywords: [String]) {
            guard let match = matcher.match(title: title, keywords: keywords) else { return }
            result.append(PaletteEntry(id: id, kind: kind, title: title, detail: nil, keycaps: [], group: .actions,
                                       matched: match.positions, isDestructive: false, symbol: "rectangle.split.3x1",
                                       score: match.score))
        }
        for choice in choices {
            for split in targets {
                add("split.\(split.id.rawValue).\(choice.kind.rawValue).\(choice.value)", .addToSplit(choice, split.id),
                    title: "Add to \(split.name): \(choice.title)", keywords: [AddToSplit.paletteQuery, split.name, choice.value])
            }
            add("split.new.\(choice.kind.rawValue).\(choice.value)", .addToSplit(choice, nil),
                title: "New split: \(choice.title)", keywords: [AddToSplit.paletteQuery, "new split", choice.value])
        }
        return result
    }

    private func goToEntries(_ matcher: FuzzyMatcher, _ context: ActionContext) -> [PaletteEntry] {
        guard let router, let active = router.active else { return [] }
        var scored: [PaletteEntry] = []
        func add(_ id: String, kind: PaletteEntry.Kind, title: String, symbol: String, keywords: [String] = []) {
            guard let match = matcher.match(title: title, keywords: keywords) else { return }
            scored.append(PaletteEntry(id: id, kind: kind, title: title, detail: nil, keycaps: [], group: .goTo,
                                       matched: match.positions, isDestructive: false, symbol: symbol, score: match.score))
        }
        for tab in active.allTabs where tab.location != active.location {
            add("tab.\(tab.title)", kind: .goTo(tab.location), title: "Go to \(tab.title)", symbol: "tray", keywords: [tab.title])
        }
        for label in userLabels() {
            add("goto.label.\(label.id)", kind: .goTo(.label(label.labelID)), title: "Go to \(label.displayName)", symbol: "tag",
                keywords: [label.name])
        }
        if router.environment.smartSearchEnabled, let search = (router.environment.actions.presenter as? OverlayCenter)?.search {
            search.saved.follow(active.id)
            for saved in search.saved.searches where search.saved.account == active.id {
                add("goto.saved.\(saved.id)", kind: .searchMail(saved.query), title: "Go to saved search: \(saved.name)",
                    symbol: "bookmark", keywords: [saved.query, "saved search"])
            }
        }
        for other in router.accounts where other.id != active.id {
            let name = other.account.alias ?? other.account.displayName ?? other.account.email
            add("account.\(other.id.rawValue)", kind: .account(other.id), title: "Go to \(name) › Inbox", symbol: "person.crop.circle",
                keywords: [other.account.email])
        }
        return scored.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
    }

    private func mailEntries(_ text: String) -> [PaletteEntry] {
        guard mailQuery == text, !mailRows.isEmpty else { return [] }
        var result = mailRows.prefix(Self.maxMail).map { row in
            PaletteEntry(id: "mail.\(row.id.account.rawValue).\(row.id.gmailThreadID.rawValue)", kind: .mail(row.id),
                         title: row.subject, detail: row.participantsDisplay, keycaps: [], group: .mail, matched: [],
                         isDestructive: false, symbol: "envelope", score: 0)
        }
        if mailTotal > Self.maxMail {
            result.append(PaletteEntry(id: "search.all", kind: .searchMail(text), title: "See all \(mailTotal) results",
                                       detail: nil, keycaps: ["↵"], group: .mail, matched: [], isDestructive: false,
                                       symbol: "magnifyingglass", score: 0))
        }
        return result
    }

    public func loadMail() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, let router, let account = router.active?.id else { return }
        var found: SearchResultsInfo?
        do {
            for try await page in router.environment.data.search(text, accounts: [account], limit: Self.maxMail + 1) {
                found = page
                break
            }
        } catch {
            return
        }
        guard let found, query.trimmingCharacters(in: .whitespaces) == text else { return }
        mailQuery = text
        mailRows = found.hits.map(\.row)
        mailTotal = found.hasMore || found.hits.count > Self.maxMail ? max(found.hits.count, Self.maxMail + 1) : found.hits.count
        recompute()
    }

    @discardableResult
    public func performSelected() -> Bool {
        guard entries.indices.contains(cursor) else { return false }
        return perform(entries[cursor])
    }

    @discardableResult
    public func perform(_ entry: PaletteEntry) -> Bool {
        guard entry.isAvailable, model.isOpen, let router, let context = model.context else { return false }
        let registry = router.environment.actions
        if case .action(let id) = entry.kind {
            closeOverlay?()
            return model.perform(id)
        }
        close()
        switch entry.kind {
        case .action:
            return false
        case .goTo(let location):
            router.go(to: location)
        case .account(let id):
            router.switchAccount(to: id)
        case .snooze(let date):
            registry.threadActions?.snooze(context.selection, until: date, host: router)
        case .remind(let date, let kind):
            guard let thread = context.focusedThread else { return false }
            registry.threadActions?.remind(thread, at: date, kind: kind, host: router)
        case .label(let label):
            registry.threadActions?.setLabels(context.selection, add: [label], remove: [], host: router)
        case .mail(let key):
            if key.account != router.active?.id { router.switchAccount(to: key.account) }
            router.open(key)
        case .searchMail(let text):
            router.active?.searchText = text
            router.active?.searchOpen = true
            router.go(to: .search(text))
        case .askAI(let text):
            registry.presenter?.present(.askInbox(question: text))
        case .addToSplit(let choice, let split):
            guard let account = context.focusedThread?.account ?? context.account,
                  let handler = registry.superhumanCore else { return false }
            Task { await handler.addToSplit(choice, into: split, account: account) }
        }
        return true
    }
}
