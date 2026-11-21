import Foundation
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import OpenHumanLinks
import Testing
@testable import MailFeatures

@MainActor
struct ReaderPureTests {
    @Test func policyDecisionsAndTheirSources() {
        let sender = "Dana <dana@news.example.com>"
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: [], sender: sender, loadOnce: false) == (.block, nil))
        #expect(RemoteContentPolicy.decision(policy: .ask, allowedSenders: [], sender: sender, loadOnce: false) == (.block, nil))
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: [], sender: sender, loadOnce: true) == (.load, .once))
        #expect(RemoteContentPolicy.decision(policy: .allow, allowedSenders: [], sender: sender, loadOnce: false) == (.load, .policy))
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: ["@example.com"], sender: sender, loadOnce: false)
            == (.load, .allowlist("@example.com")))
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: ["dana@news.example.com"], sender: "DANA@news.example.com",
                                             loadOnce: false) == (.load, .allowlist("dana@news.example.com")))
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: ["@other.example"], sender: sender, loadOnce: false) == (.block, nil))
    }

    @Test func alwaysEntriesAreTheExactSenderAddress() {
        #expect(RemoteContentPolicy.alwaysEntry(forSender: "news@mail.example.com") == "news@mail.example.com")
        #expect(RemoteContentPolicy.alwaysEntry(forSender: "Desk <Desk@Mail.Example.com>") == "desk@mail.example.com")
        #expect(RemoteContentPolicy.alwaysEntry(forSender: "Sam <Sam.Lee@Gmail.com>") == "sam.lee@gmail.com")
        #expect(RemoteContentPolicy.alwaysEntry(forSender: "a@outlook.com") == "a@outlook.com")
        #expect(RemoteContentPolicy.alwaysEntry(forSender: "not an address") == nil)
        let entries = [RemoteContentPolicy.alwaysEntry(forSender: "news@mail.example.com")].compactMap { $0 }
        #expect(entries == ["news@mail.example.com"])
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: entries, sender: "billing@mail.example.com",
                                             loadOnce: false) == (.block, nil))
        #expect(RemoteContentPolicy.decision(policy: .block, allowedSenders: entries, sender: "News <news@mail.example.com>",
                                             loadOnce: false) == (.load, .allowlist("news@mail.example.com")))
        #expect(RemoteContentPolicy.unverifiedSenderNote.contains("can't verify"))
        #expect(RemoteContentPolicy.displayName(ofEntry: "@example.com") == "example.com")
        #expect(RemoteContentPolicy.adding("@Example.com", to: ["@example.com"]) == ["@example.com"])
        #expect(RemoteContentPolicy.adding("@b.example", to: ["@a.example"]) == ["@a.example", "@b.example"])
        #expect(RemoteContentPolicy.removingEntries(for: "x@news.example.com", from: ["@example.com", "@news.example.com", "@other.example", "x@news.example.com"])
            == ["@other.example"])
    }

    @Test func colorOverridesAreKeyedByAddress() {
        var map = RemoteContentPolicy.setting(.darkColors, forSender: "Dana <DANA@example.com>", in: [:])
        #expect(map == ["dana@example.com": "darkColors"])
        #expect(RemoteContentPolicy.colorOverride(forSender: "dana@example.com", in: map) == .darkColors)
        map = RemoteContentPolicy.setting(nil, forSender: "dana@example.com", in: map)
        #expect(map.isEmpty)
        #expect(RemoteContentPolicy.colorOverride(forSender: nil, in: ["": "darkColors"]) == nil)
    }

    @Test func headerBlockLinesAndCopyText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatting = ReaderFormatting(calendar: calendar, locale: Locale(identifier: "en_US"))
        let message = MessageSummary(
            id: ReaderFixtures.message(1), from: EmailAddress(name: "Dana Ruiz", email: "dana@example.com"),
            to: [EmailAddress(name: nil, email: "robin@example.com"), EmailAddress(name: "Sam", email: "sam@example.com")],
            cc: [EmailAddress(name: "dana@example.com", email: "dana@example.com")], bcc: [],
            date: Date(timeIntervalSince1970: 1_791_000_000), snippet: "", isUnread: false, attachments: [])
        let lines = formatting.headerLines(message)
        #expect(lines.map(\.label) == ["From", "To", "Cc", "Date"])
        #expect(lines[0].value == "Dana Ruiz <dana@example.com>")
        #expect(lines[1].value == "robin@example.com, Sam <sam@example.com>")
        #expect(lines[2].value == "dana@example.com", "a name equal to the address is not repeated")
        #expect(lines[3].value.contains("2026"))
        let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")
        #expect(ReaderFormatting.copyText(dana, includingName: false) == "dana@example.com")
        #expect(ReaderFormatting.copyText(dana, includingName: true) == "Dana Ruiz <dana@example.com>")
    }

    @Test func attachmentTextTilesAndSafeNames() {
        let formatting = ReaderFormatting(locale: Locale(identifier: "en_US"))
        let pdf = AttachmentInfo(id: 1, filename: "plan.pdf", mimeType: "application/pdf", size: 2_100_000, contentID: nil, isInline: false)
        let chart = AttachmentInfo(id: 2, filename: "chart.png", mimeType: "image/png", size: 2_100_000, contentID: "<chart-1@x>", isInline: true)
        #expect(formatting.attachmentsSummary([pdf, chart]).hasPrefix("2 attachments · 4.2 MB"))
        #expect(formatting.attachmentsSummary([pdf]).hasPrefix("1 attachment · "))
        #expect(ReaderFormatting.tiles([pdf, chart], shownInline: ["chart-1@x"]) == [pdf], "shown inline: no tile")
        #expect(ReaderFormatting.tiles([pdf, chart], shownInline: []) == [pdf, chart], "not referenced: a tile")
        #expect(ReaderFormatting.safeFilename("../../etc/passwd") == "-..-etc-passwd")
        #expect(ReaderFormatting.safeFilename("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(ReaderFormatting.safeFilename(" .hidden\u{0007}") == "hidden")
        #expect(ReaderFormatting.safeFilename("") == "attachment")
        #expect(ReaderFormatting.safeFilename("a:b\\c") == "a-b-c")
        let long = ReaderFormatting.safeFilename(String(repeating: "x", count: 300) + ".pdf")
        #expect(long.count == 200 && long.hasSuffix(".pdf"))
    }

    @Test func safeNamesFitTheFileSystemsByteLimitAndCanBeWritten() throws {
        func bytes(_ name: String) -> Int { name.decomposedStringWithCanonicalMapping.utf8.count }
        #expect(ReaderFormatting.maxFilenameBytes <= 255 - 16, "room for a collision suffix")
        let emoji = ReaderFormatting.safeFilename(String(repeating: "😀", count: 180) + ".pdf")
        #expect(emoji.hasSuffix(".pdf") && bytes(emoji) <= ReaderFormatting.maxFilenameBytes)
        #expect(emoji.dropLast(4).allSatisfy { $0 == "😀" })
        let decomposing = ReaderFormatting.safeFilename(String(repeating: "é", count: 120) + ".txt")
        #expect(decomposing.hasSuffix(".txt") && bytes(decomposing) <= ReaderFormatting.maxFilenameBytes)
        let toned = ReaderFormatting.safeFilename(String(repeating: "👍🏽", count: 60) + ".zip")
        #expect(toned.hasSuffix(".zip") && toned.dropLast(4).allSatisfy { $0 == "👍🏽" }, "never splits a character")
        let piled = ReaderFormatting.safeFilename("a" + String(repeating: "\u{301}", count: 300) + ".pdf")
        #expect(piled == "a" + String(repeating: "\u{301}", count: ReaderFormatting.maxCombiningRun) + ".pdf")
        let selectors = ReaderFormatting.safeFilename("a" + String(repeating: "\u{FE0F}", count: 300) + ".pdf")
        #expect(selectors.unicodeScalars.first == "a" && selectors.hasSuffix(".pdf") && bytes(selectors) <= ReaderFormatting.maxFilenameBytes)
        #expect(ReaderFormatting.safeFilename("Plan 😀 é.pdf") == "Plan 😀 é.pdf")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oh-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in [emoji, decomposing, toned, piled] {
            try Data("first".utf8).write(to: folder.appendingPathComponent(name))
            let second = AttachmentFiles.uniqueURL(in: folder, filename: name)
            try Data("second".utf8).write(to: second)
            #expect(second.lastPathComponent != name)
        }
    }

    @Test func bannerAndWarningText() throws {
        #expect(ReaderFormatting.imagesHiddenText(blockedCount: 0) == "Remote images hidden for privacy.")
        #expect(ReaderFormatting.imagesHiddenText(blockedCount: 1) == "1 remote image hidden for privacy.")
        #expect(ReaderFormatting.imagesHiddenText(blockedCount: 3) == "3 remote images hidden for privacy.")
        #expect(ReaderFormatting.imagesShownText(source: .once, trackerCount: 2) == "Images shown · 2 trackers blocked")
        #expect(ReaderFormatting.imagesShownText(source: .allowlist("@example.com"), trackerCount: 0)
            == "Images always shown for example.com")
        let link = try #require(LinkAnalyzer.check(href: "https://login.evil.example/x", displayText: "https://bank.example/"))
        let warning = ReaderFormatting.warning(for: link)
        #expect(warning.lines == ["The text shows bank.example", "It opens evil.example (login.evil.example)"])
        let ip = try #require(LinkAnalyzer.check(href: "https://10.0.0.1/a", displayText: "Click"))
        #expect(ReaderFormatting.warning(for: ip).lines.contains("The address is a bare IP address."))
        #expect(ReaderFormatting.hoverText(URL(string: "https://example.com/a/b")!) == "example.com/a/b")
        let longURL = URL(string: "https://example.com/" + String(repeating: "p", count: 300))!
        #expect(ReaderFormatting.hoverText(longURL).count == 120)
    }

    @Test func linksResolveByScheme() {
        #expect(ReaderLinkAction.resolve(URL(string: "https://example.com/a")!) == .openInBrowser(URL(string: "https://example.com/a")!))
        guard case .compose(let prefill) = ReaderLinkAction.resolve(URL(string: "mailto:dana@example.com?subject=Hi&bcc=spy@evil.example")!) else {
            Issue.record("mailto should compose"); return
        }
        #expect(prefill.to == ["dana@example.com"])
        #expect(prefill.droppedBcc)
        guard case .inApp = ReaderLinkAction.resolve(URL(string: "openhuman://thread/robin@example.com/18c2a1f0b9")!) else {
            Issue.record("openhuman should route in the app"); return
        }
        for raw in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/x", "data:text/html,hi", "https:///nohost"] {
            #expect(ReaderLinkAction.resolve(URL(string: raw)!) == .unsupported, "\(raw)")
        }
    }

    @Test func linksFollowThroughTheRouterAndNeverMutate() async {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow))
        let router = env.router
        router.start()
        await eventually { router.accountsLoaded && router.active != nil }
        let compose = ReaderLinkAction.resolve(URL(string: "mailto:dana@example.com")!)
        #expect(compose.follow(with: router) == nil)
        #expect(env.composeIfStarted?.windowSession?.linkRecipients?.map(\.email) == ["dana@example.com"])
        #expect(ReaderLinkAction.unsupported.follow(with: router) == "Link type not supported")
        #expect(ReaderLinkAction.openInBrowser(URL(string: "https://example.com")!).follow(with: router) == nil)
    }

    @Test func zoomStepsAndPersistence() throws {
        let defaults = ScopedDefaults("dev.openhuman.mail.tests")
        defer { defaults.cleanup() }
        let preferences = ReaderPreferences(defaults: defaults)
        #expect(preferences.textZoom == 1)
        preferences.zoomIn()
        preferences.zoomIn()
        #expect(preferences.textZoom == 1.25)
        #expect(ReaderPreferences(defaults: defaults).textZoom == 1.25, "kept across launches")
        for _ in 0..<10 { preferences.zoomIn() }
        #expect(preferences.textZoom == 1.5 && !preferences.canZoomIn && preferences.zoomPercent == "150%")
        for _ in 0..<10 { preferences.zoomOut() }
        #expect(preferences.textZoom == 0.9 && !preferences.canZoomOut && preferences.zoomPercent == "90%")
        preferences.resetZoom()
        #expect(preferences.textZoom == 1)
        preferences.setZoom(1.25)
        #expect(preferences.textZoom == 1.25)
        preferences.setZoom(1.3)
        #expect(preferences.textZoom == 1.25, "only a step")
        defaults.set(7.0, forKey: ReaderPreferences.zoomKey)
        #expect(ReaderPreferences(defaults: defaults).textZoom == 1, "an unknown stored value is ignored")
        defaults.set(2.0, forKey: ReaderPreferences.zoomKey)
        #expect(ReaderPreferences(defaults: defaults).textZoom == 1.5, "an earlier build's 200% reads as 150%")
        defaults.set(0.8, forKey: ReaderPreferences.zoomKey)
        #expect(ReaderPreferences(defaults: defaults).textZoom == 0.9, "and 80% as 90%")
    }

    @Test func renderQueueCachesByTheFullKey() async {
        let queue = RenderQueue()
        let key = ReaderFixtures.message(5)
        let content = MessageContent(html: ReaderFixtures.plainHTML, text: nil)
        _ = await queue.render(content, for: key)
        _ = await queue.render(content, for: key)
        #expect(await queue.renderCount == 1)
        _ = await queue.render(content, for: key, context: RenderContext(allowRemoteImages: true))
        #expect(await queue.renderCount == 2, "the image decision is part of the key")
        _ = await queue.render(content, for: key, renderer: MessageRenderer(theme: .dark, appearance: .dark))
        #expect(await queue.renderCount == 3, "so are theme and appearance")
        _ = await queue.render(MessageContent(html: ReaderFixtures.plainHTML + "!", text: nil), for: key)
        #expect(await queue.renderCount == 4, "and the content")
    }

    @Test func renderQueueRetainsAtMostItsByteLimit() async {
        let limit = 1_048_576
        let queue = RenderQueue(byteLimit: limit)
        let paragraph = "<p>" + String(repeating: "lorem ipsum dolor ", count: 1_100) + "</p>"
        var maxSeen = 0
        for i in 0..<300 {
            let content = MessageContent(html: paragraph + "<p>variant \(i)</p>", text: nil)
            _ = await queue.render(content, for: ReaderFixtures.message(Int64(i)))
            maxSeen = max(maxSeen, await queue.cachedBytes)
        }
        #expect(await queue.renderCount == 300)
        #expect(maxSeen <= limit)
        #expect(await queue.cachedBytes > limit / 2, "the bound is used, not just respected")
        #expect(await queue.cachedCount < 300)
        let newest = MessageContent(html: paragraph + "<p>variant 299</p>", text: nil)
        _ = await queue.render(newest, for: ReaderFixtures.message(299))
        #expect(await queue.renderCount == 300)
        let oldest = MessageContent(html: paragraph + "<p>variant 0</p>", text: nil)
        _ = await queue.render(oldest, for: ReaderFixtures.message(0))
        #expect(await queue.renderCount == 301)
    }

    @Test func aCancelledRenderJobIsSkippedWithoutRendering() async {
        let queue = RenderQueue()
        let content = MessageContent(html: ReaderFixtures.plainHTML, text: nil)
        let key = ReaderFixtures.message(7)
        let (stream, gate) = AsyncStream.makeStream(of: Void.self)
        let job = Task { () -> RenderedBody? in
            for await _ in stream { break }
            return await queue.renderUnlessCancelled(content, for: key)
        }
        job.cancel()
        gate.yield(())
        #expect(await job.value == nil)
        #expect(await queue.renderCount == 0)
        #expect(await queue.skippedCancelled == 1)
        #expect(await queue.cachedCount == 0)
        #expect(await queue.renderUnlessCancelled(content, for: key) != nil)
        let again = Task { () -> RenderedBody? in
            for await _ in stream { break }
            return await queue.renderUnlessCancelled(content, for: key)
        }
        again.cancel()
        gate.yield(())
        #expect(await again.value != nil)
        #expect(await queue.renderCount == 1)
        #expect(await queue.skippedCancelled == 1)
    }
}

