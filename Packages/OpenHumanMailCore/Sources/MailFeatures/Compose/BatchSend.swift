import Foundation
import MailModel
import MailRender
import Observation
import OpenHumanCore

/// Why a checked draft stays in Drafts instead of going out with the others.
public enum BatchSendSkipReason: Sendable, Hashable {
    case noDraft
    case scheduled(Date)
    case alreadySending
    case needsReview
    case changedElsewhere
    case openInComposer
    case noRecipients
    case invalidAddress(String)
    case attachmentNotReady(String)
    case tooLarge
    case unfilledPlaceholders([String])
    case empty
    case noText
    case missingAttachment
}

public struct BatchSendPlan: Sendable, Equatable {
    public struct Item: Identifiable, Sendable, Equatable {
        public let draft: DraftSummary
        public let thread: ThreadKey?
        public let noSubject: Bool
        public var id: DraftKey { draft.id }
    }

    public struct Skipped: Identifiable, Sendable, Equatable {
        public let thread: ThreadKey?
        public let draft: DraftSummary?
        public let reason: BatchSendSkipReason
        public var id: String { draft.map { "d\($0.id.rawValue)" } ?? "t\(thread?.rowID ?? 0)" }
    }

    public var ready: [Item]
    public var skipped: [Skipped]

    public init(ready: [Item] = [], skipped: [Skipped] = []) {
        self.ready = ready
        self.skipped = skipped
    }

    /// One draft per checked row, in the list's order: the row's newest draft that isn't scheduled, preferring one
    /// that doesn't wait for review. A row whose drafts are all scheduled keeps its schedule.
    public static func make(rows: [ThreadKey], drafts: [DraftSummary], openInComposer: Set<DraftKey> = []) -> BatchSendPlan {
        var plan = BatchSendPlan()
        var seen = Set<DraftKey>()
        for row in rows {
            let candidates = drafts.filter { $0.thread == row }
            let unscheduled = candidates.filter { $0.status != .scheduled }.sorted { $0.updatedAt > $1.updatedAt }
            guard let draft = unscheduled.first(where: { $0.review != .pending }) ?? unscheduled.first else {
                let soonest = candidates.filter { $0.status == .scheduled && $0.sendAt != nil }
                    .min { ($0.sendAt ?? .distantFuture) < ($1.sendAt ?? .distantFuture) }
                plan.skipped.append(Skipped(thread: row, draft: soonest,
                                            reason: soonest?.sendAt.map(BatchSendSkipReason.scheduled) ?? .noDraft))
                continue
            }
            guard seen.insert(draft.id).inserted else { continue }
            if let reason = skipReason(draft, openInComposer: openInComposer) {
                plan.skipped.append(Skipped(thread: row, draft: draft, reason: reason))
            } else {
                plan.ready.append(Item(draft: draft, thread: row, noSubject: PreSendCheck.isBlank(draft.fields.subject)))
            }
        }
        return plan
    }

    public static func skipReason(_ draft: DraftSummary, openInComposer: Set<DraftKey> = []) -> BatchSendSkipReason? {
        switch draft.status {
        case .scheduled: return draft.sendAt.map(BatchSendSkipReason.scheduled) ?? .noDraft
        case .sending: return .alreadySending
        case .sent, .discarded: return .noDraft
        case .editing, .failed: break
        }
        if !draft.canBeScheduled { return .needsReview }
        if draft.hasRemoteConflict { return .changedElsewhere }
        if openInComposer.contains(draft.id) { return .openInComposer }
        let fields = draft.fields
        let recipients = fields.to + fields.cc + fields.bcc
        if recipients.isEmpty { return .noRecipients }
        if let invalid = recipients.first(where: { !RecipientParser.isValid($0.email) }) {
            return .invalidAddress(invalid.email)
        }
        if let unready = fields.attachments.first(where: { $0.localPath == nil && $0.sourceAttachmentID == nil }) {
            return .attachmentNotReady(unready.filename)
        }
        if fields.attachments.reduce(0, { $0 + $1.size }) > AttachmentLimits.maxTotalBytes { return .tooLarge }
        let text = plainText(fields)
        let unfilled = SnippetExpander.unfilledPlaceholders(in: fields.subject + "\n" + text)
        if !unfilled.isEmpty { return .unfilledPlaceholders(unfilled) }
        let issues = Set(PreSendCheck.issues(subject: fields.subject, body: text, quote: "", forwards: draft.mode == .forward,
                                             hasAttachments: !fields.attachments.isEmpty))
        if issues.contains(.noBody) { return issues.contains(.noSubject) ? .empty : .noText }
        if issues.contains(.missingAttachment) { return .missingAttachment }
        return nil
    }

    static func plainText(_ fields: DraftFields) -> String {
        if let text = fields.bodyText, !PreSendCheck.isBlank(text) { return text }
        return fields.bodyHTML.isEmpty ? "" : PlainTextExtractor.text(fromHTML: fields.bodyHTML)
    }

    public var accounts: [AccountID] {
        var seen = Set<AccountID>()
        return ready.map(\.draft.account).filter { seen.insert($0).inserted }
    }

    public var recipients: [EmailAddress] {
        var seen = Set<String>()
        return ready.flatMap { $0.draft.fields.to + $0.draft.fields.cc + $0.draft.fields.bcc }
            .filter { seen.insert($0.email.lowercased()).inserted }
    }

    public var noSubjectCount: Int { ready.count { $0.noSubject } }
}

