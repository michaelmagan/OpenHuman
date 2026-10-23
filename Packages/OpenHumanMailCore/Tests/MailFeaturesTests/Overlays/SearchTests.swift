import Foundation
import MailActions
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@Suite struct SearchSyntaxTests {
    @Test func operatorsBecomeChipsAndTheRestStaysText() {
        let tokens = SearchSyntax.tokens(#"from:dana has:attachment -label:"Big Deals" invoice is:unread before:2026/10/01"#)
        let expected: [SearchOperator?] = [.from, .has, .label, nil, SearchOperator.`is`, .before]
        #expect(tokens.map(\.operator) == expected)
        #expect(tokens[0].value == "dana")
        #expect(tokens[2].value == "Big Deals", "quotes keep a space inside one word")
        #expect(tokens[2].isNegated)
        #expect(tokens.filter(\.isChip).allSatisfy { $0.isValid })
        #expect(tokens[3].text == "invoice" && !tokens[3].isChip)
    }

    @Test func unknownOperatorsAreFreeText() {
        let tokens = SearchSyntax.tokens("foo:bar category:updates")
        #expect(tokens.allSatisfy { !$0.isChip }, "the Store decides what it knows; the field offers nine")
    }

    @Test func dateOperatorsAreCheckedLocally() {
        func valid(_ value: String) -> Bool { SearchSyntax.tokens("before:\(value)").first?.isValid ?? false }
        #expect(valid("2026/10/01") && valid("2026-10-01") && valid("1791000000"))
        #expect(!valid("yesterday") && !valid("2026/13/01") && !valid("2026/02/30"))
    }

    @Test func theTextIsNeverRewritten() {
        let text = #"from:dana  "quoted phrase"   (a OR b)"#
        let tokens = SearchSyntax.tokens(text)
        #expect(tokens.map(\.text) == ["from:dana", "\"quoted phrase\"", "(a OR b)"])
        #expect(tokens.allSatisfy { text[$0.range] == $0.text })
    }

    @Test func operatorSuggestionsCompleteTheWordBeingTyped() {
        let result = SearchSuggestions.make(text: "invoice fr", recents: [], labels: [], people: [])
        #expect(result.map(\.title) == ["from:"])
        #expect(result.first?.replacement == "invoice from:")
        let negated = SearchSuggestions.make(text: "-su", recents: [], labels: [], people: [])
        #expect(negated.first?.replacement == "-subject:")
    }

    @Test func peopleAndLabelsCompleteValues() {
        let people = [SearchSuggestions.Person(name: "Dana Ruiz", email: "dana@acme.example"),
                      SearchSuggestions.Person(name: nil, email: "dan@example.org")]
        let from = SearchSuggestions.make(text: "x from:da", recents: [], labels: [], people: people)
        #expect(from.map(\.title) == ["Dana Ruiz", "dan@example.org"])
        #expect(from.first?.replacement == "x from:dana@acme.example ")
        let label = SearchSuggestions.make(text: "label:cl", recents: [], labels: ["Clients/Acme", "Receipts"], people: [])
        #expect(label.map(\.title) == ["Clients/Acme"])
        #expect(label.first?.replacement == "label:Clients/Acme ")
        let spaced = SearchSuggestions.make(text: "label:big", recents: [], labels: ["Big Deals"], people: [])
        #expect(spaced.first?.replacement == "label:\"Big Deals\" ")
    }

    @Test func anEmptyFieldOffersRecentsThenOperatorsUpToEightRows() {
        let result = SearchSuggestions.make(text: "", recents: ["a", "b", "c", "d", "e", "f"], labels: [], people: [])
        #expect(result.count == SearchSuggestions.maxRows)
        #expect(result.prefix(4).map(\.kind) == Array(repeating: .recent, count: 4))
        #expect(result[4].kind == .operator(.from))
        let afterSpace = SearchSuggestions.make(text: "invoice ", recents: ["a"], labels: [], people: [])
        #expect(!afterSpace.contains { $0.kind == .recent }, "recents only for an empty field")
    }
}

@MainActor
@Suite struct SearchModelTests {
    @Test func slashOpensTheFieldOverThePlaceAndEscReturns() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let origin = try #require(state.location)
        let search = f.center.search
        search.liveDelay = nil
        #expect(await f.run(.search))
        #expect(search.isOpen && state.searchOpen)
        #expect(search.focusRequest == 1)

        search.text = "from:dana has:attachment"
        #expect(search.tokens.filter(\.isChip).count == 2)
        search.submit()
        #expect(state.location == .search("from:dana has:attachment"), "the raw string goes to the location")
        #expect(search.recents == ["from:dana has:attachment"])

        search.escape()
        #expect(search.text.isEmpty && search.isOpen, "the first Esc clears the text")
        #expect(state.location == .search("from:dana has:attachment"))
        search.escape()
        #expect(!search.isOpen)
        #expect(state.location == origin, "the second Esc returns to the split")
    }

    @Test func aPillSelectionBelongsToItsQueryAndAClickAsksForTheField() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = nil
        #expect(await f.run(.search))
        search.text = "from:dana has:attachment "
        search.selectedPills = [1]
        #expect(search.selectedPills == [1])
        search.text = "from:dana has:attachment x"
        #expect(search.selectedPills.isEmpty, "typing lets go of the pill")
        search.text = "from:dana has:attachment "
        #expect(search.selectedPills.isEmpty, "and an Undo back to the query does not select it again")
        let request = search.focusRequest
        search.focusField()
        #expect(search.focusRequest == request + 1)
    }

    @Test func enterHandsTheKeysToTheResultsAndEscInTheListClosesTheSearch() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let origin = try #require(state.location)
        let search = f.center.search
        search.liveDelay = nil
        #expect(!search.focusResults(), "no results shown yet: ↓ stays in the field")
        #expect(await f.run(.search))
        #expect(search.focusRequest != search.focusTaken, "the field is asked to take focus")
        search.fieldTookFocus()
        #expect(search.focusRequest == search.focusTaken)
        search.text = "invoice"
        search.submit()
        #expect(search.resultsFocusRequest == 1, "Enter gives the list the keys (j/k/e stop typing into the query)")
        #expect(search.focusResults())
        #expect(search.resultsFocusRequest == 2, "↓ with no suggestion does too")
        await eventually { f.router.list?.state != .loading }

        let context = f.router.actionContext()
        let descriptor = try #require(f.registry.descriptor(.clearChecks))
        #expect(ActionRules.title(for: descriptor, in: context) == "Close search")
        #expect(await f.run(.clearChecks))
        #expect(!search.isOpen)
        #expect(state.location == origin)
        #expect(f.registry.availability(.clearChecks, host: f.router) == .hidden, "Esc in a plain list still passes on")
    }

    @Test func escInTheResultsClearsChecksFirst() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        search.text = "a"
        search.submit()
        await eventually { f.router.list?.state != .loading && !(f.router.list?.rows.isEmpty ?? true) }
        #expect(await f.run(.toggleCheck))
        #expect(await f.run(.clearChecks))
        #expect(state.selection.checked.isEmpty && search.isOpen, "the first Esc clears the checks")
        #expect(await f.run(.clearChecks))
        #expect(!search.isOpen, "the next one leaves the search")
    }

    @Test func slashInAConversationGoesBackToTheListAndFocusesTheField() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let key = try #require(f.rows.first?.id)
        f.router.open(key)
        #expect(state.mode == .reader)
        let asked = f.center.search.focusRequest
        #expect(await f.run(.search))
        #expect(state.mode == .list, "the field lives in the list's toolbar: `/` is never a dead key")
        #expect(state.searchOpen && f.center.search.focusRequest == asked + 1)
    }

    @Test func escapeOnAnEmptyFieldClosesAtOnce() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let origin = state.location
        f.center.search.open()
        f.center.search.escape()
        #expect(!state.searchOpen && state.location == origin)
    }

    @Test func recentsAreUniqueNewestFirstAndBounded() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        for query in (0..<14).map({ "term\($0)" }) + ["term3"] {
            search.text = query
            search.submit()
        }
        #expect(search.recents.count == SearchModel.maxRecent)
        #expect(search.recents.first == "term3" && search.recents.filter { $0 == "term3" }.count == 1)
    }

    @Test func recentSearchesPersistThroughTheirStore() async throws {
        let store = InMemoryRecentSearchesStore()
        store.save(["from:dana"])
        let f = OverlayFixture()
        await f.loaded()
        let model = SearchModel(router: f.router, store: store)
        #expect(model.recents == ["from:dana"])
        model.liveDelay = nil
        f.router.active?.searchOpen = true
        model.text = "invoice"
        model.submit()
        #expect(store.load() == ["invoice", "from:dana"])
    }

    @Test func acceptingASuggestionCompletesOrRuns() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        search.text = "fr"
        search.accept(try #require(search.suggestions.first))
        #expect(search.text == "from:")
        search.text = ""
        let seeded = InMemoryRecentSearchesStore()
        seeded.save(["subject:budget"])
        let withRecents = SearchModel(router: f.router, store: seeded)
        withRecents.liveDelay = nil
        let recent = try #require(withRecents.suggestions.first { $0.kind == .recent })
        withRecents.accept(recent)
        #expect(f.router.active?.location == .search("subject:budget"), "a recent search runs")
    }

    @Test func liveResultsFollowTheTypingAfterAPause() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = .milliseconds(20)
        search.open()
        search.text = "inv"
        search.text = "invoice"
        await eventually { f.router.active?.location == .search("invoice") }
    }

    @Test func theSearchIsNotRunWhileRestoringASavedField() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let origin = state.location
        state.searchText = "restored"
        state.searchOpen = true
        #expect(state.location == origin, "a saved field shows its text without searching")
    }
}

