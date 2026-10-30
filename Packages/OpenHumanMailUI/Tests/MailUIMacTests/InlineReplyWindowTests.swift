import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
struct InlineReplyWindow {
    let environment: AppEnvironment
    let window: NSWindow
    let content: MainContentViewController
    var gated = false

    var router: AppRouter { environment.router }
    var reader: ReaderViewController { content.reader }

    static func make(size: NSSize = NSSize(width: 1100, height: 1000),
                     mode: AppearanceMode = .light, frameName: String = "dev.openhuman.tests.inline-reply",
                     heldSends: FakeMailStore.Options.HeldSends = .realTime,
                     ai: AICenter? = nil, reduceMotion: Bool = false,
                     featureFlags: FeatureFlags = .atLaunch,
                     exclusive: Bool = false, environment: AppEnvironment? = nil) async throws -> InlineReplyWindow {
        if exclusive { await FocusWindowGate.enter() }
        do {
            var window = try await makeUngated(size: size, mode: mode, frameName: frameName, heldSends: heldSends, ai: ai, reduceMotion: reduceMotion, featureFlags: featureFlags, environment: environment)
            window.gated = exclusive
            return window
        } catch {
            if exclusive { FocusWindowGate.leave() }
            throw error
        }
    }

    private static func makeUngated(size: NSSize = NSSize(width: 1100, height: 1000),
                     mode: AppearanceMode = .light, frameName: String = "dev.openhuman.tests.inline-reply",
                     heldSends: FakeMailStore.Options.HeldSends = .realTime,
                     ai: AICenter? = nil, reduceMotion: Bool = false,
                     featureFlags: FeatureFlags = .atLaunch,
                     environment given: AppEnvironment? = nil) async throws -> InlineReplyWindow {
        let environment = given ?? AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate, heldSends: heldSends),
                                              featureFlags: featureFlags, ai: ai, notices: NoticeCenter(autoExpire: false))
        let themes = ThemeStore(preferencesStore: MemoryThemePreferencesStore(ThemePreferences(mode: mode)),
                                reduceMotion: reduceMotion)
        var attached: MainContentViewController?
        let hosting = NSHostingView(rootView: MainWindowRoot(environment: environment, themes: themes) { attached = $0 })
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let frame = NSRect(origin: NSPoint(x: -6000, y: -6000), size: size)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(frameName)")
        let window = UnconstrainedTestWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                                             backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        #expect(window.setFrameAutosaveName(frameName), "the frame name \(frameName) is free")
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        try await until { attached != nil && environment.router.list?.state == .loaded }
        let content = try #require(attached)
        try await settleWindowChrome(of: window)
        content.keyRouter.isMailWindow = { $0 === window }
        return InlineReplyWindow(environment: environment, window: window, content: content)
    }

    func close() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(window.frameAutosaveName)")
        environment.composeIfStarted?.windowSession.map { environment.compose.close($0) }
        if environment.overlays.isShowing { environment.overlays.dismiss() }
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        window.setFrameAutosaveName("")
        window.close()
        window.contentView = nil
        if gated { FocusWindowGate.leave() }
    }

    func resize(_ size: NSSize) {
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func conversationWithAMiddleSender() async throws -> (ThreadKey, [MessageSummary]) {
        let account = try #require(router.accounts.first?.account)
        let rows = try await environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 500).rows
        var fallback: (ThreadKey, [MessageSummary])?
        for row in rows {
            var messages: [MessageSummary] = []
            for try await detail in environment.data.threadDetail(row.id) {
                messages = detail?.messages ?? []
                break
            }
            guard messages.count >= 3 else { continue }
            let middle = messages[messages.count - 2]
            guard let sender = middle.from?.email, !account.isMe(sender) else { continue }
            if fallback == nil { fallback = (row.id, messages) }
            if sender != messages.last?.from?.email { return (row.id, messages) }
        }
        return try #require(fallback)
    }

    func open(_ thread: ThreadKey) async throws -> ReaderModel {
        router.open(thread)
        try await until { router.reader?.thread == thread && router.reader?.state == .loaded }
        let model = try #require(router.reader)
        try await until { reader.messageViews.count == model.items.filter { if case .message = $0 { true } else { false } }.count }
        try await settleWindowChrome(of: window)
        return model
    }

    func inlineComposer() async throws -> InlineComposerView {
        try await until { reader.inlineComposer?.superview != nil && reader.inlineComposer?.session.isPreparing == false }
        window.contentView?.layoutSubtreeIfNeeded()
        return try #require(reader.inlineComposer)
    }

    var editors: [ComposerTextView] { subviews(of: ComposerTextView.self, in: window.contentView!) }

    func isUnderItsMessage(_ composer: InlineComposerView) -> Bool {
        guard let host = composer.hostMessage, let header = host.header ?? host.collapsedRow else { return false }
        window.contentView?.layoutSubtreeIfNeeded()
        let card = host.convert(host.bounds, to: nil)
        let frame = composer.convert(composer.bounds, to: nil)
        let message = header.convert(header.bounds, to: nil)
        return frame.maxY <= message.minY - 0.5 && card.contains(frame.insetBy(dx: 0.5, dy: 0.5))
    }
}

