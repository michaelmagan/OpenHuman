import AppKit
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
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct ReaderSnapshotTests {
    typealias F = UIFixtures

    @Test(arguments: [("light", ThemeTokens.light), ("dark", ThemeTokens.dark)])
    func renderReaderStates(_ name: String, _ theme: ThemeTokens) async throws {
        let shots = SnapshotRenderTests()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reader-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdfFile = folder.appendingPathComponent("plan.pdf")
        try Data("%PDF-1.4 synthetic".utf8).write(to: pdfFile)

        var detail = F.conversation(1, count: 8, unread: [7], subject: "Q4 planning: budget, dates and the newsletter draft")
        let pdf = AttachmentInfo(id: 1, filename: "Q4 plan.pdf", mimeType: "application/pdf", size: 2_200_000, contentID: nil, isInline: false)
        let sheet = AttachmentInfo(id: 2, filename: "Budget.xlsx", mimeType: "application/vnd.ms-excel", size: 48_000, contentID: nil, isInline: false)
        var messages = detail.messages
        messages[7] = F.summary(107, unread: true, minutesAgo: 30, attachments: [pdf, sheet],
                                cc: [EmailAddress(name: "Lee Park", email: "lee@example.com")])
        detail = ConversationDetail(id: detail.id, subject: detail.subject, messages: messages)
        var bodies: [MessageKey: MessageContent] = [:]
        for m in detail.messages { bodies[m.id] = MessageContent(html: nil, text: "Body \(m.id.rowID)") }
        bodies[messages[7].id] = MessageContent(html: F.newsletterHTML, text: nil)
        let accessory = UIRecordingAccessory()
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies, files: [1: pdfFile]),
                                             thread: detail.id, theme: theme,
                                             accessorySlot: ReaderHeaderAccessoryStore(current: accessory))
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 860), display: true)
        let key = messages[7].id
        _ = try await h.shownWebView(key)
        try await until { h.container(key)?.header?.accessoryTitle != nil }
        h.container(key)?.header?.toggleDetails()
        h.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        try shots.snapshot(h.window, name: "reader-\(name)-thread")

        h.model.loadImagesOnce(key)
        try await until { (h.container(key)?.banner as? ImagesShownView) != nil && h.container(key)?.htmlBody?.incoming == nil }
        h.controller.linkPreview.show(URL(string: "https://login.evil.example/x"),
                                      suspicious: LinkAnalyzer.check(href: "https://login.evil.example/x", displayText: "https://bank.example/"))
        h.controller.showFind()
        h.controller.findBar.field.stringValue = "Body"
        _ = await h.controller.findNextAsync("Body", backwards: false)
        try await Task.sleep(for: .milliseconds(200))
        try shots.snapshot(h.window, name: "reader-\(name)-images-find")
    }

    @Test func renderPlainTextAndQuotes() async throws {
        let shots = SnapshotRenderTests()
        let detail = F.conversation(2, count: 2, unread: [0, 1], subject: "Notes")
        let plain = "Thanks, looks right.\n\nTwo small things: page 3 totals and the dates.\nhttps://docs.example.com/q4\n\nOn Mon, Sam wrote:\n> Here is the draft.\n> > Earlier: before Friday?\n\n-- \nDana\nExample Co."
        let bodies = [detail.messages[0].id: MessageContent(html: F.gmailReplyHTML, text: nil),
                      detail.messages[1].id: MessageContent(html: nil, text: plain)]
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 860), display: true)
        _ = try await h.shownWebView(detail.messages[0].id)
        try await Task.sleep(for: .milliseconds(200))
        try shots.snapshot(h.window, name: "reader-quotes-folded")
        h.model.toggleQuotedText(detail.messages[0].id)
        h.model.toggleQuotedText(detail.messages[1].id)
        try await Task.sleep(for: .milliseconds(400))
        try shots.snapshot(h.window, name: "reader-quotes-open")
    }
}