@MainActor
@Suite struct SearchCoverageTests {
    private func showSearch(_ f: OverlayFixture, _ query: String = "zzqx") async {
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        search.text = query
        search.submit()
        await eventually { f.router.active?.location == .search(query) && f.router.list?.searchStatus != nil }
    }

    @Test func aCompleteLocalAnswerSaysNothing() async throws {
        let f = OverlayFixture()
        await f.loaded()
        #expect(f.router.list?.searchStatus == nil, "only search windows carry coverage")
        await showSearch(f)
        #expect(f.router.list?.searchStatus?.completeness.isComplete == true)
        #expect(f.center.search.coverageNotice == nil)
        #expect(!f.center.search.canSearchGmail)
        #expect(f.registry.availability(.searchGmail, host: f.router) == .hidden, "⌘K does not offer it")
    }

    @Test func olderMailNotOnTheMacOffersSearchGmailWhichListsWhatOnlyGmailFound() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let account = try #require(f.router.active?.id)
        let onlyOnGmail = try #require(f.rows.first?.id)
        f.store.setSearchIncomplete([.olderMailNotLocal(searchedBack: nil)], account: account)
        f.store.setGmailOnlyResults([onlyOnGmail], account: account)
        await showSearch(f)
        let search = f.center.search
        let notice = try #require(search.coverageNotice)
        #expect(notice.text == "Results may be incomplete: older mail isn't on this Mac yet.")
        #expect(notice.offersGmailSearch && !notice.isSearching)
        #expect(search.canSearchGmail)
        #expect(f.registry.availability(.searchGmail, host: f.router) == .enabled, "⌘K offers it")
        #expect(f.rows.isEmpty)
        #expect(f.store.gmailSearchCount == 0, "nothing reaches Gmail before the user asks (the fake has no automatic ask)")

