import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization

final class RecordingCommands: MailCommanding {
    let store: FakeMailStore
    private let log = Mutex<[String]>([])
    private let scheduleHold = Mutex<Checkpoint?>(nil)
    private let createHold = Mutex<Checkpoint?>(nil)
    private let discardFailure = Mutex<MailPortError?>(nil)
    private let applied = Mutex<[MailCommand]>([])

    init(_ store: FakeMailStore) { self.store = store }

    var calls: [String] { log.withLock { $0 } }
    var commands: [MailCommand] { applied.withLock { $0 } }
    private func record(_ name: String) { log.withLock { $0.append(name) } }

    func holdSchedules(at checkpoint: Checkpoint) { scheduleHold.withLock { $0 = checkpoint } }
    func holdCreates(at checkpoint: Checkpoint) { createHold.withLock { $0 = checkpoint } }
    func failDiscards(with error: MailPortError) { discardFailure.withLock { $0 = error } }

    func apply(_ command: MailCommand) async throws -> UndoToken {
        record("apply")
        applied.withLock { $0.append(command) }
        return try await store.apply(command)
    }
    func undo(_ token: UndoToken) async throws -> UndoToken? { record("undo"); return try await store.undo(token) }
    func createDraft(_ input: DraftInput) async throws -> (key: DraftKey, version: Int) {
        record("createDraft")
        if let hold = createHold.withLock({ $0 }) { await hold.pass() }
        return try await store.createDraft(input)
    }
    func updateDraft(_ key: DraftKey, _ fields: DraftFields, expectedVersion: Int?) async throws -> Int {
        record("updateDraft"); return try await store.updateDraft(key, fields, expectedVersion: expectedVersion)
    }
    func flushDraft(_ key: DraftKey) async throws { record("flushDraft"); try await store.flushDraft(key) }
    func discardDraft(_ key: DraftKey) async throws {
        record("discardDraft")
        if let failure = discardFailure.withLock({ $0 }) { throw failure }
        try await store.discardDraft(key)
    }
    func setReviewState(_ key: DraftKey, _ state: DraftReview) async throws {
        record("setReviewState"); try await store.setReviewState(key, state)
    }
    func resolveDraftConflict(_ key: DraftKey, _ resolution: DraftConflictResolution) async throws {
        record("resolveDraftConflict"); try await store.resolveDraftConflict(key, resolution)
    }
    func send(_ key: DraftKey, undoWindow: Duration) async throws -> SendToken {
        record("send"); return try await store.send(key, undoWindow: undoWindow)
    }
    func cancelSend(_ token: SendToken) async throws -> Bool { record("cancelSend"); return try await store.cancelSend(token) }
    func sendNow(_ token: SendToken) async throws -> Bool { record("sendNow"); return try await store.sendNow(token) }
    func scheduleSend(_ key: DraftKey, at: Date) async throws {
        record("scheduleSend")
        if let hold = scheduleHold.withLock({ $0 }) { await hold.pass() }
        try await store.scheduleSend(key, at: at)
    }
    func scheduleSend(_ key: DraftKey, at: Date, condition: SendLaterCondition) async throws {
        record("scheduleSend:\(condition.rawValue)"); try await store.scheduleSend(key, at: at, condition: condition)
    }
    func cancelScheduledSend(_ key: DraftKey) async throws {
        record("cancelScheduledSend"); try await store.cancelScheduledSend(key)
    }
    func fetchDraftNow(_ account: AccountID, gmailDraftID: GmailDraftID) async throws -> DraftKey? {
        record("fetchDraftNow"); return try await store.fetchDraftNow(account, gmailDraftID: gmailDraftID)
    }
    func fetchThreadNow(_ account: AccountID, gmailThreadID: GmailThreadID) async throws -> ThreadKey? {
        record("fetchThreadNow"); return try await store.fetchThreadNow(account, gmailThreadID: gmailThreadID)
    }
    func createLabel(_ account: AccountID, name: String, applyTo: [ThreadKey]) async throws -> UndoToken {
        record("createLabel"); return try await store.createLabel(account, name: name, applyTo: applyTo)
    }
    func upsertSnippet(_ snippet: SnippetInfo) async throws -> SnippetInfo {
        record("upsertSnippet"); return try await store.upsertSnippet(snippet)
    }
    func deleteSnippet(_ id: SnippetInfo.ID) async throws { record("deleteSnippet"); try await store.deleteSnippet(id) }
    func recordSnippetUse(_ id: SnippetInfo.ID) async throws { record("recordSnippetUse"); try await store.recordSnippetUse(id) }
    func storeSnippetAttachment(_ file: URL, mimeType: String) async throws -> SnippetAttachmentInfo {
        record("storeSnippetAttachment"); return try await store.storeSnippetAttachment(file, mimeType: mimeType)
    }
    func storeSnippetAttachment(data: Data, filename: String, mimeType: String) async throws -> SnippetAttachmentInfo {
        record("storeSnippetAttachment"); return try await store.storeSnippetAttachment(data: data, filename: filename, mimeType: mimeType)
    }
    func unsubscribe(_ key: MessageKey) async throws { record("unsubscribe"); try await store.unsubscribe(key) }
    func upsertSplit(_ split: SplitDefinition) async throws -> SplitKey { record("upsertSplit"); return try await store.upsertSplit(split) }
    func deleteSplit(_ account: AccountID, _ key: SplitKey) async throws { record("deleteSplit"); try await store.deleteSplit(account, key) }
    func reorderSplits(_ account: AccountID, _ order: [SplitKey]) async throws {
        record("reorderSplits"); try await store.reorderSplits(account, order)
    }
    func dismissFailedOperation(_ id: FailedOperationInfo.ID) async throws {
        record("dismissFailedOperation"); try await store.dismissFailedOperation(id)
    }
}