@MainActor
@Suite(.serialized) struct InlineReplyWindowTests {
    @Test func theReplyIsInsideTheConversationStackAndCoversNoMessageAtAnySize() async throws {
        let w = try await InlineReplyWindow.make()
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        #expect(composer.isDescendant(of: w.reader.view), "inside the reader")
        #expect(w.editors.count == 1 && w.editors.first?.isDescendant(of: composer) == true,
                "one editor, the inline one (nothing laid over the conversation)")
        let last = try #require(messages.last?.id)
        #expect(model.replyTarget == last)
        let lastView = try #require(w.reader.messageViews[last])
        #expect(composer.hostMessage === lastView, "inside the newest message's card, not an overlay")
        #expect(w.isUnderItsMessage(composer), "under the message, inside its card")
        try await until {
            w.window.contentView?.layoutSubtreeIfNeeded()
            let visible = w.reader.focusView.visibleRect
            return visible.contains(composer.convert(composer.bounds, to: w.reader.focusView).insetBy(dx: 1, dy: 1))
        }
        for size in [NSSize(width: 640, height: 700), NSSize(width: 900, height: 720), NSSize(width: 1100, height: 800),
                     NSSize(width: 1400, height: 900)] {
            w.resize(size)
            let card = composer.convert(composer.cardFrame, to: nil)
            #expect(card.width > 200, "the card has room at \(size)")
            for (key, view) in w.reader.messageViews where !view.isHiddenOrHasHiddenAncestor && view !== lastView {
                let frame = view.convert(view.bounds, to: nil)
                let overlap = frame.intersection(card)
                #expect(overlap.isNull || overlap.height < 0.5 || overlap.width < 0.5,
                        "the composer covers no message (\(key.gmailMessageID.rawValue)) at \(size)")
            }
            #expect(w.isUnderItsMessage(composer), "below the newest message, inside its card at \(size)")
            let readerFrame = w.reader.view.convert(w.reader.view.bounds, to: nil)
            #expect(card.minX >= readerFrame.minX && card.maxX <= readerFrame.maxX, "within the reader's width at \(size)")
        }
    }

    @Test func aMiddleMessagesReplyButtonAnswersThatMessageAndSitsUnderIt() async throws {
        let w = try await InlineReplyWindow.make()
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2]
        model.toggle(middle.id)
        try await until { w.reader.messageViews[middle.id]?.header != nil }
        let header = try #require(w.reader.messageViews[middle.id]?.header)
        let reply = try #require(header.actionButtons.first { $0.identifier?.rawValue == ActionID.reply.rawValue })
        #expect(reply.isEnabled)
        reply.onPress?()
        let composer = try await w.inlineComposer()
        let session = composer.session
        #expect(session.replyTo == middle.id, "answers the middle message")
        #expect(session.to.tokens.map { $0.email.lowercased() } == [try #require(middle.from?.email.lowercased())])
        #expect(QuoteSplit.quoteBlockCount(session.assembledFields().bodyHTML) == 1)
        let attribution = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML).header
        #expect(attribution.hasPrefix("On ") && attribution.hasSuffix(" wrote:"))
        #expect(attribution.contains(try #require(middle.from?.email)), "the quote is the middle message's")
        let middleView = try #require(w.reader.messageViews[middle.id])
        #expect(composer.hostMessage === middleView && w.isUnderItsMessage(composer),
                "the composer sits under the message it answers, in its card")
        let menu = NSMenu()
        header.fillMenu(menu)
        #expect(menu.items.prefix(3).map(\.title) == ["Reply", "Reply all", "Forward"])
    }

    @Test func aReplyPrefillsTheRecipientsAndTheQuoteWhichToggles() async throws {
        let w = try await InlineReplyWindow.make()
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let session = composer.session
        let last = try #require(messages.last)
        #expect(!session.to.tokens.isEmpty, "To is prefilled")
        if let sender = last.from?.email, !(w.router.accounts.first?.account.isMe(sender) ?? true) {
            #expect(session.to.tokens.map { $0.email.lowercased() } == [sender.lowercased()])
        }
        #expect(session.subject.hasPrefix("Re: "))
        #expect(QuoteSplit.quoteBlockCount(session.quotedHTML) == 1)
        #expect(QuoteSplit.quoteBlockCount(session.assembledFields().bodyHTML) == 1, "the quote, once")
        #expect(session.notice == nil, "no 'recipients aren't filled in' notice any more")
        #expect(!session.isQuoteExpanded)
        let collapsed = composer.bounds.height
        session.isQuoteExpanded = true
        try await until {
            w.window.contentView?.layoutSubtreeIfNeeded()
            return composer.bounds.height > collapsed + 10
        }
        let preview = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML)
        #expect(preview.header.hasPrefix("On ") && preview.header.hasSuffix(" wrote:") && !preview.body.isEmpty)
        session.isQuoteExpanded = false
        try await until {
            w.window.contentView?.layoutSubtreeIfNeeded()
            return abs(composer.bounds.height - collapsed) < 1
        }
    }

    @Test func keysGoBackToTheConversationWhenTheFocusLeavesTheComposer() async throws {
        let w = try await InlineReplyWindow.make()
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.hasKeyboardFocus }
        #expect(w.router.actionContext().scope == .composer, "typing in the reply: the composer has the keys")
        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(w.router.actionContext().scope == .reader, "back in the thread: the conversation's keys")
        #expect(w.router.perform(.reply))
        try await until { composer.hasKeyboardFocus }
        #expect(w.environment.compose.sessions.count == 1)
        #expect(!w.router.isEnabled(.backToList), "while typing, Esc is the composer's (it closes it)")
        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(w.router.perform(.backToList))
        try await until { w.reader.view.isHiddenOrHasHiddenAncestor }
        #expect(w.router.actionContext().scope == .list)
        let other = try #require(w.router.list?.rows.first { $0.id != thread }?.id)
        _ = try await w.open(other)
        #expect(w.reader.inlineComposer == nil && w.router.actionContext().scope == .reader)
        _ = try await w.open(thread)
        let again = try await w.inlineComposer()
        #expect(again.session === composer.session, "the same reply, as it was")
    }
}

// Waits until SwiftUI has installed the window's toolbar and the content has stopped moving under it, so frames
// measured afterwards are the ones the user sees
@MainActor
func settleWindowChrome(of window: NSWindow) async throws {
    var last: NSRect?
    try await until(timeout: .seconds(10)) {
        window.contentView?.layoutSubtreeIfNeeded()
        let layout = window.contentLayoutRect
        defer { last = layout }
        return window.toolbar != nil && layout == last
    }
}

// Keeps the frame it is given: AppKit would clamp a titled window to the screen and make layout depend on the display
final class UnconstrainedTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
enum FocusWindowGate {
    private static var held = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func enter() async {
        if held { await withCheckedContinuation { waiters.append($0) } } else { held = true }
    }

    static func leave() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}
