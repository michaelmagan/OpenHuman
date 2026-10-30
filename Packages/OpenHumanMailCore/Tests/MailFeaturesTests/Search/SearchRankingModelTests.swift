import Foundation
import MailActions
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private func key(_ n: Int64) -> ThreadKey { ThreadKey(account: AccountID(1), rowID: n, gmailThreadID: GmailThreadID("t\(n)")) }

private func row(_ n: Int64, minutesAgo: Double) -> ThreadRow {
    let at = Date(timeIntervalSince1970: 1_791_000_000 - minutesAgo * 60)
    return ThreadRow(id: key(n), subject: "Subject \(n)", snippet: "s", participantsDisplay: "P\(n)", participants: [],
                     messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false,
                     isImportant: false, userLabelIDs: [], lastMessageAt: at, sortAt: at)
}

@MainActor @Suite struct SearchRankingModelTests {
    @Test func defaultsAreMostRelevantAndBalancedWithEachLevelDominating() {
        let model = SearchRankingModel(port: InMemorySearchRankingPort())
        #expect(model.settings == .defaults)
        #expect(model.settings.sort == .relevant)
        #expect(model.settings.preset == .balanced)
        #expect(model.settings.weights == .balanced)
        #expect(SearchRankingWeights.balanced.headerLevelsDominate)
        #expect(SearchRankingWeights.relevance.headerLevelsDominate)
        #expect(!SearchRankingWeights.recentFirst.headerLevelsDominate, "Recent first lets recency cross levels")
        #expect(SearchRankingSettings(preset: .classic).weights == nil)
    }

    @Test func changingAWeightMakesItCustomAndResetPutsBalancedBack() {
        let port = InMemorySearchRankingPort()
        let model = SearchRankingModel(port: port)
        model.setWeight(.recency, 0.5)
        #expect(model.settings.preset == .custom)
        #expect(model.shownWeights.recency == 0.5)
        #expect(model.isChanged(.recency))
        #expect(port.settings() == model.settings, "saved through the port")
        model.resetWeight(.recency)
        #expect(!model.isChanged(.recency))
        #expect(model.settings.preset == .balanced, "every weight is Balanced's again")
        model.setPreset(.recentFirst)
        model.setWeight(.halfLifeDays, 10_000)
        #expect(model.shownWeights.halfLifeDays == 730, "clamped to the control's range")
        #expect(model.shownWeights.recency == SearchRankingWeights.recentFirst.recency, "Custom starts from the preset shown")
        model.resetAll()
        #expect(model.settings == .defaults)
    }

    @Test func theHeaderSwitchAppliesToOneSearch() {
        let port = InMemorySearchRankingPort()
        let model = SearchRankingModel(port: port)
        model.toggleSort(for: "quince developer")
        #expect(model.sort(for: "quince developer") == .recent)
        #expect(model.sort(for: "another search") == .relevant, "a new search starts in the default order")
        #expect(port.sortOverride() == SearchSortOverride(query: "quince developer", sort: .recent))
        model.toggleSort(for: "quince developer")
        #expect(model.sortOverride == nil, "back to the default: no override kept")
        model.setDefaultSort(.recent)
        #expect(model.sort(for: "anything") == .recent)
    }

    @Test func onlyOpensFromSearchResultsAreRemembered() async {
        let port = InMemorySearchRankingPort()
        let model = SearchRankingModel(port: port, notices: NoticeCenter())
        model.noteOpened(key(1), from: .system(.inbox))
        #expect(model.lastOpenRecord == nil)
        model.noteOpened(key(2), from: .search("quince"))
        await model.lastOpenRecord?.value
        #expect(port.opens(key(2)) == 1)
        #expect(port.opens(key(1)) == 0)
        await model.refresh()
        #expect(model.rememberedConversations == 1)
        await model.resetLearning()
        #expect(model.rememberedConversations == 0)
        #expect(model.settings == .defaults, "reset learning keeps the settings")
    }

