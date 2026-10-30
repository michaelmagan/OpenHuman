import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore

extension MailEngine {
    public func newDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?,
                         origin: DraftOrigin, initial: DraftContent? = nil) async throws -> NewDraft {
        try checkMailWrite([account], what: "newDraft")
        let skeleton = try await replySkeleton(account: account, mode: mode, replyTo: replyTo)
        let forwarded = try forwardedAttachments(account: account, mode: mode, replyTo: replyTo)
        let byAgent = origin != .user
        var headers = ComposeSupport.threadingHeaders(skeleton)
        if byAgent { headers[ComposeSupport.originHeader] = origin.rawValue }
        let id = try store.createDraft(account: account, mode: mode, replyTo: replyTo,
                                       content: ComposeSupport.merge(initial, skeleton, forwarded: forwarded),
                                       origin: origin,
                                       reviewState: byAgent ? .pending : .none, agentNote: nil, extraHeaders: headers)
        if byAgent { try await saveRemotelyNow(id, account: account) }
        return NewDraft(id: id, version: 1, skeleton: try skeleton.map { try withThread($0, of: id) })
    }

    public func saveDraft(_ id: DraftID, content: DraftContent, expectedVersion: Int?) async throws -> Int {
        let draft = try requireDraft(id)
        try checkMailWrite([draft.accountID], what: "saveDraft")
        let version = try store.updateDraft(id, content: content, expectedVersion: expectedVersion)
        if version == draft.localVersion, !draft.isDirty { return version }
        if configuration.role == .app {
            await debouncer().noteEdit(id)
        } else {
            try await saveRemotelyNow(id, account: draft.accountID)
        }
        return version
    }

    public func flushDraft(_ id: DraftID) async throws {
        let draft = try requireDraft(id)
        try checkMailWrite([draft.accountID], what: "flushDraft")
        await cancelRemoteSave(id)
        try await saveRemotelyNow(id, account: draft.accountID)
    }

    public func discardDraft(_ id: DraftID) async throws {
        let draft = try requireDraft(id)
        try checkMailWrite([draft.accountID], what: "discardDraft")
        await cancelRemoteSave(id)
        _ = try store.discardDraft(id)
        await poke([draft.accountID])
    }

    public func send(_ id: DraftID, authorization: SendAuthorization, undoWindow: Duration?) async throws -> SendReceipt {
        try EnginePolicy.checkSend(role: configuration.role, what: "send")
        let draft = try requireDraft(id)
        try checkGrants([draft.accountID], what: "send")
        await cancelRemoteSave(id)
        let receipt: SendReceipt
        switch authorization {
        case .userConfirmed:
            let window = try undoWindow ?? Self.undoWindow(storedSeconds: store.setting(.undoSendSeconds, scope: .global))
            receipt = try store.send(id, undoWindow: window, origin: .app)
        case .scheduled:
            receipt = try store.send(id, undoWindow: .zero, origin: .scheduler)
        }
        await poke([draft.accountID])
        return receipt
    }

    static func undoWindow(storedSeconds: Int) -> Duration {
        let range = SettingKey<Int>.undoSendSecondsRange
        return .seconds(min(max(storedSeconds, range.lowerBound), range.upperBound))
    }

    public func cancelSend(_ receipt: SendReceipt) async throws -> Bool {
        guard configuration.role == .app else { throw EngineError.sendNotAllowed }
        return try store.cancelSend(receipt)
    }

    public func sendNow(_ receipt: SendReceipt) async throws -> Bool {
        try EnginePolicy.checkSend(role: configuration.role, what: "sendNow")
        let done = try store.sendNow(receipt)
        if let account = try store.draft(receipt.draftID)?.accountID { await poke([account]) }
        return done
    }

    public func scheduleSend(_ id: DraftID, at: Date) async throws {
        try await scheduleSend(id, at: at, onlyIfNoReply: false)
    }

    public func scheduleSend(_ id: DraftID, at: Date, onlyIfNoReply: Bool) async throws {
        try EnginePolicy.checkSend(role: configuration.role, what: "scheduleSend")
        guard at > configuration.clock.now else { throw StoreError.conflict("the scheduled time has passed") }
        let draft = try requireDraft(id)
        try checkGrants([draft.accountID], what: "scheduleSend")
        await cancelRemoteSave(id)
        try store.scheduleSend(id, at: at, onlyIfNoReply: onlyIfNoReply)
        await poke([draft.accountID])
    }

    public func cancelScheduledSend(_ id: DraftID) async throws {
        guard configuration.role == .app else { throw EngineError.sendNotAllowed }
        let draft = try requireDraft(id)
        try checkMailWrite([draft.accountID], what: "cancelScheduledSend")
        try store.cancelScheduledSend(id)
        await poke([draft.accountID])
    }

    public func createAgentDraft(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?,
                                 content: DraftContent, note: String?, origin: DraftOrigin) async throws -> DraftID {
        try checkMailWrite([account], what: "createAgentDraft")
        guard origin != .user else { throw StoreError.conflict("createAgentDraft needs origin agent or cli") }
        let skeleton = try await replySkeleton(account: account, mode: mode, replyTo: replyTo)
        var headers = ComposeSupport.threadingHeaders(skeleton)
        headers[ComposeSupport.originHeader] = origin.rawValue
        let id = try store.createDraft(account: account, mode: mode, replyTo: replyTo,
                                       content: ComposeSupport.merge(content, skeleton), origin: origin,
                                       reviewState: .pending, agentNote: note, extraHeaders: headers)
        try await saveRemotelyNow(id, account: account)
        return id
    }

    public func updateAgentDraft(_ id: DraftID, content: DraftContent, note: String?) async throws {
        let draft = try requireDraft(id)
        try checkMailWrite([draft.accountID], what: "updateAgentDraft")
        _ = try store.updateAgentDraft(id, content: ComposeSupport.agentUpdate(content, over: draft.content),
                                       agentNote: note)
        try await saveRemotelyNow(id, account: draft.accountID)
    }

    public func setReviewState(_ id: DraftID, _ state: DraftReviewState) async throws {
        let draft = try requireDraft(id)
        try checkMailWrite([draft.accountID], what: "setReviewState")
        try store.setReviewState(id, state)
        await poke([draft.accountID])
    }

    func requireDraft(_ id: DraftID) throws -> DraftListItem {
        guard let draft = try store.draft(id) else { throw StoreError.notFound("draft \(id.rawValue)") }
        return draft
    }

    func replySkeleton(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?) async throws -> ReplySkeleton? {
        guard mode != .new, let replyTo else { return nil }
        guard let message = try store.message(account: account, gmailMessageID: replyTo) else {
            throw StoreError.notFound("message \(replyTo.rawValue)")
        }
        var body = try store.body(message.id)
        if body == nil, configuration.role == .app, message.bodyState != .failed, let api = try? client(for: account) {
            do {
                _ = try await BodyFetcher(account: account, store: store, api: api).ensureBody(replyTo, priority: .interactive)
                body = try store.body(message.id)
            } catch {
                log.notice("account \(account.rawValue): quote body fetch failed (\(AccountSyncer.code(error)))")
            }
        }
        return try DraftSkeleton.skeleton(message: message, body: body, store: store, account: account, mode: mode)
    }

    func forwardedAttachments(account: AccountID, mode: ComposeMode, replyTo: GmailMessageID?) throws -> [DraftAttachment] {
        guard mode == .forward, let replyTo,
              let message = try store.message(account: account, gmailMessageID: replyTo) else { return [] }
        return DraftSkeleton.forwardedAttachments(message.attachments, html: try store.body(message.id)?.html)
    }

    private func withThread(_ skeleton: ReplySkeleton, of draft: DraftID) throws -> ReplySkeleton {
        var out = skeleton
        guard skeleton.gmailThreadID != nil else { return out }
        out.gmailThreadID = try store.draft(draft)?.thread?.gmailThreadID.rawValue
        return out
    }

    func debouncer() -> DraftSaveDebouncer {
        if let draftDebouncer { return draftDebouncer }
        let debouncer = DraftSaveDebouncer(store: store, clock: configuration.clock) { [weak self] id, _ in
            Task { await self?.pokeAccount(ofDraft: id) }
        }
        draftDebouncer = debouncer
        return debouncer
    }

    func pokeAccount(ofDraft id: DraftID) async {
        guard let account = (try? store.draft(id))?.accountID else { return }
        await poke([account])
    }

    func cancelRemoteSave(_ id: DraftID) async {
        await draftDebouncer?.cancel(id)
    }

    func saveRemotelyNow(_ id: DraftID, account: AccountID) async throws {
        _ = try store.saveDraftRemotely(id)
        await poke([account])
    }
}

