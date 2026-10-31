import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct BatchSendPlanTests {
    static let work = AccountID(1)
    static let home = AccountID(2)

    func row(_ n: Int64, account: AccountID = work) -> ThreadKey {
        ThreadKey(account: account, rowID: n, gmailThreadID: GmailThreadID("t\(n)"))
    }

    func key(_ n: Int64) -> DraftKey { DraftKey("d\(n)") }

    func draft(_ n: Int64, in thread: ThreadKey?, to: [String] = ["ana@example.org"], subject: String = "Plans",
               body: String = "See you on Friday.", status: DraftStatus = .editing, sendAt: Date? = nil,
               source: DraftSource = .user, review: DraftReview = .none, conflict: Bool = false,
               attachments: [DraftAttachmentInfo] = [], mode: DraftMode = .reply,
               updated: TimeInterval = 0) -> DraftSummary {
        DraftSummary(id: key(n), account: thread?.account ?? Self.work, thread: thread, mode: mode,
                     fields: DraftFields(to: to.map { EmailAddress(name: nil, email: $0) }, subject: subject,
                                         bodyHTML: "<p>\(body)</p>", bodyText: body, attachments: attachments),
                     source: source, review: review, status: status, sendAt: sendAt, hasRemoteConflict: conflict,
                     updatedAt: fixedNow.addingTimeInterval(updated))
    }

    @Test func validDraftsAreReadyInTheListsOrder() {
        let rows = [row(3), row(1), row(2)]
        let drafts = [draft(1, in: row(1)), draft(2, in: row(2)), draft(3, in: row(3))]
        let plan = BatchSendPlan.make(rows: rows, drafts: drafts)
        #expect(plan.ready.map(\.id) == [key(3), key(1), key(2)])
        #expect(plan.skipped.isEmpty)
    }

    @Test func eachProblemIsSkippedWithItsReason() {
        let future = fixedNow.addingTimeInterval(3_600)
        let big = DraftAttachmentInfo(localPath: "/tmp/big.bin", filename: "big.bin", mimeType: "application/octet-stream",
                                      size: AttachmentLimits.maxTotalBytes + 1)
        let unready = DraftAttachmentInfo(filename: "notes.pdf", mimeType: "application/pdf", size: 10)
        let cases: [(DraftSummary, BatchSendSkipReason)] = [
            (draft(1, in: row(1), to: []), .noRecipients),
            (draft(2, in: row(2), to: ["not-an-address"]), .invalidAddress("not-an-address")),
            (draft(3, in: row(3), subject: "", body: ""), .empty),
            (draft(4, in: row(4), body: ""), .noText),
            (draft(5, in: row(5), body: "The plan is attached."), .missingAttachment),
            (draft(6, in: row(6), attachments: [unready]), .attachmentNotReady("notes.pdf")),
            (draft(7, in: row(7), attachments: [big]), .tooLarge),
            (draft(8, in: row(8), body: "Hi {{first_name}},"), .unfilledPlaceholders(["first_name"])),
            (draft(9, in: row(9), status: .scheduled, sendAt: future), .scheduled(future)),
            (draft(10, in: row(10), source: .agent, review: .pending), .needsReview),
            (draft(11, in: row(11), conflict: true), .changedElsewhere),
            (draft(12, in: row(12)), .openInComposer),
        ]
        let plan = BatchSendPlan.make(rows: cases.compactMap(\.0.thread) + [row(13)], drafts: cases.map(\.0),
                                      openInComposer: [key(12)])
        #expect(plan.ready.isEmpty)
        #expect(plan.skipped.map(\.reason) == cases.map(\.1) + [.noDraft])
        #expect(plan.skipped.last?.thread == row(13) && plan.skipped.last?.draft == nil)
    }

    @Test func aMissingSubjectIsSentButCalledOut() throws {
        let plan = BatchSendPlan.make(rows: [row(1)], drafts: [draft(1, in: row(1), subject: "  ")])
        let item = try #require(plan.ready.first)
        #expect(item.noSubject && plan.noSubjectCount == 1)
        let model = BatchSendModel(plan: plan, remindersOn: false, reminderDays: 3) { _, _ in nil }
        #expect(model.lines.first?.subject == "(no subject)" && model.lines.first?.detail.hasSuffix("No subject") == true)
    }

    @Test func aRowWithAScheduledAndAnOpenDraftSendsTheOpenOneAndKeepsTheSchedule() {
        let future = fixedNow.addingTimeInterval(7_200)
        let scheduled = draft(1, in: row(1), status: .scheduled, sendAt: future, updated: 10)
        let editing = draft(2, in: row(1), updated: 0)
        let plan = BatchSendPlan.make(rows: [row(1)], drafts: [scheduled, editing])
        #expect(plan.ready.map(\.id) == [key(2)] && plan.skipped.isEmpty)
        let onlyScheduled = BatchSendPlan.make(rows: [row(1)], drafts: [scheduled])
        #expect(onlyScheduled.ready.isEmpty && onlyScheduled.skipped.map(\.reason) == [.scheduled(future)])
    }

    @Test func aFailedDraftCanBeSentAgainButOneAlreadySendingCannot() {
        #expect(BatchSendPlan.skipReason(draft(1, in: row(1), status: .failed)) == nil)
        #expect(BatchSendPlan.skipReason(draft(1, in: row(1), status: .sending)) == .alreadySending)
        #expect(BatchSendPlan.skipReason(draft(1, in: row(1), source: .agent, review: .approved)) == nil)
    }

    @Test func recipientsAndAccountsAreCountedOnce() {
        let drafts = [draft(1, in: row(1), to: ["ana@example.org", "ben@example.org"]),
                      draft(2, in: row(2, account: Self.home), to: ["ANA@example.org"]),
                      draft(3, in: row(3), to: ["cy@example.org"])]
        let plan = BatchSendPlan.make(rows: [row(1), row(2, account: Self.home), row(3)], drafts: drafts)
        #expect(plan.recipients.map { $0.email.lowercased() } == ["ana@example.org", "ben@example.org", "cy@example.org"])
        #expect(plan.accounts == [Self.work, Self.home])
        #expect(ComposeManager.byAccount(drafts).map(\.id) == [key(1), key(3), key(2)])
    }

    @Test func theConfirmationStatesTheCountRecipientsAndWhatStays() {
        let drafts = [draft(1, in: row(1), to: ["ana@example.org"]), draft(2, in: row(2), to: ["ben@example.org"]),
                      draft(3, in: row(3), to: [])]
        let plan = BatchSendPlan.make(rows: [row(1), row(2), row(3)], drafts: drafts)
        let model = BatchSendModel(plan: plan, remindersOn: true, reminderDays: 3) { _, _ in nil }
        #expect(model.title == "Send 2 drafts?" && model.confirmTitle == "Send 2 Drafts")
        #expect(model.summary == "To ana@example.org and ben@example.org.")
        #expect(model.skippedTitle == "1 stays in Drafts")
        #expect(model.skippedLines.map(\.detail) == ["No recipients"])
        #expect(model.reminderDetail.hasPrefix("Conversations come back after 3 days if no one replies."))
        model.toggleReminders()
        #expect(!model.remindersOn && model.reminderDetail == "For these drafts only. Your reminder setting stays as it is.")
    }

    @Test func twoAccountsAreNamedInTheSummaryAndEachLine() {
        let drafts = [draft(1, in: row(1)), draft(2, in: row(2, account: Self.home))]
        let plan = BatchSendPlan.make(rows: [row(1), row(2, account: Self.home)], drafts: drafts)
        let model = BatchSendModel(plan: plan, remindersOn: false, reminderDays: 3,
                                   accountNames: [Self.work: "Work", Self.home: "Personal"]) { _, _ in nil }
        #expect(model.summary == "To ana@example.org, from 2 accounts.")
        #expect(model.lines.map(\.detail) == ["ana@example.org · Work", "ana@example.org · Personal"])
    }

    @Test func confirmingHandsOverThePlanAndTheReminderChoiceOnce() async {
        let plan = BatchSendPlan.make(rows: [row(1)], drafts: [draft(1, in: row(1))])
        @MainActor final class Handed { var calls: [(BatchSendPlan, Bool)] = [] }
        let handed = Handed()
        let model = BatchSendModel(plan: plan, remindersOn: true, reminderDays: 3) { plan, reminders in
            handed.calls.append((plan, reminders))
            return Task {}
        }
        model.toggleReminders()
        let task = model.confirm()
        await task?.value
        #expect(task != nil && model.isClosed && model.sending != nil)
        #expect(handed.calls.count == 1 && handed.calls.first?.0 == plan && handed.calls.first?.1 == false)
        #expect(model.confirm() == nil, "a second ↵ does nothing")
        model.toggleReminders()
        #expect(!model.remindersOn, "closed: the switch no longer changes")
    }

    @Test func nothingToSendCannotBeConfirmed() {
        let plan = BatchSendPlan.make(rows: [row(1)], drafts: [draft(1, in: row(1), to: [])])
        let model = BatchSendModel(plan: plan, remindersOn: false, reminderDays: 3) { _, _ in Task {} }
        #expect(!model.canConfirm && model.confirm() == nil)
        #expect(model.title == "None of these drafts can be sent")
    }
}
