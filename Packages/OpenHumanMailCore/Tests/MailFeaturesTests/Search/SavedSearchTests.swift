import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let bills = "from:billing@example.com has:attachment"

@MainActor
@Suite struct SavedSearchesModelTests {
    @Test func saveRenameAndDeleteAreStoredSettings() async throws {
        let f = SettingsFixture()
        let model = SavedSearchesModel(settings: f.store)
        model.now = { fixedNow }
        model.follow(f.work)
        #expect(model.canSave)
        let saved = try #require(await model.save(query: "  \(bills) ", name: "Bills"))
        #expect(saved.query == bills)
        #expect(saved.createdAt == Int64(fixedNow.timeIntervalSince1970 * 1000))
        await eventually { model.searches.map(\.name) == ["Bills"] }
        #expect(try await f.store.get(AppSettings.savedSearches(f.work)).map(\.name) == ["Bills"])
        #expect(try await f.store.get(AppSettings.savedSearches(f.personal)).isEmpty, "saved searches are per account")

        await model.rename(saved.id, to: "Bills to pay\nsoon")
        await eventually { model.searches.first?.name == "Bills to pay soon" }
        _ = await model.save(query: bills, name: "Invoices")
        await eventually { model.searches.map(\.name) == ["Invoices"] }

        let relaunched = SavedSearchesModel(settings: f.store)
        relaunched.follow(f.work)
        await eventually { relaunched.searches.map(\.name) == ["Invoices"] }

        await model.delete(saved.id)
        await eventually { model.searches.isEmpty }
        await eventually { relaunched.searches.isEmpty }
    }

    @Test func atMostFiftyPerAccount() async throws {
        let f = SettingsFixture()
        let model = SavedSearchesModel(settings: f.store)
        model.follow(f.work)
        for index in 0..<SavedSearch.maxPerAccount {
            #expect(await model.save(query: "subject:item\(index)") != nil)
        }
        #expect(await model.save(query: "subject:one-more") == nil)
        #expect(model.errorMessage == SavedSearchesModel.fullMessage)
        #expect(SavedSearchesModel.fullMessage.hasSuffix("Delete one in Settings › Search."))
        #expect(try await f.store.get(AppSettings.savedSearches(f.work)).count == SavedSearch.maxPerAccount)
        await eventually { model.searches.count == SavedSearch.maxPerAccount }
    }

    @Test func theDefaultNameIsTheQueryOnOneLineCut() {
        #expect(SavedSearch.defaultName(for: "invoice") == "invoice")
        let long = String(repeating: "word ", count: 30)
        let name = SavedSearch.defaultName(for: long)
        #expect(name.count == SavedSearch.nameLimit)
        #expect(name.hasSuffix("…"))
        #expect(SavedSearch.defaultName(for: "a\nb") == "a b")
    }

    @Test func withoutASettingsPortNothingIsOffered() async {
        let model = SavedSearchesModel(settings: nil)
        model.follow(AccountID(1))
        #expect(!model.canSave)
        #expect(await model.save(query: bills) == nil)
    }

    @Test func savedSearchesTravelInTheSettingsExport() async throws {
        let source = SettingsFixture()
        try await source.store.set(AppSettings.savedSearches(source.work),
                                   [SavedSearch(name: "Bills", query: bills, createdAt: 1),
                                    SavedSearch(name: "Team", query: "label:Team is:unread", createdAt: 2)])
        let file = try await SettingsTransferModel(environment: source.env).export()

        let target = SettingsFixture()
        try await target.store.set(AppSettings.savedSearches(target.work),
                                   [SavedSearch(name: "bills", query: "invoice", createdAt: 3)])
        let transfer = SettingsTransferModel(environment: target.env)
        let preview = try await transfer.prepareImport(file)
        #expect(preview.settingsToApply > 0)
        _ = await transfer.applyImport()
        let merged = try await target.store.get(AppSettings.savedSearches(target.work))
        #expect(merged.map(\.name) == ["bills", "Team"])
        #expect(merged.first?.query == bills)
    }

