import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
func soon(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    await eventually(timeout: .seconds(15), condition, sourceLocation: sourceLocation)
}

@MainActor
@Suite(.serialized) struct ComposeFlowTests {
    @Test func cOpensAModalComposerThatSavesLazilyAndKeepsTheDraftOnClose() async throws {
        let f = ComposeFixture()
        await f.loaded()
        #expect(await f.run(.compose))
        let session = try #require(f.compose.windowSession)
        #expect(session.mode == .new && session.placement == .modal)
        #expect(session.from.email == "robin@example.com" && session.fromReason == .accountDefault)
        #expect(f.router.actionContext().scope == .composer, "the composer has the keys while it is up")
        #expect(f.env.actions.availability(.markDone, host: f.router) == .hidden)
        await session.settle()
        #expect(f.recorder.calls.isEmpty, "an untouched composer writes nothing")

        session.to.text = "Dana Ruiz <dana@acme.example>,"
        session.subject = "Plan"
        session.updateBody(doc("Hello there"))
        await soon { session.draftKey != nil && session.saveState == .saved }
        let key = try #require(session.draftKey)
        #expect(f.recorder.calls.first == "createDraft")
        #expect(f.router.openDraftIDs == [key.rawValue])
        let row = try #require(await f.draftRow(key))
        #expect(row.fields.to.map(\.email) == ["dana@acme.example"] && row.fields.subject == "Plan")
        #expect(row.fields.from?.email == "robin@example.com")
        #expect(row.fields.bodyHTML.contains("Hello there") && row.fields.bodyText?.contains("Hello there") == true)
        #expect(row.fields.bodyHTML.contains("gmail_signature"), "the From identity's signature")

        session.updateBody(doc("Hello there, again"))
        await soon { f.recorder.calls.filter { $0 == "updateDraft" }.count >= 1 && session.saveState == .saved }
        #expect(session.version == (try #require(await f.draftRow(key))).version)

        f.compose.close(session)
        await f.compose.settle()
        #expect(f.compose.windowSession == nil && f.router.openDraftIDs.isEmpty)
        #expect(f.recorder.calls.contains("flushDraft"), "close saves to Gmail now")
        #expect(try #require(await f.draftRow(key)).gmailDraftID != nil)
    }

    @Test func theDefaultFromForNewMailIsASettingPerAccount() async throws {
        let f = ComposeFixture()
        await f.loaded()
        try await f.store.set(ComposeSettings.defaultFrom(ComposeFixture.work), "robin@team.example")
        let session = try #require(f.compose.openNew(placement: .modal))
        await session.settle()
        #expect(session.from.email == "robin@team.example" && session.fromReason == .accountDefault)
        #expect(!session.isFromNonDefault)
        #expect(!session.showsFromReason, "the default address: the reason is in the tooltip")
        #expect(session.signature?.html == "<p>Robin · Team</p>", "the signature follows the From")
        #expect(session.offersFromPicker && f.env.actions.availability(.chooseFrom, host: session) == .enabled)
        #expect(await f.run(.chooseFrom, in: session))
        #expect(session.isFromPickerOpen)
        let primary = try #require(session.fromChoices.first { $0.email == "robin@example.com" })
        session.chooseFrom(primary)
        #expect(session.from == primary && session.fromReason == .chosen && session.isFromNonDefault)
        #expect(session.showsFromReason, "not the default: the line says why")
        #expect(session.signature?.html == "<p>Robin Example<br>Example Co.</p>")
        let personal = try #require(f.compose.openNew(placement: .modal, account: AccountID(2)))
        #expect(!personal.offersFromPicker && f.env.actions.availability(.chooseFrom, host: personal) == .hidden)
    }

