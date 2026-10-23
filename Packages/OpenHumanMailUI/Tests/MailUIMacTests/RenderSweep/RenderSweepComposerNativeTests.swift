import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailUIMac

extension SweepTheme {
    static let composerNative: [SweepTheme] = builtIns.filter { ["light", "dark", "paper"].contains($0.slug) }
}

extension RenderSweepTests {
    private static let dana = EmailAddress(name: "Dana Reyes", email: "dana@example.org")
    private static let sam = EmailAddress(name: "Sam Lee", email: "sam@example.org")
    private static let ops = EmailAddress(name: "Ops Desk", email: "ops@example.org")
    private static let lee = EmailAddress(name: "Lee Park", email: "lee@example.org")

    private static func chooseAnotherFrom(_ session: ComposeSession) throws {
        let alias = try #require(session.fromChoices.first { $0 != session.from }, "the synthetic account has a second address")
        session.chooseFrom(alias)
        #expect(session.showsFromReason, "a second address shows why it was picked")
    }

    private static func syntheticFiles() throws -> (folder: URL, files: [URL]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oh-sweep-attachments-\(UUID().uuidString)") // temp-ok: removed by the caller's defer
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [("Offsite agenda.pdf", 184_320), ("Whiteboard photo.png", 1_240_000), ("Budget draft.xlsx", 46_080)]
        let urls = try files.map { name, size in
            let url = folder.appendingPathComponent(name)
            try Data(repeating: 0x20, count: size).write(to: url)
            return url
        }
        return (folder, urls)
    }

    @Test(arguments: SweepTheme.composerNative)
    func composerNativeNewMessageAndAttachments(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        session.to.setTokens([Self.dana, Self.sam, EmailAddress(email: "pat.example.org")])
        session.subject = "Plan for the offsite"
        let editor = try #require(w.editors.first)
        editor.insertText("Hi both,\nHere is the plan for the offsite. Comments welcome before Thursday noon.",
                          replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("offsite") }
        try await sweepShoot(w.window, screen: "composer-native-new-message", theme: theme)

        let (folder, files) = try Self.syntheticFiles()
        defer { try? FileManager.default.removeItem(at: folder) }
        session.attach(files)
        try await until { session.fileAttachments.count == files.count }
        try await sweepShoot(w.window, screen: "composer-native-attachments", theme: theme)
    }

    @Test(arguments: SweepTheme.composerNative)
    func composerNativeReplyWithChips(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, messages) = try await w.longestConversation()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2]
        model.reveal(middle.id)
        model.focus(middle.id)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let session = composer.session
        #expect(!session.to.tokens.isEmpty, "the reply is addressed to the sender")
        session.showCc()
        session.cc.setTokens([Self.ops, Self.sam])
        let editor = try #require(w.editors.first)
        editor.insertText("Thursday at 10 works for me. I'll bring the draft agenda.", replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("Thursday") }
        try await sweepShoot(w.window, screen: "composer-native-reply-chips", theme: theme)
    }

    @Test(arguments: SweepTheme.composerNative)
    func composerNativeWithTheAIPanel(_ theme: SweepTheme) async throws {
        let center = AICenter.make(registry: ProviderRegistry(providers: [ScriptedProvider()]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(AISettings())))
        let environment = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                              featureFlags: FeatureFlags(), ai: center)
        let w = try await SweepWindow.make(environment, theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        session.to.setTokens([Self.dana])
        session.subject = "Offsite follow-up"
        let editor = try #require(w.editors.first)
        editor.insertText("Thanks for joining today.", replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("joining") }
        let panel = try #require(center.togglePanel(session))
        try await until { session.aiPanel === panel }
        try await sweepShoot(w.window, screen: "composer-native-ai-panel", theme: theme)
        panel.close()
    }

    @Test(arguments: SweepTheme.composerNative)
    func composerNativeForwardWithTheOriginalFiles(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let account = try #require(w.router.accounts.first?.account)
        let rows = try await w.environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 500).rows
        var found: (ThreadKey, [AttachmentInfo])?
        for row in rows where row.attachmentCount > 0 {
            var files: [AttachmentInfo] = []
            for try await detail in w.environment.data.threadDetail(row.id) {
                files = detail?.messages.last?.attachments.filter { !$0.isInline } ?? []
                break
            }
            if !files.isEmpty {
                found = (row.id, files)
                break
            }
        }
        let (thread, files) = try #require(found, "a conversation whose newest message has files")
        _ = try await w.open(thread)
        #expect(w.router.perform(.forward))
        let composer = try await w.inlineComposer()
        let session = composer.session
        try await until { session.fileAttachments.count == files.count && !session.quotedHTML.isEmpty }
        session.to.setTokens([Self.sam])
        let editor = try #require(w.editors.first)
        editor.insertText("Forwarding the files from this thread.", replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("Forwarding") }
        try await sweepShoot(w.window, screen: "composer-native-forward-files", theme: theme)
    }

    @Test(arguments: SweepTheme.composerNative)
    func composerNativeCcBccAndTheFromReason(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let compose = w.environment.compose
        #expect(w.router.perform(.compose))
        try await until { compose.windowSession?.placement == .modal }
        let session = try #require(compose.windowSession)
        await session.settle()
        session.to.setTokens([Self.dana, Self.sam])
        session.showCc()
        session.cc.setTokens([Self.ops])
        session.showBcc()
        session.bcc.setTokens([Self.lee])
        session.subject = "Budget review"
        try Self.chooseAnotherFrom(session)
        let editor = try #require(w.editors.first)
        editor.insertText("Hi all,\nThe budget review moves to Friday at 2. The draft numbers are attached.",
                          replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("budget") }
        try await sweepShoot(w.window, screen: "composer-native-cc-bcc-from", theme: theme)
    }

    @Test(arguments: SweepTheme.composerNative)
    func composerNativeReplyFromReasonFormatBarAndNotice(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let session = composer.session
        try Self.chooseAnotherFrom(session)
        let editor = try #require(subviews(of: ComposerTextView.self, in: composer).first)
        editor.insertText("Friday works. I'll send the room details in the morning.", replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("Friday") }
        try await sweepShoot(w.window, screen: "composer-native-reply-from", theme: theme)

        w.environment.compose.toggleFormatBar()
        try await sweepShoot(w.window, screen: "composer-native-reply-format-bar", theme: theme)
        w.environment.compose.toggleFormatBar()

        session.notice = ComposeSession.Notice(.error, "Couldn't send. The connection dropped; your draft is kept.",
                                               offersSendAgain: true)
        try await sweepShoot(w.window, screen: "composer-native-reply-notice", theme: theme)
        session.notice = nil
    }
}