    @Test func settingsDecodeWithMissingOrUnknownKeys() throws {
        let decoded = try JSONDecoder().decode(SearchRankingSettings.self, from: Data(#"{"preset":"relevance","later":1}"#.utf8))
        #expect(decoded == SearchRankingSettings(sort: .relevant, preset: .relevance))
        let round = try JSONDecoder().decode(SearchRankingSettings.self,
                                             from: try JSONEncoder().encode(SearchRankingSettings(sort: .recent, preset: .custom)))
        #expect(round.sort == .recent && round.preset == .custom)
    }

    @Test func explanationTextIsNumbersAndFixedLabels() {
        let explanation = SearchScoreExplanation(match: "sender name match", wordsTogether: true, parts: [
            .init(label: "Sender and subject", value: 1, weight: 4), .init(label: "Recency", value: 0.5, weight: 0.15),
        ])
        #expect(explanation.text == """
            Search ranking: 4.075 points
            Match: sender name match
            Words together: yes
            Sender and subject: 1.000 × 4.000 = 4.000
            Recency: 0.500 × 0.150 = 0.075
            """)
    }
}

@Suite struct SearchListOrderingTests {
    @Test func dateHeadersOnlyForADateOrder() {
        #expect(ThreadListGroups.applies(groupsByDate: true, sortsAscending: false, searchOrdering: nil))
        #expect(ThreadListGroups.applies(groupsByDate: true, sortsAscending: false, searchOrdering: .date))
        #expect(!ThreadListGroups.applies(groupsByDate: true, sortsAscending: false, searchOrdering: .relevance))
        #expect(!ThreadListGroups.applies(groupsByDate: false, sortsAscending: false, searchOrdering: .date))
        #expect(!ThreadListGroups.applies(groupsByDate: true, sortsAscending: true, searchOrdering: nil))
    }

    @Test func relevancePagesKeepRowsWhatEverTheirDates() {
        var assembler = ThreadListAssembler(sortsAscending: false)
        assembler.live = [row(1, minutesAgo: 10), row(2, minutesAgo: 900_000)]
        assembler.liveHasMore = true
        assembler.pages = [ThreadListPage(after: nil, rows: [row(2, minutesAgo: 900_000), row(3, minutesAgo: 5)], next: nil,
                                          generation: 0, fetchedAt: Date(timeIntervalSince1970: 1_791_000_000))]
        #expect(assembler.baseRows().map(\.id) == [key(1), key(2)], "a date order drops it (it belongs above)")
        assembler.ordersByRelevance = true
        #expect(assembler.baseRows().map(\.id) == [key(1), key(2), key(3)], "a relevance order keeps it, once")
    }
}

@Suite struct SearchHeaderScopeTests {
    @Test func theSearchLinesShowOnlyOverTheSearchResults() {
        func shows(searchOpen: Bool = true, location: MailLocation? = .search("quince"), readerShown: Bool = false,
                   unifiedInboxShown: Bool = false, calendarShown: Bool = false) -> Bool {
            SearchHeaderScope.shows(searchOpen: searchOpen, location: location, readerShown: readerShown,
                                    unifiedInboxShown: unifiedInboxShown, calendarShown: calendarShown)
        }
        #expect(shows())
        #expect(!shows(readerShown: true), "an opened result shows no search lines")
        #expect(!shows(calendarShown: true))
        #expect(!shows(unifiedInboxShown: true))
        #expect(!shows(location: .system(.inbox)))
        #expect(!shows(searchOpen: false))
        #expect(!shows(location: nil))
    }
}

@MainActor @Suite struct SearchHeaderInTheReaderTests {
    @Test func anOpenedResultHidesTheSearchLinesAndBackBringsThemBack() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let words = f.rows.flatMap { $0.subject.split(separator: " ") }
        let word = try #require(words.first { $0.count >= 4 && $0.allSatisfy(\.isLetter) }.map(String.init))
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        search.text = word
        search.submit()
        await eventually { f.router.active?.location == .search(word) && f.router.list?.state == .loaded && !f.rows.isEmpty }
        #expect(f.router.showsSearchResultsHeader)
        let opened = try #require(f.rows.first?.id)
        f.router.open(opened)
        await eventually { f.router.mode == .reader && f.router.reader?.thread == opened }
        #expect(!f.router.showsSearchResultsHeader, "no search lines over the conversation")
        #expect(await f.run(.backToList))
        await eventually { f.router.mode == .list }
        #expect(f.router.showsSearchResultsHeader)
        #expect(search.shownQuery == word && f.router.active?.location == .search(word))
        #expect(f.router.list?.cursor == opened)
    }
}

@MainActor @Suite struct SearchRankingActionTests {
    @Test func theCatalogHasThePaletteEntries() {
        let ids = Set(ActionCatalog.all.map(\.id))
        #expect(ids.isSuperset(of: [.resetSearchLearning, .toggleSearchSort, .copySearchRanking, .settingsPage("search")]))
        #expect(SettingsPageID.search.title == "Search")
    }
}
