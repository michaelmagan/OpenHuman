#if os(macOS)
import Foundation
import MailActions
import MailFakes
import MailFeatures
import MailModel
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

@MainActor
@Suite struct ShellTitlesTests {
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func aMailboxSubtitleNamesTheAccountAndItsSize() {
        #expect(ShellTitles.listParts(account: "Work", location: .system(.inbox), total: 1_204) == ["Work", 1_204.formatted()])
        #expect(ShellTitles.listParts(account: "Work", location: .system(.inbox), total: 0) == ["Work"])
        #expect(ShellTitles.listParts(account: "Work", location: .system(.inbox), total: nil) == ["Work"])
        #expect(ShellTitles.listParts(account: "Work", location: .system(.allMail), total: 5_000) == ["Work"],
                "All mail and Done show no size, as their titles never did")
        #expect(ShellTitles.listParts(account: "Work", location: .system(.done), total: 5_000) == ["Work"])
    }

    @Test func searchResultsAreCountedInTheSubtitle() {
        #expect(ShellTitles.results(1) == "1 result")
        #expect(ShellTitles.results(107) == "107 results")
        #expect(ShellTitles.results(4_598) == "\(4_598.formatted()) results")
    }

    @Test func theTitleIsThePlaceAndTheSubtitleWhoseItIs() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: Self.now))
        let router = environment.router
        router.start()
        defer { router.stop() }
        await awaitObserved("the list loads") { router.list?.state == .loaded }
        let state = try #require(router.active)
        let location = try #require(state.location)
        #expect(ShellTitles.title(router) == state.title(for: location))
        let subtitle = ShellTitles.subtitle(router)
        #expect(subtitle.hasPrefix(ShellTitles.accountName(state.account)), "\(subtitle)")
        #expect(subtitle.hasSuffix(ShellTitles.fakeDataNote) == environment.isFake, "\(subtitle)")

        router.go(to: .system(.allMail))
        await awaitObserved("All mail loads") { router.list?.location == .system(.allMail) && router.list?.state == .loaded }
        #expect(ShellTitles.title(router) == state.title(for: .system(.allMail)))
        #expect(ShellTitles.placeParts(router) == [ShellTitles.accountName(state.account)])
    }

    @Test func theReaderSubtitleNamesTheConversation() async throws {
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: Self.now))
        let router = environment.router
        router.start()
        defer { router.stop() }
        await awaitObserved("the list loads") { router.list?.state == .loaded && router.list?.rows.isEmpty == false }
        let place = ShellTitles.title(router)
        let thread = try #require(router.list?.rows.first?.id)
        router.open(thread)
        await awaitObserved("the conversation loads") { router.reader?.thread == thread && router.reader?.state == .loaded }
        #expect(ShellTitles.title(router) == place, "the title stays the mailbox while reading")
        let conversation = ShellToolbar.conversationTitle(router.reader)
        #expect(ShellTitles.placeParts(router) == (conversation.isEmpty ? [] : [conversation]))
    }
}

@Suite struct SplitPickerLayoutTests {
    private func tabs(_ count: Int) -> [MailTab] {
        (0..<count).map { MailTab(location: .label(GmailLabelID("Label_\($0)")), title: "Split \($0)", unread: $0, total: 10) }
    }

    @Test func upToSixSplitsAreSegmentsAndTheRestGoUnderMore() {
        #expect(NativeMetrics.Toolbar.maxSplitSegments == 6)
        let two = SplitInboxPicker.layout(tabs(2), active: tabs(2)[0].location)
        #expect(two.segments.count == 2 && two.overflow.isEmpty)
        let six = SplitInboxPicker.layout(tabs(6), active: nil)
        #expect(six.segments.count == 6 && six.overflow.isEmpty, "six fit without a More menu")
        let nine = tabs(9)
        let layout = SplitInboxPicker.layout(nine, active: nine[1].location)
        #expect(layout.segments == Array(nine.prefix(6)))
        #expect(layout.overflow == Array(nine.suffix(3)))
        #expect(layout.activeInOverflow == nil && layout.overflowTitle == SplitInboxPicker.moreTitle)
    }

    @Test func aSplitChosenUnderMoreNamesTheMenu() {
        let nine = tabs(9)
        let layout = SplitInboxPicker.layout(nine, active: nine[7].location)
        #expect(layout.activeInOverflow == nine[7])
        #expect(layout.overflowTitle == "Split 7")
    }

    @Test func aSegmentShowsItsNameAndCount() {
        let tab = MailTab(location: .splitOther, title: "Other", unread: 12, total: 4_598)
        #expect(SplitInboxPicker.segmentTitle(tab, count: 12) == "Other 12")
        #expect(SplitInboxPicker.segmentTitle(tab, count: 0) == "Other")
        #expect(SplitInboxPicker.segmentTitle(tab, count: 1_000) == "Other 999+")
    }
}

