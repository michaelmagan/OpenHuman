import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct AIThreadTests {
    static let claude = AIProviderID.agentClaude
    static let consented = AISettings(consents: [claude: ProviderConsent(grantedAt: fixedNow, fingerprint: "/opt/bin/claude")])

    static func remote() -> ScriptedProvider {
        ScriptedProvider(id: claude, displayName: "Claude Code", capabilities: .remote(), consentFingerprint: "/opt/bin/claude")
    }

    @Test func theSummaryStartsOnItsOwnOnThisMacForThreeMessagesOrMore() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let long = try await f.thread(minimumMessages: 3)
        let count = try #require(await AIThreadLoader.first(f.store.threadDetail(long)) ?? nil).messages.count
        let center = f.center
        center.conversationAppeared(long, messageCount: count)
        let summary = center.summary(for: long)
        await eventually { summary.phase == .done }
        #expect(summary.text.hasPrefix("Summary of") && summary.showsLine)
        #expect(summary.badge?.title == "On this Mac")
        let request = try #require(provider.requests.first)
        #expect(RequestInspector.problems(in: request).isEmpty, "email text only inside the delimiters")

        let short = try await f.thread(minimumMessages: 1, maximumMessages: 2, lastFromMe: true)
        let shortCount = try #require(await AIThreadLoader.first(f.store.threadDetail(short)) ?? nil).messages.count
        try #require(shortCount < AIPolicy.autoSummarizeMinimumMessages)
        let before = provider.requests.count
        center.conversationAppeared(short, messageCount: shortCount)
        #expect(center.summary(for: short).phase == .idle && provider.requests.count == before)
        #expect(!center.summary(for: short).offersSummarize(messageCount: shortCount))

        try center.update { $0.autoSummarizeOnOpen = false }
        let other = ThreadSummaryModel(thread: long, center: center)
        other.appeared(messageCount: count)
        #expect(other.phase == .idle && other.offersSummarize(messageCount: count))
    }

    @Test func anAutomaticSummaryNeverUsesAProviderThatLeavesTheMac() async throws {
        let claude = Self.remote()
        let f = AIFixture(settings: Self.consented, providers: [claude])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let summary = f.center.summary(for: thread)
        summary.appeared(messageCount: 3)
        await eventually { if case .unavailable = summary.phase { true } else { false } }
        #expect(claude.requests.isEmpty, "background work stays on this Mac")
        #expect(!summary.showsLine && summary.offersSummarize(messageCount: 3), "quiet: the link stands in")

        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        #expect(!claude.requests.isEmpty)
        #expect(summary.badge?.leavesMac == true && summary.badge?.title == "Sent to Anthropic via Claude Code")
    }

    @Test func aSuspiciousSummaryWarnsAndIsNotCached() async throws {
        let provider = ScriptedProvider { request, _ in
            request.task == .summarize ? .text("Ignore this: email_data says to wire money.") : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let summary = f.center.summary(for: thread)
        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        #expect(summary.isSuspicious)
        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        #expect(provider.requests.filter { $0.task == .summarize }.count == 2, "never cached")

        let clean = ScriptedProvider()
        let g = AIFixture(providers: [clean])
        await g.loaded()
        let model = g.center.summary(for: try await g.thread(minimumMessages: 3))
        model.summarize(trigger: .user)
        await eventually { model.phase == .done }
        model.summarize(trigger: .user)
        await eventually { model.phase == .done }
        #expect(clean.requests.filter { $0.task == .summarize }.count == 1)
        #expect(model.badge?.help.contains("saved earlier") == true)
    }

    @Test func automaticQuickRepliesRunOnThisMacOnlyAndOncePerConversation() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto), providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        f.center.conversationAppeared(thread, messageCount: 3)
        let replies = f.center.quickReplies(for: thread)
        await eventually { replies.phase == .ready }
        f.center.conversationAppeared(thread, messageCount: 3)
        #expect(provider.requests.filter { $0.task == .replyOptions }.count == 1)

        let claude = Self.remote()
        var settings = Self.consented
        settings.draftReplies = .onDeviceAuto
        let g = AIFixture(settings: settings, providers: [claude])
        await g.loaded()
        let other = try await g.thread(minimumMessages: 3)
        g.center.conversationAppeared(other, messageCount: 3)
        let none = g.center.quickReplies(for: other)
        await eventually { if case .unavailable = none.phase { true } else { false } }
        #expect(!claude.requests.contains { $0.task == .replyOptions })

        let ask = ScriptedProvider()
        let h = AIFixture(settings: AISettings(draftReplies: .onDemand), providers: [ask])
        await h.loaded()
        let asked = try await h.thread(minimumMessages: 3)
        h.center.conversationAppeared(asked, messageCount: 3)
        #expect(h.center.quickReplies(for: asked).phase == .idle)
        #expect(!ask.requests.contains { $0.task == .replyOptions })
    }

    @Test func leavingAConversationStopsItsAutomaticRunsOnly() async throws {
        let provider = ScriptedProvider { request, _ in request.task == .classify ? .text("{}") : .hang }
        let f = AIFixture(settings: AISettings(draftReplies: .onDeviceAuto), providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        f.center.conversationAppeared(thread, messageCount: 3)
        let summary = f.center.summary(for: thread)
        let replies = f.center.quickReplies(for: thread)
        await eventually { summary.phase == .loading && replies.phase == .loading }
        f.center.conversationDisappeared(thread)
        #expect(summary.phase == .idle && replies.phase == .idle, "j/k never queues up model runs")
        f.center.conversationAppeared(thread, messageCount: 3)
        #expect(summary.phase == .loading && replies.phase == .loading, "opening it again starts them again")

        summary.summarize(trigger: .user)
        f.center.conversationDisappeared(thread)
        #expect(summary.phase == .loading, "what the user asked for finishes")
        summary.cancel()
        replies.cancel()
    }

    @Test func aRunCancelledWhileItsConversationLoadsLeavesNoFailureBehind() async throws {
        let f = AskFixture(settings: AISettings(draftReplies: .onDeviceAuto))
        await f.loaded()
        let thread = try await f.conversation(matching: "hiring loop").id
        let summary = f.center.summary(for: thread)
        let replies = f.center.quickReplies(for: thread)
        f.source.holdDetails()
        summary.summarize(trigger: .automatic, messageCount: 3)
        replies.request(trigger: .automatic)
        #expect(summary.phase == .loading && replies.phase == .loading)
        summary.cancelAutomatic()
        replies.cancelAutomatic()
        await summary.settled()
        await replies.settled()
        #expect(summary.phase == .idle, "a cancelled load is not a conversation that went away")
        #expect(replies.phase == .idle && replies.isOffered)
    }

    @Test func aSummaryNeverShowsThePromptsOwnTags() async throws {
        let provider = ScriptedProvider { request, _ in
            request.task == .summarize
                ? .text("<email_data nonce=\"\(request.nonce)\" kind=\"summary\">\nDana asks for the budget by Friday.\n</email_data>",
                        chunkSize: 4)
                : FakeAIProvider.cannedScript(request)
        }
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let summary = f.center.summary(for: try await f.thread(minimumMessages: 3))
        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        #expect(summary.text == "Dana asks for the budget by Friday.")
        #expect(summary.isSuspicious)
    }

    @Test func noQuickRepliesWhenTheNewestMessageIsTheUsers() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let mine = try await f.thread(minimumMessages: 2, lastFromMe: true)
        let replies = f.center.quickReplies(for: mine)
        replies.request(trigger: .user)
        await eventually { replies.phase == .unavailable("The newest message is yours") }
        #expect(!replies.isOffered)
        #expect(!provider.requests.contains { $0.task == .replyOptions })
    }

    @Test func summarizeOpensTheConversationAndSummarizes() async throws {
        let f = AIFixture()
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(f.env.actions.availability(.aiSummarize, host: f.router) == .enabled)
        #expect(f.env.actions.descriptor(.aiSummarize)?.changesMail == false)
        #expect(await f.run(.aiSummarize))
        #expect(f.router.reader?.thread == thread)
        let summary = f.center.summary(for: thread)
        await eventually { summary.phase == .done }
        #expect(f.recorder.calls.isEmpty)

        #expect(await f.run(.aiReplyOptions))
        let session = try #require(f.compose.windowSession)
        #expect(session.mode == .reply && session.aiPanel?.quickReplies != nil)
    }

    @Test func clearingTheCacheForgetsTheSessionResults() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 3)
        let summary = f.center.summary(for: thread)
        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        await f.center.clearCache()
        #expect(summary.phase == .idle && summary.text.isEmpty)
        summary.summarize(trigger: .user)
        await eventually { summary.phase == .done }
        #expect(provider.requests.filter { $0.task == .summarize }.count == 2)
        #expect(f.center.activity.entries.count >= 2, "the activity log keeps numbers per request")
    }

    @Test func theProviderListShowsActionableAvailability() async throws {
        let missing = ScriptedProvider(id: .agentClaude, displayName: "Claude Code", capabilities: .remote(),
                                       availability: .unavailable(reason: .binaryNotFound(name: "claude")))
        let f = AIFixture(providers: [ScriptedProvider(), missing])
        await f.loaded()
        await f.center.refreshProviders()
        #expect(f.center.providers.map(\.status) == ["Ready", "Install Claude Code"])
        #expect(f.center.providers.map(\.needsConsent) == [false, true])
        let status = await f.center.onDeviceStatus()
        #expect(status.available && status.hint == nil)
    }
}