/// The confirmation shown before checked drafts go out: how many, to whom, which stay behind and why, and whether
/// this batch gets the "remind me if no reply" reminders. The reminder choice is for this batch only.
@MainActor @Observable
public final class BatchSendModel {
    public struct Line: Identifiable, Equatable, Sendable {
        public let id: String
        public let subject: String
        public let detail: String
        public let isWarning: Bool
    }

    public let plan: BatchSendPlan
    public var remindersOn: Bool
    public let reminderDays: Int
    public private(set) var isClosed = false
    public private(set) var sending: Task<Void, Never>?

    @ObservationIgnored private let accountNames: [AccountID: String]
    @ObservationIgnored private let formatDate: @MainActor (Date) -> String
    @ObservationIgnored private let onConfirm: @MainActor (BatchSendPlan, Bool) -> Task<Void, Never>?

    public init(plan: BatchSendPlan, remindersOn: Bool, reminderDays: Int, accountNames: [AccountID: String] = [:],
                formatDate: @escaping @MainActor (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) },
                confirm: @escaping @MainActor (BatchSendPlan, Bool) -> Task<Void, Never>?) {
        self.plan = plan
        self.remindersOn = remindersOn
        self.reminderDays = reminderDays
        self.accountNames = accountNames
        self.formatDate = formatDate
        self.onConfirm = confirm
    }

    public var count: Int { plan.ready.count }

    public var canConfirm: Bool { !isClosed && count > 0 }

    public var title: String {
        switch count {
        case 0: String(localized: "None of these drafts can be sent")
        case 1: String(localized: "Send 1 draft?")
        default: String(localized: "Send \(count) drafts?")
        }
    }

    public var confirmTitle: String {
        count == 1 ? String(localized: "Send 1 Draft") : String(localized: "Send \(count) Drafts")
    }

    public var summary: String {
        guard count > 0 else { return String(localized: "They stay in Drafts. Open one to fix it.") }
        let who = ComposeManager.recipientSummary(plan.recipients)
        let accounts = plan.accounts
        guard accounts.count > 1 else { return String(localized: "To \(who).") }
        return String(localized: "To \(who), from \(accounts.count) accounts.")
    }

    public var undoNote: String {
        String(localized: "You can undo the whole batch for a few seconds after sending.")
    }

    public var reminderTitle: String { String(localized: "Remind me if no reply") }

    public var reminderDetail: String {
        let note = String(localized: "For these drafts only. Your reminder setting stays as it is.")
        guard remindersOn else { return note }
        let after = reminderDays == 1 ? String(localized: "after 1 day") : String(localized: "after \(reminderDays) days")
        return String(localized: "Conversations come back \(after) if no one replies. \(note)")
    }

    public var lines: [Line] {
        let accounts = plan.accounts.count > 1
        return plan.ready.map { item in
            let fields = item.draft.fields
            var detail = ComposeManager.recipientSummary(fields.to + fields.cc + fields.bcc)
            if accounts, let name = accountNames[item.draft.account] { detail += " · " + name }
            if item.noSubject { detail += " · " + String(localized: "No subject") }
            return Line(id: "d\(item.draft.id.rawValue)", subject: Self.subject(item.draft), detail: detail,
                        isWarning: item.noSubject)
        }
    }

    public var skippedTitle: String? {
        switch plan.skipped.count {
        case 0: nil
        case 1: String(localized: "1 stays in Drafts")
        default: String(localized: "\(plan.skipped.count) stay in Drafts")
        }
    }

    public var skippedLines: [Line] {
        plan.skipped.map { skipped in
            Line(id: skipped.id, subject: skipped.draft.map(Self.subject) ?? String(localized: "(no draft)"),
                 detail: text(for: skipped.reason), isWarning: true)
        }
    }

    public func text(for reason: BatchSendSkipReason) -> String {
        switch reason {
        case .noDraft: String(localized: "No draft here any more")
        case .scheduled(let date): String(localized: "Scheduled for \(formatDate(date)): keeps its schedule")
        case .alreadySending: String(localized: "Already sending")
        case .needsReview: String(localized: "An agent wrote it: review it first")
        case .changedElsewhere: String(localized: "Changed on another device: open it to pick a version")
        case .openInComposer: String(localized: "Open in a composer: send it from there")
        case .noRecipients: String(localized: "No recipients")
        case .invalidAddress(let address): String(localized: "“\(address)” is not a valid address")
        case .attachmentNotReady(let name): String(localized: "“\(name)” hasn't finished attaching")
        case .tooLarge: String(localized: "Attachments are too large to send")
        case .unfilledPlaceholders(let names): Self.unfilledText(names)
        case .empty: String(localized: "Empty")
        case .noText: String(localized: "Nothing written in the body")
        case .missingAttachment: String(localized: "Mentions an attachment, but nothing is attached")
        }
    }

    static func unfilledText(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }.joined(separator: ", ")
        return String(localized: "\(quoted) still needs filling in")
    }

    static func subject(_ draft: DraftSummary) -> String {
        let subject = draft.fields.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return subject.isEmpty ? String(localized: "(no subject)") : subject
    }

    public func toggleReminders() {
        guard !isClosed else { return }
        remindersOn.toggle()
    }

    @discardableResult
    public func confirm() -> Task<Void, Never>? {
        guard canConfirm else { return nil }
        isClosed = true
        sending = onConfirm(plan, remindersOn)
        return sending
    }

    public func close() { isClosed = true }
}
