import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import OpenHumanCore
import Testing
import WebKit
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct ReaderViewTests {
    typealias F = UIFixtures

    @Test func headersRowsAndThePillFollowTheModel() async throws {
        let detail = F.conversation(1, count: 8, unread: [7])
        var bodies: [MessageKey: MessageContent] = [:]
        for m in detail.messages { bodies[m.id] = MessageContent(html: nil, text: "Plain body of \(m.id.rowID)") }
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        let keys = detail.messages.map(\.id)
        try await until { h.controller.messageViews.count == 3 }
        let pills = subviews(of: OlderMessagesPillView.self, in: h.controller.view)
        #expect(pills.map(\.count) == [5])
        #expect(h.container(keys[0])?.collapsedRow != nil)
        #expect(h.container(keys[7])?.header != nil)
        #expect(h.container(keys[7])?.isFocused == true)
        try await until { h.container(keys[7])?.plainBody != nil }

        #expect(h.controller.handleKey(Keys.event("p")))
        #expect(h.model.focusedMessage == keys[6])
        try await until { h.container(keys[6])?.isFocused == true && h.container(keys[7])?.isFocused == false }
        #expect(h.controller.handleKey(Keys.event("o")))
        try await until { h.container(keys[6])?.header != nil }
        #expect(h.controller.handleKey(Keys.event("n")))
        #expect(h.model.focusedMessage == keys[7])
        pills.first?.onClick?()
        try await until { h.controller.messageViews.count == 8 }
        #expect(h.controller.handleKey(Keys.event("O")))
        try await until { keys.allSatisfy { h.container($0)?.header != nil } }
        #expect(!h.controller.handleKey(Keys.event("j")), "j and k stay the window's")
        #expect(!h.controller.handleKey(Keys.event("n", modifiers: .command)))
        #expect(h.model.focusedMessage == keys[7])
        #expect(!h.controller.handleKey(Keys.arrow(.down)), "nothing newer: ↓ scrolls")
        #expect(h.controller.handleKey(Keys.arrow(.up)))
        #expect(h.model.focusedMessage == keys[6])
        #expect(!h.controller.handleKey(Keys.arrow(.up, modifiers: .shift)), "⇧↑ scrolls")
        #expect(h.controller.handleKey(Keys.arrow(.down)))
        #expect(h.model.focusedMessage == keys[7])
    }

    @Test func readerKeysPassTheWindowRouterAndReachTheReader() async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 20, now: Date()))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.orderFrontRegardless()
        defer { window.close() }
        content.keyRouter.isMailWindow = { $0 === window }
        try await until { content.windowModel.list?.rows.count == 20 }
        let thread = try #require(content.windowModel.list?.rows.first { $0.messageCount >= 2 }?.id)
        content.windowModel.open(thread)
        let reader = try #require(content.children.compactMap { $0 as? ReaderViewController }.first)
        let model = try #require(content.windowModel.reader)
        try await until { model.state == .loaded && reader.messageViews.count > 0 }
        try await until { window.firstResponder === reader.focusView }
        let before = model.focusedMessage
        #expect(before == model.messages.last?.id, "the focus starts on the newest message")
        #expect(content.keyRouter.route(Keys.event("p", code: 35, window: window)) == nil, "consumed by the window router")
        #expect(model.focusedMessage != before)
        window.firstResponder?.keyDown(with: Keys.event("n", code: 45, window: window))
        #expect(model.focusedMessage == before)
        #expect(reader.router === content.windowModel)
    }

    @Test func theToolbarGroupAndTheMoreMenuFollowTheCatalogOrder() async throws {
        let detail = F.conversation(2, count: 1)
        let source = UITestSource(details: [detail], bodies: [detail.messages[0].id: MessageContent(html: nil, text: "Hi")])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        try await until { !h.controller.toolbarActions.primary.isEmpty }
        let actions = h.controller.toolbarActions
        let offered = ReaderActions.threadActions.filter { h.controller.decided($0) != .hidden }
        let catalogOrder = ActionCatalog.all.map(\.id.rawValue).filter { id in offered.contains { $0.id.rawValue == id } }
        #expect(offered.map(\.id.rawValue) == catalogOrder)
        let primary = ReaderToolbarActions.primaryIDs.filter { id in offered.contains { $0.id == id } }
        #expect(actions.primary.map(\.id) == primary)
        let sections = ReaderToolbarActions.moreMenuSections.map { $0.filter { h.controller.decided($0) != .hidden } }
            .filter { !$0.isEmpty }
        #expect(actions.more.map { $0.map(\.id) } == sections.map { $0.map(\.id) })
        #expect(offered.contains { $0.id == .markDone } && offered.contains { $0.id == .trash })
        #expect(ReaderToolbarActions(router: h.router).isEmpty, "no open conversation in the router, no toolbar actions")
    }

    @Test func markDoneFromTheReaderGoesThroughTheRouter() async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 5, now: Date()),
                                              options: .init(remoteAck: .immediate))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.orderFrontRegardless()
        defer { window.close() }
        try await until { content.windowModel.list?.rows.count == 5 }
        let first = try #require(content.windowModel.list?.rows.first?.id)
        content.windowModel.open(first)
        let reader = try #require(content.children.compactMap { $0 as? ReaderViewController }.first)
        try await until { reader.toolbarActions.item(.markDone)?.isEnabled == true }
        let done = try #require(reader.toolbarActions.item(.markDone))
        #expect(done.help == "Mark done  E")
        #expect(ReaderToolbarActions(router: content.windowModel) == reader.toolbarActions, "the toolbar reads the same actions")
        #expect(ReaderToolbarActions.perform(done.id, router: try #require(reader.router)))
        try await until { content.windowModel.list?.rows.contains { $0.id == first } == false }
    }

    @Test func imagesBannerLoadsOnceHidesAndAlwaysLoadsForTheExactSender() async throws {
        let detail = F.conversation(3, count: 1)
        let key = detail.messages[0].id
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: [key: MessageContent(html: F.newsletterHTML, text: nil)]),
                                             thread: detail.id)
        defer { h.close() }
        let blockedView = try await h.shownWebView(key)
        #expect(blockedView.mode == .blocked)
        let banner = try #require(h.container(key)?.banner as? RemoteImagesBannerView)
        #expect(banner.text == "2 remote images hidden to keep your reading private.")
        #expect(banner.alwaysButton?.title == "Always from dana@news.example.com")
        #expect(banner.alwaysButton?.toolTip?.contains(RemoteContentPolicy.unverifiedSenderNote) == true)

        banner.loadButton.onPress?()
        try await until { (h.container(key)?.banner as? ImagesShownView)?.text == "Images shown · 1 tracker blocked" }
        try await until { h.container(key)?.htmlBody?.current?.mode == .imagesAllowed && h.container(key)?.htmlBody?.incoming == nil }
        #expect(try await h.shownWebView(key).rendered?.html.contains("https://images.news.example/chart.png") == true)
        let hide = try #require((h.container(key)?.banner as? ImagesShownView)?.actionButton)
        hide.onPress?()
        try await until {
            return h.container(key)?.banner is RemoteImagesBannerView
        }
        try await until { h.container(key)?.htmlBody?.current?.mode == .blocked }

        let always = try #require((h.container(key)?.banner as? RemoteImagesBannerView)?.alwaysButton)
        always.onPress?()
        try await until {
            (h.container(key)?.banner as? ImagesShownView)?.text == "Images always shown for dana@news.example.com · 1 tracker blocked"
        }
        #expect(try await h.store.get(AppSettings.remoteImageSenders(F.account)) == ["dana@news.example.com"])
        let stop = try #require((h.container(key)?.banner as? ImagesShownView)?.actionButton)
        #expect(stop.title == "Stop")
        stop.onPress?()
        try await until { h.container(key)?.banner is RemoteImagesBannerView }
        #expect(try await h.store.get(AppSettings.remoteImageSenders(F.account)).isEmpty)

        #expect(h.controller.handleKey(Keys.event("I")))
        try await until { (h.container(key)?.banner as? ImagesShownView)?.text.hasPrefix("Images shown") == true }
    }

    @Test func headerDetailsAndCopy() async throws {
        let detail = ConversationDetail(id: F.thread(4), subject: "Plan", messages: [
            F.summary(400, cc: [EmailAddress(name: "Lee", email: "lee@example.com")]),
        ])
        let key = detail.messages[0].id
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: [key: MessageContent(html: nil, text: "Hi")]),
                                             thread: detail.id)
        defer { h.close() }
        let header = try await h.header(key)
        header.pasteboard = h.pasteboard
        #expect(!header.detailsShown)
        let recipients = try #require(subviews(of: ReaderButton.self, in: header).first { $0.identifier?.rawValue == "reader.recipients" })
        recipients.onPress?()
        #expect(header.detailsShown)
        let labels = subviews(of: NSTextField.self, in: header).map(\.stringValue)
        for expected in ["From", "To", "Cc", "Date", "Dana Ruiz <dana@news.example.com>", "Robin Example <robin@example.com>, Sam <sam@example.com>"] {
            #expect(labels.contains(expected), "\(expected)")
        }
        let copyTo = try #require(subviews(of: ReaderButton.self, in: header).first { $0.identifier?.rawValue == "reader.copy.to" })
        copyTo.onPress?()
        #expect(h.pasteboard.string(forType: .string) == "robin@example.com, sam@example.com")
        let menu = NSMenu()
        header.fillMenu(menu)
        let copyAddress = try #require(menu.items.first { $0.title == "Copy Name and Address" } as? MenuAction)
        copyAddress.perform()
        #expect(h.pasteboard.string(forType: .string) == "Dana Ruiz <dana@news.example.com>")
        #expect(menu.items.contains { $0.title == "Collapse Message" })
    }

    @Test func accessorySlotShowsInTheHeader() async throws {
        let accessory = UIRecordingAccessory()
        let detail = F.conversation(5, count: 1)
        let key = detail.messages[0].id
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: [key: MessageContent(html: nil, text: "Hi")]),
                                             thread: detail.id, accessorySlot: ReaderHeaderAccessoryStore(current: accessory))
        defer { h.close() }
        try await until { h.container(key)?.header?.accessoryTitle == "· Unsubscribe" }
        let header = try #require(h.container(key)?.header)
        let button = try #require(subviews(of: ReaderButton.self, in: header).first { $0.attributedTitle.string == "· Unsubscribe" })
        button.onPress?()
        #expect(accessory.activated == [key])
    }

    @Test func attachmentsQuickLookAndSaveQuarantined() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdfFile = folder.appendingPathComponent("plan.pdf")
        try Data("%PDF-1.4 synthetic".utf8).write(to: pdfFile)
        let pngFile = folder.appendingPathComponent("chart.png")
        try TestImages.png(width: 12, height: 8).write(to: pngFile)
        let pdf = AttachmentInfo(id: 1, filename: "plan.pdf", mimeType: "application/pdf", size: 18, contentID: nil, isInline: false)
        let chart = AttachmentInfo(id: 2, filename: "chart.png", mimeType: "image/png", size: 100, contentID: "chart@x", isInline: true)
        let detail = ConversationDetail(id: F.thread(6), subject: "Files", messages: [F.summary(600, attachments: [pdf, chart])])
        let key = detail.messages[0].id
        let html = "<p>See the chart:</p><img src=\"cid:chart@x\" width=\"12\" height=\"8\">"
        let source = UITestSource(details: [detail], bodies: [key: MessageContent(html: html, text: nil)],
                                  files: [1: pdfFile, 2: pngFile])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        try await until { h.container(key)?.attachmentsStrip?.attachments == [pdf] }
        let strip = try #require(h.container(key)?.attachmentsStrip)

        var previewed: [URL] = []
        h.controller.quickLook = { url, _ in previewed.append(url) }
        strip.tiles[0].quickLook()
        try await until { previewed == [pdfFile] }
        #expect(AttachmentFiles.quarantine(of: pdfFile) != nil, "previewed files are quarantined")

        let out = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        h.controller.chooseSaveDestination = { _, _ in out }
        let saveAll = try #require(subviews(of: ReaderButton.self, in: strip).first { $0.identifier?.rawValue == "reader.attachments.saveAll" })
        saveAll.onPress?()
        try await until { h.toasts.contains("Saved 1 attachment") }
        let saved = out.appendingPathComponent("plan.pdf")
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(AttachmentFiles.quarantine(of: saved) != nil)
    }

    @Test func anInlineImageIsShownInTheBodyAndNotAsATile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-ui-inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pngFile = folder.appendingPathComponent("chart.png")
        try TestImages.png(width: 12, height: 8).write(to: pngFile)
        let chart = AttachmentInfo(id: 2, filename: "chart.png", mimeType: "image/png", size: 100, contentID: "chart@x", isInline: true)
        let detail = ConversationDetail(id: F.thread(9), subject: "Files", messages: [F.summary(900, attachments: [chart])])
        let key = detail.messages[0].id
        let html = "<p>See the chart:</p><img src=\"cid:chart@x\" width=\"12\" height=\"8\">"
        let source = UITestSource(details: [detail], bodies: [key: MessageContent(html: html, text: nil)], files: [2: pngFile])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        let web = try await h.shownWebView(key)
        let loaded = try await web.callAsyncJavaScript(
            """
            const img = document.images[0];
            if (!img.complete) { await new Promise(done => { img.addEventListener('load', done); img.addEventListener('error', done); }); }
            return img.naturalWidth;
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? Int
        #expect(loaded == 12)
        #expect(h.container(key)?.attachmentsStrip == nil, "an inline image alone leaves no attachment strip")
    }

    @Test func aRiskyAttachmentAsksBeforeItOpensAndADocumentDoesNot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("privacy-f10-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scriptFile = folder.appendingPathComponent("invoicefdp.command")
        try Data("echo synthetic\n".utf8).write(to: scriptFile)
        let pdfFile = folder.appendingPathComponent("plan.pdf")
        try Data("%PDF-1.4 synthetic".utf8).write(to: pdfFile)
        let script = AttachmentInfo(id: 1, filename: "invoice\u{202E}fdp.command", mimeType: "application/pdf", size: 15,
                                    contentID: nil, isInline: false)
        let pdf = AttachmentInfo(id: 2, filename: "plan.pdf", mimeType: "application/pdf", size: 18, contentID: nil, isInline: false)
        let detail = ConversationDetail(id: F.thread(8), subject: "Files", messages: [F.summary(800, attachments: [script, pdf])])
        let key = detail.messages[0].id
        let source = UITestSource(details: [detail], bodies: [key: MessageContent(html: nil, text: "Attached.")],
                                  files: [1: scriptFile, 2: pdfFile])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        var opened: [URL] = []
        var asked: [ReaderFormatting.AttachmentWarning] = []
        var answer = false
        h.controller.openFile = { opened.append($0) }
        h.controller.confirmRiskyAttachment = { warning, _ in
            asked.append(warning)
            return answer
        }

        h.controller.open(script, of: key)
        try await until { asked.count == 1 }
        #expect(asked[0].title == "Open “invoicefdp.command”?")
        #expect(asked[0].message == "This file can run programs on your Mac. Open it only if you expected it.")
        #expect(AttachmentFiles.quarantine(of: scriptFile) != nil, "quarantined before the question")

        answer = true
        h.controller.open(script, of: key)
        try await until { !opened.isEmpty }
        #expect(opened == [scriptFile], "Cancel opened nothing; Open opened it once")
        #expect(asked.count == 2)

        h.controller.open(pdf, of: key)
        try await until { opened.count == 2 }
        #expect(opened.last == pdfFile)
        #expect(asked.count == 2, "a document opens without a question")
    }

    @Test func linksOpenOutsideAndSuspiciousOnesAreConfirmed() async throws {
        let html = """
        <p><a id="bad" href="https://login.evil.example/x">https://bank.example/</a>
        <a id="good" href="https://example.com/doc">the doc</a> <a id="mail" href="mailto:dana@example.com?bcc=x@evil.example">mail</a></p>
        """
        let detail = F.conversation(7, count: 1)
        let key = detail.messages[0].id
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: [key: MessageContent(html: html, text: nil)]),
                                             thread: detail.id, windowRouter: true)
        defer { h.close() }
        let web = try await h.shownWebView(key)
        var opened: [(URL, Bool)] = []
        var confirmations: [(SuspiciousLink, () -> Void)] = []
        h.controller.openInBrowser = { opened.append(($0, $1)) }
        h.controller.confirmLink = { link, _, open in confirmations.append((link, open)) }

        h.controller.followLink(URL(string: "https://example.com/doc")!, from: web, modifiers: [])
        #expect(opened.map(\.0) == [URL(string: "https://example.com/doc")!])
        h.controller.followLink(URL(string: "https://example.com/doc")!, from: web, modifiers: .command)
        #expect(opened.last?.1 == true, "⌘-click opens in the background")

        h.controller.followLink(URL(string: "https://login.evil.example/x")!, from: web, modifiers: [])
        #expect(opened.count == 2, "not opened before the confirmation")
        let confirmation = try #require(confirmations.first)
        #expect(confirmation.0.displayedDestination == "bank.example")
        confirmation.1()
        #expect(opened.last?.0 == URL(string: "https://login.evil.example/x")!)

        try await until { h.router.active != nil }
        h.controller.followLink(URL(string: "mailto:dana@example.com?bcc=x@evil.example")!, from: web, modifiers: [])
        try await until { h.environment.composeIfStarted?.windowSession != nil }
        let session = try #require(h.environment.composeIfStarted?.windowSession)
        #expect(session.linkRecipients?.map(\.email) == ["dana@example.com"])
        #expect(session.bcc.tokens.isEmpty)
        #expect(session.linkTriedBcc)
        h.controller.followLink(URL(string: "ftp://example.com/x")!, from: web, modifiers: [])
        #expect(h.toasts.last == "Link type not supported")
        #expect(opened.count == 3)

        _ = try await web.evaluateJavaScript("document.getElementById('good').click(); 0", in: nil, contentWorld: .defaultClient)
        try await until { opened.count == 4 }
        #expect(opened.last?.0 == URL(string: "https://example.com/doc")!)
        #expect(web.rendered != nil, "the message is still loaded: the click was not a navigation")

        _ = try await web.evaluateJavaScript("document.getElementById('bad').dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); 0",
                                             in: nil, contentWorld: .defaultClient)
        try await until { !h.controller.linkPreview.isHidden }
        #expect(h.controller.linkPreview.text == "⚠︎ Shows bank.example · Opens login.evil.example")
        _ = try await web.evaluateJavaScript("document.getElementById('good').dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); 0",
                                             in: nil, contentWorld: .defaultClient)
        try await until { h.controller.linkPreview.text == "example.com/doc" }
    }

    @Test func confirmationPopoverOpensOnlyOnTheExplicitChoice() async throws {
        let html = "<p><a href=\"https://login.evil.example/x\">https://bank.example/</a></p>"
        let detail = F.conversation(8, count: 1)
        let key = detail.messages[0].id
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: [key: MessageContent(html: html, text: nil)]),
                                             thread: detail.id)
        defer { h.close() }
        let web = try await h.shownWebView(key)
        var opened: [URL] = []
        h.controller.openInBrowser = { url, _ in opened.append(url) }
        h.controller.followLink(URL(string: "https://login.evil.example/x")!, from: web, modifiers: [])
        let popover = try #require(h.controller.presentedLinkPopover)
        let content = try #require(popover.contentViewController as? LinkConfirmationViewController)
        #expect(content.warning.lines.first == "The text shows bank.example")
        content.cancel(nil)
        #expect(opened.isEmpty)
        h.controller.followLink(URL(string: "https://login.evil.example/x")!, from: web, modifiers: [])
        let second = try #require(h.controller.presentedLinkPopover?.contentViewController as? LinkConfirmationViewController)
        second.open(nil)
        #expect(opened == [URL(string: "https://login.evil.example/x")!])
    }

    @Test func findMovesAcrossMessagesAndWraps() async throws {
        let detail = F.conversation(9, count: 2, unread: [0, 1])
        let (a, b) = (detail.messages[0].id, detail.messages[1].id)
        let bodies = [a: MessageContent(html: "<p>first needle here</p>", text: nil),
                      b: MessageContent(html: nil, text: "Second message with a needle\nand another needle.")]
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        _ = try await h.shownWebView(a)
        try await until { h.container(b)?.plainBody != nil }
        #expect(h.controller.handleKeyEquivalent(Keys.event("f", code: 3, modifiers: .command)))
        #expect(!h.controller.findBar.isHidden)
        #expect(await h.controller.findNextAsync("needle", backwards: false))
        #expect(h.controller.searchableBodies.count == 2)
        #expect(await h.controller.findNextAsync("needle", backwards: false))
        let plain = try #require(h.container(b)?.plainBody)
        #expect(plain.textView.selectedRange().length == 6)
        let firstPlain = plain.textView.selectedRange()
        #expect(await h.controller.findNextAsync("needle", backwards: false))
        #expect(plain.textView.selectedRange().location > firstPlain.location)
        #expect(await h.controller.findNextAsync("needle", backwards: false), "wraps back to the first message")
        #expect(await h.controller.findNextAsync("needle", backwards: true))
        #expect(await h.controller.findNextAsync("absent", backwards: false) == false)
        #expect(h.controller.findBar.status.stringValue == "Not found")
        h.controller.closeFind()
        #expect(h.controller.findBar.isHidden)
    }

    @Test func zoomKeysScaleHTMLAndPlainBodies() async throws {
        let detail = F.conversation(10, count: 2, unread: [0, 1])
        let (a, b) = (detail.messages[0].id, detail.messages[1].id)
        let bodies = [a: MessageContent(html: String(repeating: "<p>Some text to zoom in on in the reader.</p>", count: 6), text: nil),
                      b: MessageContent(html: nil, text: String(repeating: "Plain text that also zooms.\n", count: 6))]
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        let web = try await h.shownWebView(a)
        let base = try #require(web.measuredHeight)
        try await until {
            h.window.contentView?.layoutSubtreeIfNeeded()
            return (h.container(b)?.plainBody?.measuredHeight ?? 0) > 22
        }
        let plainBase = try #require(h.container(b)?.plainBody?.measuredHeight)
        #expect(h.controller.handleKeyEquivalent(Keys.event("=", code: 24, modifiers: .command)))
        #expect(h.controller.handleKeyEquivalent(Keys.event("=", code: 24, modifiers: .command)))
        #expect(h.controller.preferences.textZoom == 1.25)
        try await until { web.pageZoom == 1.25 && (web.measuredHeight ?? 0) > base * 1.15 }
        try await until {
            h.window.contentView?.layoutSubtreeIfNeeded()
            return (h.container(b)?.plainBody?.measuredHeight ?? 0) > plainBase * 1.15
        }
        #expect(h.controller.handleKeyEquivalent(Keys.event("0", code: 29, modifiers: .command)))
        try await until { web.pageZoom == 1 && abs((web.measuredHeight ?? 0) - base) <= 2 }
    }

    @Test func periodTogglesQuotedTextInHTMLAndPlainBodies() async throws {
        let detail = F.conversation(11, count: 2, unread: [0, 1])
        let (a, b) = (detail.messages[0].id, detail.messages[1].id)
        let plain = "Thanks, see below.\n\nOn Mon, Sam wrote:\n> line one\n> line two\n> line three\n\n-- \nDana\nExample Co."
        let bodies = [a: MessageContent(html: F.gmailReplyHTML, text: nil), b: MessageContent(html: nil, text: plain)]
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        let web = try await h.shownWebView(a)
        let folded = try #require(web.measuredHeight)
        try await until { h.container(b)?.plainBody != nil }
        let plainView = try #require(h.container(b)?.plainBody)
        #expect(!plainView.quotesExpanded)
        #expect(plainView.hasFoldedText)
        #expect(!plainView.textView.string.contains("line two"), "the trailing quote is folded")
        let plainFolded = plainView.measuredHeight

        h.model.focus(a)
        #expect(h.controller.handleKey(Keys.event(".")))
        try await until { (web.measuredHeight ?? 0) > folded + 100 }
        h.model.focus(b)
        #expect(h.controller.handleKey(Keys.event(".")))
        try await until { plainView.quotesExpanded && plainView.textView.string.contains("line two") }
        h.window.contentView?.layoutSubtreeIfNeeded()
        #expect(plainView.measuredHeight > plainFolded)
    }

    @Test func htmlIsNeverShownWithoutTheRuleList() async throws {
        let broken = ReaderWebKit(blockRules: "[{\"trigger\":{}}]", blockIdentifier: "dev.openhuman.mail.tests.broken.\(UUID().uuidString)",
                                  imagesRules: "[]", imagesIdentifier: "dev.openhuman.mail.tests.broken-i.\(UUID().uuidString)")
        let detail = F.conversation(12, count: 1)
        let key = detail.messages[0].id
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: [key: MessageContent(html: "<p>hi</p>", text: nil)]),
                                             thread: detail.id, webKit: broken)
        defer { h.close() }
        try await until {
            subviews(of: NSTextField.self, in: h.controller.view).contains { $0.stringValue == "This message can't be shown safely right now." }
        }
        #expect(subviews(of: ReaderWebView.self, in: h.controller.view).isEmpty)
    }

    @Test func twentyConsecutiveFixtureEmailsShowWithoutAJump() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenHumanMailCore/Tests/Fixtures/emails")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "html" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(20)
        #expect(files.count == 20)
        let details = files.enumerated().map { i, _ in F.conversation(Int64(100 + i), count: 1) }
        var bodies: [MessageKey: MessageContent] = [:]
        for (detail, file) in zip(details, files) { bodies[detail.messages[0].id] = MessageContent(html: try String(contentsOf: file, encoding: .utf8), text: nil) }
        let webKit = ReaderWebKit()
        let source = UITestSource(details: details, bodies: bodies)
        let h = try await ReaderHarness.make(source, thread: details[0].id, webKit: webKit)
        defer { h.close() }
        for (detail, file) in zip(details, files) {
            let model = ReaderModel(thread: detail.id, data: source, renderQueue: h.environment.renderQueue)
            h.controller.model = model
            model.start()
            let key = detail.messages[0].id
            try await until { h.container(key)?.htmlBody?.current != nil }
            let web = try #require(h.container(key)?.htmlBody?.current)
            var reports: [(shown: Bool, alpha: CGFloat, height: CGFloat)] = []
            let relayout = web.onHeightChange
            web.onHeightChange = { height in
                relayout?(height)
                reports.append((web.isShown, web.alphaValue, height))
            }
            try await until { web.isShown }
            let shown = try #require(web.measuredHeight)
            try await until { (try? await web.evaluateJavaScript("document.readyState", in: nil, contentWorld: .defaultClient) as? String) == "complete" }
            #expect(reports.filter { !$0.shown }.allSatisfy { $0.alpha == 0 }, "\(file.lastPathComponent): visible before its height was final")
            #expect(web.alphaValue == 1)
            let after = reports.filter { $0.shown }.map { $0.height }
            #expect(after.allSatisfy { abs($0 - shown) <= 1 }, "\(file.lastPathComponent): height jumped \(after) after \(shown)")
        }
        #expect(webKit.pool.created <= 3, "views are reused: \(webKit.pool.created)")
    }

    @Test func aThemeSwitchReRendersTheOpenConversation() async throws {
        let corpus = FakeCorpus.make(threadCount: 10, now: Date())
        let environment = AppEnvironment.fake(corpus: corpus)
        let content = MainContentViewController(router: AppRouter(environment: environment), theme: .light)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.orderFrontRegardless()
        defer { window.close() }
        try await until { content.windowModel.list?.rows.count == 10 }
        let html = corpus.threads.first { t in
            guard let last = t.detail.messages.last?.id, let kind = t.bodyKinds[last] else { return false }
            return ![FakeBodyKind.plainReply, .plainShort].contains(kind)
        }
        let thread = try #require(html?.row.id)
        content.windowModel.open(thread)
        let model = try #require(content.windowModel.reader)
        func scheme() -> ReaderCSS.ColorScheme? {
            for message in model.messages {
                if case .rendered(.html(let rendered)) = message.body { return rendered.colorScheme }
            }
            return nil
        }
        try await until { scheme() == .light }
        content.apply(theme: .dark)
        try await until { scheme() == .dark }
        #expect(environment.renderQueue.renderer.appearance == .dark)
        let reader = try #require(content.children.compactMap { $0 as? ReaderViewController }.first)
        try await until { reader.messageViews.values.contains { $0.htmlBody?.current?.rendered?.colorScheme == .dark } }
        content.apply(theme: .light)
        try await until { scheme() == .light }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1"))
    func headersAppearWithinAFrame() async throws {
        let detail = F.conversation(13, count: 6, unread: [5])
        var bodies: [MessageKey: MessageContent] = [:]
        for m in detail.messages { bodies[m.id] = MessageContent(html: F.gmailReplyHTML, text: nil) }
        let source = UITestSource(details: [detail], bodies: bodies)
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        _ = try await h.shownWebView(detail.messages[5].id)
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<10 {
            let model = ReaderModel(thread: detail.id, data: source, renderQueue: h.environment.renderQueue)
            let start = clock.now
            h.controller.model = model
            model.start()
            let deadline = clock.now + .seconds(60)
            while h.container(detail.messages[5].id)?.header == nil, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            h.window.contentView?.layoutSubtreeIfNeeded()
            samples.append(clock.now - start)
        }
        let median = samples.sorted()[samples.count / 2]
        print("selection → headers median \(median)")
        #expect(median < .milliseconds(16))
    }
}

@MainActor
final class UIRecordingAccessory: ReaderHeaderAccessory {
    var activated: [MessageKey] = []

    func item(for message: MessageSummary, in thread: ThreadKey) async -> ReaderHeaderAccessoryItem? {
        ReaderHeaderAccessoryItem(title: "Unsubscribe")
    }

    func activate(_ item: ReaderHeaderAccessoryItem, for message: MessageSummary, in thread: ThreadKey) {
        activated.append(message.id)
    }
}