    @Test func mergingNeverDeletesAndStopsAtFifty() {
        let existing = (0..<49).map { SavedSearch(name: "s\($0)", query: "q\($0)", createdAt: Int64($0)) }
        let incoming = [SavedSearch(name: "new1", query: "n1", createdAt: 0), SavedSearch(name: "new2", query: "n2", createdAt: 0),
                        SavedSearch(name: "S0", query: "changed", createdAt: 0)]
        let merged = SettingsTransferModel.merge(existing, incoming)
        #expect(merged.count == SavedSearch.maxPerAccount)
        #expect(merged.first?.query == "changed")
        #expect(merged.contains { $0.name == "new1" } && !merged.contains { $0.name == "new2" })
    }
}

@Suite struct SavedSearchSuggestionTests {
    let saved = (1...5).map { SavedSearch(name: "Saved \($0)", query: "label:L\($0)", createdAt: Int64($0)) }

    @Test func theEmptyFieldShowsSavedThenRecentThenOperators() {
        let rows = SearchSuggestions.make(text: "", recents: ["label:L1", "invoice", "from:dana"], labels: [], people: [],
                                          saved: saved)
        #expect(rows.count == SearchSuggestions.maxRows)
        #expect(rows.prefix(4).allSatisfy { $0.kind == .saved })
        #expect(rows.prefix(4).map(\.title) == ["Saved 1", "Saved 2", "Saved 3", "Saved 4"])
        #expect(rows.dropFirst(4).prefix(2).map(\.title) == ["invoice", "from:dana"], "a recent equal to a saved query is skipped")
        #expect(rows.map(\.group) == [.saved, .saved, .saved, .saved, .recent, .recent, .operators, .operators])
        let chosen = rows[0]
        #expect(chosen.replacement == "label:L1" && chosen.detail == "label:L1")
    }

    @Test func typingMatchesSavedSearchesBeforePeople() {
        let people = [SearchSuggestions.Person(name: "Savannah Reed", email: "savannah@example.com")]
        let rows = SearchSuggestions.make(text: "sav", recents: [], labels: [], people: people, saved: saved)
        #expect(rows.first?.kind == .saved)
        #expect(rows.last?.kind == .person)
        #expect(rows.last?.email == "savannah@example.com")
        let byQuery = SearchSuggestions.make(text: "L3", recents: [], labels: [], people: [], saved: saved)
        #expect(byQuery.map(\.title) == ["Saved 3"])
        #expect(SearchSuggestions.make(text: "from:sav", recents: [], labels: [], people: people, saved: saved)
            .allSatisfy { $0.kind == .person })
    }

    @Test func withoutSavedSearchesTheListIsWP09s() {
        let before = SearchSuggestions.make(text: "", recents: ["a"], labels: [], people: [])
        #expect(before.first?.kind == .recent)
        #expect(!before.contains { $0.kind == .saved })
    }
}

@MainActor
@Suite struct RecentMailDetailTests {
    private func row(subject: String, at date: Date) -> ThreadRow {
        ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t-7")), subject: subject,
                  snippet: "", participantsDisplay: "Dana Ruiz", participants: [], messageCount: 1, unreadCount: 0,
                  draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false, isImportant: false,
                  userLabelIDs: [], lastMessageAt: date, sortAt: date)
    }

    @Test func oneReadPerHighlightCachedForTheFieldsLifetime() async throws {
        let calls = Counter()
        let details = RecentMailDetails { email in
            calls.add(email)
            return nil
        }
        details.delay = .zero
        details.highlight("Dana.Ruiz@example.com")
        await eventually { details.details["dana.ruiz@example.com"] != nil }
        #expect(details.lookups == 1)
        #expect(details.detail(for: "dana.ruiz@example.com") == nil, "no conversation: nothing shown")
        details.highlight(nil)
        details.highlight("dana.ruiz@example.com")
        details.highlight("sam.lee@example.com")
        await eventually { details.details["sam.lee@example.com"] != nil }
        #expect(details.lookups == 2, "the cached person is not read again")
        details.reset()
        #expect(details.details.isEmpty)
    }

    @Test func movingOnBeforeTheDelayCancelsTheRead() async throws {
        let calls = Counter()
        let details = RecentMailDetails { email in
            calls.add(email)
            return nil
        }
        details.delay = .seconds(600)
        details.highlight("a@example.com")
        details.highlight("b@example.com")
        details.reset()
        #expect(details.lookups == 0)
        #expect(calls.count == 0)
    }

    @Test func theLineHasTheSubjectAndAShortDate() throws {
        let details = RecentMailDetails()
        details.locale = Locale(identifier: "en_US_POSIX")
        details.timeZone = TimeZone(identifier: "UTC")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let october8 = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12)))
        details.now = { october8.addingTimeInterval(3 * 86_400) }
        #expect(details.line(row(subject: "Q4 budget", at: october8)) == "Last: Q4 budget · Oct 8")
        #expect(details.line(row(subject: " ", at: october8)) == "Last: (no subject) · Oct 8")
        let lastYear = details.line(row(subject: "Q4 budget", at: october8.addingTimeInterval(-365 * 86_400)))
        #expect(lastYear.contains("2025"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var emails: [String] = []
    func add(_ email: String) { lock.withLock { emails.append(email) } }
    var count: Int { lock.withLock { emails.count } }
}