@Suite struct AIThreadLoaderTests {
    final class OneThread: MailDataSource {
        let detail: ConversationDetail
        let contents: [MessageKey: MessageContent]
        let asked = Mutex<[MessageKey]>([])

        init(detail: ConversationDetail, contents: [MessageKey: MessageContent]) {
            self.detail = detail
            self.contents = contents
        }

        func accounts() -> AsyncThrowingStream<[Account], Error> { AsyncThrowingStream { $0.finish() } }
        func threadWindow(_ location: MailLocation, account: AccountID, limit: Int)
            -> AsyncThrowingStream<ThreadListWindow, Error> { AsyncThrowingStream { $0.finish() } }
        func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> {
            let detail = detail
            return AsyncThrowingStream { $0.yield(detail) }
        }
        func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> {
            asked.withLock { $0.append(key) }
            let content = contents[key]
            return AsyncThrowingStream { continuation in
                continuation.yield(.fetching)
                continuation.yield(content.map { .available($0) } ?? .failed("gone"))
            }
        }
    }

    static let account = Account(id: AccountID(1), email: "robin@example.com", displayName: "Robin", alias: nil, health: .active)
    static let thread = ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t-7"))

    static func message(_ n: Int, unread: Bool, from: String) -> MessageSummary {
        MessageSummary(id: MessageKey(account: AccountID(1), rowID: Int64(n), gmailMessageID: GmailMessageID("m-\(n)")),
                       from: EmailAddress(name: from == "robin@example.com" ? "Robin" : "Dana", email: from), to: [], cc: [],
                       bcc: [], date: fixedNow.addingTimeInterval(Double(n) * 60), snippet: "snippet \(n)", isUnread: unread,
                       attachments: [])
    }