public enum DraftSkeleton {
    public static func content(store: any MailReading, account: AccountID, mode: ComposeMode,
                               replyTo: GmailMessageID?) throws -> DraftContent? {
        guard mode != .new, let replyTo else { return nil }
        guard let message = try store.message(account: account, gmailMessageID: replyTo) else {
            throw StoreError.notFound("message \(replyTo.rawValue)")
        }
        let body = try store.body(message.id)
        let skeleton = try skeleton(message: message, body: body, store: store, account: account, mode: mode)
        let forwarded = mode == .forward ? forwardedAttachments(message.attachments, html: body?.html) : []
        return skeleton.map { ComposeSupport.merge(nil, $0, forwarded: forwarded) }
    }

    // As in the reader's tiles: only an inline part whose Content-ID the HTML shows stays out (an inline PDF is a file)
    public static func forwardedAttachments(_ attachments: [AttachmentItem], html: String?) -> [DraftAttachment] {
        let shown = html?.lowercased() ?? ""
        return attachments.filter { item in
            guard item.isInline, let cid = item.contentID, !cid.isEmpty else { return true }
            return !shown.contains("cid:" + cid.lowercased())
        }.map {
            DraftAttachment(sourceAttachmentID: $0.id, filename: $0.filename, mimeType: $0.mimeType, size: $0.size,
                            isInline: false)
        }
    }