        search.searchGmail()
        #expect(search.coverageNotice?.isSearching == true, "the line says so at once")
        #expect(!search.canSearchGmail, "no second ask while one runs")
        await eventually { f.rows.map(\.id) == [onlyOnGmail] }
        await eventually { search.coverageNotice?.text == "Also searched Gmail: 1 more result, listed after these." }
        #expect(search.coverageNotice?.offersGmailSearch == false)
        #expect(search.resultsSummary?.hasPrefix("1 result in") == true)
        #expect(f.store.gmailSearchCount == 1)
    }

    @Test func aFailedGmailSearchSaysSoAndCanBeAskedAgainFromThePalette() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let account = try #require(f.router.active?.id)
        f.store.setSearchIncomplete([.bodiesNotDownloaded(messages: 3)], account: account)
        f.store.failNextGmailSearch()
        await showSearch(f)
        let search = f.center.search
        #expect(search.coverageNotice?.text == "Results may be incomplete: 3 messages aren't fully downloaded yet.")
        search.searchGmail()
        await eventually {
            search.coverageNotice?.text == "Results may be incomplete: 3 messages aren't fully downloaded yet. Couldn't search Gmail."
        }
        #expect(search.canSearchGmail, "the line offers Search Gmail again")
        #expect(await f.run(.searchGmail, source: .palette))
        await eventually { search.coverageNotice?.text == "Also searched Gmail: no more results." }
        #expect(f.store.gmailSearchCount == 2)
        #expect(f.rows.isEmpty)
    }

    @Test func searchGmailNeedsNoWritePort() async throws {
        let f = OverlayFixture(writePort: false)
        await f.loaded()
        let account = try #require(f.router.active?.id)
        f.store.setSearchIncomplete([.olderMailNotLocal(searchedBack: nil)], account: account)
        await showSearch(f)
        #expect(f.registry.availability(.searchGmail, host: f.router) == .enabled, "Gmail is only read")
        #expect(await f.run(.searchGmail, source: .palette))
        await eventually { f.store.gmailSearchCount == 1 }
    }

    @Test func theLineSaysWhatIsMissingAndWhereGmailStands() {
        let older = SearchWindowStatus(completeness: SearchCompletenessInfo(
            reasons: [.olderMailNotLocal(searchedBack: nil), .bodiesNotDownloaded(messages: 2)]), gmailAvailable: true)
        #expect(SearchCoverageNotice.make(older, gmail: .notAsked)?.text
                == "Results may be incomplete: older mail isn't on this Mac yet.", "the first reason")
        #expect(SearchCoverageNotice.make(older, gmail: .searching)
                == SearchCoverageNotice(text: "Results may be incomplete: older mail isn't on this Mac yet. Searching Gmail…",
                                        offersGmailSearch: false, isSearching: true))
        #expect(SearchCoverageNotice.make(older, gmail: .done(added: 4))?.text
                == "Also searched Gmail: 4 more results, listed after these.")
        #expect(SearchCoverageNotice.make(older, gmail: .failed)?.offersGmailSearch == true)
        let noGmail = SearchWindowStatus(completeness: older.completeness, gmailAvailable: false)
        #expect(SearchCoverageNotice.make(noGmail, gmail: .notAsked)?.offersGmailSearch == false,
                "a source without Gmail still says the results may be incomplete")
        #expect(SearchCoverageNotice.make(SearchWindowStatus(), gmail: .notAsked) == nil)
        #expect(SearchCoverageNotice.make(SearchWindowStatus(gmailAvailable: true), gmail: .searching)?.text == "Searching Gmail…")
        let one = SearchWindowStatus(completeness: SearchCompletenessInfo(reasons: [.bodiesNotDownloaded(messages: 1)]))
        #expect(SearchCoverageNotice.make(one, gmail: .notAsked)?.text
                == "Results may be incomplete: 1 message isn't fully downloaded yet.")
        let many = SearchWindowStatus(completeness: SearchCompletenessInfo(reasons: [.tooManyMatches(limit: 20_000)]))
        #expect(SearchCoverageNotice.make(many, gmail: .notAsked)?.text.contains("only the newest") == true)
    }
}
