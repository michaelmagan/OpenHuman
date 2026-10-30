import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct MessageFocusWindowTests {
    static let frameName = "dev.openhuman.tests.message-focus"

    @discardableResult
    private func press(_ event: NSEvent, in w: InlineReplyWindow) -> Bool {
        if w.content.keyRouter.route(event) == nil { return true }
        w.window.firstResponder?.keyDown(with: event)
        return false
    }

    @Test func arrowsMoveTheHighlightedFocusAndScrollItIntoView() async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: 900, height: 520), frameName: Self.frameName)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let keys = messages.map(\.id)
        try await until { w.highlighted() == [keys.last!] && w.window.firstResponder === w.reader.focusView }
        #expect(model.replyTarget == keys.last, "the highlighted message is the one a reply answers")

        #expect(press(Keys.event("O", code: 31, modifiers: .shift, window: w.window), in: w))
        try await until { w.reader.messageViews.count == keys.count && w.reader.messageViews.values.allSatisfy(\.isExpanded) }
        for index in stride(from: keys.count - 2, through: 0, by: -1) {
            #expect(press(Keys.arrow(.up, window: w.window), in: w), "↑ is the conversation's (message \(index))")
            #expect(model.focusedMessage == keys[index])
            try await until {
                w.window.contentView?.layoutSubtreeIfNeeded()
                guard let frame = w.frameInDocument(keys[index]) else { return false }
                return w.highlighted() == [keys[index]] && w.reader.visibleDocumentRect.contains(NSPoint(x: frame.midX, y: frame.minY + 1))
            }
        }
        #expect(!press(Keys.arrow(.up, window: w.window), in: w), "nothing older: ↑ passes on (the view scrolls)")
        #expect(model.focusedMessage == keys[0])
        #expect(press(Keys.event("n", code: 45, window: w.window), in: w))
        #expect(model.focusedMessage == keys[1])
        for _ in keys.indices where model.focusedMessage != keys.last {
            #expect(press(Keys.arrow(.down, window: w.window), in: w))
        }
        try await until { w.highlighted() == [keys.last!] }
        w.window.contentView?.layoutSubtreeIfNeeded()
        let document = w.reader.focusView
        let before = w.reader.visibleDocumentRect.minY
        let maxY = max(0, document.frame.height - w.reader.visibleDocumentRect.height)
        #expect(!press(Keys.arrow(.down, window: w.window), in: w), "at the newest ↓ is the scroll key again")
        #expect(abs(w.reader.visibleDocumentRect.minY - min(before + 40, maxY)) < 1)
        #expect(model.focusedMessage == keys.last)
        #expect(!press(Keys.arrow(.up, modifiers: .shift, window: w.window), in: w))
        #expect(model.focusedMessage == keys.last)
        #expect(w.content.keyRouter.route(Keys.tab(window: w.window)) != nil, "⇥ passes on")
        #expect(w.content.keyRouter.route(Keys.tab(modifiers: .shift, window: w.window)) != nil, "⇧⇥ passes on")
    }

    @Test func theHighlightIsDrawnInTheThemesColorsInLightAndDark() async throws {
        for mode in [AppearanceMode.light, .dark] {
            let w = try await InlineReplyWindow.make(mode: mode, frameName: Self.frameName)
            defer { w.close() }
            let (thread, messages) = try await w.conversationWithAMiddleSender()
            let model = try await w.open(thread)
            let keys = messages.map(\.id)
            let focused = keys[keys.count - 2]
            model.reveal(focused)
            #expect(press(Keys.event("p", code: 35, window: w.window), in: w))
            #expect(model.focusedMessage == focused)
            try await until {
                guard let reader = w.liveReader, let view = reader.messageViews[focused] else { return false }
                return view.isExpanded && view.plateLook == .focus
                    && reader.messageViews.filter { !$0.value.focusPlate.isHidden }.count == 1
            }
            let reader = try #require(w.liveReader)
            let theme = reader.theme
            #expect(ReaderAppearance.appearance(of: theme) == (mode == .dark ? .dark : .light), "the window's theme: \(mode)")
            let image = try #require(snapshot(reader.view), "reader view \(reader.view.bounds)")
            let container = try #require(reader.messageViews[focused])
            let other = try #require(reader.messageViews[keys.last!])
            let plate = container.focusPlate.convert(NSPoint(x: container.focusPlate.bounds.maxX - 2,
                                                             y: container.focusPlate.bounds.midY), to: reader.view)
            let otherEdge = other.convert(NSPoint(x: other.bounds.maxX - 2, y: other.bounds.midY), to: reader.view)
            let tint = theme.component.row.bgCursor.composited(over: theme.bgCanvas)
            #expect(image.color(at: plate, in: reader.view).matches(tint), "the plate, \(mode)")
            #expect(other.focusPlate.isHidden, "no plate elsewhere, \(mode)")
            #expect(image.color(at: otherEdge, in: reader.view).matches(theme.bgCanvas), "no plate elsewhere, \(mode)")
            let message = container.accessibilityLabel() ?? ""
            #expect(message.hasSuffix(", focused") && container.isAccessibilitySelected())
        }
    }

    @Test func theHighlightKeepsItsContrastInEveryBuiltInTheme() {
        let library = ThemeLibrary.builtIn
        let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]
        for themeID in [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight] + darkThemes {
            for accent in BuiltinThemeID.accents {
                for increase in [false, true] {
                    let appearance: ThemeAppearance = darkThemes.contains(themeID) ? .dark : .light
                    let t = library.resolve(themeID: themeID, appearance: appearance, preferences: ThemePreferences(accentID: accent),
                                            increaseContrast: increase).tokens
                    let label = "\(themeID) \(accent) increaseContrast=\(increase)"
                    let bar = t.component.row.cursorBar, plate = t.component.row.bgCursor
                    #expect(bar.contrastRatio(on: t.bgWindow) >= 3, "bar on the window: \(label)")
                    #expect(bar.contrastRatio(on: plate) >= 3, "bar on the plate: \(label)")
                    #expect(t.textPrimary.contrastRatio(on: plate) >= 4.5, "name on the plate: \(label)")
                    #expect(t.textSecondary.contrastRatio(on: plate) >= 4.5, "date on the plate: \(label)")
                    #expect(t.textTertiary.contrastRatio(on: plate) >= 3, "address on the plate: \(label)")
                    #expect(t.borderWidthCursorBar >= 2)
                }
            }
        }
    }

    @Test func rAndFAfterTheArrowsAnswerTheFocusedMessageRightUnderIt() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2]
        #expect(press(Keys.arrow(.up, window: w.window), in: w))
        #expect(model.focusedMessage == middle.id)

        #expect(press(Keys.event("r", code: 15, window: w.window), in: w))
        let composer = try await w.inlineComposer()
        let session = composer.session
        #expect(session.mode == .reply && session.replyTo == middle.id)
        #expect(session.to.tokens.map { $0.email.lowercased() } == [try #require(middle.from?.email.lowercased())])
        let attribution = QuotePreview(quotedText: session.quotedText, quotedHTML: session.quotedHTML).header
        #expect(attribution.contains(try #require(middle.from?.email)), "the quote is the focused message's")
        try await until {
            guard let view = w.reader.messageViews[middle.id] else { return false }
            return composer.hostMessage === view && w.isUnderItsMessage(composer)
        }
        #expect(w.highlighted() == [middle.id], "the answered message stays highlighted")

        try await until { composer.hasKeyboardFocus }
        for key in [Keys.arrow(.up, window: w.window), Keys.arrow(.down, window: w.window), Keys.event("p", code: 35, window: w.window)] {
            #expect(w.content.keyRouter.route(key) != nil, "a focused composer keeps its keys")
        }
        #expect(model.focusedMessage == middle.id)

        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(press(Keys.event("f", code: 3, window: w.window), in: w))
        try await until { w.reader.inlineComposer?.session.mode == .forward }
        let forward = try await w.inlineComposer()
        #expect(forward.session.replyTo == middle.id)
        #expect(forward.session.quotedHTML.contains(try #require(middle.from?.email)))
        let middleView = try #require(w.reader.messageViews[middle.id])
        #expect(forward.hostMessage === middleView && w.isUnderItsMessage(forward))
        #expect(w.environment.compose.sessions.count == 1)
    }

    @Test func returnAndShiftReturnAnswerTheFocusedMessage() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let returnKey = Keys.event("\r", code: 36, window: w.window)
        let shiftReturn = Keys.event("\r", code: 36, modifiers: .shift, window: w.window)
        let (replyKey, replyAllKey) = ActionCatalog.returnRepliesAll ? (shiftReturn, returnKey) : (returnKey, shiftReturn)
        try await until { w.window.firstResponder === w.content.tableView }
        #expect(press(returnKey, in: w))
        try await until { w.router.mode == .reader }
        #expect(w.environment.compose.sessions.isEmpty, "↵ in the list is Open, never Reply")
        #expect(w.router.perform(.backToList))

        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        try await until { w.window.firstResponder === w.reader.focusView }
        let middle = messages[messages.count - 2]
        #expect(press(Keys.arrow(.up, window: w.window), in: w))
        #expect(model.focusedMessage == middle.id)
        w.reader.showFind()
        #expect(w.content.keyRouter.route(returnKey) != nil && w.content.keyRouter.route(shiftReturn) != nil)
        #expect(w.environment.compose.sessions.isEmpty)
        w.reader.closeFind()
        #expect(w.window.makeFirstResponder(w.reader.focusView))

        #expect(press(replyKey, in: w))
        let reply = try await w.inlineComposer()
        #expect(reply.session.mode == .reply && reply.session.replyTo == middle.id)
        #expect(reply.session.to.tokens.map { $0.email.lowercased() } == [try #require(middle.from?.email.lowercased())])
        let middleView = try #require(w.reader.messageViews[middle.id])
        #expect(reply.hostMessage === middleView && w.isUnderItsMessage(reply))
        try await until { reply.hasKeyboardFocus }
        #expect(w.content.keyRouter.route(returnKey) != nil && w.content.keyRouter.route(shiftReturn) != nil)
        #expect(w.environment.compose.sessions.count == 1 && reply.session.mode == .reply)

        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(press(replyAllKey, in: w))
        try await until { w.reader.inlineComposer?.session.mode == .replyAll }
        let all = try await w.inlineComposer()
        #expect(all.session.replyTo == middle.id && w.environment.compose.sessions.count == 1)
    }

    @Test func aClickInAMessageFocusesIt() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let keys = messages.map(\.id)
        let middle = keys[keys.count - 2]
        if let row = w.reader.messageViews[middle]?.collapsedRow {
            #expect(w.reader.message(clickedBy: click(at: row, in: w)) == nil, "the row answers its own click")
        }
        model.reveal(middle)
        try await until { w.reader.messageViews[middle]?.header != nil }
        let container = try #require(w.reader.messageViews[middle])
        w.window.contentView?.layoutSubtreeIfNeeded()
        #expect(model.focusedMessage == keys.last)

        let header = try #require(container.header)
        #expect(w.reader.message(clickedBy: click(at: header, offset: NSPoint(x: header.bounds.width * 0.5, y: 2), in: w)) == nil)
        let more = try #require(header.actionButtons.first { $0.identifier?.rawValue == "reader.more" })
        #expect(w.reader.message(clickedBy: click(at: more, in: w)) == middle)
        try await until { container.plainBody != nil || container.htmlBody?.current != nil }
        w.window.contentView?.layoutSubtreeIfNeeded()
        let body: NSView = try #require(container.plainBody ?? container.htmlBody?.current)
        let event = click(at: body, in: w)
        #expect(w.reader.message(clickedBy: event) == middle)
        w.reader.focusMessage(clickedBy: event)
        #expect(model.focusedMessage == middle && model.replyTarget == middle)
        try await until { w.highlighted() == [middle] }
        #expect(model.focusScrollRequest == 0, "a click does not scroll the conversation")
        #expect(w.reader.message(clickedBy: click(at: w.reader.subjectView, in: w)) == nil)
        let elsewhere = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(w.reader.message(clickedBy: elsewhere) == nil)

        #expect(press(Keys.event("r", code: 15, window: w.window), in: w))
        let composer = try await w.inlineComposer()
        #expect(composer.session.replyTo == middle)
    }

    @Test func theViewMenuListsTheMessageKeysWithTheirShortcuts() {
        let items = MailCommands.menuDescriptors(.view).filter(MailCommands.isMessageItem)
        #expect(items.map(\.id) == [.nextMessage, .previousMessage, .toggleMessage, .expandAllMessages, .toggleQuotedText,
                                     .showImages, .showNewMessages, .findInConversation])
        #expect(!MailCommands.menuDescriptors(.view).filter { !MailCommands.isMessageItem($0) }.contains { $0.scopes == [.reader] })
        let hints = MenuShortcutHints()
        #expect(hints.hint(for: "Next message") == "N, ↓" && hints.hint(for: "Previous message") == "P, ↑")
        #expect(hints.hint(for: "Expand or collapse message") == "O" && hints.hint(for: "Expand all messages") == "⇧O")
        #expect(hints.hint(for: "Show or hide quoted text") == "." && hints.hint(for: "Show remote images") == "⇧I")
        #expect(hints.hint(for: "Show new messages") == "⇧N")
        #expect(hints.hint(for: "Find in conversation") == "⌘F", "the key router's ⌘F, shown as a hint")
        for item in items { #expect(MailCommands.keyboardShortcut(for: item) == nil, "no key equivalent in this group") }
    }

    private func click(at view: NSView, offset: NSPoint? = nil, in w: InlineReplyWindow) -> NSEvent {
        let point = offset ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let location = view.convert(point, to: nil)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                  windowNumber: w.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

private extension InlineReplyWindow {
    var liveReader: ReaderViewController? {
        window.contentView.flatMap { root in
            subviews(of: ReaderRootView.self, in: root).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }?.controller
        }
    }

    func highlighted() -> [MessageKey] {
        reader.messageViews.filter { $0.value.plateLook == .focus }.map(\.key)
    }

    func frameInDocument(_ key: MessageKey) -> NSRect? {
        guard let view = reader.messageViews[key] else { return nil }
        return view.convert(view.bounds, to: reader.focusView)
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
    // Compared as raw components: colorAt returns sRGB values tagged as calibrated RGB, so converting would shift them
    func matches(_ token: ThemeColor) -> Bool {
        guard type == .componentBased, colorSpace.colorSpaceModel == .rgb else { return false }
        return abs(redComponent - token.red) < 0.02 && abs(greenComponent - token.green) < 0.02
            && abs(blueComponent - token.blue) < 0.02
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct MessageFocusSnapshotTests {
    @Test(arguments: [(640.0, AppearanceMode.light), (1100.0, .light), (640.0, .dark), (1100.0, .dark)])
    func focusedMessage(width: Double, mode: AppearanceMode) async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: width, height: 820), mode: mode,
                                                 frameName: "dev.openhuman.tests.message-focus-shots")
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let tag = "\(Int(width))-\(mode.rawValue)"
        let shots = InlineReplySnapshotTests()
        if messages.count > 2 {
            for _ in 0..<(messages.count - 1) { model.focusPrevious() }
            try await until { w.reader.messageViews[messages[0].id]?.isFocused == true }
            try await shots.shoot(w, "focus-\(tag)-collapsed-row")
        }
        let middle = messages[messages.count - 2].id
        model.reveal(middle)
        model.focus(middle)
        try await until { w.reader.messageViews[middle]?.isFocused == true && w.reader.messageViews[middle]?.isExpanded == true }
        try await shots.shoot(w, "focus-\(tag)-expanded")
        #expect(w.router.perform(.reply))
        _ = try await w.inlineComposer()
        try await shots.shoot(w, "focus-\(tag)-reply")
    }
}
