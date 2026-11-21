import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanStore

extension AccountSyncer {
    // Why: a failed fetch must never mark a draft discarded; a 404 means deleted meanwhile and is left out, other errors throw
    @discardableResult
    public func refreshDrafts() async throws -> Int {
        let started = clock.now
        let generation = try store.syncStatus(account: account).generation
        let uploadedBefore = try uploadedDraftIDs()
        var listed: [GmailDraft] = []
        var token: String?
        var calls = 0, units = 0
        repeat {
            let page = try await api.listDrafts(pageToken: token, q: nil, maxResults: 500)
            calls += 1
            units += QuotaCost.units(.listDrafts)
            listed += page.drafts ?? []
            token = page.nextPageToken
        } while token != nil

        var drafts: [RemoteDraftUpsert] = []
        var cache: [String: RemoteDraftUpsert] = [:]
        var messages: [MessageUpsert] = []
        var complete = true
        let horizon = clock.now.addingTimeInterval(-settings.bodyHorizon.timeInterval)
        for stub in listed {
            guard let messageID = stub.message?.id else { complete = false; continue }
            if let known = draftCache[stub.id], known.gmailMessageID.rawValue == messageID {
                drafts.append(known)
                cache[stub.id] = known
                continue
            }
            let full: GmailDraft
            do {
                full = try await api.getDraft(id: stub.id, format: .full)
                calls += 1
                units += QuotaCost.units(.getDraft)
            } catch GmailError.notFound {
                calls += 1
                units += QuotaCost.units(.getDraft)
                continue
            }
            do {
                let upsert = try GmailMapper.remoteDraft(full)
                drafts.append(upsert)
                cache[stub.id] = upsert
                if let message = full.message {
                    let inHorizon = (message.internalDateValue ?? .distantPast) >= horizon
                    messages.append(try GmailMapper.messageUpsert(message, includeBody: inHorizon))
                }
            } catch {
                complete = false
                log.notice("account \(account.rawValue): draft \(stub.id) skipped (\(Self.code(error)))")
            }
        }
        if !messages.isEmpty {
            let result = try store.upsertMessages(messages, account: account, generation: generation)
            if !result.unknownLabelIDs.isEmpty { try await refreshLabels() }
        }
        // Why: a draft first uploaded after the listing was read is missing from it, not deleted; the next refresh decides
        if complete, !(try uploadedDraftIDs()).subtracting(uploadedBefore).isSubset(of: Set(listed.map(\.id))) {
            complete = false
        }
        try store.reconcileRemoteDrafts(drafts, account: account, complete: complete)
        draftCache = cache
        let finished = clock.now
        try store.updateSyncState(account: account) { $0.draftsRefreshedAt = finished }
        appendLog("drafts", started, finished, outcome: "ok",
                  units: units, requests: calls,
                  Counts(added: 0, changed: drafts.count, deleted: 0), errorCode: nil)
        log.info("account \(account.rawValue): drafts refreshed (\(listed.count) listed, \(complete ? "complete" : "partial"))")
        return drafts.count
    }

    private func uploadedDraftIDs() throws -> Set<String> {
        Set(try store.drafts(account: account, states: [.editing, .scheduled, .failed], limit: Int.max / 2)
            .compactMap(\.gmailDraftID?.rawValue))
    }
}
