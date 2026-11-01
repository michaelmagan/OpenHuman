import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore
import OpenHumanLinks

@MainActor @Observable
public final class ComposeManager: ActionPresenting {
    public private(set) var sessions: [ComposeSession] = []
    public internal(set) var outgoing: [OutgoingMessage] = []
    public internal(set) var undoSendSeconds = 10
    public internal(set) var showsFormatBar = false
    public internal(set) var sending: [SendingMessage] = [] {
        didSet { if sending != oldValue { updateSendingLine() } }
    }
    public internal(set) var shownSendingID: UUID?
    /// The drafts the last batch send couldn't send; they stay in Drafts.
    public internal(set) var lastBatchFailures: [DraftKey] = []

    @ObservationIgnored public weak var next: (any ActionPresenting)?
    @ObservationIgnored public var openWindow: (@MainActor (ComposeSession) -> Void)?
    @ObservationIgnored public var closeWindow: (@MainActor (ComposeSession) -> Void)?
    @ObservationIgnored public var chooseFiles: (@MainActor (ComposeSession) -> Void)?
    @ObservationIgnored public var dockedComposerHasFocus: (@MainActor (ComposeSession) -> Bool)?
    @ObservationIgnored public var timing: ComposeTiming
    @ObservationIgnored public var recovery: any DraftRecoveryStoring
    @ObservationIgnored public var staging: any AttachmentStaging
    @ObservationIgnored public var calendar: Calendar = .current
    @ObservationIgnored public var locale: Locale = .current
    @ObservationIgnored public var batchPacing = BatchSendPacing()

    @ObservationIgnored unowned let environment: AppEnvironment
    @ObservationIgnored let handler: ComposeActionHandler
    @ObservationIgnored lazy var undoer = ComposeUndoer(manager: self)
    @ObservationIgnored var held: [UUID: HeldSend] = [:]
    @ObservationIgnored var sendsStarting: Set<UUID> = []
    @ObservationIgnored var pendingDiscards: [UUID: PendingDiscard] = [:]
    @ObservationIgnored var scheduled: [UUID: ComposeSession] = [:]
    @ObservationIgnored var pendingSendConditions: [UUID: SendLaterCondition] = [:]
    @ObservationIgnored var archivedBySend: [DraftKey: ArchivedBySend] = [:]
    @ObservationIgnored var sendDoneUpdate: Task<Void, Never>?
    @ObservationIgnored var sendReminderDrafts: Set<DraftKey> = []
    @ObservationIgnored var sendReminderUpdate: Task<Void, Never>?
    @ObservationIgnored var sendingUndoEntries: [UUID: UndoCoordinator.Entry.ID] = [:]
    @ObservationIgnored var batches: [UUID: BatchSend] = [:]
    @ObservationIgnored private var defaultFrom: [AccountID: String?] = [:]
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    // Why: without a store, staged files go to one folder per process that a later process removes once this one exits
    private static let defaultStagingDirectory = TemporaryDirectory.processScoped("OpenHumanMailDrafts-")

