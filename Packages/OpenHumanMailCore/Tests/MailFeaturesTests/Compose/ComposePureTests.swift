import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private let work = Account(
    id: AccountID(1), email: "robin@example.com", displayName: "Robin Example", alias: "Work", health: .active,
    sendAs: [SenderIdentity(email: "robin@example.com", name: "Robin Example", isDefault: false, isPrimary: true,
                            signatureHTML: "<p>Robin</p>"),
             SenderIdentity(email: "robin@team.example", name: "Robin (Team)", isDefault: true, isPrimary: false,
                            signatureHTML: "<p>Team</p>"),
             SenderIdentity(email: "sales@example.com", name: "Sales", isDefault: false, isPrimary: false),
             SenderIdentity(email: "relay@other.example", name: "Relay", isDefault: false, isPrimary: false,
                            needsVerification: true)])

private func message(_ id: Int64, from: String, to: [String], cc: [String] = [], at offset: TimeInterval = 0) -> MessageSummary {
    MessageSummary(id: MessageKey(account: AccountID(1), rowID: id, gmailMessageID: GmailMessageID("m\(id)")),
                   from: EmailAddress(email: from), to: to.map { EmailAddress(email: $0) }, cc: cc.map { EmailAddress(email: $0) },
                   bcc: [], date: Date(timeIntervalSince1970: 1_791_000_000 + offset), snippet: "", isUnread: false,
                   attachments: [])
}

@Suite struct FromAddressTests {
    @Test func aliasesAreMeAndListedDefaultFirst() {
        #expect(work.isMe("ROBIN@team.example") && work.isMe("robin@example.com") && work.isMe("sales@example.com"))
        #expect(!work.isMe("dana@acme.example"))
        let ids = FromResolver.identities(of: work)
        #expect(ids.map(\.email) == ["robin@team.example", "robin@example.com", "sales@example.com", "relay@other.example"])
        #expect(ids[0].isGmailDefault && ids[1].isPrimary && ids[3].needsVerification)
        let bare = Account(id: AccountID(2), email: "me@home.example", displayName: "Me", alias: nil, health: .active)
        #expect(FromResolver.identities(of: bare).map(\.email) == ["me@home.example"])
    }

    @Test func newMailUsesTheDefaultSettingElseGmailsDefault() {
        #expect(FromResolver.forNew(account: work, defaultSetting: nil).0.email == "robin@team.example")
        #expect(FromResolver.forNew(account: work, defaultSetting: "Robin@Example.com").0.email == "robin@example.com")
        #expect(FromResolver.forNew(account: work, defaultSetting: "gone@example.com").0.email == "robin@team.example")
        #expect(FromResolver.forNew(account: work, defaultSetting: "relay@other.example").0.email == "robin@team.example")
        #expect(FromResolver.forNew(account: work, defaultSetting: nil).1 == .accountDefault)
    }