    @Test func replyDocksWithTheSkeletonAndSendsOnceWithUndo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        #expect(session.placement == .docked(thread) && session.mode == .reply)
        #expect(f.router.mode == .reader && f.router.reader?.thread == thread, "the conversation opens above it")
        await session.settle()
        let key = try #require(session.draftKey)
        #expect(!session.to.tokens.isEmpty, "recipients from the engine's skeleton")
        #expect(session.subject.hasPrefix("Re: ") && !session.showsSubject)
        #expect(!session.quotedHTML.isEmpty && session.document.blocks.isEmpty)
        #expect(QuoteSplit.quoteBlockCount(session.assembledFields().bodyHTML) == 1)

        session.updateBody(doc("Sounds good"))
        #expect(await f.run(.send, in: session))
        #expect(f.compose.windowSession == nil && f.compose.heldSendCount == 1 && f.store.heldSendCount == 1)
        await f.toast("Reply sent.")
        #expect(f.recorder.calls.contains("send"))

        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session }
        #expect(f.recorder.calls.contains("cancelSend") && f.store.heldSendCount == 0)
        #expect(session.plainText.contains("Sounds good") && session.draftKey == key)
        #expect(f.store.sentMessages.isEmpty, "nothing reached Gmail")

        #expect(await f.run(.send, in: session))
        f.store.completeHeldSends()
        f.heldGate.release()
        await f.toast("Sent.")
        let sent = try #require(f.store.sentMessages.last)
        #expect(QuoteSplit.quoteBlockCount(sent.bodyHTML) == 1, "exactly one quote block")
        #expect(sent.bodyHTML.contains("Sounds good") && sent.thread == thread)
        #expect(sent.from?.email == "robin@example.com")
        #expect(await f.draftRow(key) == nil)
    }

    @Test func aReplyNobodyTypedInIsDiscardedOnClose() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let thread = try #require(f.router.list?.cursor)
        let session = try #require(f.compose.openReply(thread, mode: .replyAll))
        await session.settle()
        let key = try #require(session.draftKey)
        f.compose.close(session)
        await f.compose.settle()
        #expect(f.recorder.calls == ["createDraft", "discardDraft"])
        #expect(await f.draftRow(key) == nil)
    }

    @Test func repliesComeFromTheAliasTheMailWasSentToAndThePickerIsRemembered() async throws {
        let f = ComposeFixture()
        await f.loaded()
        f.store.deliverMessage(account: ComposeFixture.work, from: EmailAddress(name: "Dana Ruiz", email: "dana@acme.example"),
                               subject: "For the team", at: fixedNow.addingTimeInterval(60),
                               recipients: [EmailAddress(name: "Team", email: "robin@team.example")])
        let thread = try await f.thread(subject: "For the team")
        let session = try #require(f.compose.openReply(thread, mode: .reply))
        await session.settle()
        #expect(session.from.email == "robin@team.example" && session.fromReason == .sentToAlias)
        #expect(session.isFromNonDefault, "the From line says it is not the default")
        #expect(session.signature?.html == "<p>Robin · Team</p>")
        session.updateBody(doc("On it"))
        #expect(await f.run(.send, in: session))
        f.store.completeHeldSends()
        f.heldGate.release()
        await f.toast("Sent.")
        #expect(f.store.sentMessages.last?.from?.email == "robin@team.example")

        let second = try #require(f.compose.openReply(thread, mode: .reply))
        await second.settle()
        #expect(second.from.email == "robin@team.example")
        let primary = try #require(second.fromChoices.first { $0.email == "robin@example.com" })
        second.chooseFrom(primary)
        f.compose.close(second)
        await f.compose.settle()
        let remembered = try await f.store.get(ComposeSettings.threadFrom(ComposeFixture.work))
        #expect(remembered == [ThreadFromChoice(thread: thread.gmailThreadID.rawValue, email: "robin@example.com")])
        let third = try #require(f.compose.openReply(thread, mode: .forward))
        await third.settle()
        #expect(third.from.email == "robin@example.com" && third.fromReason == .rememberedForThread)
    }

    @Test func thePolicyForExistingEmailsCanAlwaysUseTheDefault() async throws {
        let f = ComposeFixture()
        await f.loaded()
        try await f.store.set(ComposeSettings.replyFrom(ComposeFixture.work), .accountDefault)
        f.store.deliverMessage(account: ComposeFixture.work, from: EmailAddress(email: "dana@acme.example"), subject: "Alias mail",
                               recipients: [EmailAddress(email: "robin@team.example")])
        let thread = try await f.thread(subject: "Alias mail")
        let session = try #require(f.compose.openReply(thread, mode: .reply))
        await session.settle()
        #expect(session.from.email == "robin@example.com" && session.fromReason == .accountDefault)
    }

    @Test func aSourceWithoutAWritePortComposesLocally() async throws {
        let f = ComposeFixture(writePort: false)
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("Hi"))
        await session.settle()
        if case .localOnly(let why) = session.saveState { #expect(why == "Drafts can't be saved here") } else {
            Issue.record("expected localOnly")
        }
        #expect(f.compose.perform(.send, in: session, source: .keyboard))
        #expect(session.notice?.kind == .error && !f.compose.canSendInThisProcess)
        #expect(f.store.heldSendCount == 0)
    }

    @Test func sendNeedsValidRecipientsAndAsksAboutUnfilledPlaceholders() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.updateBody(doc("Hi"))
        #expect(await f.run(.send, in: session))
        #expect(session.notice?.text == "Add at least one recipient.")
        session.to.text = "not-an-address,"
        #expect(await f.run(.send, in: session))
        #expect(session.notice?.text.contains("is not a valid address") == true)
        session.to.removeLast()
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("About {{project}}"))
        #expect(await f.run(.send, in: session))
        #expect(session.notice?.kind == .warning && session.notice?.text.contains("“project”") == true)
        #expect(!f.recorder.calls.contains("send"))
        #expect(await f.run(.send, in: session), "the second ⌘↵ sends anyway")
        #expect(f.recorder.calls.contains("send") && f.compose.heldSendCount == 1)
    }

    @Test func snippetsFromThePickerFillVariablesTheSubjectAndRankByUse() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "Dana Ruiz <dana@acme.example>,"
        await soon { session.snippets.count == 3 }
        #expect(session.snippetShortcuts == ["thx", "intro", "fu"])
        #expect(await f.run(.insertSnippet, in: session))
        let picker = try #require(session.snippetPicker)
        picker.query = "intro"
        picker.confirm()
        #expect(session.snippetPicker == nil)
        let insertion = try #require(session.pendingSnippet)
        #expect(insertion.snippet.name == "Intro" && insertion.range == nil)
        let body = ComposeSerializer.plainText(insertion.document, signature: nil)
        let expansion = SnippetExpander.expand(body, variables: insertion.snippet.variables, context: insertion.context)
        #expect(expansion.text == "Hi Dana, meet my colleague. I think you two should talk.")
        session.updateBody(doc(expansion.text))
        session.didInsertSnippet(insertion, unresolved: [])
        #expect(session.pendingSnippet == nil && session.subject == "Introduction")
        await soon { f.recorder.calls.contains("recordSnippetUse") }
        let direct = try #require(session.expansion(forShortcut: "THX", replacing: 0..<6))
        #expect(direct.snippet.name == "Thanks" && direct.range == 0..<6)
        session.didInsertSnippet(direct, unresolved: ["project"])
        session.updateBody(doc("Status of project"))
        #expect(session.unfilledPlaceholders == ["project"])
    }

    @Test func sendLaterSchedulesThroughTheEngineWithUndoAndAnotherMacSendingClosesTheComposer() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.subject = "Later"
        session.updateBody(doc("See you"))
        #expect(await f.run(.sendLater, in: session))
        let picker = try #require(f.timePicker)
        #expect(picker.kind == .sendLater)
        #expect(picker.chooseNumber(1))
        await f.compose.settle()
        let key = try #require(session.draftKey)
        #expect(f.recorder.calls.contains("scheduleSend") && !f.recorder.calls.contains("send"))
        #expect(f.compose.windowSession == nil)
        await f.toast("Scheduled for ")
        let scheduled = try #require(await f.draftRow(key))
        #expect(scheduled.status == .scheduled && scheduled.sendAt == ScheduleStamp.floorToMinute(fixedNow.addingTimeInterval(3_600)))

        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session }
        #expect(f.recorder.calls.contains("cancelScheduledSend"))
        await soon { session.sendAt == nil }

        await f.compose.schedule(session, at: fixedNow.addingTimeInterval(7_200))
        #expect(f.compose.windowSession == nil)
        let reopened = try #require(await f.compose.openDraft(key).value)
        await soon { reopened.sendAt != nil }
        #expect(f.env.actions.availability(.cancelSendLater, host: reopened) == .enabled)
        f.store.simulateOtherInstallSend(key)
        await soon { f.compose.windowSession == nil }
        await f.toast("Sent")
    }

    @Test func cancelSendLaterWorksWithUndo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("Later"))
        let at = fixedNow.addingTimeInterval(7_200)
        await f.compose.schedule(session, at: at)
        let key = try #require(session.draftKey)
        let reopened = try #require(await f.compose.openDraft(key).value)
        await soon { reopened.sendAt != nil }
        #expect(await f.run(.cancelSendLater, in: reopened))
        await soon { reopened.sendAt == nil }
        await f.toast("Send later canceled")
        #expect(await f.run(.undo))
        await soon { reopened.sendAt == ScheduleStamp.floorToMinute(at) }
    }

    @Test func undoNeverRestoresAScheduleWhoseTimeHasPassed() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("Later"))
        let at = fixedNow.addingTimeInterval(7_200)
        await f.compose.schedule(session, at: at)
        let key = try #require(session.draftKey)
        let reopened = try #require(await f.compose.openDraft(key).value)
        await soon { reopened.sendAt != nil }
        #expect(await f.run(.cancelSendLater, in: reopened))
        await soon { reopened.sendAt == nil }
        await f.toast("Send later canceled")
        let schedules = f.recorder.calls.filter { $0 == "scheduleSend" }.count

        f.compose.timing.now = { at.addingTimeInterval(20 * 60) }
        #expect(await f.run(.undo))
        await f.toast("That time has passed")
        #expect(f.recorder.calls.filter { $0 == "scheduleSend" }.count == schedules)
        #expect(reopened.sendAt == nil)
        #expect(await f.draftRow(key)?.status != .scheduled)
    }

    @Test func anUnreviewedAgentDraftCannotBeScheduled() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let key = f.store.agentCreatesDraft(account: ComposeFixture.work,
                                            fields: DraftFields(to: [EmailAddress(email: "dana@acme.example")], subject: "Agent",
                                                                bodyHTML: "<p>From the agent</p>"))
        let session = try #require(await f.compose.openDraft(key).value)
        await soon { session.review == .pending }
        #expect(f.env.actions.availability(.sendLater, host: session)
            == .disabled(.other("Review this agent draft before scheduling it")))
        if case .done = f.compose.sendLater(session) {} else { Issue.record("expected a refusal") }
        #expect(session.notice?.text == "An agent wrote this draft. Review it before scheduling it.")
        #expect(!f.recorder.calls.contains("scheduleSend") && f.timePicker == nil)
    }

    @Test func withTheSendLaterModuleOffNothingSchedules() async throws {
        let f = ComposeFixture(flags: FeatureFlags().with(.sendLater, false))
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        #expect(!f.env.actions.contains(.sendLater) && !f.env.actions.contains(.cancelSendLater))
        #expect(f.env.actions.availability(.sendLater, host: session) == .hidden && !f.compose.offersSendLater)
        #expect(!f.env.modules.scheduleKinds.contains(.sendLater))
        #expect(f.env.actions.contains(.send), "sending stays (the composer is core)")
    }

    @Test func discardIsDeferredAndUndoable() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.updateBody(doc("Throwaway"))
        await soon { session.draftKey != nil && session.saveState == .saved }
        let key = try #require(session.draftKey)
        #expect(await f.run(.discardDraft, in: session))
        #expect(f.compose.windowSession == nil)
        await f.toast("Discarded draft")
        #expect(!f.recorder.calls.contains("discardDraft"), "nothing reaches Gmail inside the window")
        #expect(await f.run(.undo))
        await soon { f.compose.windowSession === session }
        #expect(await f.draftRow(key) != nil && session.plainText == "Throwaway")

        #expect(await f.run(.discardDraft, in: session))
        f.discardGate.release()
        await soon { f.recorder.calls.contains("discardDraft") }
        await f.compose.settle()
        #expect(await f.draftRow(key) == nil)
    }

    @Test func aComposeLinkPrefillsShowsTheRecipientsAndConfirmsBeforeTheFirstSend() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.open(link: ComposePrefill(to: ["Ana <ana@example.com>"], cc: ["billing@acme.example"],
                                                                      subject: "Invoice", body: "Line 1\nLine 2",
                                                                      droppedBcc: true), account: nil))
        await session.settle()
        #expect(session.linkBanner == "Opened from a link. It added these recipients: ana@example.com, billing@acme.example. Check them before sending.")
        #expect(session.linkTriedBcc && session.bcc.tokens.isEmpty && session.showsCc)
        #expect(session.subject == "Invoice" && session.plainText == "Line 1\nLine 2")
        #expect(f.recorder.calls.isEmpty, "a link only pre-fills; nothing is written")
        #expect(await f.run(.send, in: session))
        #expect(session.isLinkConfirmationShown && f.recorder.calls.isEmpty)
        session.confirmLinkRecipients()
        #expect(await f.run(.send, in: session))
        #expect(f.recorder.calls == ["createDraft", "send"])
        #expect(f.store.heldSendCount == 1)
    }

    @Test func editingALinksRecipientsDropsTheConfirmation() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.open(link: ComposePrefill(to: ["ana@example.com"]), account: nil))
        session.to.text = "sam@example.com,"
        #expect(session.linkBanner == nil)
        session.updateBody(doc("Hi"))
        #expect(await f.run(.send, in: session))
        #expect(!session.isLinkConfirmationShown && f.recorder.calls.contains("send"))
    }

    @Test func theOpenComposerReopensFromItsRowWithDraftJSONOnlyWhenTheVersionMatches() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let recovery = InMemoryDraftRecovery()
        f.compose.recovery = recovery
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.text = "dana@acme.example,"
        session.updateBody(RichTextDocument(blocks: [.list(ordered: false, items: [[.paragraph([.text("one", [.bold])])]])]))
        await soon { session.saveState == .saved && session.draftKey != nil }
        let key = try #require(session.draftKey)
        let version = try #require(session.version)
        #expect(recovery.load(key, version: version)?.document == session.document)
        recovery.save(DraftRecoveryRecord(draftID: key.rawValue, version: version, document: doc("FROM DRAFT JSON"),
                                          quotedText: "", includeSignature: true))

        let env2 = AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store, isFake: true)
        env2.router.openDraftIDs = [key.rawValue]
        env2.router.start()
        env2.compose.recovery = recovery
        env2.compose.restoreOpenDrafts()
        await soon { env2.compose.windowSession != nil }
        let restored = try #require(env2.compose.windowSession)
        #expect(restored.draftKey == key && restored.plainText == "FROM DRAFT JSON")
        #expect(restored.to.tokens.map(\.email) == ["dana@acme.example"], "recipients come from the row")

        _ = try await f.store.updateDraft(key, DraftFields(from: EmailAddress(email: "robin@example.com"),
                                                          to: [EmailAddress(email: "dana@acme.example")], subject: "Edited",
                                                          bodyHTML: "<div dir=\"auto\"><p>Edited elsewhere</p></div>"),
                                          expectedVersion: nil)
        let env3 = AppEnvironment(data: f.store, commands: f.store, accounts: f.store, settings: f.store, isFake: true)
        env3.router.openDraftIDs = [key.rawValue]
        env3.router.start()
        env3.compose.recovery = recovery
        env3.compose.restoreOpenDrafts()
        await soon { env3.compose.windowSession != nil }
        #expect(env3.compose.windowSession?.plainText == "Edited elsewhere")
        #expect(recovery.load(key, version: version) == nil)
    }

    @Test func popOutMovesTheSameSessionAndOneComposerShowsInTheWindow() async throws {
        let f = ComposeFixture()
        await f.loaded()
        var windows: [UUID] = []
        f.compose.openWindow = { windows.append($0.id) }
        let first = try #require(f.compose.openNew(placement: .modal))
        first.to.text = "dana@acme.example,"
        first.updateBody(doc("Keep me"))
        #expect(await f.run(.popOutComposer, in: first))
        #expect(first.placement == .window && windows == [first.id] && f.compose.windowSession == nil)
        #expect(f.env.actions.availability(.popOutComposer, host: first) == .hidden)
        #expect(await f.run(.composeInWindow))
        #expect(windows.count == 2)
        let a = try #require(f.compose.openNew(placement: .modal))
        a.to.text = "x@y.com,"
        a.updateBody(doc("A"))
        let b = try #require(f.compose.openNew(placement: .modal))
        #expect(f.compose.windowSession === b && !a.isOpen)
        await f.compose.settle()
        #expect(a.draftKey != nil && f.recorder.calls.contains("flushDraft"))
    }

    @Test func quittingSendsHeldSendsNowCompletesDiscardsAndSavesComposers() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let sending = try #require(f.compose.openNew(placement: .modal))
        sending.to.text = "dana@acme.example,"
        sending.updateBody(doc("Go"))
        #expect(await f.run(.send, in: sending))
        let discarding = try #require(f.compose.openNew(placement: .modal))
        discarding.to.text = "x@y.com,"
        discarding.updateBody(doc("Bin"))
        await soon { discarding.saveState == .saved }
        #expect(await f.run(.discardDraft, in: discarding))
        let open = try #require(f.compose.openNew(placement: .window))
        open.to.text = "z@y.com,"
        open.updateBody(doc("Keep"))
        #expect(f.compose.hasQuitWork)
        await f.compose.prepareForQuit()
        #expect(f.recorder.calls.contains("sendNow") && f.store.sentMessages.count == 1)
        #expect(f.recorder.calls.contains("discardDraft") && f.recorder.calls.contains("flushDraft"))
    }
}

@Suite struct SendReachabilityTests {
    static let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func sources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for dir in ["OpenHumanMailCore/Sources", "OpenHumanMailUI/Sources"] {
            let root = packages.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files { out.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8))) }
        }
        #expect(out.count > 100, "found the sources")
        return out
    }

    static func files(_ sources: [(name: String, text: String)], matching pattern: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: pattern)
        return Set(sources.filter { regex.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
            .map(\.name))
    }

    @Test func onlyTheComposerSends() throws {
        let sources = try Self.sources()
        #expect(Self.files(sources, matching: #"\.send\([^)]*undoWindow:"#) == ["ComposeManager+Send.swift", "ComposeManager+BatchSend.swift"])
        #expect(Self.files(sources, matching: #"\.scheduleSend\("#) == ["ComposeManager+Send.swift"])
        #expect(Self.files(sources, matching: #"\.sendNow\("#) == ["ComposeManager+Send.swift", "ComposeManager+BatchSend.swift"])
        #expect(Self.files(sources, matching: #"manager\.send\(|\.send\(session\)"#) == ["ComposeActionHandler.swift"])
        #expect(Self.files(sources, matching: #"manager\.sendLater\("#) == ["ComposeActionHandler.swift"])
    }
}