    static func source() -> OneThread {
        let messages = [message(1, unread: false, from: "dana@acme.example"), message(2, unread: true, from: "dana@acme.example"),
                        message(3, unread: false, from: "robin@example.com"), message(4, unread: false, from: "dana@acme.example")]
        var contents: [MessageKey: MessageContent] = [:]
        for summary in messages {
            contents[summary.id] = MessageContent(
                html: "<p>Body \(summary.id.rowID)</p><blockquote type=\"cite\">quoted history</blockquote><script>x()</script>",
                text: nil)
        }
        return OneThread(detail: ConversationDetail(id: thread, subject: "Plan", messages: messages), contents: contents)
    }

    @Test func automaticRunsReadOnlyTheBodiesTheReaderOpensAndUserRunsReadAll() async throws {
        let data = Self.source()
        let loader = AIThreadLoader(data: data, bodyTimeout: .seconds(15))
        let auto = try #require(await loader.load(Self.thread, account: Self.account, accountKey: "k", trigger: .automatic,
                                                 bodies: .readerDefault))
        #expect(Set(data.asked.withLock { $0 }.map(\.rowID)) == [2, 4], "the unread message and the newest only")
        #expect(auto.input.messages.map(\.bodyText) == ["snippet 1", "Body 2", "snippet 3", "Body 4"])
        #expect(auto.input.threadKey == "1.t-7" && auto.input.accountKey == "k" && auto.input.trigger == .automatic)
        #expect(auto.input.messages[2].from == "Robin <robin@example.com> (the user)")
        #expect(!auto.lastIsFromMe)

        data.asked.withLock { $0.removeAll() }
        let user = try #require(await loader.load(Self.thread, account: Self.account, accountKey: "k", trigger: .user, bodies: .all))
        #expect(Set(data.asked.withLock { $0 }.map(\.rowID)) == [1, 2, 3, 4])
        #expect(user.input.messages.map(\.bodyText) == ["Body 1", "Body 2", "Body 3", "Body 4"],
                "plain text: quoted history and scripts never reach a prompt")
        #expect(user.isNewest && user.messageKeys.last?.rowID == 4)
    }

    @Test func aLoadForAnOlderMessageStopsAtItAndReadsItsBody() async throws {
        let data = Self.source()
        let loader = AIThreadLoader(data: data, bodyTimeout: .seconds(15))
        let target = Self.message(1, unread: false, from: "dana@acme.example").id
        let first = try #require(await loader.load(Self.thread, upTo: target, account: Self.account, accountKey: "k",
                                                  trigger: .automatic, bodies: .readerDefault))
        #expect(first.messageKeys.map(\.rowID) == [1] && first.input.messages.map(\.messageKey) == ["1.m-1"])
        #expect(first.input.messages.map(\.bodyText) == ["Body 1"], "the message answered is read in full")
        #expect(Set(data.asked.withLock { $0 }.map(\.rowID)) == [1], "nothing after it is even read")
        #expect(!first.isNewest && !first.lastIsFromMe)

        let mine = Self.message(3, unread: false, from: "robin@example.com").id
        let own = try #require(await loader.load(Self.thread, upTo: mine, account: Self.account, accountKey: "k",
                                                trigger: .user, bodies: .all))
        #expect(own.messageKeys.map(\.rowID) == [1, 2, 3] && own.lastIsFromMe && !own.isNewest)
        #expect(!own.input.messages.contains { $0.bodyText == "Body 4" })

        let gone = MessageKey(account: AccountID(1), rowID: 99, gmailMessageID: GmailMessageID("m-99"))
        #expect(await loader.load(Self.thread, upTo: gone, account: Self.account, accountKey: "k", trigger: .user,
                                  bodies: .all) == nil)
        #expect(AIThreadLoader.window(data.detail.messages, upTo: nil)?.map(\.id.rowID) == [1, 2, 3, 4])
    }
}

