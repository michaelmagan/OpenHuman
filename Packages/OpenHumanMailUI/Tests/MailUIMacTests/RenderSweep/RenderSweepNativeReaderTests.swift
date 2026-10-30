import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    private static func nativeReaderWindow(_ corpus: FakeCorpus, theme: SweepTheme,
                                           size: NSSize = SweepWindow.size) async throws -> InlineReplyWindow {
        let environment = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags())
        return try await SweepWindow.make(environment, theme: theme, size: size)
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func readerNativeConversation(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.longestConversation()
        let model = try await w.open(thread)
        try await sweepShoot(w.window, screen: "reader-native-thread", theme: theme)

        model.expandAll()
        try await until { model.messages.allSatisfy(\.isExpanded) && w.reader.messageViews.values.allSatisfy(\.isExpanded) }
        try await sweepShoot(w.window, screen: "reader-native-expanded", theme: theme)

        let newest = try #require(model.messages.last?.id)
        let header = try #require(w.reader.messageViews[newest]?.header)
        header.toggleDetails()
        try await sweepShoot(w.window, screen: "reader-native-details", theme: theme)
        header.toggleDetails()

        w.reader.showFind()
        w.reader.findBar.field.stringValue = "the"
        try await sweepShoot(w.window, screen: "reader-native-find", theme: theme)
        w.reader.closeFind()
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func readerNativeAttachments(_ theme: SweepTheme) async throws {
        let corpus = FakeCorpus.small
        // A calendar invite shows as its card, not as a tile, so the message needs a file that is not one
        func hasFile(_ message: MessageSummary) -> Bool {
            message.attachments.contains { $0.contentID == nil } && InviteCenter.calendarPart(of: message.attachments) == nil
        }
        let thread = try #require(corpus.threads.first { $0.detail.messages.contains(where: hasFile) },
                                  "a conversation with a file attached that is not an invite")
        let w = try await Self.nativeReaderWindow(corpus, theme: theme)
        defer { w.close() }
        let model = try await w.open(thread.row.id)
        let message = try #require(model.messages.last { hasFile($0.summary) }?.id)
        model.expandAll()
        try await until { w.reader.messageViews[message]?.attachmentsStrip != nil }
        try await sweepShoot(w.window, screen: "reader-native-attachments", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func readerNativeLongSubject(_ theme: SweepTheme) async throws {
        let corpus = FakeCorpus.small
        let thread = try #require(corpus.threads.max { $0.detail.subject.count < $1.detail.subject.count })
        let w = try await Self.nativeReaderWindow(corpus, theme: theme, size: NSSize(width: 900, height: 860))
        defer { w.close() }
        _ = try await w.open(thread.row.id)
        try await sweepShoot(w.window, screen: "reader-native-long-subject", theme: theme)
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func readerNativePlainText(_ theme: SweepTheme) async throws {
        let corpus = FakeCorpus.small
        let thread = try #require(corpus.threads.first { candidate in
            candidate.detail.messages.last.map { [.plainReply, .plainShort].contains(candidate.bodyKinds[$0.id]) } == true
        }, "a conversation whose newest message is plain text")
        let w = try await Self.nativeReaderWindow(corpus, theme: theme)
        defer { w.close() }
        let model = try await w.open(thread.row.id)
        let newest = try #require(model.messages.last?.id)
        try await until { w.reader.messageViews[newest]?.plainBody != nil }
        try await sweepShoot(w.window, screen: "reader-native-plain-text", theme: theme)
    }
}
