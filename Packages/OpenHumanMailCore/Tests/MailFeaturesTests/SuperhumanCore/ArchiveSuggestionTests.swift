import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private struct CleanupSource: MailDataSource {
    var inbox: [ThreadRow]
    var promotions: Set<ThreadKey> = []
    var wroteTo: Set<String> = []
    var labelList: [LabelInfo] = []

    func accounts() -> AsyncThrowingStream<[Account], Error> { AsyncThrowingStream { $0.finish() } }
    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> { AsyncThrowingStream { $0.finish() } }
    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> { AsyncThrowingStream { $0.finish() } }

    func labels(_ account: AccountID) -> AsyncThrowingStream<[LabelInfo], Error> {
        let list = labelList
        return AsyncThrowingStream { continuation in
            continuation.yield(list)
            continuation.finish()
        }
    }

    func threadPage(_ location: MailLocation, account: AccountID, after: PageCursor?,
                    limit: Int) async throws -> (rows: [ThreadRow], next: PageCursor?) {
        switch location {
        case .system(.inbox):
            return (inbox, nil)
        case .search(let query) where query.contains("category:promotions"):
            return (inbox.filter { promotions.contains($0.id) }, nil)
        case .search(let query) where query.hasPrefix("in:sent to:"):
            let address = query.replacingOccurrences(of: "in:sent to:", with: "").replacingOccurrences(of: "\"", with: "")
            return (wroteTo.contains(address) ? Array(inbox.prefix(1)) : [], nil)
        default:
            return ([], nil)
        }
    }
}

@MainActor
@Suite struct ArchiveSuggestionTests {
    private static let me = Account(id: AccountID(1), email: "me@work.example", displayName: nil, alias: nil,
                                    health: .active)
    private static let mutedRow: Int64 = 900
    private static let projectsLabel: Int64 = 901

    private func row(_ n: Int64, from sender: String, daysAgo: Double, starred: Bool = false,
                     labels: [Int64] = []) -> ThreadRow {
        let at = fixedNow.addingTimeInterval(-daysAgo * 86_400)
        return ThreadRow(id: ThreadKey(account: Self.me.id, rowID: n, gmailThreadID: GmailThreadID("t\(n)")),
                         subject: "Subject \(n)", snippet: "", participantsDisplay: "Sender",
                         participants: [Participant(name: nil, email: sender, isMe: false, hasUnread: false)],
                         messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                         isStarred: starred, isImportant: false, userLabelIDs: labels, lastMessageAt: at, sortAt: at)
    }

    private var labels: [LabelInfo] {
        [LabelInfo(id: Self.mutedRow, account: Self.me.id, labelID: GmailLabelID("Label_muted"), kind: .user,
                   name: OHGmailLabels.muted, displayName: "Muted", position: 0),
         LabelInfo(id: Self.projectsLabel, account: Self.me.id, labelID: GmailLabelID("Label_projects"), kind: .user,
                   name: "Projects", displayName: "Projects", position: 1)]
    }

    private func source() -> CleanupSource {
        let rows = [
            row(1, from: "deals@shop.example", daysAgo: 30),
            row(2, from: "offers@shop.example", daysAgo: 1),
            row(3, from: "deals@shop.example", daysAgo: 40, starred: true),
            row(4, from: "friend@else.example", daysAgo: 40),
            row(5, from: "news@work.example", daysAgo: 40),
            row(6, from: "promo@shop.example", daysAgo: 40, labels: [Self.projectsLabel]),
            row(7, from: "promo@shop.example", daysAgo: 40, labels: [Self.mutedRow]),
            row(8, from: "person@else.example", daysAgo: 40),
        ]
        return CleanupSource(inbox: rows, promotions: Set(rows.prefix(7).map(\.id)), wroteTo: ["friend@else.example"],
                             labelList: labels)
    }

    @Test func underTheThresholdOnlyOldPromotionsTheRulesAllowAreSuggested() async throws {
        let found = await ArchiveSuggestionModel.find(in: Self.me, data: source(), threshold: 1_000, ageDays: 14,
                                                      overrides: [:], now: fixedNow)
        let suggestion = try #require(found)
        #expect(suggestion.kind == .promotions)
        #expect(suggestion.threads.map(\.rowID) == [1])
        #expect(suggestion.text == "1 promotion is older than 14 days. Archive it?")
    }

    @Test func overTheThresholdOldConversationsAreSuggestedToo() async throws {
        let found = await ArchiveSuggestionModel.find(in: Self.me, data: source(), threshold: 5, ageDays: 14,
                                                      overrides: [:], now: fixedNow)
        let suggestion = try #require(found)
        #expect(suggestion.kind == .oldConversations)
        #expect(suggestion.threads.map(\.rowID) == [1, 8])
        #expect(suggestion.inboxCount == 8 && suggestion.text.contains("8 conversations"))
    }

