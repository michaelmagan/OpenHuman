import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct ThreadCardsWindowTests {
    static let frameName = "dev.openhuman.tests.thread-cards"

    @discardableResult
    private func press(_ event: NSEvent, in w: InlineReplyWindow) -> Bool {
        if w.content.keyRouter.route(event) == nil { return true }
        w.window.firstResponder?.keyDown(with: event)
        return false
    }

    @Test func messagesSitOnTheConversationsBackgroundUnderHairlinesInLightAndDark() async throws {
        for mode in [AppearanceMode.light, .dark] {
            let w = try await InlineReplyWindow.make(mode: mode, frameName: Self.frameName)
            defer { w.close() }
            let (thread, messages) = try await w.conversationWithAMiddleSender()
            let model = try await w.open(thread)
            let keys = messages.map(\.id)
            try await until {
                guard let reader = w.liveReader else { return false }
                return reader.messageViews[keys.last!]?.isFocused == true && reader.messageViews.count >= 2
            }
            try await until {
                guard let reader = w.liveReader else { return false }
                return bodiesAreSettled(reader, model)
            }
            let reader = try #require(w.liveReader)
            let theme = reader.theme
            reader.view.layoutSubtreeIfNeeded()
            let image = try #require(snapshot(reader.view))
            for (key, view) in reader.messageViews {
                let name = "\(key.gmailMessageID.rawValue), \(mode)"
                #expect(view.separator.superview === view, "a hairline above \(name)")
                let line = view.separator.convert(view.separator.bounds, to: view)
                #expect(abs(line.minX) < 0.5 && abs(line.maxX - view.bounds.width) < 0.5, "the hairline spans the column: \(name)")
                #expect(view.isFlipped ? line.minY < 0.5 : abs(line.maxY - view.bounds.height) < 0.5, "at the top: \(name)")
                #expect(view.plateLook == (view.isFocused ? ReaderPlateView.Look.focus : ReaderPlateView.Look.none), "\(name)")
                let inside = view.convert(NSPoint(x: MessageContainerView.horizontalPadding(theme) / 2,
                                                  y: view.bounds.midY), to: reader.view)
                let outside = view.convert(NSPoint(x: -30, y: view.bounds.midY), to: reader.view)
                if view.focusPlate.isHidden || view.isExpanded {
                    #expect(image.color(at: inside, in: reader.view).matches(theme.bgCanvas), "no card behind \(name)")
                }
                #expect(image.color(at: outside, in: reader.view).matches(theme.bgCanvas), "conversation background, \(mode)")
            }
            let focused = try #require(reader.messageViews[keys.last!])
            let plate = focused.focusPlate
            let tint = plate.convert(NSPoint(x: plate.bounds.maxX - 2, y: plate.bounds.midY), to: reader.view)
            let color = theme.component.row.bgCursor.composited(over: theme.bgCanvas)
            #expect(image.color(at: tint, in: reader.view).matches(color), "the focus plate, \(mode)")
            #expect(reader.messageViews.values.filter { !$0.focusPlate.isHidden }.count == 1, "one plate, \(mode)")
        }
    }

    @Test func oneFoldControlPerMessageTogglesAllItsFoldsLikeThePeriodKey() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        var found: (MessageKey, ReaderWebView)?
        for message in model.messages {
            model.reveal(message.id)
            try await until { w.reader.messageViews[message.id]?.isExpanded == true }
            guard case .rendered(.html(let rendered))? = await renderedBody(message.id, model), rendered.hasQuotedText else { continue }
            try await until { w.reader.messageViews[message.id]?.htmlBody?.current?.isShown == true }
            found = (message.id, try #require(w.reader.messageViews[message.id]?.htmlBody?.current))
            break
        }
        let (key, web) = try #require(found, "a message with folded quoted text")
        let visible = "Array.prototype.filter.call(document.querySelectorAll('details.oh-quoted > summary'), function (s) { return s.offsetHeight > 0; }).length"
        #expect(try await web.evaluateJavaScript(visible, in: nil, contentWorld: .defaultClient) as? Int == 1, "one control")
        #expect(model.message(key)?.quotesExpanded == false)
        _ = try await web.evaluateJavaScript("document.querySelector('details.oh-quoted > summary').click(); 0", in: nil,
                                             contentWorld: .defaultClient)
        try await until { model.message(key)?.quotesExpanded == true }
        let allOpen = "Array.prototype.every.call(document.querySelectorAll('details.oh-quoted'), function (d) { return d.open; })"
        try await until { (try? await web.evaluateJavaScript(allOpen, in: nil, contentWorld: .defaultClient) as? Bool) == true }
        model.focus(key)
        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(press(Keys.event(".", code: 47, window: w.window), in: w))
        try await until { model.message(key)?.quotesExpanded == false }
        let noneOpen = "Array.prototype.some.call(document.querySelectorAll('details.oh-quoted'), function (d) { return d.open; })"
        try await until { (try? await web.evaluateJavaScript(noneOpen, in: nil, contentWorld: .defaultClient) as? Bool) == false }
    }

    @Test func aReplyIsAttachedToTheFocusedMessagesCardAndStaysThereWhenMailArrives() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2]
        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(press(Keys.arrow(.up, window: w.window), in: w))
        #expect(press(Keys.event("r", code: 15, window: w.window), in: w))
        let composer = try await w.inlineComposer()
        let session = composer.session
        let middleView = try #require(w.reader.messageViews[middle.id])
        #expect(composer.hostMessage === middleView && w.isUnderItsMessage(composer), "in the answered message's card")
        #expect(middleView.isFocused, "the answered message keeps the highlight")
        let sender = try #require(middle.from)
        #expect(session.to.tokens.map { $0.email.lowercased() } == [sender.email.lowercased()])
        #expect(session.recipientSummary == RecipientParser.displayName(sender))
        let attribution = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML).header
        #expect(attribution.contains(sender.email))
        try await wait("the reply has the keyboard") { composer.hasKeyboardFocus }
        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.accounts.first?.id)
        store.deliverMessage(account: account, to: thread, from: EmailAddress(name: "Sam Lee", email: "sam@example.org"))
        try await wait("the new-messages pill") { model.pendingMessages.count == 1 && !w.reader.newMessagesPill.isHidden }
        #expect(model.messages.count == messages.count && composer.hostMessage === middleView && composer.hasKeyboardFocus)
        #expect(w.reader.newMessagesPill.accessibilityPerformPress())
        try await wait("the new message's card") {
            model.messages.count == messages.count + 1
                && w.reader.messageViews.count == model.items.filter { if case .message = $0 { true } else { false } }.count
        }
        #expect(composer.hostMessage === middleView && composer.hasKeyboardFocus, "still attached, still typing")
        #expect(w.reader.inlineComposer === composer)

        #expect(w.environment.compose.undoSendSeconds == 10)
        let remind = try #require(w.environment.compose.remindButton(for: session))
        #expect(remind.isEnabled && remind.help.hasPrefix("Remind me"))
        #expect(w.environment.compose.remind(from: session))
        guard case .time(let picker) = w.environment.overlays.overlay else {
            Issue.record("the remind picker is up")
            return
        }
        #expect(picker.kind == .remind && picker.targets == [thread])
        w.environment.overlays.dismiss()
    }

    @Test func sendingShowsTheReplyAsACardWithReplySentAndUndoForTheWholeWindow() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, heldSends: .manual)
        defer { w.close() }
        let store = try #require(w.environment.data as? FakeMailStore)
        let window = WindowGate()
        w.environment.compose.timing = ComposeTiming(sleep: { duration in
            if duration >= .seconds(8) { await window.wait() } else { try await Task.sleep(for: duration) }
        })
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let session = composer.session
        let editor = try #require(w.editors.first)
        editor.insertText("Thursday works.", replacementRange: editor.selectedRange())
        try await until { session.plainText.contains("Thursday works.") }

        #expect(w.environment.compose.perform(.send, in: session, source: .keyboard))
        try await until { w.router.mode == .list && w.environment.compose.windowSession == nil }
        try await until { w.router.list?.cursor != thread }
        _ = try await w.open(thread)
        try await until { w.reader.inlineComposer == nil && w.reader.outgoingViews.count == 1 }
        let card = try #require(w.reader.outgoingViews.values.first)
        #expect(card.statusText == "Sending…" && card.isDescendant(of: w.reader.view))
        let last = try #require(w.reader.messageViews[messages.last!.id])
        w.window.contentView?.layoutSubtreeIfNeeded()
        #expect(card.convert(card.bounds, to: nil).maxY <= last.convert(last.bounds, to: nil).minY,
                "after the conversation's messages")
        let top = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.maxY - 2), to: w.reader.focusView)
        try await until { w.reader.visibleDocumentRect.contains(top) }
        await awaitObserved("the reply toast") { w.environment.notices.toasts.contains { $0.message == "Reply sent." } }
        let toast = try #require(w.environment.notices.toasts.first { $0.message == "Reply sent." })
        #expect(toast.actionTitle == "Undo" && toast.shortcut == "⌘Z" && toast.secondaryActionTitle == "View")
        let sending = try #require(w.environment.compose.sending.first)
        guard case .queued(let windowEnd) = sending.state else {
            Issue.record("expected the send in its undo window, found \(sending.state)")
            return
        }
        let toastEnd = try #require(toast.expiresAt)
        #expect(abs(toastEnd.timeIntervalSince(windowEnd)) < 0.05, "toast ends \(toastEnd), window ends \(windowEnd)")

        await w.environment.notices.activate(toast.id)
        try await until { w.reader.outgoingViews.isEmpty && w.reader.inlineComposer?.session === session }
        let back = try await w.inlineComposer()
        #expect(back.hostMessage === w.reader.messageViews[messages.last!.id] && session.plainText.contains("Thursday works."))
        #expect(store.sentMessages.isEmpty, "nothing was sent")

        #expect(w.environment.compose.perform(.send, in: session, source: .keyboard))
        try await until { w.router.mode == .list }
        let model = try await w.open(thread)
        try await until { w.reader.outgoingViews.count == 1 }
        window.open()
        try await until { w.environment.compose.outgoing.first?.state == .sending }
        #expect(w.reader.outgoingViews.count == 1, "still shown while it goes")
        store.completeHeldSends()
        try await until { model.messages.count == messages.count + 1 && w.reader.outgoingViews.isEmpty }
        let copy = try #require(model.messages.last)
        #expect(w.reader.messageViews[copy.id] != nil && copy.summary.from?.email.lowercased() == session.from.email)
        try await until { w.environment.notices.toasts.contains { $0.message == "Sent." } }
        #expect(store.sentMessages.count == 1)
    }

    @Test func theMessageTextAndTheSendPillKeepTheirContrastInEveryBuiltInTheme() {
        let library = ThemeLibrary.builtIn
        let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let t = library.resolve(themeID: themeID, appearance: appearance, preferences: ThemePreferences(accentID: accent),
                                            increaseContrast: increase).tokens
                    let label = "\(themeID) \(accent) increaseContrast=\(increase)"
                    #expect(t.accentOnFill.contrastRatio(on: t.accentFill) >= 4.5, "Send on its pill: \(label)")
                    let canvas = t.bgCanvas
                    #expect(t.textSuccess.contrastRatio(on: canvas) >= 4.5, "\"Draft\" on the conversation: \(label)")
                    #expect(t.textSecondary.contrastRatio(on: canvas) >= 4.5, "\"to Dana\" on the conversation: \(label)")
                    #expect(t.textTertiary.contrastRatio(on: canvas) >= 4.5, "the header's date on the conversation: \(label)")
                    #expect(t.textPrimary.contrastRatio(on: t.bgCanvas) >= 4.5, "the subject on the conversation: \(label)")
                }
            }
        }
    }

    private func wait(_ what: @autoclosure () -> String, _ condition: @MainActor () async -> Bool) async throws {
        do {
            try await until(condition)
        } catch {
            Issue.record("timed out waiting for \(what())")
            throw error
        }
    }

    private func bodiesAreSettled(_ reader: ReaderViewController, _ model: ReaderModel) -> Bool {
        for (key, view) in reader.messageViews where view.isExpanded {
            switch model.message(key)?.body {
            case .rendered(.html):
                guard view.htmlBody?.current?.isShown == true && view.htmlBody?.incoming == nil else { return false }
            case .rendered, .failed:
                continue
            case .notLoaded, .fetching, nil:
                return false
            }
        }
        return true
    }

    private func renderedBody(_ key: MessageKey, _ model: ReaderModel) async -> ReaderModel.BodyState? {
        try? await until { if case .rendered? = model.message(key)?.body { true } else { false } }
        return model.message(key)?.body
    }

    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