@MainActor
struct ReaderStateTextTests {
    @Test func aConversationThatCannotBeShownSaysWhy() {
        #expect(ReaderFormatting.conversationTitle(subject: "Plans", state: .loaded, hasMessages: true) == "Plans")
        #expect(ReaderFormatting.conversationTitle(subject: "", state: .loading, hasMessages: false) == "")
        #expect(ReaderFormatting.conversationTitle(subject: "Plans", state: .missing, hasMessages: false)
            == "This conversation is no longer here.")
        #expect(ReaderFormatting.conversationTitle(subject: "", state: .failed("x"), hasMessages: false)
            == "Couldn't open this conversation.")
        #expect(ReaderFormatting.conversationTitle(subject: "Plans", state: .failed("x"), hasMessages: true) == "Plans")
    }

    @Test func filesThatRunOrOpenSomethingAskBeforeOpening() {
        #expect(AttachmentRisk.of(filename: "Report.pdf") == nil)
        #expect(AttachmentRisk.of(filename: "Setup.APP") == .runsCode)
        #expect(AttachmentRisk.of(filename: "update.pkg") == .installer)
        #expect(AttachmentRisk.of(filename: "site.webloc") == .opensLocation)
        #expect(AttachmentRisk.of(filename: "share.afploc") == .opensLocation)
        #expect(AttachmentRisk.of(filename: "files.ftploc") == .opensLocation)
        #expect(AttachmentRisk.of(filename: "screen.vncloc") == .opensLocation)
        #expect(ReaderFormatting.openWarning(filename: "notes.txt") == nil)
        #expect(ReaderFormatting.openWarning(filename: "share.afploc")?.title == "Open “share.afploc”?")
        let onDisk = URL(fileURLWithPath: "/tmp/cache/run.command")
        #expect(ReaderFormatting.openWarning(filename: "notes.txt", file: onDisk) != nil)
    }
}