    @Test func aNeverRuleBeatsEverythingAndAnAlwaysRuleBeatsTheRest() async throws {
        let never = await ArchiveSuggestionModel.find(in: Self.me, data: source(), threshold: 1_000, ageDays: 14,
                                                      overrides: ["@shop.example": .never], now: fixedNow)
        #expect(never == nil, "the only candidate's domain is never included")
        let always = await ArchiveSuggestionModel.find(in: Self.me, data: source(), threshold: 1_000, ageDays: 14,
                                                       overrides: ["friend@else.example": .always], now: fixedNow)
        #expect(always?.threads.map(\.rowID) == [1, 4], "Always beats \"the user wrote to them\"")
    }

    @Test func nothingOldNoQuestion() async {
        var quiet = source()
        quiet.inbox = quiet.inbox.filter { $0.id.rowID == 2 }
        let found = await ArchiveSuggestionModel.find(in: Self.me, data: quiet, threshold: 1_000, ageDays: 14,
                                                      overrides: [:], now: fixedNow)
        #expect(found == nil)
    }

    @Test func atMostOnceADayAndNotNowHidesItForAWeek() {
        let now = fixedNow
        #expect(ArchiveSuggestionSchedule().mayOffer(at: now))
        let shown = ArchiveSuggestionSchedule(lastOfferedAt: now)
        #expect(!shown.mayOffer(at: now.addingTimeInterval(3_600)))
        #expect(shown.mayOffer(at: now.addingTimeInterval(86_400)))
        let notNow = ArchiveSuggestionSchedule(hiddenUntil: now.addingTimeInterval(ArchiveSuggestionSchedule.snoozeInterval))
        #expect(!notNow.mayOffer(at: now.addingTimeInterval(6 * 86_400)))
        #expect(notNow.mayOffer(at: now.addingTimeInterval(8 * 86_400)))
        #expect(notNow.mayOffer(at: now, byUser: true), "the palette can always ask")
    }

    private func suggestion(_ f: OverlayFixture, count: Int) throws -> ArchiveSuggestionModel.Suggestion {
        let keys = Array(f.rows.prefix(count).map(\.id))
        let account = try #require(f.router.active?.id)
        return ArchiveSuggestionModel.Suggestion(account: account, threads: keys, kind: .promotions, ageDays: 14,
                                                 inboxCount: f.rows.count)
    }

    @Test func oneKeyArchivesTheSuggestionAsOneUndoEntry() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 30, now: fixedNow))
        await f.loaded()
        let model = try #require(f.env.archiveSuggestion)
        #expect(f.registry.availability(.archiveSuggested, host: f.router) == .hidden, "only while the banner asks")
        let shown = try suggestion(f, count: 3)
        model.show(shown)
        #expect(f.registry.availability(.archiveSuggested, host: f.router).isEnabled)
        let before = f.rows.count
        let entries = f.env.undo?.stack.count ?? 0
        #expect(await f.run(.archiveSuggested))
        #expect(model.suggestion == nil, "the banner goes")
        await eventually { f.rows.count == before - 3 }
        await eventually { (f.env.undo?.stack.count ?? 0) == entries + 1 }
        await eventuallyAsync { ((try? await f.env.settings?.get(AppSettings.lastBulkArchive)) ?? nil) != nil }
        #expect(await f.run(.undo))
        await eventually { f.rows.count == before }
    }

    @Test func notNowStoresAWeekAndTheAutomaticCheckThenStaysQuiet() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        let model = try #require(f.env.archiveSuggestion)
        model.show(try suggestion(f, count: 1))
        await model.notNow()
        #expect(model.suggestion == nil)
        let state = try await f.env.settings?.get(AppSettings.archiveSuggestionState)
        let hidden = try #require(state?.hiddenUntil)
        #expect(hidden.timeIntervalSinceNow > 6 * 86_400)
        await model.check(byUser: false)
        #expect(model.suggestion == nil)
    }

    @Test func thePaletteCheckSaysSoWhenThereIsNothing() async throws {
        let f = OverlayFixture(corpus: .make(threadCount: 5, now: fixedNow))
        await f.loaded()
        #expect(f.registry.availability(.suggestCleanup, host: f.router).isEnabled)
        #expect(await f.run(.suggestCleanup))
        let model = try #require(f.env.archiveSuggestion)
        if model.suggestion == nil {
            await f.toast("Nothing to clean up")
        }
    }
}
