import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct AskModelTests {
    static let claude = AIProviderID.agentClaude
    static let consented = AISettings(consents: [claude: ProviderConsent(grantedAt: fixedNow, fingerprint: "/opt/bin/claude")])

    static func remote() -> ScriptedProvider {
        ScriptedProvider(id: claude, displayName: "Claude Code", capabilities: .remote(), consentFingerprint: "/opt/bin/claude")
    }

    static func citing(_ pick: @escaping @Sendable ([String]) -> [String] = { Array($0.prefix(1)) }) -> ScriptedProvider {
        ScriptedProvider { request, _ in
            let ids = request.untrusted.filter { $0.kind == .excerpt }.map(\.id)
            return .text("Here is the answer.\nSources: \(pick(ids).joined(separator: ", "))", chunkSize: 5)
        }
    }

    @Test func cmdJOpensAskAIOutsideTheComposerAndClosesOnTheSecondPress() async throws {
        let f = AskFixture()
        await f.loaded()
        #expect(f.env.actions.availability(.aiAskInbox, host: f.router) == .enabled)
        #expect(f.env.actions.descriptor(.aiAskInbox)?.shortcutHint == "⌘J")
        #expect(await f.run(.aiAskInbox))
        #expect(f.isAskShown && f.model.isPresented)
        #expect(f.model.scopes == [.account(AskFixture.work), .allAccounts])
        #expect(f.model.scope == .account(AskFixture.work) && f.model.scopeTitle == "Work")
        #expect(f.model.footer == AskWording.footerIdle)
        #expect(await f.run(.aiAskInbox))
        #expect(!f.isAskShown && !f.model.isPresented, "⌘J again closes it")

        let session = try #require(f.env.compose.openNew(placement: .modal))
        #expect(f.env.actions.availability(.aiAskInbox, host: session) == .hidden)
        #expect(f.env.actions.availability(.aiRewrite, host: session) == .enabled)
    }

    @Test func askAIIsAbsentWithoutAIOrWithTheModuleOffAndChangesNoMail() async throws {
        let none = AskFixture(withAI: false)
        await none.loaded()
        #expect(none.env.actions.availability(.aiAskInbox, host: none.router) == .hidden)
        #expect(await none.run(.aiAskInbox) == false, "the key passes on")

        let off = AskFixture(flags: FeatureFlags().with(.ai, false))
        await off.loaded()
        #expect(off.env.actions.availability(.aiAskInbox, host: off.router) == .hidden)

        let f = AskFixture()
        await f.loaded()
        #expect(f.env.actions.availability(.aiAskInbox, host: f.router) == .enabled)
        let before = try await f.store.threadPage(.system(.inbox), account: AskFixture.work, after: nil, limit: 1_000).rows
        await f.ask("offsite planning")
        #expect(f.model.phase == .done)
        let after = try await f.store.threadPage(.system(.inbox), account: AskFixture.work, after: nil, limit: 1_000).rows
        #expect(after == before, "asking changes no mail")
        #expect(f.env.undo?.stack.isEmpty == true && f.store.sentMessages.isEmpty)
    }

    @Test func anAnswerStreamsWithItsSourcesInCitationOrder() async throws {
        let provider = Self.citing { ids in Array(ids.dropFirst().prefix(1)) + Array(ids.prefix(1)) + ["nope.1"] }
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.ask("When is the offsite planning review?")
        let model = f.model
        #expect(model.phase == .done)
        #expect(model.answer.hasPrefix("Here is the answer."))
        #expect(!model.answer.contains("Sources:"), "the sources line is parsed and hidden")

        let request = try #require(provider.requests.first)
        #expect(RequestInspector.problems(in: request).isEmpty, "email text only inside the delimiters")
        #expect(request.trusted.first == TrustedPart(kind: .userQuestion, text: "When is the offsite planning review?"))
        let ids = request.untrusted.filter { $0.kind == .excerpt }.map(\.id)
        try #require(ids.count >= 2)
        let retrieval = try #require(model.lastRetrieval)
        let second = try #require(retrieval.sources[ids[1]])
        let first = try #require(retrieval.sources[ids[0]])
        #expect(model.sources == (second.thread == first.thread ? [second] : [second, first]),
                "citation order, one row per conversation, an id that was not sent is dropped")
        #expect(Set(model.otherMatches.map(\.thread)).isDisjoint(with: model.sources.map(\.thread)))
        #expect(model.otherMatches.count <= AskModel.otherMatchesMax)
        #expect(model.visibleOtherMatches.count <= AskModel.otherMatchesShown)
        #expect(model.badge?.title == "On this Mac")
        #expect(model.planLine?.hasPrefix("Searched Work for “offsite planning review”") == true)
        #expect(model.readyAnnouncement == AskWording.ready(sources: model.sources.count))
        #expect(model.footer == AskWording.footerDone)
        #expect(model.spokenLabel(.source(model.sources[0])).hasPrefix("Source 1 of \(model.sources.count): "))
        #expect(f.center.activity.entries.count == 1, "one request, numbers only in the activity log")

        #expect(model.moveDown() && model.cursor == 0)
        #expect(model.moveUp() && model.cursor == nil, "↑ on the first row returns to the field")
        if model.hiddenOtherMatchCount > 0 {
            let hidden = model.hiddenOtherMatchCount
            model.activate(.showMore(hidden))
            #expect(model.hiddenOtherMatchCount == 0 && model.visibleOtherMatches.count == model.otherMatches.count)
        }
    }

    @Test func nothingRetrievedMeansNoRequestAndNoWordsMeansNoSearch() async throws {
        let provider = ScriptedProvider()
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.ask("zebra quokka xylophone")
        #expect(f.model.phase == .notFound)
        #expect(f.model.statusText == "No mail on this Mac matches “zebra quokka xylophone”.")
        #expect(provider.requests.isEmpty, "nothing can be invented from nothing")
        #expect(f.model.rows.isEmpty)

        let searches = f.source.searches.count
        await f.ask("is it so?")
        #expect(f.model.phase == .notFound && f.model.statusText == AskWording.tooFewWords)
        #expect(f.source.searches.count == searches && provider.requests.isEmpty)
    }

    @Test func thisConversationAnswersFromItsOwnMessagesOnly() async throws {
        let provider = Self.citing()
        let f = AskFixture(providers: [provider])
        await f.loaded()
        let detail = try await f.conversation(matching: "hiring loop")
        f.router.open(detail.id)
        await eventually { f.router.reader?.state == .loaded }
        await f.run(.aiAskInbox)
        let conversation = AskModel.Scope.conversation(detail.id)
        #expect(f.model.scopes == [.account(AskFixture.work), .allAccounts, conversation])
        #expect(f.model.scope == .account(AskFixture.work), "this account by default in a conversation (open question 2)")
        f.model.cycleScope(by: 1)
        #expect(f.model.scope == .allAccounts && f.model.scopeTitle == "All accounts")
        f.model.cycleScope(by: 1)
        #expect(f.model.scope == conversation && f.model.scopeTitle == "This conversation")
        f.model.cycleScope(by: 1)
        #expect(f.model.scope == .account(AskFixture.work), "⇥ wraps around")
        f.model.cycleScope(by: -1)
        #expect(f.model.scope == conversation, "⇧⇥ goes back")

        await f.ask("what did we decide?")
        #expect(f.model.phase == .done)
        let request = try #require(provider.requests.first)
        let ids = Set(detail.messages.map { AIThreadLoader.messageKey($0.id) })
        #expect(!request.untrusted.isEmpty && request.untrusted.allSatisfy { ids.contains($0.id) },
                "only that conversation's messages")
        #expect(f.source.searches.isEmpty, "no search")
        #expect(f.model.planLine?.hasPrefix("Read “") == true)
        #expect(!f.model.canShowAsList)
    }

    @Test func allAccountsFailsClosedForAnOnDeviceOnlyAccountAndASwitchClosesTheCard() async throws {
        let claude = Self.remote()
        var settings = Self.consented
        settings.featurePins[.askInbox] = Self.claude
        let f = AskFixture(providers: [claude, ScriptedProvider()], settings: settings)
        await f.loaded()
        let work = try #require(f.router.accounts.first { $0.id == AskFixture.work }?.account)
        try f.center.setOnDeviceOnly(true, account: work)
        await f.run(.aiAskInbox)
        f.model.select(.allAccounts)
        await f.ask("offsite planning")
        #expect(f.model.phase == .failed(.onDeviceOnly))
        #expect(f.model.statusText == "One of your accounts allows on-device AI only.")
        f.model.select(.account(AskFixture.work))
        await f.ask("offsite planning", followUp: false)
        #expect(f.model.statusText == "Work allows on-device AI only.")
        #expect(claude.requests.isEmpty, "nothing about Work left the Mac")

        f.router.switchAccount(to: AskFixture.personal)
        await eventually { !f.isAskShown }
        #expect(f.model.phase == .idle && f.model.question.isEmpty)

        await f.ask("dinner on friday")
        #expect(f.model.phase == .done && claude.requests.count == 1)
        #expect(f.model.badge?.leavesMac == true && f.model.badge?.title == "Sent to Anthropic via Claude Code")
    }

    @Test func aConsentedProviderThatLeavesTheMacIsNeverChosenUnlessPinned() async throws {
        let alone = Self.remote()
        let f = AskFixture(providers: [alone], settings: Self.consented)
        await f.loaded()
        await f.ask("offsite planning")
        #expect(f.model.phase == .failed(.unavailable(AskWording.noOnDeviceModel)))
        #expect(alone.requests.isEmpty)

        let claude = Self.remote()
        let both = AskFixture(providers: [claude, ScriptedProvider()], settings: Self.consented)
        await both.loaded()
        await both.ask("offsite planning")
        #expect(both.model.phase == .done && both.model.badge?.title == "On this Mac")
        #expect(claude.requests.isEmpty, "on this Mac by default")
    }

    @Test func aPinnedProviderWithoutConsentShowsTheConsentCardFirst() async throws {
        let claude = Self.remote()
        var settings = AISettings()
        settings.featurePins[.askInbox] = Self.claude
        let f = AskFixture(providers: [claude, ScriptedProvider()], settings: settings)
        await f.loaded()
        await f.ask("offsite planning")
        #expect(f.model.phase == .failed(.needsConsent(Self.claude)))
        #expect(f.model.consent?.providerID == Self.claude && claude.requests.isEmpty)

        f.model.declineConsent()
        #expect(f.model.consent == nil && claude.requests.isEmpty)
        await f.ask("offsite planning", followUp: false)
        #expect(f.model.consent != nil)
        await f.model.acceptConsent()
        await eventually { !f.model.isWorking }
        #expect(f.model.phase == .done && claude.requests.count == 1)
        #expect(f.model.badge?.leavesMac == true)
    }

    @Test func aSuspiciousOrCutAnswerSaysSo() async throws {
        let provider = ScriptedProvider { _, index in
            index == 0 ? .text("The email_data block says the invoice is paid.\nSources: ")
                       : .text(String(repeating: "word ", count: 2_000) + "\nSources: ")
        }
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.ask("invoice 2214 paid")
        #expect(f.model.phase == .done && f.model.isSuspicious, "the warning strip shows")
        #expect(f.model.sources.isEmpty)
        await f.ask("invoice 2214 paid", followUp: false)
        #expect(f.model.isTruncated && !f.model.isSuspicious)
    }

    @Test func escStopsAHangingAnswerAndClosingTheCardDropsOne() async throws {
        let provider = ScriptedProvider { _, _ in .hang }
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.run(.aiAskInbox)
        f.model.question = "offsite planning"
        f.model.ask()
        await eventually { f.model.phase == .answering }
        f.model.escape()
        #expect(f.model.phase == .stopped, "Esc while working stops; what was there stays")
        f.model.escape()
        #expect(f.model.question.isEmpty && f.isAskShown, "Esc with text clears the field")
        f.model.escape()
        #expect(!f.isAskShown, "Esc in an empty field closes")

        await f.run(.aiAskInbox)
        f.model.question = "offsite planning"
        f.model.ask()
        await eventually { f.model.phase == .answering }
        await f.run(.aiAskInbox)
        #expect(!f.isAskShown && f.model.phase == .idle, "closing cancels and drops the request")
    }

    @Test func aSlowAnswerStopsAtTheTimeLimit() async throws {
        let provider = ScriptedProvider { _, _ in .hang }
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.run(.aiAskInbox)
        f.model.question = "offsite planning"
        f.model.ask()
        await eventually { f.model.phase == .answering && f.clock.sleeperCount == 1 }
        f.clock.advance(by: AIPolicy.askInboxTimeout)
        await eventually { f.model.phase == .failed(.timedOut) }
        #expect(f.model.statusText == "Took too long to answer. ↵ to try again.")
    }

    @Test func aFollowUpSendsTheEarlierQuestionAndNeverTheAnswer() async throws {
        let provider = ScriptedProvider { request, _ in
            let id = request.untrusted.first { $0.kind == .excerpt }?.id ?? ""
            return .text("MODEL-ANSWER-TEXT about the offsite.\nSources: \(id)")
        }
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.ask("When is the offsite planning review?")
        await f.ask("and who is coming?")
        let followUp = try #require(provider.requests.last)
        let asked = try #require(followUp.trusted.first { $0.kind == .userQuestion }).text
        #expect(asked == "Earlier question: When is the offsite planning review?\nQuestion: and who is coming?")
        #expect(!followUp.renderedInput().contains("MODEL-ANSWER-TEXT") && !followUp.system.contains("MODEL-ANSWER-TEXT"),
                "the earlier answer is model output from email: never sent back")
        #expect(f.model.planLine == "Following up on: When is the offsite planning review?")
        #expect(f.source.searches.contains { $0.query == "coming offsite planning review" }, "both questions' words")

        let before = provider.requests.count
        await f.ask("and who is coming to the offsite?", followUp: false)
        #expect(provider.requests.count == before + 1)
        #expect(provider.requests.last?.trusted.first { $0.kind == .userQuestion }?.text
            == "and who is coming to the offsite?")
        await f.ask("what else did they say about the budget for the team dinner")
        #expect(provider.requests.last?.trusted.first { $0.kind == .userQuestion }?.text
            == "what else did they say about the budget for the team dinner")

        f.model.question = ""
        #expect(f.model.moveUp() && f.model.question == "what else did they say about the budget for the team dinner")
        #expect(f.model.moveUp() && f.model.question == "and who is coming to the offsite?")
        #expect(f.model.moveUp() && f.model.question == "and who is coming?")
        #expect(f.model.moveUp() && f.model.question == "When is the offsite planning review?")
    }

    @Test func nothingIsWrittenAnywhere() async throws {
        let navigation = InMemoryNavigationStore()
        let f = AskFixture(navigationStore: navigation)
        await f.loaded()
        await f.ask("When does the zanzibarian offsite planning start?")
        #expect(f.model.phase == .done)
        f.router.persist()
        let saved = String(decoding: try JSONEncoder().encode(navigation.load()), as: UTF8.self)
        #expect(!saved.contains("zanzibarian"), "not in the restoration snapshot")
        #expect(!String(describing: UserDefaults.standard.dictionaryRepresentation()).contains("zanzibarian"))
        #expect(!String(describing: f.center.activity.entries).contains("zanzibarian"), "the activity log holds numbers only")
        #expect(!String(describing: f.center.settings).contains("zanzibarian"))
    }

    @Test func aSourceOpensItsConversationAtThatMessageAndTheAnswerComesBack() async throws {
        let f = AskFixture(providers: [Self.citing()])
        await f.loaded()
        await f.ask("offsite planning")
        let source = try #require(f.model.sources.first)
        #expect(f.model.moveDown() && f.model.cursor == 0)
        f.model.submit()
        #expect(!f.isAskShown)
        await eventually { f.router.reader?.focusedMessage == source.id && f.router.reader?.focusChosen == true }
        #expect(f.router.reader?.thread == source.thread)

        await f.run(.aiAskInbox)
        #expect(f.model.phase == .done && f.model.sources.first == source)
        #expect(f.model.askedAtText?.hasPrefix("Asked at ") == true)
        f.model.close()

        f.clock.advance(by: .seconds(31 * 60))
        await f.run(.aiAskInbox)
        #expect(f.model.phase == .idle && f.model.sources.isEmpty && f.model.question.isEmpty)
    }

    @Test func showAsListShowsTheSearchBehindTheAnswerAndCopyCopiesIt() async throws {
        let f = AskFixture()
        await f.loaded()
        await f.ask("When is the offsite planning review?")
        f.model.copyAnswer()
        #expect(f.pasteboard.copied == [f.model.answer])
        await eventually { f.env.notices.toasts.contains { $0.message == "Answer copied" } }
        #expect(f.model.canShowAsList)
        f.model.showAsList()
        #expect(!f.isAskShown)
        #expect(f.router.location == .search("offsite OR planning OR review"))
        #expect(f.router.active?.searchOpen == true && f.router.active?.searchText == "offsite OR planning OR review")
    }

    @Test func thePaletteOffersAskAIForAQuestion() async throws {
        let f = AskFixture()
        await f.loaded()
        await f.run(.commandPalette)
        guard case .palette(let palette) = f.overlays.overlay else {
            Issue.record("no palette")
            return
        }
        palette.query = "when is the offsite?"
        let row = try #require(palette.entries.first { $0.kind == .askAI("when is the offsite?") })
        #expect(row.title == "Ask AI: “when is the offsite?”" && row.group == .ask)
        palette.query = "star"
        #expect(!palette.entries.contains { if case .askAI = $0.kind { true } else { false } }, "a command is no question")
        palette.query = "when is the offsite planning?"
        let ask = try #require(palette.entries.first { if case .askAI = $0.kind { true } else { false } })
        #expect(palette.perform(ask))
        #expect(f.isAskShown && f.model.question == "when is the offsite planning?")
        await eventually { !f.model.isWorking }
        #expect(f.model.phase == .done)
    }

    @Test func cmdJInTheSearchFieldAsksAboutTheTypedText() async throws {
        let f = AskFixture()
        await f.loaded()
        let search = f.overlays.search
        search.liveDelay = nil
        search.open()
        #expect(!search.askAI(), "an empty field: the key goes on")
        search.text = "offsite planning budget"
        #expect(search.askAI())
        #expect(f.isAskShown && f.model.question == "offsite planning budget")
        await eventually { !f.model.isWorking }
        #expect(f.model.phase == .done)
    }

    @Test func aQuestionWithACueWordIsPlannedFromTheQuestionAlone() async throws {
        let planner = RecordingPlanner(AskPlan(query: "subject:offsite", chips: ["“offsite”"], semanticText: "the offsite"))
        let f = AskFixture(planner: planner)
        await f.loaded()
        await f.ask("anything about the offsite since last week?")
        #expect(planner.questions == ["anything about the offsite since last week?"], "the planner sees only the question")
        #expect(f.source.searches.map(\.query) == ["subject:offsite"])
        #expect(f.source.searches.first?.semanticText == "the offsite")
        #expect(f.model.planLine?.hasPrefix("Searched Work: “offsite” · ") == true)

        await f.ask("offsite planning budget", followUp: false)
        #expect(planner.questions.count == 1, "no cue word: the planner is skipped")
    }

    @Test func theOlderMailRowAsksGmailOnlyWhenPressed() async throws {
        let provider = Self.citing()
        let f = AskFixture(providers: [provider])
        await f.loaded()
        await f.ask("zebra quokka")
        #expect(f.model.olderMail == nil && !f.model.rows.contains(.olderMail), "the local answer was complete")

        f.source.olderMailMissing(searchedBack: Date(timeIntervalSince1970: 1_709_300_000))
        await f.ask("zebra quokka", followUp: false)
        #expect(f.model.phase == .notFound && f.model.rows == [.olderMail])
        #expect(f.model.olderMailText == "Search Gmail for older mail (before Mar 2024)")
        #expect(f.source.gmailCalls.isEmpty, "never on its own")

        let rows = try await f.store.threadPage(.system(.inbox), account: AskFixture.work, after: nil, limit: 30).rows
        f.source.gmailFinds(rows.map(\.id))
        #expect(f.model.moveDown() && f.model.cursor == 0)
        f.model.submit()
        await eventually { !f.model.isWorking }
        #expect(f.source.gmailCalls == [.init(query: "zebra quokka", account: AskFixture.work, maxResults: 20)])
        #expect(f.source.bodyReads.count <= MailAskRetriever.olderMailBodies)
        #expect(f.model.phase == .done && f.model.olderMail == .done && !f.model.rows.contains(.olderMail))
        #expect(provider.requests.count == 1)
        f.model.searchOlderMail()
        #expect(f.source.gmailCalls.count == 1, "never repeated without a new question")
    }

    @Test func offlineTheOlderMailRowIsDisabled() async throws {
        let f = AskFixture(liveConnectivity: true)
        await f.loaded()
        let status = Task { await f.env.status.run() }
        defer { status.cancel() }
        f.store.setOffline(true)
        await eventually {
            if case .offline? = f.env.status.connectivity[AskFixture.work] { true } else { false }
        }
        f.source.olderMailMissing(searchedBack: nil)
        await f.ask("zebra quokka")
        #expect(f.model.olderMail == .offline && !f.model.olderMailEnabled)
        #expect(f.model.olderMailText == "Offline: only mail on this Mac was searched.")
        f.model.searchOlderMail()
        #expect(f.source.gmailCalls.isEmpty)
    }

    @Test func askAICodeLogsNothingAndWritesNothing() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = package.appendingPathComponent("Sources/MailFeatures/AI/Ask")
        var files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        files.append(package.appendingPathComponent("../OpenHumanMailUI/Sources/MailUI/AI/AskPanelView.swift"))
        #expect(files.count >= 5, "found the Ask sources")
        let forbidden = [#"\bLog\("#, #"\bprint\("#, #"os_log"#, #"NSLog"#, #"UserDefaults"#, #"FileManager"#,
                         #"\.write\("#, #"\.send\("#, #"sendNow"#, #"scheduleSend"#, #"\.commands"#, #"createDraft"#,
                         #"updateDraft"#, #"\.apply\("#, #"MailCommanding"#]
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
                .joined(separator: "\n")
            for pattern in forbidden {
                let regex = try NSRegularExpression(pattern: pattern)
                let found = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
                #expect(!found, "\(file.lastPathComponent) matches \(pattern)")
            }
        }
    }
}