@MainActor
@Suite struct ReaderToolbarActionsTests {
    @Test func theToolbarGroupIsDoneRemindLabelAndTrashWithSymbols() {
        #expect(ReaderToolbarActions.primaryIDs == [.markDone, .remind, .label, .trash])
        for id in ReaderToolbarActions.primaryIDs + ReaderActions.navigationActionIDs {
            #expect(ReaderActions.symbol(for: id) != nil, "\(id) has a toolbar symbol")
        }
    }

    @Test func moreHoldsEverythingElseAndSnoozeJoinsTheThreadActions() throws {
        let sections = ReaderToolbarActions.moreMenuSections.map { $0.map(\.id) }
        let more = sections.joined()
        #expect(Set(more).isDisjoint(with: ReaderToolbarActions.primaryIDs), "nothing twice between the group and More")
        let thread = try #require(sections.first { $0.contains(.toggleStar) })
        #expect(thread.contains(.snooze), "Snooze joins the thread actions")
        #expect(sections.last == [.printConversation])
        #expect(ReaderToolbarActions.empty.isEmpty, "no sections, so More can be disabled")
    }
}

@MainActor
@Suite struct ShellSidebarVisibilityTests {
    typealias Shell = MailShellView<EmptyView, EmptyView>

    @Test func theSidebarColumnFollowsTheRoutersSetting() {
        #expect(Shell.visibility(sidebarShown: true) == .all)
        #expect(Shell.visibility(sidebarShown: false) == .detailOnly)
        #expect(Shell.sidebarShown(.all) && Shell.sidebarShown(.doubleColumn))
        #expect(!Shell.sidebarShown(.detailOnly))
    }
}

@MainActor
@Suite struct ShellDetailColumnTests {
    @Test func theCalendarTemporarilyHidesAllInboxes() async throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: now),
                                              featureFlags: FeatureFlags(), calendar: FakeCalendar())
        let router = environment.router
        router.start()
        defer { router.stop() }
        await awaitObserved("both accounts load") { router.accounts.count == 2 }
        #expect(router.goToAllInboxes())
        let unified = try #require(router.unifiedInbox)
        #expect(ShellDetailColumn<EmptyView>.shownAllInboxes(router) === unified)
        let calendar = try #require(environment.calendarWindow)
        calendar.now = { now }
        await calendar.open()
        #expect(ShellDetailColumn<EmptyView>.shownAllInboxes(router) == nil)
        #expect(router.unifiedInbox === unified)
        await calendar.close()
        #expect(ShellDetailColumn<EmptyView>.shownAllInboxes(router) === unified)
        await calendar.open()
        #expect(router.goToAllInboxes())
        #expect(!calendar.isOpen, "All Inboxes steps the Calendar aside")
        #expect(router.unifiedInbox === unified)
        #expect(ShellDetailColumn<EmptyView>.shownAllInboxes(router) === unified)
    }

    @Test func theSelectBeforeHintShowsOnlyOverTheMailList() {
        #expect(CheckBeforeHint.applies(mode: .list, isMail: true, offersCheckBefore: true))
        #expect(!CheckBeforeHint.applies(mode: .list, isMail: true, offersCheckBefore: false), "nothing to offer")
        #expect(!CheckBeforeHint.applies(mode: .reader, isMail: true, offersCheckBefore: true), "not over a conversation")
        #expect(!CheckBeforeHint.applies(mode: .list, isMail: false, offersCheckBefore: true),
                "not over the Calendar or All Inboxes")
    }

    @Test func theSelectBeforeHintStepsAsideForTheCalendarAndAllInboxes() async throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: now),
                                              featureFlags: FeatureFlags(), calendar: FakeCalendar())
        let router = environment.router
        router.start()
        defer { router.stop() }
        await awaitObserved("the list loads") { router.list?.state == .loaded && (router.list?.rows.count ?? 0) >= 3 }
        let list = try #require(router.list)
        let rows = list.rows.map(\.id)
        list.selection.checkFromHere(cursor: rows[1], in: rows)
        #expect(list.offersCheckBefore, "every conversation from the second down is checked")
        #expect(CheckBeforeHint.shows(router: router) != nil, "the list on screen offers the ones above")

        let calendar = try #require(environment.calendarWindow)
        calendar.now = { now }
        await calendar.open()
        #expect(list.offersCheckBefore, "the checks stay behind the Calendar")
        #expect(CheckBeforeHint.shows(router: router) == nil, "but the hint does not show over it")
        await calendar.close()
        #expect(CheckBeforeHint.shows(router: router) != nil, "back on the list it shows again")

        await awaitObserved("both accounts load") { router.accounts.count == 2 }
        #expect(router.goToAllInboxes())
        #expect(CheckBeforeHint.shows(router: router) == nil, "not over All Inboxes")
    }
}
#endif