    static func logicalText(_ body: MessageBody) -> String? {
        guard let text = body.text else { return nil }
        switch body.textFormat {
        case .fixed: return text
        case .flowed: return FlowedText.decode(text, delSp: false)
        case .flowedDelSp: return FlowedText.decode(text, delSp: true)
        }
    }

    static func skeleton(message: MessageItem, body: MessageBody?, store: any MailReading, account: AccountID,
                         mode: ComposeMode) throws -> ReplySkeleton? {
        guard mode != .new else { return nil }
        guard let item = try store.accounts().first(where: { $0.id == account }) else {
            throw StoreError.notFound("account \(account.rawValue)")
        }
        let context = ReplyContext(messageID: message.rfc822MessageID, references: message.references,
                                   inReplyTo: message.inReplyTo, subject: message.subject, from: message.from,
                                   to: message.to, cc: message.cc, replyTo: message.replyTo,
                                   date: message.headerDate ?? message.date, htmlBody: body?.html,
                                   textBody: body.flatMap(logicalText), gmailThreadID: "")
        let replyMode: ReplyMode = mode == .forward ? .forward : (mode == .replyAll ? .replyAll : .reply)
        return ReplyComposer.skeleton(for: context, mode: replyMode,
                                      myAddresses: [item.email] + item.sendAs.map(\.email),
                                      locale: .current, timeZone: .current)
    }
}

enum ComposeSupport {
    static let originHeader = "X-OpenHuman-Origin"
    static let quoteMarker = "<div class=\"gmail_quote\" data-oh-quote=\"1\">"

    static func threadingHeaders(_ skeleton: ReplySkeleton?) -> [String: String] {
        var headers: [String: String] = [:]
        if let inReplyTo = skeleton?.inReplyTo { headers["In-Reply-To"] = inReplyTo }
        if let references = skeleton?.references, !references.isEmpty {
            headers["References"] = references.joined(separator: " ")
        }
        return headers
    }

    static func merge(_ initial: DraftContent?, _ skeleton: ReplySkeleton?,
                      forwarded: [DraftAttachment] = []) -> DraftContent {
        let base = initial ?? DraftContent(to: [], cc: [], bcc: [], subject: "", bodyHTML: "", attachments: [])
        guard let skeleton else { return base }
        var out = base
        if out.to.isEmpty { out.to = skeleton.to }
        if out.cc.isEmpty { out.cc = skeleton.cc }
        if out.subject.isEmpty { out.subject = skeleton.subject }
        out.bodyHTML = base.bodyHTML + skeleton.quotedHTML
        out.bodyText = joinedText(base.bodyText, skeleton.quotedText)
        let present = Set(base.attachments.compactMap(\.sourceAttachmentID))
        out.attachments += forwarded.filter { $0.sourceAttachmentID.map { !present.contains($0) } ?? true }
        return out
    }

    static func agentUpdate(_ update: DraftContent, over stored: DraftContent) -> DraftContent {
        var out = update
        if out.to.isEmpty { out.to = stored.to }
        if out.cc.isEmpty { out.cc = stored.cc }
        if out.bcc.isEmpty { out.bcc = stored.bcc }
        if out.subject.isEmpty { out.subject = stored.subject }
        if out.from == nil { out.from = stored.from }
        guard let quote = stored.bodyHTML.range(of: quoteMarker) else { return out }
        out.bodyHTML = update.bodyHTML + stored.bodyHTML[quote.lowerBound...]
        if let attribution = firstQuoteLine(String(stored.bodyHTML[quote.lowerBound...])),
           let text = stored.bodyText, let start = text.range(of: attribution) {
            out.bodyText = joinedText(update.bodyText, String(text[start.lowerBound...]))
        }
        return out
    }

    static func joinedText(_ own: String?, _ quote: String) -> String {
        guard let own, !own.isEmpty else { return "\n\n" + quote }
        return own + "\n\n" + quote
    }

    static func firstQuoteLine(_ quoteHTML: String) -> String? {
        guard let open = quoteHTML.range(of: "<div class=\"gmail_attr\">"),
              let close = quoteHTML.range(of: "</div>", range: open.upperBound..<quoteHTML.endIndex) else { return nil }
        let inner = String(quoteHTML[open.upperBound..<close.lowerBound])
        let first = inner.components(separatedBy: "<br>").first ?? inner
        let text = first.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        return text.isEmpty ? nil : text
    }
}