@Suite struct AIPureTests {
    @Test func thePolicyKeyIsAStableHashOfTheAddress() {
        let a = AICenter.policyKey(email: "Robin@Example.com")
        #expect(a == AICenter.policyKey(email: "robin@example.com"))
        #expect(a != AICenter.policyKey(email: "robin.home@example.net"))
        #expect(!a.contains("robin") && !a.contains("@"))
    }

    @Test func settingsPersistThroughTheBox() throws {
        let store = InMemoryAISettingsStore()
        let box = AISettingsBox(store: store)
        try box.update { $0.draftReplies = .onDeviceAuto }
        #expect(AISettingsBox(store: store).current.draftReplies == .onDeviceAuto)
    }

    @Test func badgesNameWhereTheTextWent() {
        #expect(AIProviderBadge(providerName: "Apple on-device model", location: .onDevice).title == "On this Mac")
        let pcc = AIProviderBadge(providerName: "Apple Private Cloud Compute", location: .appleCloud)
        #expect(pcc.title == "Sent to Apple Private Cloud Compute" && pcc.leavesMac && pcc.symbol == "cloud")
        let codex = AIProviderBadge(providerName: "Codex (Experimental)", location: .thirdParty(vendor: "OpenAI"))
        #expect(codex.title == "Sent to OpenAI via Codex (Experimental)" && codex.leavesMac)
        #expect(AIWording.reason(.appleIntelligenceNotEnabled) == "Turn on Apple Intelligence in System Settings")
        #expect(AIWording.reason(.notLoggedIn(name: "claude")) == "Run `claude auth login` in Terminal")
        #expect(AIWording.failure(AIError.contextOverflow(counted: 9, limit: 3)) == "Too long for this model. Select less and try again")
        #expect(AIWording.failure(CocoaError(.fileReadNoPermission)) == "Something went wrong", "foreign errors never echo")
    }