final class WindowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for c in pending { c.resume() }
    }
}

private extension InlineReplyWindow {
    var liveReader: ReaderViewController? {
        window.contentView.flatMap { root in
            subviews(of: ReaderRootView.self, in: root).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }?.controller
        }
    }
}

private extension NSBitmapImageRep {
    func color(at point: NSPoint, in view: NSView) -> NSColor {
        let scale = CGFloat(pixelsWide) / view.bounds.width
        let y = view.isFlipped ? point.y : view.bounds.height - point.y
        return colorAt(x: Int(point.x * scale), y: Int(y * scale)) ?? .clear
    }
}

private extension NSColor {
    func matches(_ token: ThemeColor) -> Bool {
        guard type == .componentBased, colorSpace.colorSpaceModel == .rgb else { return false }
        return abs(redComponent - token.red) < 0.02 && abs(greenComponent - token.green) < 0.02
            && abs(blueComponent - token.blue) < 0.02
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct ThreadCardsSnapshotTests {
    @Test(arguments: [(640.0, AppearanceMode.light), (1100.0, .light), (640.0, .dark), (1100.0, .dark)])
    func cards(width: Double, mode: AppearanceMode) async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: width, height: 820), mode: mode,
                                                 frameName: "dev.openhuman.tests.thread-cards-shots", heldSends: .manual)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let tag = "\(Int(width))-\(mode.rawValue)"
        let shots = InlineReplySnapshotTests()
        try await shots.shoot(w, "cards-\(tag)-thread")
        model.reveal(messages[messages.count - 2].id)
        model.focus(messages[messages.count - 2].id)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        let editor = try #require(w.editors.first)
        editor.insertText("Thursday works for me.", replacementRange: editor.selectedRange())
        try await shots.shoot(w, "cards-\(tag)-reply")
        #expect(w.environment.compose.perform(.send, in: composer.session, source: .keyboard))
        try await until { w.router.mode == .list }
        _ = try await w.open(thread)
        try await until { w.reader.outgoingViews.count == 1 }
        try await shots.shoot(w, "cards-\(tag)-sent")
    }
}
