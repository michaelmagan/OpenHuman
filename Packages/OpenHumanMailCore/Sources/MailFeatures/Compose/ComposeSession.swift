import Foundation
import MailActions
import MailModel
import MailRender
import Observation
import OpenHumanCore

@MainActor @Observable
public final class ComposeSession: Identifiable {
    public enum Placement: Hashable, Sendable {
        case modal
        case docked(ThreadKey)
        case window
    }

    public enum SaveState: Equatable, Sendable {
        case idle
        case saving
        case saved
        case localOnly(String)
        case failed(String)

        public var text: String? {
            switch self {
            case .idle: nil
            case .saving: String(localized: "Saving…")
            case .saved: String(localized: "Draft saved")
            case .localOnly(let why), .failed(let why): why
            }
        }
    }

    public struct Notice: Equatable, Sendable {
        public enum Kind: Sendable { case info, warning, error }
        public let kind: Kind
        public let text: String
        public let offersSendAgain: Bool

        public init(_ kind: Kind, _ text: String, offersSendAgain: Bool = false) {
            self.kind = kind
            self.text = text
            self.offersSendAgain = offersSendAgain
        }
    }

    public struct SendConfirmation: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case send
            case schedule(Date)
        }

        public let kind: Kind
        public let title: String
        public let message: String
        public let confirmTitle: String

        public init(kind: Kind, title: String, message: String, confirmTitle: String) {
            self.kind = kind
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
        }
    }

    public struct PendingReminder: Equatable, Sendable {
        public let dueAt: Date
        public let kind: ReminderKind

        public init(dueAt: Date, kind: ReminderKind) {
            self.dueAt = dueAt
            self.kind = kind
        }
    }

    public struct SnippetInsertion: Identifiable, Sendable {
        public let id = UUID()
        public let snippet: SnippetInfo
        public let document: RichTextDocument
        public let range: Range<Int>?
        public let context: SnippetContext

        public init(snippet: SnippetInfo, document: RichTextDocument, range: Range<Int>?, context: SnippetContext) {
            self.snippet = snippet
            self.document = document
            self.range = range
            self.context = context
        }
    }

    public struct PendingReply: Equatable, Sendable {
        public let base: RichTextDocument
        public let insertion: String
        public let replacesAll: Bool
        public let revision: Int
    }

    public let id = UUID()
    public let account: Account
    public let mode: DraftMode
    public let thread: ThreadKey?
    public private(set) var replyTo: MessageKey?
    public private(set) var replyToGmailMessageID: GmailMessageID?
    public private(set) var draftKey: DraftKey?
    public private(set) var version: Int?
    public var placement: Placement
    public internal(set) var isOpen = true
    public internal(set) var isPreparing = false
    public private(set) var focusRequest = 0
    @ObservationIgnored public var focusHandled = 0

    public let to: RecipientFieldModel
    public let cc: RecipientFieldModel
    public let bcc: RecipientFieldModel
    public var subject = "" { didSet { if subject != oldValue { edited() } } }
    public var showsCc = false
    public var showsBcc = false
    public internal(set) var recipientDrag: RecipientDrag?
    @ObservationIgnored let recipientUndoBox = RecipientUndoBox()
    public var showsSubject: Bool
    public let fromChoices: [FromIdentity]
    public private(set) var from: FromIdentity
    public private(set) var fromReason: FromReason
    public var isFromPickerOpen = false
    public var includesSignature = true { didSet { if includesSignature != oldValue { edited() } } }
    public private(set) var document = RichTextDocument()
    public private(set) var documentRevision = 0
    public private(set) var quotedHTML = ""
    public private(set) var quotedText = ""
    public var isQuoteExpanded = false
    public internal(set) var attachments: [DraftAttachmentInfo] = []
    public private(set) var isPlainText = false

    public private(set) var saveState: SaveState = .idle
    public private(set) var sendAt: Date?
    public private(set) var sendCondition: SendLaterCondition = .always
    public private(set) var draftStatus: DraftStatus = .editing
    public private(set) var draftError: String?
    public private(set) var source: DraftSource = .user
    public private(set) var review: DraftReview = .none
    public var notice: Notice?
    public internal(set) var pendingReminder: PendingReminder?
    public private(set) var linkRecipients: [EmailAddress]?
    public private(set) var linkTriedBcc = false
    public var isLinkConfirmationShown = false
    public internal(set) var linkScheduleDate: Date?
    @ObservationIgnored var linkScheduleCondition: SendLaterCondition = .always
    public var sendConfirmation: SendConfirmation?
    public var preSendWarning: PreSendWarning?
    public private(set) var snippetPicker: SnippetPickerModel?
    public internal(set) var mentionPicker: MentionPickerModel?
    @ObservationIgnored let mentionState = MentionState()
    public private(set) var snippetTriggerRange: Range<Int>?
    public private(set) var pendingSnippet: SnippetInsertion?
    public private(set) var snippets: [SnippetInfo] = []
    public var aiPanel: AIComposerModel?
    public internal(set) var instantReply: InstantReplyModel?
    @ObservationIgnored var instantReplyDecided = false
    public internal(set) var offeredReplyTarget: MessageKey?
    public internal(set) var scheduling: SchedulingReplyContext?
    public internal(set) var isAutoDraft = false
    public var pendingQuickReplyPreview: Int?
    public private(set) var pendingReply: PendingReply?
    public private(set) var suggestionInBody: String?

    public var holdsUserText: Bool {
        let text = plainText
        guard !Self.isBlank(text) else { return false }
        if let suggestion = suggestionInBody, ReplySuggestions.same(text, suggestion) { return false }
        return true
    }
    @ObservationIgnored public weak var editor: (any ComposeTextEditing)?
    public internal(set) var formatState = ComposeFormatState()
    @ObservationIgnored public weak var formatter: (any ComposeFormatEditing)?

    @ObservationIgnored let services: ComposeServices
    @ObservationIgnored var linkConfirmed = false
    @ObservationIgnored var placeholdersAcknowledged = false
    @ObservationIgnored var sendConfirmed = false
    @ObservationIgnored var preSendChecked = false
    @ObservationIgnored var unresolvedPlaceholders: [String] = []
    @ObservationIgnored var snippetPhrases: [String] = []
    @ObservationIgnored public private(set) var hasUserEdits = false
    @ObservationIgnored var fromChosenByUser = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var isSaving = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Bool, Never>?
    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var snippetTask: Task<Void, Never>?
    @ObservationIgnored var preparation: Task<Void, Never>?
    @ObservationIgnored var fromResolution: Task<Void, Never>?
    @ObservationIgnored var expectsDraftGone = false
    @ObservationIgnored var resumed = false
    @ObservationIgnored var draftThread: ThreadKey?
    @ObservationIgnored var onDraftGone: (@MainActor (ComposeSession, DraftStatus) -> Void)?
    @ObservationIgnored var quickQuote: String?

    init(account: Account, mode: DraftMode, thread: ThreadKey?, placement: Placement, from: (FromIdentity, FromReason),
         services: ComposeServices) {
        self.account = account
        self.mode = mode
        self.thread = thread
        self.placement = placement
        self.services = services
        self.fromChoices = FromResolver.identities(of: account)
        self.from = from.0
        self.fromReason = from.1
        self.showsSubject = mode == .new || mode == .forward
        let suggest: @Sendable (String) async -> [EmailAddress]
        let data = services.data
        let accountID = account.id
        suggest = { prefix in
            (try? await data.contactSuggestions(accountID, prefix: prefix, limit: RecipientFieldModel.maxSuggestions)) ?? []
        }
        to = RecipientFieldModel(kind: .to, suggest: suggest)
        cc = RecipientFieldModel(kind: .cc, suggest: suggest)
        bcc = RecipientFieldModel(kind: .bcc, suggest: suggest)
        for field in [to, cc, bcc] {
            field.onChange = { [weak self] _ in self?.recipientsChanged() }
        }
        if !services.canPersist { saveState = .localOnly(services.localOnlyReason) }
    }

    isolated deinit {
        saveTask?.cancel()
        observeTask?.cancel()
        snippetTask?.cancel()
        preparation?.cancel()
        fromResolution?.cancel()
    }

    public var title: String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        switch mode {
        case .new: return String(localized: "New message")
        case .reply, .replyAll: return String(localized: "Reply")
        case .forward: return String(localized: "Forward")
        }
    }

    public var canPersist: Bool { services.canPersist }

    public var offersFromPicker: Bool { fromChoices.count > 1 }

    public var isFromNonDefault: Bool {
        guard let standard = FromResolver.defaultIdentity(fromChoices, setting: services.defaultFromSetting(account.id))
        else { return false }
        return standard.email != from.email
    }

    public var showsFromReason: Bool { isFromNonDefault || from.needsVerification }

    public var attachmentBytes: Int { outgoingAttachments.reduce(0) { $0 + $1.size } }

    public var signature: SignatureHTML? {
        guard includesSignature, let html = from.signatureHTML,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SignatureHTML(html: html)
    }

    // Plain text only: untrusted Gmail signature HTML is never rendered as HTML
    public var signaturePreview: String? {
        guard let html = from.signatureHTML, !html.isEmpty else { return nil }
        let text = ComposeSerializer.plainText(RichTextDocument(), signature: SignatureHTML(html: html))
        let lines = text.components(separatedBy: "\n").drop { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0 == "-- " }
        let preview = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? nil : preview
    }

    public func assembledFields() -> DraftFields {
        if isPlainText {
            let ownText = ComposeSerializer.plainText(document, signature: signature)
            return DraftFields(from: from.address, to: to.tokens, cc: cc.tokens, bcc: bcc.tokens, subject: subject,
                               bodyHTML: "", bodyText: QuoteSplit.joinText(own: ownText, quote: quotedText),
                               attachments: attachments.filter { !$0.isInline || $0.sourceAttachmentID != nil })
        }
        let parts = Set(attachments.compactMap { $0.isInline ? $0.contentID : nil })
        let shown = document.keepingImages(parts)
        let own = ComposeSerializer.html(shown, signature: signature)
        let ownText = ComposeSerializer.plainText(shown, signature: signature)
        return DraftFields(from: from.address, to: to.tokens, cc: cc.tokens, bcc: bcc.tokens, subject: subject,
                           bodyHTML: own + quotedHTML, bodyText: QuoteSplit.joinText(own: ownText, quote: quotedText),
                           attachments: outgoingAttachments)
    }

    public var outgoingAttachments: [DraftAttachmentInfo] {
        let shown = Set(document.inlineImageIDs)
        return attachments.filter { attachment in
            guard attachment.isInline, attachment.sourceAttachmentID == nil, attachment.localPath != nil,
                  let contentID = attachment.contentID else { return true }
            return shown.contains(contentID)
        }
    }

    public var plainText: String { ComposeSerializer.plainText(document, signature: nil) }

    public var allRecipients: [EmailAddress] { to.tokens + cc.tokens + bcc.tokens }

    public var recipientSummary: String? {
        allRecipients.isEmpty ? nil : ComposeManager.recipientSummary(allRecipients)
    }

    @discardableResult
    func insertSuggestedReply(_ text: String) -> Bool {
        let previous = suggestionInBody
        if let editor, editor.isOnScreen {
            let current = editor.editorText
            let replaces = Self.isBlank(current) || previous.map { ReplySuggestions.same(current, $0) } == true
            let caret = min(editor.editorSelection.upperBound, editor.fullRange.upperBound)
            let target = replaces ? editor.fullRange : caret..<caret
            if editor.replaceText(in: target, with: text) {
                editor.placeCaret(at: target.lowerBound + (text as NSString).length)
                editor.focusEditor()
                suggestionInBody = replaces ? text : nil
                return replaces
            }
        }
        let replaces = Self.isBlank(plainText) || previous.map { ReplySuggestions.same(plainText, $0) } == true
        let base = replaces ? RichTextDocument() : document
        let lines: [RichTextDocument.Block] = text.components(separatedBy: "\n").map {
            .paragraph($0.isEmpty ? [] : [.text($0, [])])
        }
        document = RichTextDocument(blocks: base.blocks + lines)
        documentRevision += 1
        pendingReply = PendingReply(base: base, insertion: replaces ? text : "\n" + text, replacesAll: replaces,
                                    revision: documentRevision)
        instantReply?.bodyDidChange()
        edited()
        suggestionInBody = replaces ? text : nil
        return replaces
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func pendingReplyApplied(_ reply: PendingReply) {
        if pendingReply == reply { pendingReply = nil }
    }

    public func updateBody(_ new: RichTextDocument) {
        guard new != document else { return }
        document = new
        if let suggestion = suggestionInBody, !ReplySuggestions.same(plainText, suggestion) { suggestionInBody = nil }
        instantReply?.bodyDidChange()
        edited()
    }

    public func chooseFrom(_ identity: FromIdentity) {
        isFromPickerOpen = false
        guard fromChoices.contains(identity) else { return }
        fromChosenByUser = true
        guard identity != from else { return }
        from = identity
        fromReason = .chosen
        edited()
        if let thread { services.rememberFrom(identity.email, thread) }
    }

    public func requestFocus() { focusRequest += 1 }

    public func clearPendingReminder() { pendingReminder = nil }

    func setReplyTarget(_ message: MessageKey?) {
        guard let message else { return }
        replyTo = message
        replyToGmailMessageID = message.gmailMessageID
    }

    public func setPlainText(_ on: Bool) {
        guard on != isPlainText else { return }
        isPlainText = on
        if on {
            document = Self.plainDocument(ComposeSerializer.plainText(document, signature: nil))
            documentRevision += 1
        }
        edited()
    }

    static func plainDocument(_ text: String) -> RichTextDocument {
        RichTextDocument(blocks: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map {
            .paragraph($0.isEmpty ? [] : [.text($0, [])])
        })
    }

    public func showCc() { showsCc = true }
    public func showBcc() { showsBcc = true }

    public func attach(_ files: [URL], countsAsEdit: Bool = true) {
        var added: [DraftAttachmentInfo] = []
        var failed = 0
        let folder = draftKey?.rawValue ?? id.uuidString
        for file in files {
            if let staged = try? services.staging.stage(file, draft: folder) { added.append(staged) } else { failed += 1 }
        }
        if !added.isEmpty {
            attachments += added
            if countsAsEdit { edited() } else { dirty = true }
        }
        if failed > 0 {
            notice = Notice(.error, failed == 1 ? String(localized: "Couldn't attach one file.")
                                                : String(localized: "Couldn't attach \(failed) files."))
        } else if attachmentBytes > AttachmentLimits.maxTotalBytes {
            notice = Self.tooLargeNotice
        }
    }

    @discardableResult
    func addOriginalAttachments(_ files: [AttachmentInfo]) -> Int {
        let present = Set(attachments.compactMap(\.sourceAttachmentID))
        let added = files.filter { !present.contains($0.id) }.map {
            DraftAttachmentInfo(sourceAttachmentID: $0.id, filename: $0.filename, mimeType: $0.mimeType, size: $0.size)
        }
        guard !added.isEmpty else { return 0 }
        attachments += added
        edited()
        if attachmentBytes > AttachmentLimits.maxTotalBytes { notice = Self.tooLargeNotice }
        return added.count
    }

    public func removeAttachment(_ attachment: DraftAttachmentInfo) {
        guard let index = attachments.firstIndex(of: attachment) else { return }
        attachments.remove(at: index)
        edited()
    }

    static let tooLargeNotice = Notice(.error, String(localized: "Attachments are over 25 MB. Gmail can't send them; remove some first."))

    public var snippetShortcuts: Set<String> { Set(snippets.compactMap { $0.shortcut?.lowercased() }) }

    public func openSnippetPicker(replacing range: Range<Int>? = nil, query: String = "") {
        snippetTriggerRange = range
        snippetPicker = SnippetPickerModel(snippets: snippets, query: query, onChoose: { [weak self] snippet in
            self?.insertChosenSnippet(snippet)
        }, onClose: { [weak self] in
            self?.snippetPicker = nil
            self?.snippetTriggerRange = nil
        })
    }

    public func updateSnippetTrigger(_ pending: (range: Range<Int>, query: String)?) {
        guard let picker = snippetPicker, snippetTriggerRange != nil else { return }
        guard let pending else {
            picker.close()
            return
        }
        snippetTriggerRange = pending.range
        if picker.query != pending.query { picker.query = pending.query }
    }

    public func closeSnippetPicker() { snippetPicker?.close() }

    public func expansion(forShortcut shortcut: String, replacing range: Range<Int>) -> SnippetInsertion? {
        guard let snippet = snippets.first(where: { $0.shortcut?.lowercased() == shortcut.lowercased() }) else { return nil }
        return insertion(snippet, range: range)
    }

    func insertChosenSnippet(_ snippet: SnippetInfo) {
        let range = snippetTriggerRange
        snippetPicker = nil
        snippetTriggerRange = nil
        pendingSnippet = insertion(snippet, range: range)
    }

    func insertion(_ snippet: SnippetInfo, range: Range<Int>?) -> SnippetInsertion {
        SnippetInsertion(snippet: snippet, document: ComposeSerializer.importHTML(snippet.bodyHTML), range: range,
                         context: snippetContext(snippet))
    }

    public func snippetContext(_ snippet: SnippetInfo? = nil) -> SnippetContext {
        SnippetContext(recipient: to.tokens.first, myName: from.name ?? account.displayName, now: services.timing.now(),
                       calendar: services.calendar, locale: services.locale)
    }

    public func didInsertSnippet(_ insertion: SnippetInsertion, unresolved: [String]) {
        if pendingSnippet?.id == insertion.id { pendingSnippet = nil }
        unresolvedPlaceholders += unresolved
        snippetPhrases += SnippetExpander.phrases(in: ComposeSerializer.plainText(insertion.document, signature: nil))
        placeholdersAcknowledged = false
        if let subjectTemplate = insertion.snippet.subject, subject.trimmingCharacters(in: .whitespaces).isEmpty {
            subject = SnippetExpander.expand(subjectTemplate, variables: insertion.snippet.variables,
                                             context: insertion.context).text
            if mode != .new { showsSubject = true }
        }
        applySnippetRecipientsAndFiles(insertion.snippet)
        services.recordSnippetUse(insertion.snippet.id)
    }

    @discardableResult
    func applySnippetRecipientsAndFiles(_ snippet: SnippetInfo) -> Int {
        var present = Set(allRecipients.map { $0.email.lowercased() })
        for (field, extra) in [(to, snippet.to), (cc, snippet.cc), (bcc, snippet.bcc)] {
            var added: [EmailAddress] = []
            for address in extra {
                let email = address.email.trimmingCharacters(in: .whitespaces)
                guard !email.isEmpty, present.insert(email.lowercased()).inserted else { continue }
                added.append(EmailAddress(name: address.name, email: email))
            }
            guard !added.isEmpty else { continue }
            field.setTokens(field.tokens + added, notify: true)
            if field === cc { showsCc = true }
            if field === bcc { showsBcc = true }
        }
        let wanted = snippet.attachments.filter { file in
            !attachments.contains { $0.filename == file.filename && $0.size == file.size }
        }
        let files = wanted.compactMap(\.fileURL)
        if !files.isEmpty { attach(files) }
        let missing = wanted.count - files.count
        if missing > 0 {
            notice = Notice(.error, missing == 1 ? String(localized: "One of the snippet's files isn't on this Mac.")
                                                 : String(localized: "\(missing) of the snippet's files aren't on this Mac."))
        }
        return missing
    }

    public var unfilledPlaceholders: [String] {
        let text = subject + "\n" + plainText
        var found = SnippetExpander.unfilledPlaceholders(in: text)
        let words = Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).map(String.init))
        for name in unresolvedPlaceholders where words.contains(name.lowercased()) && !found.contains(name) {
            found.append(name)
        }
        for phrase in snippetPhrases where text.contains("{\(phrase)}") && !found.contains(phrase) {
            found.append(phrase)
        }
        return found
    }

    func applyLink(to: [EmailAddress], cc: [EmailAddress], subject: String?, body: String?, triedBcc: Bool) {
        loading = true
        self.to.setTokens(to)
        self.cc.setTokens(cc)
        showsCc = !cc.isEmpty
        if let subject { self.subject = subject }
        if let body, !body.isEmpty {
            document = RichTextDocument(blocks: body.components(separatedBy: "\n").map {
                .paragraph($0.isEmpty ? [] : [.text($0, [])])
            })
            documentRevision += 1
        }
        loading = false
        let added = to + cc
        linkRecipients = added.isEmpty ? nil : added
        linkTriedBcc = triedBcc
        dirty = true
    }

    public var linkBanner: String? {
        guard let linkRecipients else { return nil }
        let list = linkRecipients.map(\.email).joined(separator: ", ")
        return String(localized: "Opened from a link. It added these recipients: \(list). Check them before sending.")
    }

    public func confirmLinkRecipients() {
        linkConfirmed = true
        isLinkConfirmationShown = false
    }

    public func editLinkRecipients() {
        isLinkConfirmationShown = false
        linkScheduleDate = nil
    }

    public func cancelSendConfirmation() {
        sendConfirmation = nil
        sendConfirmed = false
    }

    private func recipientsChanged() {
        if sendConfirmation != nil { cancelSendConfirmation() }
        if linkRecipients != nil {
            linkRecipients = nil
            linkConfirmed = true
            isLinkConfirmationShown = false
            linkScheduleDate = nil
        }
        if notice?.kind != .info { notice = nil }
        edited()
    }

    func edited() {
        guard !loading else { return }
        hasUserEdits = true
        dirty = true
        if notice?.kind == .warning { notice = nil }
        scheduleSave()
    }

    private func scheduleSave() {
        guard canPersist else { return }
        guard isOpen, !isPreparing else { return }
        saveTask?.cancel()
        let timing = services.timing
        saveTask = Task { [weak self] in
            try? await timing.sleep(timing.autosaveDelay)
            guard !Task.isCancelled else { return }
            _ = await self?.save()
        }
    }

    @discardableResult
    public func save(force: Bool = false) async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        let previous = saveChain
        let task = Task { [weak self] () -> Bool in
            _ = await previous?.value
            guard let self else { return false }
            return await self.performSave(force: force)
        }
        saveChain = task
        return await task.value
    }

    public func settle() async {
        await preparation?.value
        await fromResolution?.value
        if let saveTask { await saveTask.value }
        _ = await saveChain?.value
    }

    private func performSave(force: Bool) async -> Bool {
        guard canPersist, let commands = services.commands else { return false }
        await preparation?.value
        if draftKey != nil, !dirty { return true }
        if draftKey == nil, !hasUserEdits, mode == .new, !force { return true }
        let fields = assembledFields()
        dirty = false
        saveState = .saving
        isSaving = true
        defer { isSaving = false }
        do {
            if let key = draftKey {
                version = try await commands.updateDraft(key, fields, expectedVersion: version)
            } else {
                let created = try await commands.createDraft(DraftInput(account: account.id, mode: mode, replyTo: replyTo,
                                                                         content: fields))
                draftKey = created.key
                version = created.version
                services.draftOpened(created.key)
                startObserving(created.key)
            }
            if let key = draftKey, let version {
                services.recovery.save(DraftRecoveryRecord(draftID: key.rawValue, version: version, document: document,
                                                           quotedText: quotedText, includeSignature: includesSignature))
            }
            saveState = dirty ? .saving : .saved
            if dirty { scheduleSave() }
            return !dirty
        } catch MailPortError.conflict {
            saveState = .saved
            if let key = draftKey, let row = await services.draftRow(key) {
                load(from: row, recovered: nil)
                notice = Notice(.warning, String(localized: "This draft changed somewhere else. Mail reloaded it."))
            }
            return false
        } catch {
            dirty = true
            saveState = .failed(String(localized: "Couldn't save the draft"))
            return false
        }
    }

    var recoveryRecord: DraftRecoveryRecord? {
        guard let draftKey, let version else { return nil }
        return DraftRecoveryRecord(draftID: draftKey.rawValue, version: version, document: document,
                                   quotedText: quotedText, includeSignature: includesSignature)
    }

    func load(from row: DraftSummary, recovered: DraftRecoveryRecord?) {
        loading = true
        defer { loading = false }
        draftKey = row.id
        version = row.version
        if let original = row.replyToGmailMessageID { replyToGmailMessageID = original }
        to.setTokens(row.fields.to)
        cc.setTokens(row.fields.cc)
        bcc.setTokens(row.fields.bcc)
        showsCc = showsCc || !row.fields.cc.isEmpty
        showsBcc = showsBcc || !row.fields.bcc.isEmpty
        subject = row.fields.subject
        if !fromChosenByUser, let rowFrom = row.fields.from?.email,
           let identity = fromChoices.first(where: { $0.email == rowFrom.lowercased() }), identity != from {
            from = identity
            fromReason = .draft
        }
        attachments = row.fields.attachments
        if row.fields.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let text = row.fields.bodyText, !text.isEmpty {
            isPlainText = true
            quotedHTML = ""
            if let recovered {
                document = recovered.document
                quotedText = recovered.quotedText
                includesSignature = recovered.includeSignature
            } else {
                document = Self.plainDocument(text)
                quotedText = ""
                includesSignature = false
            }
            documentRevision += 1
            apply(row: row)
            dirty = false
            saveState = canPersist ? .saved : saveState
            return
        }
        let split = QuoteSplit.splitHTML(row.fields.bodyHTML)
        quotedHTML = split.quote
        let imported = ComposeSerializer.importHTML(split.own)
        if let recovered {
            document = recovered.document
            quotedText = recovered.quotedText
            includesSignature = recovered.includeSignature
        } else {
            document = imported
            if let html = from.signatureHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !split.own.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                includesSignature = split.own.contains("gmail_signature")
            }
            quotedText = QuoteSplit.splitText(row.fields.bodyText, quoteHTML: split.quote,
                                              ownText: ComposeSerializer.plainText(imported, signature: signature))
        }
        documentRevision += 1
        apply(row: row)
        dirty = false
        saveState = canPersist ? .saved : saveState
    }

    func apply(row: DraftSummary) {
        sendAt = row.sendAt
        sendCondition = row.sendCondition
        draftStatus = row.status
        draftError = row.lastError
        source = row.source
        review = row.review
        if let filed = row.thread { draftThread = filed }
    }

    func startObserving(_ key: DraftKey) {
        observeTask?.cancel()
        let data = services.data
        observeTask = Task { [weak self] in
            do {
                for try await row in data.draft(key) {
                    guard !Task.isCancelled, let self else { return }
                    self.observed(row)
                }
            } catch {}
        }
    }

    private func observed(_ row: DraftSummary?) {
        guard let row else {
            guard isOpen, !expectsDraftGone else { return }
            onDraftGone?(self, draftStatus)
            return
        }
        apply(row: row)
        if let version, row.version > version, !dirty, !isSaving {
            load(from: row, recovered: nil)
        }
    }

    func observeSnippets() {
        let data = services.data
        let account = self.account.id
        snippetTask?.cancel()
        snippetTask = Task { [weak self] in
            do {
                for try await list in data.snippets(account) {
                    guard !Task.isCancelled, let self else { return }
                    self.snippets = list
                    self.snippetPicker?.update(snippets: list)
                }
            } catch {}
        }
    }

    func prepareReply(original: MessageSummary?, subjectHint: String) async {
        setReplyTarget(original?.id)
        guard canPersist, let commands = services.commands, let original else {
            if let original, let fields = try? await services.data.draftSkeleton(
                DraftInput(account: account.id, mode: mode, replyTo: original.id)) {
                isPreparing = false
                applyLocalSkeleton(fields)
                return
            }
            isPreparing = false
            loading = true
            subject = Self.prefixed(subjectHint, mode: mode)
            loading = false
            if !canPersist {
                notice = Notice(.info, String(localized: "Drafts can't be saved here: recipients and the quoted message aren't filled in, and this reply can't be saved or sent."))
            }
            return
        }
        isPreparing = true
        saveState = .saving
        let input = DraftInput(account: account.id, mode: mode, replyTo: original.id,
                               content: DraftFields(from: from.address))
        do {
            let created = try await commands.createDraft(input)
            services.draftOpened(created.key)
            let row = await services.draftRow(created.key)
            isPreparing = false
            if let row {
                mergeSkeleton(row)
            } else {
                draftKey = created.key
                version = created.version
            }
            guard isOpen else { return }
            startObserving(created.key)
            services.draftOpened(created.key)
            if dirty { scheduleSave() }
        } catch {
            isPreparing = false
            saveState = .failed(String(localized: "Couldn't start the reply"))
            let detail = (error as? MailPortError)?.description ?? String(localized: "Try again.")
            notice = Notice(.error, String(localized: "Couldn't start the reply. \(detail)"))
        }
    }

    private func mergeSkeleton(_ row: DraftSummary) {
        let typed = document
        let typedSubject = subject
        let typedTo = to.tokens, typedCc = cc.tokens, typedBcc = bcc.tokens
        let typedAttachments = attachments
        let wasDirty = dirty
        load(from: row, recovered: nil)
        applyQuickQuote()
        let added = typedAttachments.filter { !attachments.contains($0) }
        if !added.isEmpty {
            attachments += added
            dirty = true
        }
        if wasDirty {
            loading = true
            if typed != RichTextDocument() { document = typed; documentRevision += 1 }
            if !typedSubject.isEmpty { subject = typedSubject }
            if !typedTo.isEmpty { to.setTokens(row.fields.to + typedTo.filter { !row.fields.to.contains($0) }) }
            if !typedCc.isEmpty { cc.setTokens(row.fields.cc + typedCc.filter { !row.fields.cc.contains($0) }) }
            if !typedBcc.isEmpty { bcc.setTokens(typedBcc) }
            loading = false
            dirty = true
        }
    }

    private func applyLocalSkeleton(_ fields: DraftFields) {
        loading = true
        defer { loading = false }
        to.setTokens(fields.to + to.tokens.filter { !fields.to.contains($0) })
        cc.setTokens(fields.cc + cc.tokens.filter { !fields.cc.contains($0) })
        showsCc = showsCc || !cc.tokens.isEmpty
        if subject.trimmingCharacters(in: .whitespaces).isEmpty { subject = fields.subject }
        if attachments.isEmpty { attachments = fields.attachments }
        let split = QuoteSplit.splitHTML(fields.bodyHTML)
        quotedHTML = split.quote
        quotedText = QuoteSplit.splitText(fields.bodyText, quoteHTML: split.quote,
                                          ownText: ComposeSerializer.plainText(ComposeSerializer.importHTML(split.own),
                                                                               signature: nil))
        applyQuickQuote()
    }

    private func applyQuickQuote() {
        guard let selection = quickQuote, !quotedHTML.isEmpty else { return }
        quickQuote = nil
        let cut = QuickQuote.quote(selection, mode: mode, html: quotedHTML, text: quotedText)
        quotedHTML = cut.html
        quotedText = cut.text
        dirty = true
    }

    func startWithoutSignature() {
        guard !hasUserEdits, includesSignature else { return }
        loading = true
        includesSignature = false
        loading = false
    }

    static func prefixed(_ subject: String, mode: DraftMode) -> String {
        let prefix = mode == .forward ? "Fwd: " : "Re: "
        if mode == .new || subject.lowercased().hasPrefix(prefix.lowercased()) { return subject }
        return prefix + subject
    }

    func applyDefaultFrom(_ identity: FromIdentity) {
        guard !fromChosenByUser, fromReason == .accountDefault, identity != from else { return }
        from = identity
        if draftKey != nil { edited() }
    }

    func setResolvedFrom(_ identity: FromIdentity, reason: FromReason) {
        guard !fromChosenByUser else { return }
        from = identity
        fromReason = reason
    }

    func stopObserving() {
        observeTask?.cancel()
        snippetTask?.cancel()
        saveTask?.cancel()
    }

    func reloadEditor() { documentRevision += 1 }
}