    @Test func repliesComeFromTheAddressTheOriginalWasSentTo() {
        let toSales = message(1, from: "dana@acme.example", to: ["ana@acme.example", "sales@example.com"])
        let (identity, reason) = FromResolver.forReply(account: work, policy: .addressSentTo, original: toSales,
                                                       thread: [toSales], remembered: nil, defaultSetting: "robin@example.com")
        #expect(identity.email == "sales@example.com" && reason == .sentToAlias)
        let ccPrimary = message(2, from: "dana@acme.example", to: ["ana@acme.example"], cc: ["ROBIN@example.com"])
        #expect(FromResolver.forReply(account: work, policy: .addressSentTo, original: ccPrimary, thread: [ccPrimary],
                                      remembered: nil, defaultSetting: nil).0.email == "robin@example.com")
        let mine = message(3, from: "sales@example.com", to: ["dana@acme.example"])
        #expect(FromResolver.forReply(account: work, policy: .addressSentTo, original: mine, thread: [mine],
                                      remembered: nil, defaultSetting: nil).0.email == "sales@example.com")
        let viaList = message(4, from: "dana@acme.example", to: ["team-list@acme.example"])
        let fallback = FromResolver.forReply(account: work, policy: .addressSentTo, original: viaList, thread: [viaList],
                                             remembered: nil, defaultSetting: "robin@example.com")
        #expect(fallback.0.email == "robin@example.com" && fallback.1 == .accountDefault)
    }

    @Test func anUnverifiedAliasIsNeverPickedAutomatically() {
        let toRelay = message(1, from: "dana@acme.example", to: ["relay@other.example"])
        let (identity, reason) = FromResolver.forReply(account: work, policy: .addressSentTo, original: toRelay,
                                                       thread: [toRelay], remembered: nil, defaultSetting: nil)
        #expect(identity.email == "robin@team.example" && reason == .accountDefault)
        let remembered = FromResolver.forReply(account: work, policy: .addressSentTo, original: toRelay, thread: [toRelay],
                                               remembered: "relay@other.example", defaultSetting: nil)
        #expect(remembered.0.email == "relay@other.example" && remembered.1 == .rememberedForThread)
    }

    @Test func thePoliciesForExistingEmails() {
        let first = message(1, from: "dana@acme.example", to: ["sales@example.com"], at: 0)
        let myReply = message(2, from: "robin@example.com", to: ["dana@acme.example"], at: 60)
        let latest = message(3, from: "dana@acme.example", to: ["sales@example.com"], at: 120)
        let thread = [first, myReply, latest]
        #expect(FromResolver.forReply(account: work, policy: .accountDefault, original: latest, thread: thread,
                                      remembered: nil, defaultSetting: nil).0.email == "robin@team.example")
        let last = FromResolver.forReply(account: work, policy: .lastUsedOnThread, original: latest, thread: thread,
                                         remembered: nil, defaultSetting: nil)
        #expect(last.0.email == "robin@example.com" && last.1 == .lastUsedOnThread)
        #expect(FromResolver.forReply(account: work, policy: .lastUsedOnThread, original: first, thread: [first],
                                      remembered: nil, defaultSetting: nil).0.email == "sales@example.com")
        #expect(FromResolver.forReply(account: work, policy: .accountDefault, original: latest, thread: thread,
                                      remembered: "Sales@Example.com", defaultSetting: nil).0.email == "sales@example.com")
    }

    @Test func rememberedChoicesAreCappedNewestLast() {
        var list: [ThreadFromChoice] = []
        for i in 0..<(ComposeSettings.maxRememberedThreads + 20) {
            list = ComposeSettings.remembering(ThreadFromChoice(thread: "t\(i)", email: "a@x.com"), in: list)
        }
        #expect(list.count == ComposeSettings.maxRememberedThreads)
        #expect(list.last?.thread == "t\(ComposeSettings.maxRememberedThreads + 19)")
        list = ComposeSettings.remembering(ThreadFromChoice(thread: "t100", email: "B@X.com"), in: list)
        #expect(list.filter { $0.thread == "t100" }.map(\.email) == ["b@x.com"] && list.last?.thread == "t100")
    }

    @Test func senderIdentityDecodesOlderValues() throws {
        let old = #"{"email":"a@x.com","isDefault":true,"isPrimary":true}"#
        let decoded = try JSONDecoder().decode(SenderIdentity.self, from: Data(old.utf8))
        #expect(decoded.email == "a@x.com" && !decoded.needsVerification)
        let round = try JSONDecoder().decode(SenderIdentity.self, from: JSONEncoder().encode(work.sendAs[3]))
        #expect(round == work.sendAs[3])
    }
}

@Suite struct SnippetTests {
    private var context: SnippetContext {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return SnippetContext(recipient: EmailAddress(name: "Dana Ruiz", email: "dana@acme.example"), myName: "Robin Example",
                              now: Date(timeIntervalSince1970: 1_791_000_000), calendar: calendar,
                              locale: Locale(identifier: "en_US_POSIX"))
    }

    @Test func builtInsDefaultsAndUnresolvedVariables() {
        let text = "Hi {{first_name}} {{last_name}} ({{full_name}}), from {{my_name}}: {{project}} / {{topic}}."
        let expansion = SnippetExpander.expand(text, variables: [SnippetVariableInfo(name: "topic", defaultValue: "budget")],
                                               context: context)
        #expect(expansion.text == "Hi Dana Ruiz (Dana Ruiz), from Robin Example: project / budget.")
        #expect(expansion.unresolved.count == 1)
        let u = Array(expansion.text.utf16)
        let range = expansion.unresolved[0]
        #expect(String(decoding: u[range], as: UTF16.self) == "project")
    }

