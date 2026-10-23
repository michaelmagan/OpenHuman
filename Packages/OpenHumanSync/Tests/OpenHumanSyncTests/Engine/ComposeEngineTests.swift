import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanMIME
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct ComposeEngineTests {
    private func occurrences(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func uploads(_ h: EngineHarness, _ draft: DraftID) throws -> [OperationItem] {
        try h.ops().filter { if case let .upsertDraft(id, _) = $0.payload { return id == draft } else { return false } }
    }

    private func conversation(_ h: EngineHarness) async throws -> (thread: String, newest: GmailMessageID) {
        let thread = h.threads[0]
        let reply = await h.gmail.deliver(from: "Carol Example <carol@example.com>",
                                          to: "me@example.com, dave@example.com", subject: "Re: Seeded thread 0",
                                          body: "Synthetic reply body.", threadID: thread)
        return (thread, GmailMessageID(reply.messageID))
    }

    @Test func newDraftReplyAllWritesTheQuoteOnceAndSavesKeepIt() async throws {
        let h = try await EngineHarness()
        let (thread, newest) = try await conversation(h)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let created = try await engine.newDraft(account: h.account, mode: .replyAll, replyTo: newest, origin: .user)
        #expect(created.version == 1)
        let skeleton = try #require(created.skeleton)
        #expect(skeleton.gmailThreadID == thread)
        #expect(skeleton.subject == "Re: Seeded thread 0")
        #expect(skeleton.inReplyTo != nil)
        var draft = try #require(try h.store.draft(created.id))
        #expect(occurrences("data-oh-quote", in: draft.content.bodyHTML) == 1)
        #expect(draft.content.to.map(\.email) == ["carol@example.com"])
        #expect(draft.content.cc.map(\.email) == ["dave@example.com"])
        #expect(draft.thread?.gmailThreadID.rawValue == thread)
        #expect(draft.reviewState == .none)

        var content = draft.content
        content.bodyHTML = "<p>Thanks</p>" + skeleton.quotedHTML
        let v2 = try await engine.saveDraft(created.id, content: content, expectedVersion: 1)
        #expect(v2 == 2)
        draft = try #require(try h.store.draft(created.id))
        #expect(occurrences("data-oh-quote", in: draft.content.bodyHTML) == 1)
        await #expect(throws: StoreError.self) {
            try await engine.saveDraft(created.id, content: content, expectedVersion: 1)
        }
        await engine.stop()
    }

    @Test func theSkeletonPreviewIsWhatNewDraftStoresAndWritesNothing() async throws {
        let h = try await EngineHarness()
        let (_, newest) = try await conversation(h)
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let opsBefore = try h.ops().count
        let preview = try #require(try DraftSkeleton.content(store: h.store, account: h.account, mode: .replyAll,
                                                             replyTo: newest))
        #expect(try h.ops().count == opsBefore)
        #expect(try DraftSkeleton.content(store: h.store, account: h.account, mode: .new, replyTo: nil) == nil)
        let created = try await engine.newDraft(account: h.account, mode: .replyAll, replyTo: newest, origin: .user)
        let stored = try #require(try h.store.draft(created.id)).content
        #expect(preview.to == stored.to && preview.cc == stored.cc && preview.subject == stored.subject)
        #expect(preview.bodyHTML == stored.bodyHTML && occurrences("data-oh-quote", in: preview.bodyHTML) == 1)
        #expect(preview.cc.map(\.email) == ["dave@example.com"], "the user's own address is left out")
        await engine.stop()
    }

    @Test func aForwardCarriesTheOriginalFilesAndTheQuoteIntoTheSentMessage() async throws {
        let h = try await EngineHarness(onDisk: true)
        defer { h.cleanup() }
        let pdf = Data("%PDF-1.4 synthetic forwarded document".utf8)
        let delivered = await h.gmail.deliver(
            from: "Carol Example <carol@example.com>", subject: "Quarterly report", body: "Synthetic report body.",
            html: "<p>Synthetic report body.</p><img src=\"cid:chart-1\">",
            attachments: [FakeGmailAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf),
                          FakeGmailAttachment(filename: "chart.png", mimeType: "image/png", data: FakeGmailAttachment.tinyPNG,
                                              contentID: "chart-1")])
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let original = GmailMessageID(delivered.messageID)
        let initial = DraftContent(to: [EmailAddress(email: "dave@example.com")], cc: [], bcc: [], subject: "",
                                   bodyHTML: "", attachments: [])
        let created = try await engine.newDraft(account: h.account, mode: .forward, replyTo: original, origin: .user,
                                                initial: initial)
        let draft = try #require(try h.store.draft(created.id))
        let file = try #require(try h.store.message(account: h.account, gmailMessageID: original)?
            .attachments.first { $0.filename == "report.pdf" })
        #expect(draft.content.subject == "Fwd: Quarterly report")
        #expect(draft.content.attachments == [DraftAttachment(sourceAttachmentID: file.id, filename: "report.pdf",
                                                              mimeType: file.mimeType, size: file.size, isInline: false)],
                "the file comes along; the chart the quoted body shows stays part of the quote")
        #expect(occurrences("data-oh-quote", in: draft.content.bodyHTML) == 1)
        #expect(draft.content.bodyHTML.contains("Forwarded message") && draft.content.bodyHTML.contains("Synthetic report body."))
        #expect(draft.content.bodyText?.contains("Synthetic report body.") == true)

        let preview = try #require(try DraftSkeleton.content(store: h.store, account: h.account, mode: .forward,
                                                             replyTo: original))
        #expect(preview.attachments == draft.content.attachments)
        let reply = try #require(try DraftSkeleton.content(store: h.store, account: h.account, mode: .reply,
                                                           replyTo: original))
        #expect(reply.attachments.isEmpty, "a reply leaves the files out")

        let outgoing = try await DrainContext(account: h.account, store: h.store, api: h.gmail, clock: h.clock)
            .message(for: draft)
        let raw = String(decoding: try outgoing.raw(forSend: true), as: UTF8.self)
        #expect(raw.contains("multipart/mixed") && raw.contains("report.pdf"))
        #expect(raw.contains(pdf.base64EncodedString()), "the file is fetched from the original message")
        await engine.stop()
    }

    @Test func forwardedFilesLeaveOutPartsTheQuoteShowsAndAreAddedOnce() {
        let shown = AttachmentItem(id: 7, messageRowID: MessageRowID(rawValue: 1), partID: "1", filename: "logo.png",
                                   mimeType: "image/png", size: 10, contentID: "logo", isInline: true)
        let inlinePDF = AttachmentItem(id: 8, messageRowID: MessageRowID(rawValue: 1), partID: "2", filename: "plan.pdf",
                                       mimeType: "application/pdf", size: 20, isInline: true)
        let unshown = AttachmentItem(id: 9, messageRowID: MessageRowID(rawValue: 1), partID: "3", filename: "map.png",
                                     mimeType: "image/png", size: 30, contentID: "map", isInline: true)
        let files = DraftSkeleton.forwardedAttachments([shown, inlinePDF, unshown], html: "<img src=\"CID:logo\">")
        #expect(files.map(\.sourceAttachmentID) == [8, 9], "only a part the HTML shows stays out")
        #expect(files.allSatisfy { !$0.isInline && $0.contentID == nil })
        #expect(DraftSkeleton.forwardedAttachments([shown], html: nil).map(\.sourceAttachmentID) == [7])

        let skeleton = ReplySkeleton(to: [], cc: [], subject: "Fwd: x", inReplyTo: nil, references: [],
                                     quotedHTML: ComposeSupport.quoteMarker + "q</div>", quotedText: "q", gmailThreadID: nil)
        let own = DraftAttachment(localPath: "Drafts/d/a.txt", filename: "a.txt", mimeType: "text/plain", size: 1,
                                  isInline: false)
        let initial = DraftContent(to: [], cc: [], bcc: [], subject: "", bodyHTML: "", attachments: [own, files[0]])
        let merged = ComposeSupport.merge(initial, skeleton, forwarded: files)
        #expect(merged.attachments == [own, files[0], files[1]])
        #expect(ComposeSupport.merge(nil, nil, forwarded: files).attachments.isEmpty)
    }

    @Test func remoteSavesAreDebouncedFiveSecondsAndFlushedAtOnce() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let created = try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user,
                                                initial: DraftContent(to: [EmailAddress(email: "bob@example.invalid")],
                                                                      cc: [], bcc: [], subject: "Hello", bodyHTML: "",
                                                                      attachments: []))
        #expect(try uploads(h, created.id).isEmpty)
        var content = try #require(try h.store.draft(created.id)).content
        content.bodyHTML = "<p>H</p>"
        _ = try await engine.saveDraft(created.id, content: content, expectedVersion: nil)
        content.bodyHTML = "<p>Hi</p>"
        _ = try await engine.saveDraft(created.id, content: content, expectedVersion: nil)
        #expect(try uploads(h, created.id).isEmpty)
        h.clock.advance(by: .seconds(5))
        try await eventually("one upload after 5 s") { try uploads(h, created.id).count == 1 }

        try await eventually("uploaded") { try uploads(h, created.id).first?.status == .succeeded }
        let draft = try #require(try h.store.draft(created.id))
        #expect(!draft.isDirty && draft.gmailDraftID != nil)

        let other = try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user)
        try await engine.flushDraft(other.id)
        #expect(try uploads(h, other.id).count == 1)
        await engine.stop()
    }

    @Test func aSaveWithUnchangedContentSchedulesNoUpload() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let created = try await engine.newDraft(account: h.account, mode: .new, replyTo: nil, origin: .user,
                                                initial: DraftContent(to: [EmailAddress(email: "bob@example.invalid")],
                                                                      cc: [], bcc: [], subject: "Hello", bodyHTML: "",
                                                                      attachments: []))
        var content = try #require(try h.store.draft(created.id)).content
        content.bodyHTML = "<p>Hi</p>"
        #expect(try await engine.saveDraft(created.id, content: content, expectedVersion: nil) == 2)
        h.clock.advance(by: .seconds(5))
        try await eventually("uploaded") { try uploads(h, created.id).first?.status == .succeeded }

        let saved = try #require(try h.store.draft(created.id))
        #expect(!saved.isDirty)
        let debouncer = try #require(await engine.draftDebouncer)
        #expect(try await engine.saveDraft(created.id, content: saved.content, expectedVersion: nil) == saved.localVersion)
        #expect(try await engine.saveDraft(created.id, content: saved.content, expectedVersion: saved.localVersion)
                == saved.localVersion)
        #expect(await debouncer.pending.isEmpty, "an unchanged save starts no upload timer")
        #expect(try uploads(h, created.id).count == 1)
        #expect(try #require(try h.store.draft(created.id)).localVersion == saved.localVersion)
        await engine.stop()
    }

    @Test func aDiscardOrASendDropsThePendingUploadAndQuitOrStopQueuesTheRest() async throws {
        let h = try await EngineHarness()
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        func edited(_ subject: String) async throws -> DraftID {
            let created = try await engine.newDraft(
                account: h.account, mode: .new, replyTo: nil, origin: .user,
                initial: DraftContent(to: [EmailAddress(email: "bob@example.invalid")], cc: [], bcc: [], subject: subject,
                                      bodyHTML: "", attachments: []))
            var content = try #require(try h.store.draft(created.id)).content
            content.bodyHTML = "<p>Synthetic text.</p>"
            _ = try await engine.saveDraft(created.id, content: content, expectedVersion: nil)
            return created.id
        }
        let discarded = try await edited("Discarded"), sent = try await edited("Sent"), atQuit = try await edited("Quit")
        let debouncer = try #require(await engine.draftDebouncer)
        #expect(await debouncer.pending == [discarded, sent, atQuit])

        try await engine.discardDraft(discarded)
        let receipt = try await engine.send(sent, authorization: .userConfirmed, undoWindow: .seconds(600))
        #expect(receipt.upsertOperationID != nil)
        #expect(await debouncer.pending == [atQuit])
        #expect(try uploads(h, discarded).isEmpty)
        #expect(try uploads(h, sent).count == 1)
        #expect(try await engine.cancelSend(receipt))

        await engine.flushPendingSends(deadline: .seconds(20))
        #expect(try uploads(h, atQuit).count == 1)
        #expect(await debouncer.pending.isEmpty)

        let atStop = try await edited("Stop")
        await engine.stop()
        #expect(try uploads(h, atStop).count == 1)
        h.clock.advance(by: .seconds(5))
        #expect(try uploads(h, discarded).isEmpty && uploads(h, atQuit).count == 1)
    }

    @Test func agentDraftsAreQueuedForReviewAndUpdatesKeepTheQuote() async throws {
        let h = try await EngineHarness()
        let (_, newest) = try await conversation(h)
        let app = h.engine()
        await app.start()
        try await h.waitForSyncs(app)
        try await app.ensureBodies(thread: try h.ref(h.threads[0]).rowID)
        let cli = h.engine(role: .localClient, factory: .some(nil))
        let first = DraftContent(to: [], cc: [], bcc: [], subject: "", bodyHTML: "<p>First pass</p>",
                                 bodyText: "First pass", attachments: [])
        let id = try await cli.createAgentDraft(account: h.account, mode: .reply, replyTo: newest, content: first,
                                                note: "drafted by an agent", origin: .cli)
        var draft = try #require(try h.store.draft(id))
        #expect(draft.origin == .cli && draft.reviewState == .pending)
        #expect(draft.agentNote == "drafted by an agent")
        #expect(draft.content.subject == "Re: Seeded thread 0")
        #expect(draft.content.bodyHTML.hasPrefix("<p>First pass</p>"))
        #expect(occurrences("data-oh-quote", in: draft.content.bodyHTML) == 1)
        let quote = try #require(draft.content.bodyHTML.range(of: ComposeSupport.quoteMarker)).lowerBound
        let quoteBlock = String(draft.content.bodyHTML[quote...])
        #expect(try uploads(h, id).count == 1)
        #expect(try uploads(h, id).first?.origin == .cli)

        var second = first
        second.bodyHTML = "<p>Second pass</p>"
        second.bodyText = "Second pass"
        try await cli.updateAgentDraft(id, content: second, note: nil)
        draft = try #require(try h.store.draft(id))
        #expect(draft.content.bodyHTML == "<p>Second pass</p>" + quoteBlock)
        #expect(draft.content.bodyText?.hasPrefix("Second pass\n\nOn ") == true)
        #expect(draft.content.subject == "Re: Seeded thread 0")
        #expect(draft.reviewState == .pending)

        try await app.setReviewState(id, .approved)
        #expect(try h.store.draft(id)?.reviewState == .approved)
        await app.stop()
    }

    @Test func composeHelpersOwnTheQuoteAndTheThreadingHeaders() {
        let skeleton = ReplySkeleton(to: [EmailAddress(email: "a@example.invalid")], cc: [], subject: "Re: x",
                                     inReplyTo: "<m2@example.invalid>",
                                     references: ["<m1@example.invalid>", "<m2@example.invalid>"],
                                     quotedHTML: ComposeSupport.quoteMarker + "<div class=\"gmail_attr\">On Mon, A &lt;a@example.invalid&gt; wrote:<br></div>q</div>",
                                     quotedText: "On Mon, A <a@example.invalid> wrote:\n> q", gmailThreadID: "t1")
        #expect(ComposeSupport.threadingHeaders(skeleton) == ["In-Reply-To": "<m2@example.invalid>",
                                                               "References": "<m1@example.invalid> <m2@example.invalid>"])
        #expect(ComposeSupport.threadingHeaders(nil).isEmpty)
        let initial = DraftContent(to: [EmailAddress(email: "b@example.invalid")], cc: [], bcc: [], subject: "",
                                   bodyHTML: "<p>hi</p>", bodyText: "hi", attachments: [])
        let merged = ComposeSupport.merge(initial, skeleton)
        #expect(merged.to.map(\.email) == ["b@example.invalid"])
        #expect(merged.subject == "Re: x")
        #expect(merged.bodyHTML == "<p>hi</p>" + skeleton.quotedHTML)
        #expect(merged.bodyText == "hi\n\n" + skeleton.quotedText)
        #expect(ComposeSupport.firstQuoteLine(skeleton.quotedHTML) == "On Mon, A <a@example.invalid> wrote:")

        var update = initial
        update.to = []
        update.bodyHTML = "<p>new</p>"
        update.bodyText = "new"
        let updated = ComposeSupport.agentUpdate(update, over: merged)
        #expect(updated.bodyHTML == "<p>new</p>" + skeleton.quotedHTML)
        #expect(updated.bodyText == "new\n\n" + skeleton.quotedText)
        #expect(updated.to == merged.to)
        let plain = ComposeSupport.agentUpdate(update, over: initial)
        #expect(plain.bodyHTML == "<p>new</p>")
    }
}