    @Test func theDiffMarksInsertionsAndDeletionsByWord() {
        let segments = AITextDiff.segments(from: "I have reviewed the figures.", to: "I reviewed the new figures.")
        #expect(segments.map(\.kind) == [.kept, .deleted, .kept, .inserted, .kept])
        #expect(segments.filter { $0.kind == .deleted }.map(\.text) == ["have "])
        #expect(segments.filter { $0.kind == .inserted }.map(\.text) == ["new "])
        #expect(segments.filter { $0.kind != .deleted }.map(\.text).joined() == "I reviewed the new figures.")
        #expect(segments.filter { $0.kind != .inserted }.map(\.text).joined() == "I have reviewed the figures.")
        let long = String(repeating: "word ", count: 700)
        #expect(AITextDiff.segments(from: long, to: "short").map(\.kind) == [.deleted, .inserted])
    }

    @Test func noAICodeSendsOrWritesMail() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var sources: [(String, String)] = []
        for dir in ["Sources/MailFeatures/AI", "../OpenHumanMailUI/Sources/MailUI/AI"] {
            let url = root.appendingPathComponent(dir)
            let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects ?? [])
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
            for file in files { sources.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8))) }
        }
        #expect(sources.count >= 24, "found the AI sources, the Instant Reply strip's core and row included")
        for name in ["InstantReplyModel.swift", "InstantReplyModule.swift", "InstantReplyPolicy.swift",
                     "QuickReplyInsertion.swift", "InstantReplyStrip.swift"] {
            #expect(sources.contains { $0.0 == name }, "\(name) is scanned")
        }
        let forbidden = [#"\.send\("#, #"sendNow"#, #"scheduleSend"#, #"sendLater"#, #"\.commands"#, #"createDraft"#,
                         #"updateDraft"#, #"flushDraft"#, #"\.apply\("#, #"perform\(\.send"#, #"session\.save\("#]
        for (name, text) in sources {
            for pattern in forbidden {
                let regex = try NSRegularExpression(pattern: pattern)
                let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                #expect(!found, "\(name) matches \(pattern)")
            }
        }
    }
}

@MainActor
@Suite(.serialized) struct AISettingsHookTests {
    @Test func theGuidesAIStepGoesThroughTheCenter() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let port = AICenterOnboarding(center: f.center)
        #expect(await port.onDeviceStatus() == .available)
        #expect(await port.draftReplies() == .onDemand)
        try await port.setDraftReplies(.onDeviceAuto)
        #expect(f.center.settings.draftReplies == .onDeviceAuto, "one owner: the center sees the guide's choice at once")
        #expect(await port.agentCLIAutoQuickReplies() == false)
        let thread = try await f.thread(minimumMessages: 3)
        let summary = try await port.summarizeOnDevice(thread)
        #expect(summary?.hasPrefix("Summary of") == true)

        let claude = AIThreadTests.remote()
        let g = AIFixture(settings: AIThreadTests.consented, providers: [claude])
        await g.loaded()
        let remoteOnly = AICenterOnboarding(center: g.center)
        #expect(try await remoteOnly.summarizeOnDevice(try await g.thread(minimumMessages: 3)) == nil)
        #expect(claude.requests.isEmpty)
        if case .unavailable = await remoteOnly.onDeviceStatus() {} else { Issue.record("no on-device model here") }
    }

    @Test func theSettingsSectionChangesTheCentersSettings() async throws {
        let provider = ScriptedProvider()
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let page = AISettingsPageModel(center: f.center, environment: f.env)
        await page.refresh()
        #expect(page.providers.map(\.id) == ["fake", "local", "apple.pcc"])
        let pcc = try #require(page.providers.last)
        #expect(pcc.status == "Not available in this version of Mail" && pcc.badge.leavesMac && pcc.warning != nil)
        #expect(page.providers.first { $0.id == "local" }?.status == "Not available in this version of Mail")
        page.summarizeOnOpen = false
        page.draftReplies = .off
        #expect(!f.center.settings.autoSummarizeOnOpen && f.center.settings.draftReplies == .off)
        #expect(page.providers.allSatisfy { $0.action == nil }, "nothing here leaves the Mac, so nothing asks for your OK")
        #expect(page.accounts.count == 2)
        let work = try #require(page.accounts.first)
        page.setOnDeviceOnly(true, account: work.id)
        #expect(page.accounts.first?.onDeviceOnly == true)
    }
}
