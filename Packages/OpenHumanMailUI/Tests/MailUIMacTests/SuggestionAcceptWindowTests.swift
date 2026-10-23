import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct SuggestionAcceptWindowTests {
    @Test func tabPutsTheSuggestionInTheBodyAsOneUndoableEdit() async throws {
        let w = try await SuggestionWindow.make(name: "tab")
        defer { w.close() }
        let row = try await w.readyRow()
        let expected = try #require(row.preview?.body)
        w.press(.tab)
        let (session, body) = try await w.acceptedReply(expected)
        #expect(body.string == expected && session.plainText == expected, "exactly the suggestion")
        #expect(body.selectedRange() == NSRange(location: (expected as NSString).length, length: 0), "caret at the end")
        #expect(session.isAutoDraft && session.mode == .reply && session.replyTo == row.message)
        #expect(session.notice == nil)
        try await until { body.window?.firstResponder === body }
        #expect(session.includesSignature && session.signature != nil)
        let html = session.assembledFields().bodyHTML
        #expect(QuoteSplit.quoteBlockCount(html) == 1)
        let text = try #require(html.range(of: "Sounds good"))
        let quote = try #require(html.range(of: "gmail_quote"))
        #expect(text.lowerBound < quote.lowerBound, "the suggestion is above the quote")
        let undo = try #require(body.undoManager)
        undo.undo()
        try await until { session.plainText.isEmpty }
        #expect(body.string.isEmpty)
    }

    @Test func textTheUserTypedFirstGetsNoSuggestion() async throws {
        let w = try await SuggestionWindow.make(name: "typed")
        defer { w.close() }
        let row = try await w.readyRow()
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let body = try #require(w.editors.first)
        try await until { body.window?.firstResponder === body }
        body.insertText("Hi Dana, ", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = w.window.makeFirstResponder(w.reader.focusView)
        #expect(row.state == .none, "only ⌘J's edit tools now")
        row.select(0)
        #expect(await row.accept() == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(body.string == "Hi Dana, " && composer.session.plainText.trimmingCharacters(in: .whitespaces) == "Hi Dana,", "the user's text, untouched")
    }

    @Test func acceptWhileTheReplyIsStillBeingPrepared() async throws {
        let w = try await SuggestionWindow.make(name: "async")
        defer { w.close() }
        let row = try await w.readyRow()
        let expected = try #require(row.preview?.body)
        w.settings.hold()
        w.press(.tab)
        let composer = try await w.inlineComposer(preparing: true)
        let body = try await w.editor(in: composer)
        try await until { body.window?.firstResponder === body }
        w.press(.tab)
        try await until { body.string == "\t" && composer.session.hasUserEdits }
        w.settings.release()
        let (session, shown) = try await w.acceptedReply(expected)
        #expect(shown === body)
        #expect(body.string == expected && session.plainText == expected, "the suggestion, not a tab: \(body.string.debugDescription)")
        #expect(session.isAutoDraft && session.notice == nil)
    }

    @Test func acceptAfterMovingBetweenMessagesWithTheArrowKeys() async throws {
        let w = try await SuggestionWindow.make(name: "arrows")
        defer { w.close() }
        let row = try await w.readyRow(minimumMessages: 2)
        let expected = try #require(row.preview?.body)
        let reader = try #require(w.router.reader)
        w.press(.up)
        try await until { reader.focusedMessage != reader.messages.last?.id }
        w.press(.down)
        w.press(.up)
        w.press(.tab)
        let (session, body) = try await w.acceptedReply(expected)
        #expect(session.replyTo == row.message, "the reply answers the message the suggestion was written for")
        #expect(body.string == expected && session.isAutoDraft)
        #expect(w.environment.compose.sessions.count == 1)
    }

    @Test func useWithTheReplyInTheFullComposer() async throws {
        let w = try await SuggestionWindow.make(name: "modal")
        defer { w.close() }
        let row = try await w.readyRow()
        let expected = try #require(row.preview?.body)
        #expect(w.router.perform(.reply))
        let docked = try await w.inlineComposer()
        let session = docked.session
        session.placement = .modal
        try await until {
            w.window.contentView?.layoutSubtreeIfNeeded()
            return w.reader.inlineComposer == nil && w.editors.count == 1
        }
        let body = try #require(w.editors.first)
        #expect(!body.isDescendant(of: w.reader.view), "the full composer's editor")
        let used = try #require(await row.accept())
        #expect(used === session)
        try await until { body.string == expected }
        #expect(session.plainText == expected && session.isAutoDraft && session.notice == nil)
        #expect(body.selectedRange() == NSRange(location: (expected as NSString).length, length: 0))
        let undo = try #require(body.undoManager)
        undo.undo()
        try await until { session.plainText.isEmpty && body.string.isEmpty }
    }
}

@MainActor
struct SuggestionWindow {
    let environment: AppEnvironment
    let window: NSWindow
    let content: MainContentViewController
    let center: AICenter
    let settings: HeldSettings
    var gated = false

    var router: AppRouter { environment.router }
    var reader: ReaderViewController { content.reader }

    static func make(name: String) async throws -> SuggestionWindow {
        await FocusWindowGate.enter()
        do {
            var window = try await makeUngated(name: name)
            window.gated = true
            return window
        } catch {
            FocusWindowGate.leave()
            throw error
        }
    }

    private static func makeUngated(name: String) async throws -> SuggestionWindow {
        let script = ReplyScript()
        let provider = ScriptedProvider(displayName: "Apple on-device model") { request, _ in script.respond(request) }
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(
                                       AISettings(draftReplies: .onDeviceAuto))))
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let corpus = FakeCorpus.rich(threadCount: 60, now: now)
        let store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate, now: { now }))
        let settings = HeldSettings(store)
        let environment = AppEnvironment(data: store, commands: store, accounts: store, settings: settings, isFake: true,
                                         importance: FakeImportanceRules(corpus: corpus, now: { now }),
                                         aiOnboarding: FakeAIOnboarding(), aiConnections: FakeAIConnections(),
                                         secrets: InMemorySecretStore(), ai: center)
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: .light)))
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: environment, themes: themes) { attached = $0 })
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let frame = NSRect(origin: NSPoint(x: -6000, y: -6000), size: NSSize(width: 1100, height: 800))
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame dev.openhuman.tests.suggestion-\(name)")
        let window = UnconstrainedTestWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                                             backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName("dev.openhuman.tests.suggestion-\(name)"))
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        try await settleWindowChrome(of: window)
        content.keyRouter.isMailWindow = { $0 === window }
        return SuggestionWindow(environment: environment, window: window, content: content, center: center,
                                settings: settings)
    }

    func close() {
        settings.release()
        for session in environment.composeIfStarted?.sessions ?? [] { environment.compose.close(session) }
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(window.frameAutosaveName)")
        if environment.overlays.isShowing { environment.overlays.dismiss() }
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        window.setFrameAutosaveName("")
        window.close()
        window.contentView = nil
        if gated { FocusWindowGate.leave() }
    }

    enum Key: UInt16 {
        case tab = 48, up = 126, down = 125

        var characters: String {
            switch self {
            case .tab: "\t"
            case .up: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .down: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
            }
        }
    }

    func press(_ key: Key) {
        let flags: NSEvent.ModifierFlags = key == .tab ? [] : [.numericPad, .function]
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 100,
                                           windowNumber: window.windowNumber, context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.characters, isARepeat: false,
                                           keyCode: key.rawValue) else { return }
        if content.keyRouter.route(event) != nil { window.sendEvent(event) }
    }

    func readyRow(minimumMessages: Int = 1) async throws -> InlineReplyRow {
        let account = try #require(router.accounts.first?.account)
        let rows = try await environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 500).rows
        for row in rows.prefix(30) {
            router.open(row.id)
            try await until { router.reader?.thread == row.id && router.reader?.state == .loaded }
            guard let reader = router.reader, reader.messages.count >= minimumMessages else { continue }
            let cards = reader.items.filter { if case .message = $0 { true } else { false } }.count
            try? await until { self.reader.messageViews.count == cards }
            _ = window.makeFirstResponder(self.reader.focusView)
            try? await until(timeout: .seconds(4)) {
                guard let current = center.inlineReplies.current else { return false }
                return current.state == .ready || (current.decision != .undecided && current.state == .none)
            }
            if let current = center.inlineReplies.current, current.state == .ready { return current }
        }
        Issue.record("no conversation with suggested replies in the fake inbox")
        throw TimeoutError()
    }

    func inlineComposer(preparing: Bool = false) async throws -> InlineComposerView {
        try await until {
            reader.inlineComposer?.superview != nil && (preparing || reader.inlineComposer?.session.isPreparing == false)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return try #require(reader.inlineComposer)
    }

    var editors: [ComposerTextView] { subviews(of: ComposerTextView.self, in: window.contentView!) }

    func editor(in composer: InlineComposerView) async throws -> ComposerTextView {
        try await until {
            window.contentView?.layoutSubtreeIfNeeded()
            return subviews(of: ComposerTextView.self, in: composer).first != nil
        }
        return try #require(subviews(of: ComposerTextView.self, in: composer).first)
    }

    func acceptedReply(_ expected: String) async throws -> (ComposeSession, ComposerTextView) {
        let composer = try await inlineComposer()
        let body = try await editor(in: composer)
        try? await until(timeout: .seconds(5)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return body.string.contains(expected)
        }
        return (composer.session, body)
    }
}

final class HeldSettings: SettingsPort, @unchecked Sendable {
    private let base: any SettingsPort
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ base: any SettingsPort) { self.base = base }

    func hold() { lock.withLock { held = true } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    func observe<V>(_ key: AppSettingKey<V>) -> AsyncStream<V> { base.observe(key) }

    func get<V>(_ key: AppSettingKey<V>) async throws -> V {
        if key.name == AppSettings.signatureOnReplies.name {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wait = lock.withLock { () -> Bool in
                    guard held else { return false }
                    waiters.append(continuation)
                    return true
                }
                if !wait { continuation.resume() }
            }
        }
        return try await base.get(key)
    }

    func set<V>(_ key: AppSettingKey<V>, _ value: V) async throws { try await base.set(key, value) }
}
