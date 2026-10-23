import Foundation
import MailActions
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@Suite struct SearchCompletionTests {
    let dana = SearchSuggestions.Person(name: "Dana Ruiz", email: "dana@acme.example")
    let michael = SearchSuggestions.Person(name: "Michael Stone", email: "stone@example.org")

    @Test func anEmptyFieldOffersPeopleThenRecentSearchesThenOperators() {
        let people = (1...6).map { SearchSuggestions.Person(name: "Person \($0)", email: "p\($0)@example.com") }
        let result = SearchSuggestions.make(text: "", recents: ["a", "b"], labels: [], people: people)
        #expect(result.count == SearchSuggestions.maxRows)
        #expect(result.prefix(SearchSuggestions.maxPeople).allSatisfy { $0.kind == .person })
        #expect(result.first?.replacement == "from:p1@example.com ", "a person completes into a pill")
        #expect(result[4].kind == .recent && result[5].kind == .recent)
        #expect(result[6].kind == .operator(.from))
        let typed = SearchSuggestions.make(text: "invoice ", recents: ["a"], labels: [], people: people)
        #expect(!typed.contains { $0.kind == .person }, "people without a word to match only for an empty field")
    }

    @Test func theGhostContinuesTheTypedWord() throws {
        let fro = try #require(SearchSuggestions.make(text: "fro", recents: [], labels: [], people: []).first)
        #expect(SearchSuggestions.ghost(text: "fro", suggestion: fro) == SearchGhost(remainder: "m:", detail: nil))
        let unread = try #require(SearchSuggestions.make(text: "is:un", recents: [], labels: [], people: []).first)
        #expect(SearchSuggestions.ghost(text: "is:un", suggestion: unread) == SearchGhost(remainder: "read", detail: nil))
    }

    @Test func aPersonsGhostFinishesTheNameAndNamesTheAddress() throws {
        let byName = try #require(SearchSuggestions.make(text: "from:mi", recents: [], labels: [], people: [michael]).first)
        #expect(SearchSuggestions.ghost(text: "from:mi", suggestion: byName)
                == SearchGhost(remainder: "chael Stone", detail: "stone@example.org"))
        let byAddress = try #require(SearchSuggestions.make(text: "from:da", recents: [], labels: [], people: [dana]).first)
        #expect(SearchSuggestions.ghost(text: "from:da", suggestion: byAddress)
                == SearchGhost(remainder: "na@acme.example", detail: nil), "the address itself continues the word")
        let bare = try #require(SearchSuggestions.make(text: "x ru", recents: [], labels: [], people: [dana])
            .first { $0.kind == .person })
        #expect(SearchSuggestions.ghost(text: "x ru", suggestion: bare) == SearchGhost(remainder: "", detail: "dana@acme.example"),
                "a match inside the name shows only the address Tab puts in")
    }

    @Test func searchesAreNotCompletions() {
        let recent = SearchSuggestion(kind: .recent, title: "budget", detail: nil, replacement: "budget")
        #expect(!SearchSuggestions.completes(recent))
        #expect(SearchSuggestions.ghost(text: "bud", suggestion: recent) == nil)
        let op = SearchSuggestion(kind: .operator(.from), title: "from:", detail: nil, replacement: "from:")
        #expect(SearchSuggestions.ghost(text: "from ", suggestion: op) == nil, "no word being typed")
    }
}

@MainActor
@Suite struct SearchPanelModelTests {
    @Test func tabCompletesTheHighlightedSuggestionOrTheFirstCompletion() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        #expect(!search.acceptCompletion(), "nothing typed: Tab is left alone")
        search.text = "fro"
        #expect(search.completion?.title == "from:")
        #expect(search.acceptCompletion())
        #expect(search.text == "from:")
        search.text = "invoice "
        #expect(search.completion == nil && !search.acceptCompletion())