    public init(environment: AppEnvironment, timing: ComposeTiming = ComposeTiming(),
                recovery: (any DraftRecoveryStoring)? = nil, staging: (any AttachmentStaging)? = nil) {
        self.environment = environment
        self.timing = timing
        self.recovery = recovery ?? InMemoryDraftRecovery()
        self.staging = staging ?? DirectoryAttachmentStaging(directory: Self.defaultStagingDirectory)
        self.handler = ComposeActionHandler(environment: environment)
        environment.actions.register(handler, for: ComposeActionHandler.coreIDs)
        environment.actions.register(DraftRowActionHandler(environment: environment), for: DraftRowActionHandler.coreIDs)
        let overlays = environment.overlays
        if let previous = overlays.fallback, previous !== self { next = previous }
        overlays.fallback = self
        environment.router.composerContext = { [weak self] in self?.keySession?.actionContext() }
        environment.actions.register(SendingActionHandler(environment: environment), for: [.showSending])
        environment.status.showSending = { [weak self] in _ = self?.showSending() }
        let settings = environment.settings
        track(Task { [weak self] in
            guard let seconds = await Self.read(settings, AppSettings.undoSendSeconds) else { return }
            self?.undoSendSeconds = AppSettings.undoSendHold(seconds)
        })
        track(Task { [weak self] in
            guard let shown = await Self.read(settings, ComposeSettings.showFormatBar) else { return }
            self?.showsFormatBar = shown
        })
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    private var router: AppRouter { environment.router }

    public var textSettings: ComposeTextSettings { environment.composeText }

    public var windowSession: ComposeSession? {
        sessions.last { $0.placement != .window }
    }

    public func dockedSession(for thread: ThreadKey) -> ComposeSession? {
        guard let session = windowSession, session.placement == .docked(thread) else { return nil }
        return session
    }

    public func isShown(_ session: ComposeSession) -> Bool {
        guard session.isOpen else { return false }
        switch session.placement {
        case .modal: return true
        case .window: return false
        case .docked(let thread): return router.mode == .reader && router.active?.reader?.thread == thread
        }
    }

    public var keySession: ComposeSession? {
        guard let session = windowSession, isShown(session) else { return nil }
        guard case .docked = session.placement else { return session }
        if session.focusRequest != session.focusHandled { return session }
        let focused = dockedComposerHasFocus?(session) ?? true
        return focused ? session : nil
    }

    public func ownsShortcutKeys(_ session: ComposeSession) -> Bool {
        if session.placement == .window { return true }
        return keySession === session && !environment.overlays.isShowing
    }

    public func session(id: UUID?) -> ComposeSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id } ?? held[id]?.session ?? pendingDiscards[id]?.session ?? scheduled[id]
    }

    public func canPresent(_ kind: ActionPresentation.Kind) -> Bool {
        kind == .compose || next?.canPresent(kind) == true
    }

    public func present(_ presentation: ActionPresentation) {
        guard case .compose(let request) = presentation else {
            next?.present(presentation)
            return
        }
        open(request)
    }

    @discardableResult
    public func open(_ request: ComposeRequest) -> ComposeSession? {
        switch request {
        case .new:
            return openNew(placement: .modal)
        case .newWindow:
            return openNew(placement: .window)
        case .reply(let thread):
            return openQuotingSelection(thread, mode: .reply)
        case .replyAll(let thread):
            return openQuotingSelection(thread, mode: .replyAll)
        case .forward(let thread):
            return openQuotingSelection(thread, mode: .forward)
        case .mailto(let address, let subject):
            guard let session = openNew(placement: .modal) else { return nil }
            session.applyLink(to: [address], cc: [], subject: subject, body: nil, triedBcc: false)
            return session
        }
    }

    @discardableResult
    public func open(link prefill: ComposePrefill, account: AccountID?) -> ComposeSession? {
        guard let session = openNew(placement: .modal, account: account) else { return nil }
        let to = prefill.to.compactMap(RecipientParser.parseOne)
        let cc = prefill.cc.compactMap(RecipientParser.parseOne)
        session.applyLink(to: to, cc: cc, subject: prefill.subject, body: prefill.body, triedBcc: prefill.droppedBcc)
        return session
    }

    @discardableResult
    public func openNew(placement: ComposeSession.Placement, account accountID: AccountID? = nil) -> ComposeSession? {
        guard let account = account(accountID) else {
            environment.notices.post(String(localized: "Add an account before writing a message"), style: .info,
                                     duration: NoticeCenter.infoDuration)
            return nil
        }
        let session = makeSession(account: account, mode: .new, thread: nil, placement: placement,
                                  from: FromResolver.forNew(account: account, defaultSetting: defaultFrom[account.id] ?? nil))
        present(session)
        session.observeSnippets()
        let settings = environment.settings
        session.fromResolution = Task { [weak self, weak session] in
            let setting = await Self.read(settings, ComposeSettings.defaultFrom(account.id))
            guard let self, let session else { return }
            self.defaultFrom[account.id] = .some(setting ?? nil)
            if let identity = FromResolver.defaultIdentity(session.fromChoices, setting: setting ?? nil) {
                session.applyDefaultFrom(identity)
            }
        }
        return session
    }

    func replyTarget(in thread: ThreadKey) -> MessageKey? {
        guard let reader = router.active?.reader, reader.thread == thread else { return nil }
        return reader.replyTarget
    }

    @discardableResult
    public func openReply(_ thread: ThreadKey, mode: DraftMode, message: MessageKey? = nil,
                          quoting: String? = nil) -> ComposeSession? {
        if let existing = sessions.first(where: { $0.thread == thread && $0.mode != .new && $0.placement != .window }) {
            let differs = existing.mode != mode || (message != nil && existing.replyTo != nil && existing.replyTo != message)
                || quoting != nil
            guard differs, !existing.hasUserEdits else {
                if existing.hasUserEdits { offerDrafts(in: existing, for: message) }
                bringForward(existing)
                return existing
            }
            close(existing)
        }
        guard let account = account(thread.account) else { return nil }
        if router.active?.reader?.thread != thread {
            if router.activeAccountID != thread.account { router.switchAccount(to: thread.account) }
            router.open(thread)
        }
        let session = makeSession(account: account, mode: mode, thread: thread, placement: .docked(thread),
                                  from: FromResolver.forNew(account: account, defaultSetting: defaultFrom[account.id] ?? nil))
        session.isPreparing = true
        session.setReplyTarget(message)
        session.quickQuote = quoting
        present(session)
        session.observeSnippets()
        let data = environment.data
        let settings = environment.settings
        session.preparation = Task { [weak self, weak session] in
            let detail = await Self.first(data.threadDetail(thread)) ?? nil
            let policy = await Self.read(settings, ComposeSettings.replyFrom(account.id)) ?? .addressSentTo
            let remembered = await Self.read(settings, ComposeSettings.threadFrom(account.id))?
                .last { $0.thread == thread.gmailThreadID.rawValue }?.email
            let defaultSetting = await Self.read(settings, ComposeSettings.defaultFrom(account.id)) ?? nil
            let signature = await Self.read(settings, AppSettings.signatureOnReplies) ?? true
            guard let self, let session else { return }
            if !signature { session.startWithoutSignature() }
            self.defaultFrom[account.id] = .some(defaultSetting)
            let messages = detail?.messages ?? []
            let original = message.flatMap { key in messages.first { $0.id == key } } ?? messages.last
            let (identity, reason) = FromResolver.forReply(account: account, policy: policy, original: original,
                                                           thread: messages, remembered: remembered,
                                                           defaultSetting: defaultSetting)
            session.setResolvedFrom(identity, reason: reason)
            await session.prepareReply(original: original, subjectHint: detail?.subject ?? "")
        }
        return session
    }

    private func offerDrafts(in session: ComposeSession, for message: MessageKey?) {
        guard let message, let own = session.replyTo else { return }
        session.offeredReplyTarget = message == own ? nil : message
        guard session.offeredReplyTarget != nil, let center = aiCenter, center.settings.enabled,
              center.settings.draftReplies != .off else { return }
        session.notice = ComposeSession.Notice(
            .info, String(localized: "Your reply is kept. Press ⌘J for quick replies to the message you picked."))
    }

    @discardableResult
    public func openDraft(_ key: DraftKey) -> Task<ComposeSession?, Never> {
        if let existing = sessions.first(where: { $0.draftKey == key }) {
            bringForward(existing)
            return Task { existing }
        }
        let data = environment.data
        return Task { [weak self] in
            guard let row = await Self.first(data.draft(key)) ?? nil, let self,
                  let account = await self.resolveAccount(row.account) else { return nil }
            return self.open(row: row, account: account)
        }
    }

    @discardableResult
    public func openDraft(link draftID: String, account: AccountID) -> Task<ComposeSession?, Never> {
        let data = environment.data
        let commands = environment.commands
        return Task { [weak self] in
            var row = await Self.first(data.draft(DraftKey(draftID))) ?? nil
            if row == nil, let commands,
               let key = try? await commands.fetchDraftNow(account, gmailDraftID: GmailDraftID(draftID)) {
                row = await Self.first(data.draft(key)) ?? nil
            }
            guard let row, let self, let resolved = await self.resolveAccount(row.account) else {
                self?.environment.notices.post(String(localized: "Draft not found"), style: .info,
                                               duration: NoticeCenter.infoDuration)
                return nil
            }
            return self.open(row: row, account: resolved)
        }
    }

    private func open(row: DraftSummary, account: Account) -> ComposeSession? {
        if let existing = sessions.first(where: { $0.draftKey == row.id }) {
            bringForward(existing)
            return existing
        }
        let placement: ComposeSession.Placement
        if let thread = row.thread, router.active?.reader?.thread == thread { placement = .docked(thread) } else { placement = .modal }
        let session = makeSession(account: account, mode: row.mode, thread: row.thread, placement: placement,
                                  from: FromResolver.forNew(account: account, defaultSetting: defaultFrom[account.id] ?? nil))
        session.resumed = true
        session.load(from: row, recovered: recovery.load(row.id, version: row.version))
        session.startObserving(row.id)
        present(session)
        session.observeSnippets()
        updateOpenDrafts()
        return session
    }

    public func restoreOpenDrafts() {
        guard !restored else { return }
        restored = true
        resumePendingSendDone()
        resumePendingSendReminders()
        guard let last = router.openDraftIDs.last else { return }
        openDraft(DraftKey(last))
    }

    private func present(_ session: ComposeSession) {
        if session.placement != .window {
            for other in sessions where other.placement != .window && other !== session { close(other) }
            shownSendingID = nil
        }
        sessions.append(session)
        session.requestFocus()
        if session.placement == .window { openWindow?(session) }
    }

    private func bringForward(_ session: ComposeSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        sessions.append(session)
        session.requestFocus()
        if session.placement == .window { openWindow?(session) }
    }

    public func popOut(_ session: ComposeSession) {
        guard session.isOpen, session.placement != .window else { return }
        session.placement = .window
        bringForward(session)
    }

    public func close(_ session: ComposeSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        session.isOpen = false
        session.closeSnippetPicker()
        session.dropMentionUndo()
        session.aiPanel?.close(refocus: false)
        session.isLinkConfirmationShown = false
        if session.placement == .window { closeWindow?(session) }
        updateOpenDrafts()
        let commands = environment.commands
        let recovery = self.recovery
        track(Task {
            await session.settle()
            defer { session.stopObserving() }
            guard session.canPersist, let commands else { return }
            if session.mode != .new, !session.hasUserEdits, !session.resumed, let key = session.draftKey {
                session.expectsDraftGone = true
                try? await commands.discardDraft(key)
                recovery.remove(key)
                return
            }
            guard session.draftKey != nil || session.hasUserEdits else { return }
            if await session.save(), let key = session.draftKey { try? await commands.flushDraft(key) }
        })
    }

    func hide(_ session: ComposeSession) {
        sessions.removeAll { $0 === session }
        session.isOpen = false
        session.closeSnippetPicker()
        session.dropMentionUndo()
        session.aiPanel?.close(refocus: false)
        session.isLinkConfirmationShown = false
        if session.placement == .window { closeWindow?(session) }
        updateOpenDrafts()
    }

    func reopen(_ session: ComposeSession) {
        session.isOpen = true
        session.notice = nil
        session.expectsDraftGone = false
        session.reloadEditor()
        if let key = session.draftKey { session.startObserving(key) }
        session.observeSnippets()
        if session.placement != .window {
            for other in sessions where other.placement != .window && other !== session { close(other) }
        }
        sessions.append(session)
        session.requestFocus()
        if session.placement == .window { openWindow?(session) }
        updateOpenDrafts()
    }

    func updateOpenDrafts() {
        let ids = sessions.compactMap { $0.draftKey?.rawValue }
        if router.openDraftIDs != ids { router.openDraftIDs = ids }
    }

    private func makeSession(account: Account, mode: DraftMode, thread: ThreadKey?,
                             placement: ComposeSession.Placement, from: (FromIdentity, FromReason)) -> ComposeSession {
        let session = ComposeSession(account: account, mode: mode, thread: thread, placement: placement, from: from,
                                     services: services())
        session.onDraftGone = { [weak self] session, status in self?.draftWentAway(session, status: status) }
        return session
    }

    func services() -> ComposeServices {
        let environment = self.environment
        let settings = environment.settings
        return ComposeServices(
            data: environment.data, commands: environment.commands,
            timing: timing, recovery: recovery, staging: staging, calendar: calendar, locale: locale,
            accountCount: { [weak environment] in environment?.router.accounts.count ?? 1 },
            location: { [weak environment] in environment?.router.active?.location },
            canUndo: { [weak environment] in environment?.undo?.canUndo ?? false },
            canRedo: { [weak environment] in environment?.undo?.canRedo ?? false },
            defaultFromSetting: { [weak self] account in self?.defaultFrom[account] ?? nil },
            rememberFrom: { [weak self] email, thread in self?.rememberFrom(email, thread: thread, settings: settings) },
            recordSnippetUse: { [weak environment] id in
                guard let commands = environment?.commands else { return }
                Task { try? await commands.recordSnippetUse(id) }
            },
            draftOpened: { [weak self] _ in self?.updateOpenDrafts() })
    }

    private func rememberFrom(_ email: String, thread: ThreadKey, settings: (any SettingsPort)?) {
        guard let settings else { return }
        let key = ComposeSettings.threadFrom(thread.account)
        track(Task {
            let list = (try? await settings.get(key)) ?? []
            let choice = ThreadFromChoice(thread: thread.gmailThreadID.rawValue, email: email)
            try? await settings.set(key, ComposeSettings.remembering(choice, in: list))
        })
    }

    private func draftWentAway(_ session: ComposeSession, status: DraftStatus) {
        hide(session)
        session.stopObserving()
        if let key = session.draftKey { recovery.remove(key) }
        let text = status == .scheduled || status == .sending
            ? String(localized: "Sent")
            : String(localized: "This draft was sent or deleted somewhere else")
        environment.notices.post(text, style: .info, duration: NoticeCenter.infoDuration)
    }

    private func resolveAccount(_ id: AccountID) async -> Account? {
        if let known = account(id) { return known }
        let accounts = await Self.first(environment.data.accounts()) ?? []
        return accounts.first { $0.id == id }
    }

    private func account(_ id: AccountID?) -> Account? {
        let states = router.accounts
        if let id { return states.first { $0.id == id }?.account }
        return router.active?.account ?? states.first?.account
    }

    func track(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    public func settle() async {
        for task in tasks { await task.value }
        for session in sessions { await session.settle() }
    }

    static func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async -> T? {
        do {
            for try await value in stream { return value }
        } catch {}
        return nil
    }

    static func read<V>(_ settings: (any SettingsPort)?, _ key: AppSettingKey<V>) async -> V? {
        guard let settings else { return nil }
        return try? await settings.get(key)
    }
}

struct HeldSend {
    let session: ComposeSession
    let token: SendToken
    var watcher = UUID()
}

struct PendingDiscard {
    let session: ComposeSession
    let wasPendingReview: Bool
}