@MainActor
@Suite struct SmartSearchModuleTests {
    @Test func savingTheShownSearchWithTheActionsAndThePalette() async throws {
        let f = OverlayFixture()
        await f.loaded()
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        search.text = "invoice"
        search.submit()
        #expect(search.canSaveShownSearch)
        #expect(f.registry.availability(.saveSearch, host: f.router) == .enabled)
        #expect(f.registry.availability(.deleteSavedSearch, host: f.router) == .hidden)
        #expect(await f.run(.saveSearch))
        await eventually { search.savedSearchNameDraft == "invoice" }
        await eventually { search.savedSummary == "Saved as invoice" }
        await search.commitSavedSearchName("Invoices")
        await eventually { search.savedSummary == "Saved as Invoices" }
        #expect(search.savedSearchNameDraft == nil)
        #expect(f.registry.availability(.saveSearch, host: f.router) == .hidden)

        #expect(await f.run(.commandPalette))
        let palette = try #require(f.palette)
        palette.query = "invoices"
        let entry = try #require(palette.entries.first { $0.title == "Go to saved search: Invoices" })
        #expect(entry.kind == .searchMail("invoice"))
        palette.perform(entry)
        #expect(f.router.active?.location == .search("invoice"))

        search.text = ""
        #expect(search.suggestions.first?.kind == .saved)
        #expect(search.suggestions.first?.title == "Invoices")

        #expect(f.registry.availability(.deleteSavedSearch, host: f.router) == .enabled)
        #expect(await f.run(.deleteSavedSearch))
        await eventually { search.savedSummary == nil && search.saved.searches.isEmpty }
    }

    @Test func theComposerGetsTheLookupOnlyWithTheModule() async throws {
        let on = OverlayFixture()
        await on.loaded()
        let session = try #require(on.env.compose.openNew(placement: .modal))
        let lookup = try #require(on.env.compose.recentMailLookup(for: session))
        let contact = try #require(try await on.store.contactSuggestions(session.account.id, prefix: "", limit: 1).first)
        let latest = try #require(await lookup(contact.email))
        let rows = try await on.store.recentThreads(involving: contact.email, account: session.account.id, limit: 1)
        #expect(latest.id == rows.first?.id)

        let off = OverlayFixture(flags: FeatureFlags().with(.smartSearch, false))
        await off.loaded()
        let offSession = try #require(off.env.compose.openNew(placement: .modal))
        #expect(off.env.compose.recentMailLookup(for: offSession) == nil)
    }

    @Test func theModuleOffLeavesSearchAsItWas() async throws {
        let f = OverlayFixture(flags: FeatureFlags().with(.smartSearch, false))
        await f.loaded()
        try await f.store.set(AppSettings.savedSearches(try #require(f.router.active?.id)),
                              [SavedSearch(name: "Bills", query: bills, createdAt: 1)])
        let search = f.center.search
        search.liveDelay = nil
        search.open()
        #expect(!search.smartSearchEnabled)
        #expect(!search.suggestions.contains { $0.kind == .saved })
        search.text = "invoice"
        search.submit()
        #expect(!search.canSaveShownSearch)
        #expect(search.savedSummary == nil)
        for id in [ActionID.saveSearch, .deleteSavedSearch, .goSavedSearch] {
            #expect(!f.registry.contains(id))
        }
        search.highlight(search.suggestions.first)
        #expect(search.recentMail.lookups == 0)
    }
}