        search.text = "s"
        let suggestions = search.suggestions
        let subject = try #require(suggestions.first { $0.title == "subject:" })
        search.highlight(subject)
        #expect(search.completion == subject, "the highlighted row is what Tab takes")
        search.highlight(nil)
        #expect(search.completion == suggestions.first, "with the list closed, the first completion")
        search.highlight(subject)
        search.text = "t"
        #expect(search.completion?.title == "to:", "a highlight from an earlier query is not used")
    }

    @Test func escInTheListClosesAnOpenSearchBeforeAnyResults() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let state = try #require(f.router.active)
        let origin = try #require(state.location)
        #expect(f.registry.availability(.clearChecks, host: f.router) == .hidden, "a plain list passes Esc on")
        #expect(await f.run(.search))
        #expect(state.searchOpen && state.location == origin, "an empty field searches nothing yet")
        let context = f.router.actionContext()
        #expect(context.searchOpen)
        let descriptor = try #require(f.registry.descriptor(.clearChecks))
        #expect(ActionRules.title(for: descriptor, in: context) == "Close search")
        #expect(f.registry.availability(.clearChecks, host: f.router) == .enabled)
        #expect(await f.run(.clearChecks))
        #expect(!state.searchOpen && state.location == origin)
    }

    @Test func returnAsksForTheFirstResultAndDownForTheResultsAsTheyAre() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        search.text = "invoice"
        search.submit()
        #expect(search.resultsFocusRequest == 1 && search.resultsFocusStartsAtTop)
        #expect(search.focusResults())
        #expect(search.resultsFocusRequest == 2 && !search.resultsFocusStartsAtTop)
    }

    @Test func anEmptyFieldLooksUpThePeopleWrittenToMost() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.open()
        await search.refreshPeople()
        #expect(!search.people.isEmpty && search.people.count <= SearchSuggestions.maxPeople)
        #expect(search.suggestions.first?.kind == .person)
        #expect(!search.canAskAI, "no AI in this window")

        search.liveDelay = nil
        search.text = "from:"
        await search.refreshPeople()
        #expect(!search.people.isEmpty, "a bare from: offers people to arrow through")
        #expect(search.suggestions.allSatisfy { $0.kind == .person })
        search.text = "subject:"
        await search.refreshPeople()
        #expect(search.people.isEmpty)
    }

    @Test func aCancelledPeopleLookupKeepsTheNewerPeople() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.open()
        search.liveDelay = nil
        await search.refreshPeople()
        let shown = search.people
        #expect(!shown.isEmpty)
        search.text = "from:zzqx"
        let stale = Task { await search.refreshPeople() }
        stale.cancel()
        await stale.value
        #expect(search.people == shown, "a cancelled lookup finds nobody and must not clear the list")
        await search.refreshPeople()
        #expect(search.people.isEmpty, "the lookup for the text that is there still runs")
    }

    @Test func aHighlightedPersonIsPreviewedAndOthersAreNot() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.open()
        let person = SearchSuggestion(kind: .person, title: "Dana Ruiz", detail: "dana@acme.example",
                                      replacement: "from:dana@acme.example ", email: "dana@acme.example")
        search.highlight(person)
        #expect(search.contactPreview.contact?.name == "Dana Ruiz")
        #expect(search.contactPreview.contact?.domain == "acme.example")
        search.highlight(SearchSuggestion(kind: .operator(.to), title: "to:", detail: nil, replacement: "to:"))
        #expect(search.contactPreview.contact == nil)
        search.highlight(person)
        search.close()
        #expect(search.contactPreview.contact == nil, "closing the search forgets it")
    }
}

@MainActor
@Suite struct SearchContactPreviewTests {
    private func row(_ subject: String, _ date: Date) -> ThreadRow {
        ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t-7")), subject: subject,
                  snippet: "", participantsDisplay: "Dana Ruiz", participants: [], messageCount: 1, unreadCount: 0,
                  draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false, isImportant: false,
                  userLabelIDs: [], lastMessageAt: date, sortAt: date)
    }

    @Test func itShowsTheNewestConversationsOnceAndCachesThem() async throws {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let rows = (0..<6).map { row("Subject \($0)", date) } + [row("  ", date)]
        let preview = SearchContactPreview { _ in rows }
        preview.delay = .zero
        preview.show(name: "Dana Ruiz", email: "Dana@Acme.example")
        #expect(preview.contact?.conversations == nil, "looking them up")
        await eventually { preview.contact?.conversations != nil }
        #expect(preview.contact?.conversations?.count == SearchContactPreview.maxConversations)
        #expect(preview.contact?.conversations?.first?.subject == "Subject 0")
        #expect(preview.contact?.domain == "acme.example")
        preview.show(name: nil, email: "sam@example.com")
        await eventually { preview.contact?.conversations != nil }
        preview.show(name: "Dana Ruiz", email: "dana@acme.example")
        #expect(preview.contact?.conversations?.count == SearchContactPreview.maxConversations, "cached")
        #expect(preview.lookups == 2)
        #expect(preview.contact?.title == "Dana Ruiz")
        preview.show(name: nil, email: nil)
        #expect(preview.contact == nil)
    }

    @Test func withoutLookupsItShowsTheNameAndAddressAlone() {
        let preview = SearchContactPreview { _ in [] }
        preview.delay = .seconds(600)
        preview.show(name: nil, email: "sam@example.com", looksUp: false)
        #expect(preview.contact?.conversations == [])
        #expect(preview.contact?.title == "sam@example.com")
        #expect(preview.lookups == 0)
    }
}
