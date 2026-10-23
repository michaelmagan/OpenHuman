import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct AllInboxesTests {
    private static let work = Account(id: AccountID(1), email: "me@work.example", displayName: nil, alias: "Work",
                                      health: .active)
    private static let home = Account(id: AccountID(2), email: "me@home.example", displayName: nil, alias: nil,
                                      health: .active)

    private func row(_ account: AccountID, _ n: Int64, minutesAgo: Double) -> ThreadRow {
        let at = fixedNow.addingTimeInterval(-minutesAgo * 60)
        return ThreadRow(id: ThreadKey(account: account, rowID: n, gmailThreadID: GmailThreadID("t\(n)")),
                         subject: "Subject \(n)", snippet: "", participantsDisplay: "Sender \(n)", participants: [],
                         messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                         isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: at, sortAt: at)
    }

    @Test func rowsMergeNewestFirstWithTheirAccountsChip() {
        let model = AllInboxesModel(accounts: [Self.work, Self.home], open: { _ in }, done: { _ in true })
        #expect(model.isLoading)
        model.apply([row(Self.work.id, 1, minutesAgo: 5), row(Self.work.id, 2, minutesAgo: 50)], for: Self.work.id)
        #expect(model.isLoading, "one account has not answered")
        model.apply([row(Self.home.id, 7, minutesAgo: 1), row(Self.home.id, 8, minutesAgo: 30)], for: Self.home.id)
        #expect(!model.isLoading)
        #expect(model.rows.map(\.id.rowID) == [7, 1, 8, 2])
        #expect(model.rows.map(\.account) == ["me@home.example", "Work", "me@home.example", "Work"],
                "the alias, else the address")
        #expect(model.cursor?.rowID == 1, "the cursor stays on the row it was on when more rows arrive")
        model.moveCursor(by: -5)
        #expect(model.cursor?.rowID == 7, "no wrap: the first row")
        #expect(model.moveCursor(by: 1) && model.cursor?.rowID == 1)
        model.moveCursor(by: -5)
        #expect(model.cursor?.rowID == 7, "no wrap: the first row")
    }

    @Test func equalTimesKeepTheAccountsOrder() {
        let merged = AllInboxesModel.merge([Self.home.id: [row(Self.home.id, 3, minutesAgo: 10)],
                                            Self.work.id: [row(Self.work.id, 4, minutesAgo: 10)]],
                                           order: [Self.work.id, Self.home.id])
        #expect(merged.map(\.id.account) == [Self.work.id, Self.home.id])
    }

    @Test func doneRoutesByEachConversationsOwnAccount() {
        var calls: [[ThreadKey]] = []
        let model = AllInboxesModel(accounts: [Self.work, Self.home], open: { _ in }, done: { keys in
            calls.append(keys)
            return true
        })
        let keys = [row(Self.work.id, 1, minutesAgo: 1).id, row(Self.home.id, 2, minutesAgo: 1).id,
                    row(Self.work.id, 3, minutesAgo: 1).id]
        #expect(model.markDone(keys))
        #expect(calls.count == 2, "one request (one undo entry) per account")
        #expect(calls.first?.map(\.rowID) == [1, 3] && calls.last?.map(\.rowID) == [2])
        #expect(calls.allSatisfy { group in Set(group.map(\.account)).count == 1 })
    }

    @Test func openClosesThePanelAndHandsTheConversationOn() {
        var opened: ThreadKey?
        let model = AllInboxesModel(accounts: [Self.work, Self.home], open: { opened = $0 }, done: { _ in true })
        model.apply([row(Self.home.id, 9, minutesAgo: 1)], for: Self.home.id)
        model.apply([], for: Self.work.id)
        model.openCursor()
        #expect(opened?.rowID == 9 && opened?.account == Self.home.id)
        #expect(model.isClosed)
    }

    @Test func offeredOnlyWithTwoAccounts() async {
        let one = OverlayFixture(corpus: .make(threadCount: 10, now: fixedNow))
        await one.loaded()
        #expect(one.registry.availability(.goAllInboxes, host: one.router) == .hidden)
        let two = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await two.loaded()
        await eventually { two.router.accounts.count == 2 }
        #expect(two.registry.availability(.goAllInboxes, host: two.router).isEnabled)
    }

    @Test func theLocationListsBothAccountsAndEMarksDoneInTheRightOne() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(await f.run(.goAllInboxes))
        let model = try #require(f.router.unifiedInbox, "All Inboxes is a location of the window")
        #expect(!f.center.isShowing, "not a panel over it")
        await eventually { !model.isLoading }
        let accounts = Set(model.rows.map(\.id.account))
        #expect(accounts.count == 2, "both inboxes")
        let dates = model.rows.map(\.thread.lastMessageAt)
        #expect(dates == dates.sorted(by: >), "newest first")
        let target = try #require(model.cursor)
        let entries = f.env.undo?.stack.count ?? 0
        #expect(model.markDoneAtCursor())
        await eventually { !model.rows.contains { $0.id == target } }
        await eventually { (f.env.undo?.stack.count ?? 0) == entries + 1 }
        let page = try await f.store.threadPage(.system(.inbox), account: target.account, after: nil, limit: 1_000)
        #expect(!page.rows.contains { $0.id == target }, "done in its own account")
    }

    private func named(_ account: AccountID, _ n: Int64, subject: String, from: String, minutesAgo: Double) -> ThreadRow {
        var r = row(account, n, minutesAgo: minutesAgo)
        r = ThreadRow(id: r.id, subject: subject, snippet: "", participantsDisplay: from, participants: [], messageCount: 1,
                      unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false,
                      isImportant: false, userLabelIDs: [], lastMessageAt: r.lastMessageAt, sortAt: r.sortAt)
        return r
    }

    @Test func theTextFiltersTheShownInboxRowsUntilAllAccountsIsOn() {
        let model = AllInboxesModel(accounts: [Self.work, Self.home], open: { _ in }, done: { _ in true })
        model.apply([named(Self.work.id, 1, subject: "Quarterly plan", from: "Dana", minutesAgo: 5),
                     named(Self.work.id, 2, subject: "Lunch", from: "Kim", minutesAgo: 9)], for: Self.work.id)
        model.apply([named(Self.home.id, 3, subject: "Plan the trip", from: "Lee", minutesAgo: 2)], for: Self.home.id)
        #expect(!model.searchAllAccounts, "off by default")
        model.setQuery("plan")
        #expect(model.rows.map(\.id.rowID) == [3, 1])
        model.setQuery("PLAN dana")
        #expect(model.rows.map(\.id.rowID) == [1], "every word must match")
        model.setQuery("work")
        #expect(model.rows.map(\.id.rowID) == [1, 2], "the account chip counts")
        model.setQuery("nothing like it")
        #expect(model.rows.isEmpty && model.emptyText == "No conversations match.")
        model.setQuery("")
        #expect(model.rows.count == 3 && model.emptyText == nil, "clearing brings the inboxes back")
    }

    @Test func allAccountsSearchesAllMailOfEveryAccountAndMergesTheResults() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(await f.run(.goAllInboxes))
        let model = try #require(f.router.unifiedInbox, "All Inboxes is a location of the window")
        #expect(!f.center.isShowing, "not a panel over it")
        await eventually { !model.isLoading }
        let word = try #require(model.rows.first?.thread.subject.split(separator: " ").first.map(String.init))
        model.setSearchAllAccounts(true)
        model.setQuery(word)
        await eventually { !model.isSearching }
        #expect(model.searchAllAccounts && model.searchFailedAccounts.isEmpty)
        var expected: Set<ThreadKey> = []
        for account in f.router.accounts {
            let page = try await f.store.threadPage(.search(word), account: account.id, after: nil,
                                                    limit: AllInboxesModel.searchLimit)
            expected.formUnion(page.rows.map(\.id))
        }
        #expect(Set(model.rows.map(\.id)) == expected)
        let dates = model.rows.map(\.thread.lastMessageAt)
        #expect(dates == dates.sorted(by: >), "newest first")
        model.setSearchAllAccounts(false)
        #expect(!model.isSearching)
        model.setQuery("")
        #expect(!model.rows.isEmpty)
    }

    @Test func aLaterQueryWinsOverAnEarlierSlowOne() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(await f.run(.goAllInboxes))
        let model = try #require(f.router.unifiedInbox, "All Inboxes is a location of the window")
        #expect(!f.center.isShowing, "not a panel over it")
        await eventually { !model.isLoading }
        model.setSearchAllAccounts(true)
        model.setQuery("zzzz-nothing-matches-this")
        model.setQuery("")
        await eventually { !model.isSearching }
        #expect(!model.isSearchActive && model.rows.count > 0, "the cleared field shows the inboxes, not stale results")
    }

    @Test func goToAllInboxesShowsTheLocationAndAnythingElseLeavesIt() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.unifiedInbox == nil)
        #expect(f.router.goToAllInboxes())
        #expect(f.router.isAllInboxesShown && f.router.windowTitle.hasPrefix("All Inboxes"))
        let model = try #require(f.router.unifiedInbox)
        #expect(f.router.goToAllInboxes() && f.router.unifiedInbox === model, "asking again keeps the same list")
        f.router.go(to: .system(.sent))
        #expect(f.router.unifiedInbox == nil && model.isClosed, "a location leaves it")
        #expect(f.router.goToAllInboxes())
        let other = try #require(f.router.accounts.first { $0.id != f.router.activeAccountID })
        f.router.switchAccount(to: other.id)
        #expect(f.router.unifiedInbox == nil && f.router.activeAccountID == other.id, "an account leaves it")
        #expect(f.router.goToAllInboxes())
        f.router.switchAccount(to: other.id)
        #expect(f.router.unifiedInbox == nil, "even the active account's own entry leaves it")
    }

    @Test func oneAccountHasNoAllInboxesLocation() async {
        let f = OverlayFixture(corpus: .make(threadCount: 10, now: fixedNow))
        await f.loaded()
        #expect(!f.router.goToAllInboxes())
        #expect(f.router.unifiedInbox == nil)
    }

    @Test func openingARowShowsItInItsOwnAccountAndLeavesTheLocation() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.goToAllInboxes())
        let model = try #require(f.router.unifiedInbox)
        await eventually { !model.isLoading && Set(model.rows.map(\.id.account)).count == 2 }
        let target = try #require(model.rows.first { $0.id.account != f.router.activeAccountID })
        model.setCursor(target.id)
        model.openCursor()
        #expect(f.router.unifiedInbox == nil)
        #expect(f.router.activeAccountID == target.id.account)
        await eventually { f.router.active?.reader?.thread == target.id }
    }

    @Test func lAsksForTheLabelPickerOfTheRowsOwnAccount() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.goToAllInboxes())
        let model = try #require(f.router.unifiedInbox)
        await eventually { !model.isLoading && Set(model.rows.map(\.id.account)).count == 2 }
        let target = try #require(model.rows.first { $0.id.account != f.router.activeAccountID })
        model.setCursor(target.id)
        #expect(model.labelAtCursor())
        guard case .label(let picker) = f.center.overlay else { throw TestFailure("no label picker") }
        #expect(picker.targets == [target.id], "only that conversation")
        #expect(picker.account == target.id.account, "that account's labels and Gmail account")
        #expect(f.router.unifiedInbox === model, "the list stays under the picker")
    }

    @Test func theCountsAreTheAccountsUnreadNumbers() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.goToAllInboxes())
        let model = try #require(f.router.unifiedInbox)
        await eventually { !model.isLoading && !model.rows.isEmpty }
        #expect(model.unreadCount == model.rows.filter(\.thread.isUnread).count)
        let perAccount = model.unreadByAccount.map(\.count).reduce(0, +)
        #expect(perAccount == model.unreadCount, "the chips add up to the total")
    }

    @Test func eInAllAccountsSearchMovesToTheNextResult() {
        let model = AllInboxesModel(accounts: [Self.work, Self.home], open: { _ in }, done: { _ in true })
        model.setSearchAllAccounts(true)
        model.setQuery("plan")
        model.finishSearch([Self.work.id: [row(Self.work.id, 1, minutesAgo: 1), row(Self.work.id, 2, minutesAgo: 3)],
                            Self.home.id: [row(Self.home.id, 3, minutesAgo: 2), row(Self.home.id, 4, minutesAgo: 4)]],
                           failed: [], generation: model.searchGeneration)
        #expect(model.rows.map(\.id.rowID) == [1, 3, 2, 4])
        #expect(model.cursor?.rowID == 1)
        #expect(model.markDoneAtCursor())
        #expect(model.rows.map(\.id.rowID) == [3, 2, 4] && model.cursor?.rowID == 3, "the next result, not the one after")
        model.setCursor(model.rows[2].id)
        #expect(model.markDoneAtCursor())
        #expect(model.cursor?.rowID == 2, "after the last one, the one above it")
    }

    @Test func eInTheInboxMovesToTheNextRowBeforeTheListCatchesUp() {
        let model = AllInboxesModel(accounts: [Self.work, Self.home], open: { _ in }, done: { _ in true })
        model.apply([row(Self.work.id, 1, minutesAgo: 1), row(Self.work.id, 2, minutesAgo: 3)], for: Self.work.id)
        model.apply([row(Self.home.id, 3, minutesAgo: 2)], for: Self.home.id)
        #expect(model.markDoneAtCursor())
        #expect(model.cursor?.rowID == 3, "the done row is still listed until its inbox changes")
        model.apply([row(Self.work.id, 2, minutesAgo: 3)], for: Self.work.id)
        #expect(model.cursor?.rowID == 3)
    }

    @Test func anAccountThatFailsAfterItsRowsCountsOnceWhileTheOthersLoad() {
        let third = Account(id: AccountID(3), email: "me@club.example", displayName: nil, alias: nil, health: .active)
        let model = AllInboxesModel(accounts: [Self.work, Self.home, third], open: { _ in }, done: { _ in true })
        model.apply([row(Self.work.id, 1, minutesAgo: 1)], for: Self.work.id)
        model.failed(Self.work.id)
        model.apply([], for: Self.home.id)
        #expect(model.isLoading, "the third account has not answered")
        model.apply([], for: third.id)
        #expect(!model.isLoading)
    }

    @Test func anOpenAllInboxesFollowsAddedRemovedAndRenamedAccounts() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.goToAllInboxes())
        let first = try #require(f.router.unifiedInbox)
        first.setQuery("plan")
        let list = f.router.accounts.map(\.account)
        #expect(first.reads(list))
        f.router.apply(list)
        #expect(f.router.unifiedInbox === first, "the same accounts keep the list")

        let renamed = list.map {
            Account(id: $0.id, email: $0.email, displayName: $0.displayName, alias: $0.id == list[0].id ? "Renamed" : $0.alias,
                    health: $0.health, sendAs: $0.sendAs)
        }
        f.router.apply(renamed)
        let second = try #require(f.router.unifiedInbox)
        #expect(second !== first && first.isClosed, "a renamed account starts the list again")
        #expect(second.query == "plan", "with the same text")
        #expect(second.reads(renamed))
        second.setQuery("")
        await eventually { !second.isLoading && second.rows.contains { $0.id.account == list[0].id } }
        #expect(second.rows.filter { $0.id.account == list[0].id }.allSatisfy { $0.account == "Renamed" })

        f.router.apply([renamed[0]])
        #expect(f.router.unifiedInbox == nil && second.isClosed, "one account left: no All Inboxes")
    }

    @Test func aRowOfARemovedAccountDoesNotOpenInAnother() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.goToAllInboxes())
        let model = try #require(f.router.unifiedInbox)
        await eventually { !model.isLoading && Set(model.rows.map(\.id.account)).count == 2 }
        let target = try #require(model.rows.first { $0.id.account != f.router.activeAccountID })
        let active = f.router.activeAccountID
        let list = f.router.accounts.map(\.account)
        let third = Account(id: AccountID(99), email: "me@club.example", displayName: nil, alias: nil, health: .active)
        f.router.apply(list.filter { $0.id != target.id.account } + [third])
        #expect(f.router.unifiedInbox !== model && model.isClosed, "the list starts again without the removed account")
        model.setCursor(target.id)
        model.openCursor()
        #expect(f.router.activeAccountID == active)
        #expect(f.router.active?.reader?.thread != target.id, "nothing opens in the active account")
    }

    @Test func searchInAllInboxesFocusesItsFieldAndLeavesTheAccountsSearchClosed() async throws {
        let f = OverlayFixture(corpus: .rich(threadCount: 20, now: fixedNow))
        await f.loaded()
        await eventually { f.router.accounts.count == 2 }
        #expect(f.router.goToAllInboxes())
        let model = try #require(f.router.unifiedInbox)
        #expect(await f.run(.search))
        #expect(!f.center.search.isOpen, "the account's search would open out of sight")
        #expect(model.searchFocusRequest == 1, "the field above the list takes the keys")
        f.router.leaveAllInboxes()
        #expect(await f.run(.search))
        #expect(f.center.search.isOpen, "elsewhere / opens the search as before")
    }

    @Test func gUIsBoundBesideControlZeroWithoutCollisions() {
        let descriptor = ActionCatalog.descriptor(.goAllInboxes)
        #expect(descriptor?.defaultBindings.contains(.sequence("g", "u")) == true)
        #expect(descriptor?.shortcutHint == "⌃0", "the hint stays the first binding")
        #expect(descriptor?.scopes == [.global], "`G U` works from the list, a conversation and All Inboxes itself")
    }
}