extension ComposeSession: ActionHost {
    public func actionContext() -> ActionContext {
        ActionContext(scope: .composer, account: account.id, accountCount: services.accountCount(),
                      location: services.location(), selection: thread.map { [$0] } ?? [], focusedThread: thread,
                      focusedMessage: replyTo, hasRows: false, composer: id, canWrite: services.commands != nil,
                      canUndo: services.canUndo(), canRedo: services.canRedo())
    }
}

@MainActor
struct ComposeServices {
    let data: any MailDataSource
    let commands: (any MailCommanding)?
    let timing: ComposeTiming
    let recovery: any DraftRecoveryStoring
    let staging: any AttachmentStaging
    let calendar: Calendar
    let locale: Locale
    let accountCount: @MainActor () -> Int
    let location: @MainActor () -> MailLocation?
    let canUndo: @MainActor () -> Bool
    let canRedo: @MainActor () -> Bool
    let defaultFromSetting: @MainActor (AccountID) -> String?
    let rememberFrom: @MainActor (String, ThreadKey) -> Void
    let recordSnippetUse: @MainActor (String) -> Void
    let draftOpened: @MainActor (DraftKey) -> Void

    var canPersist: Bool { commands != nil }

    var localOnlyReason: String { String(localized: "Drafts can't be saved here") }

    func draftRow(_ key: DraftKey) async -> DraftSummary? {
        do {
            for try await row in data.draft(key) { return row }
        } catch {}
        return nil
    }
}