    @Test func datesEscapesAndInvalidNames() {
        let expansion = SnippetExpander.expand("By {{date+3}}, not {{date-1}}. \\{{literal}} {{Bad}} {{a-b}} {{}} {{x", context: context)
        #expect(expansion.text.hasPrefix("By Tue, Oct 6, 2026, not Fri, Oct 2, 2026."), "\(expansion.text)")
        #expect(expansion.text.hasSuffix(" {{literal}} {{Bad}} {{a-b}} {{}} {{x"))
        #expect(expansion.unresolved.isEmpty)
        #expect(SnippetExpander.isValidName("first_name") && SnippetExpander.isValidName("date+30"))
        #expect(!SnippetExpander.isValidName("1st") && !SnippetExpander.isValidName("date+") && !SnippetExpander.isValidName("date+99999"))
        #expect(SnippetExpander.variableNames(in: "{{a}} {{b}} {{a}} \\{{c}}") == ["a", "b"])
    }

    @Test func aRecipientWithoutANameUsesTheAddress() {
        var c = context
        c.recipient = EmailAddress(email: "dana.ruiz@acme.example")
        #expect(SnippetExpander.expand("Hi {{first_name}}{{last_name}}", context: c).text == "Hi Dana" + "last_name")
        c.recipient = EmailAddress(name: "Ruiz, Dana", email: "dana@acme.example")
        #expect(SnippetExpander.expand("{{first_name}} {{last_name}}", context: c).text == "Dana Ruiz")
    }

    @Test func theTriggerRule() {
        let shortcuts: Set<String> = ["thx", "intro"]
        #expect(SnippetTrigger.detect(in: "Hi ;;", caret: 5, shortcuts: shortcuts) == .openPicker(range: 3..<5, query: ""))
        #expect(SnippetTrigger.detect(in: ";;", caret: 2, shortcuts: shortcuts) == .openPicker(range: 0..<2, query: ""))
        #expect(SnippetTrigger.detect(in: "a;;", caret: 3, shortcuts: shortcuts) == nil, "only at a word start")
        #expect(SnippetTrigger.detect(in: "Hi ;;;", caret: 6, shortcuts: shortcuts) == nil)
        #expect(SnippetTrigger.detect(in: "Hi ;;thx ", caret: 9, shortcuts: shortcuts) == .expand(range: 3..<9, shortcut: "thx"))
        #expect(SnippetTrigger.detect(in: "Hi ;;THX\t", caret: 9, shortcuts: shortcuts) == .expand(range: 3..<9, shortcut: "thx"))
        #expect(SnippetTrigger.detect(in: "Hi ;;nope ", caret: 10, shortcuts: shortcuts) == nil, "unknown shortcut: a space")
        #expect(SnippetTrigger.detect(in: "x;;thx ", caret: 7, shortcuts: shortcuts) == nil)
        #expect(SnippetTrigger.pendingQuery(in: "Hi ;;in", caret: 7)?.query == "in")
        #expect(SnippetTrigger.pendingQuery(in: "Hi ;;in", caret: 7)?.range == 3..<7)
        #expect(SnippetTrigger.pendingQuery(in: "Hi ;;in x", caret: 9) == nil, "typed past it")
    }

    @MainActor
    @Test func thePickerFiltersRanksAndChooses() {
        let corpus = FakeCorpus.small
        var chosen: [String] = []
        var closed = 0
        let picker = SnippetPickerModel(snippets: corpus.snippets, onChoose: { chosen.append($0.name) }, onClose: { closed += 1 })
        #expect(picker.rows.map(\.snippet.name) == ["Thanks", "Follow up", "Intro"], "by use count")
        #expect(picker.rows.first?.preview == "Thanks, {{first_name}}! I'll take a look today.")
        picker.query = "intro"
        #expect(picker.rows.map(\.snippet.name) == ["Intro"])
        picker.query = "update"
        #expect(picker.rows.map(\.snippet.name) == ["Follow up"], "matches the body")
        picker.query = ""
        picker.moveCursor(by: 1)
        picker.confirm()
        #expect(chosen == ["Follow up"])
        picker.close()
        #expect(closed == 0, "a chosen picker is already closed")
        #expect(SnippetPickerModel(snippets: [], onChoose: { _ in }).isEmpty)
    }
}

@Suite struct RecipientTests {
    @Test func parsingAndValidation() {
        let parsed = RecipientParser.parse("Dana Ruiz <dana@acme.example>, \"Lee, Sam\" <sam@acme.example>; bo@x.io\nmailto:al@y.org")
        #expect(parsed.map(\.email) == ["dana@acme.example", "sam@acme.example", "bo@x.io", "al@y.org"])
        #expect(parsed.map(\.name) == ["Dana Ruiz", "Lee, Sam", nil, nil])
        #expect(RecipientParser.isValid("dana@acme.example"))
        for bad in ["dana", "dana@", "@acme.example", "dana@acme", "da na@acme.example", "dana@acme..com", "a@b@c.com", "x@.com"] {
            #expect(!RecipientParser.isValid(bad), "\(bad)")
        }
    }

    @MainActor
    @Test func theFieldTurnsTextIntoTokensAndSuggests() async {
        let field = RecipientFieldModel(kind: .to, debounce: .zero) { prefix in
            [EmailAddress(name: "Dana Ruiz", email: "dana@acme.example"), EmailAddress(email: "dan@x.io")]
                .filter { $0.email.hasPrefix(prefix) }
        }
        var changes = 0
        field.onChange = { _ in changes += 1 }
        field.text = "da"
        await field.settle()
        #expect(field.suggestions.map(\.email) == ["dana@acme.example", "dan@x.io"])
        field.moveSuggestion(by: 1)
        #expect(field.commit())
        #expect(field.tokens.map(\.email) == ["dan@x.io"] && field.text.isEmpty && field.suggestions.isEmpty)
        field.text = "a@b.com, not valid, c@d.org"
        #expect(field.tokens.map(\.email) == ["dan@x.io", "a@b.com", "not valid"])
        #expect(field.text == "c@d.org")
        #expect(field.commitText())
        #expect(field.invalidTokens.map(\.email) == ["not valid"])
        field.removeLast()
        field.remove(EmailAddress(email: "a@b.com"))
        #expect(field.tokens.map(\.email) == ["dan@x.io", "not valid"])
        #expect(changes == 5)
        field.text = "DAN@x.io,"
        #expect(field.tokens.count == 2)
    }

    @MainActor
    @Test func escapeClosesTheSuggestionsAndAPointerChoosesARow() async {
        let field = RecipientFieldModel(kind: .to, debounce: .zero) { _ in
            [EmailAddress(name: "Dana Ruiz", email: "dana@acme.example"), EmailAddress(email: "dan@x.io")]
        }
        field.text = "da"
        await field.settle()
        field.selectSuggestion(1)
        #expect(field.suggestionCursor == 1)
        field.selectSuggestion(7)
        #expect(field.suggestionCursor == 1, "a row that isn't there changes nothing")
        field.dismissSuggestions()
        #expect(field.suggestions.isEmpty && field.suggestionCursor == 0 && field.text == "da")
        #expect(field.commit() && field.tokens.map(\.email) == ["da"], "Return after Escape adds the typed text")
        field.text = "d"
        await field.settle()
        #expect(field.suggestions.count == 2, "typing again looks people up again")
    }
}

@Suite struct QuoteSplitTests {
    @Test func splitsAtTheEnginesMarkerOnce() {
        let quote = "<div class=\"gmail_quote\" data-oh-quote=\"1\"><div dir=\"ltr\" class=\"gmail_attr\">On Oct 1, Dana &lt;dana@acme.example&gt; wrote:<br></div><blockquote>Hi</blockquote></div>"
        let html = "<div dir=\"auto\"><p>Thanks</p></div>" + quote
        let split = QuoteSplit.splitHTML(html)
        #expect(split.own == "<div dir=\"auto\"><p>Thanks</p></div>")
        #expect(split.quote == quote)
        #expect(QuoteSplit.quoteBlockCount(html) == 1)
        #expect(QuoteSplit.splitHTML("<p>no quote</p>") == ("<p>no quote</p>", ""))
        let text = "Thanks\n\nOn Oct 1, Dana <dana@acme.example> wrote:\n> Hi"
        #expect(QuoteSplit.splitText(text, quoteHTML: quote, ownText: "Thanks") == "On Oct 1, Dana <dana@acme.example> wrote:\n> Hi")
        #expect(QuoteSplit.splitText("Thanks\n\nOn 2026, dana wrote:\n> Hi", quoteHTML: "<div class=\"gmail_quote\" data-oh-quote=\"1\">x</div>",
                                     ownText: "Thanks") == "On 2026, dana wrote:\n> Hi")
        #expect(QuoteSplit.joinText(own: "", quote: "Q") == "\n\nQ")
        #expect(QuoteSplit.joinText(own: "Hi\n", quote: "Q") == "Hi\n\nQ")
        #expect(QuoteSplit.joinText(own: "Hi", quote: "") == "Hi")
    }
}
