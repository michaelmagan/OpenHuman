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
@Suite(.serialized) struct NewMessagesPillWindowTests {
    static let frameName = "dev.openhuman.tests.new-messages"
    static let dana = EmailAddress(name: "Dana Ruiz", email: "dana@example.com")

    @discardableResult
    private func press(_ event: NSEvent, in w: InlineReplyWindow) -> Bool {
        if w.content.keyRouter.route(event) == nil { return true }
        w.window.firstResponder?.keyDown(with: event)
        return false
    }

    @discardableResult
    private func deliver(to thread: ThreadKey, in w: InlineReplyWindow, minutes: Double) throws -> MessageKey {
        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.accounts.first?.id)
        return store.deliverMessage(account: account, to: thread, from: Self.dana, at: Date().addingTimeInterval(minutes * 60))
    }

    @Test func mailArrivingInAConversationJustOpenedShowsAtOnce() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let key = try deliver(to: thread, in: w, minutes: 1)
        try await until { w.reader.messageViews[key] != nil }
        #expect(model.pendingMessages.isEmpty && w.reader.newMessagesPill.isHidden, "no pill")
        #expect(model.messages.count == messages.count + 1)
        try await until { w.reader.messageViews[key]?.isFocused == true }
        #expect(model.focusedMessage == key, "the newest is highlighted, as before")
    }

    @Test func mailArrivingWhileReadingWaitsBehindThePillUntilShiftNOrAClick() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName)
        defer { w.close() }
        let (thread, messages) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        let middle = messages[messages.count - 2].id
        #expect(w.window.makeFirstResponder(w.reader.focusView))
        #expect(press(Keys.arrow(.up, window: w.window), in: w))
        try await until { w.reader.messageViews[middle]?.isFocused == true }
        let scroll = w.reader.visibleDocumentRect.origin
        let rows = w.reader.messageViews.count

        let first = try deliver(to: thread, in: w, minutes: 1)
        let second = try deliver(to: thread, in: w, minutes: 2)
        let pill = w.reader.newMessagesPill
        try await until { model.pendingMessages == [first, second] && pill.count == 2 && !pill.isHidden }
        #expect(pill.label.stringValue == "Show 2 new messages")
        #expect(pill.accessibilityLabel() == "Show 2 new messages")
        #expect(pill.toolTip == "Show new messages  ⇧N")
        #expect(w.reader.messageViews.count == rows && w.reader.messageViews[first] == nil, "no card joined")
        #expect(model.focusedMessage == middle && w.reader.messageViews[middle]?.isFocused == true, "the highlight stays")
        #expect(w.reader.visibleDocumentRect.origin == scroll, "nothing scrolled")
        w.window.contentView?.layoutSubtreeIfNeeded()
        w.window.colorSpace = .sRGB
        let theme = w.reader.theme
        let root = w.reader.view
        let capsule = pill.convert(pill.pillRect, to: root)
        #expect(abs(capsule.midX - root.bounds.midX) < 1 && root.bounds.contains(capsule))
        #expect(capsule.minY >= theme.component.toast.bottom + theme.component.toast.height, "a toast never covers it")
        let center = pill.convert(NSPoint(x: pill.pillRect.midX, y: pill.pillRect.midY), to: nil)
        #expect(w.window.contentView?.superview?.hitTest(center) === pill)
        let edge = pill.convert(NSPoint(x: pill.pillRect.minX + 6, y: pill.pillRect.midY), to: root)
        #expect(try #require(snapshot(root)).pixel(at: edge, in: root).isColor(theme.accentFill), "accent.fill")

        #expect(press(Keys.event("N", code: 45, modifiers: .shift, window: w.window), in: w))
        try await until { w.reader.messageViews[second]?.isFocused == true && w.reader.messageViews[first] != nil }
        #expect(model.pendingMessages.isEmpty && model.focusedMessage == second && pill.isHidden)
        #expect(w.reader.messageViews[first]?.isExpanded == true && w.reader.messageViews[second]?.isExpanded == true)
        try await until { isTopInView(second, w) }
        #expect(!press(Keys.event("N", code: 45, modifiers: .shift, window: w.window), in: w),
                "nothing waits: the key is not the conversation's")

        #expect(w.window.makeFirstResponder(w.reader.focusView))
        press(Keys.event(" ", code: 49, window: w.window), in: w)
        let third = try deliver(to: thread, in: w, minutes: 3)
        try await until { model.pendingMessages == [third] && pill.count == 1 && !pill.isHidden }
        #expect(pill.label.stringValue == "Show new message" && model.focusedMessage == second)
        w.window.contentView?.layoutSubtreeIfNeeded()
        let location = pill.convert(NSPoint(x: pill.pillRect.midX, y: pill.pillRect.midY), to: nil)
        pill.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1)!)
        try await until { w.reader.messageViews[third]?.isFocused == true && pill.isHidden }
        try await until { isTopInView(third, w) }
    }

    @Test func thePillIsTheAccentInDarkModeToo() async throws {
        let w = try await InlineReplyWindow.make(mode: .dark, frameName: Self.frameName)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        try await until { w.onScreenReader?.messageViews.isEmpty == false }
        model.noteInteraction()
        try deliver(to: thread, in: w, minutes: 1)
        try await until { w.onScreenReader?.newMessagesPill.isHidden == false }
        let reader = try #require(w.onScreenReader)
        w.window.colorSpace = .sRGB
        reader.view.layoutSubtreeIfNeeded()
        let pill = reader.newMessagesPill
        let edge = pill.convert(NSPoint(x: pill.pillRect.minX + 6, y: pill.pillRect.midY), to: reader.view)
        #expect(try #require(snapshot(reader.view)).pixel(at: edge, in: reader.view).isColor(reader.theme.accentFill))
    }

    private func isTopInView(_ key: MessageKey, _ w: InlineReplyWindow) -> Bool {
        guard let card = w.reader.messageViews[key] else { return false }
        w.window.contentView?.layoutSubtreeIfNeeded()
        let frame = card.convert(card.bounds, to: w.reader.focusView)
        return w.reader.visibleDocumentRect.contains(NSPoint(x: frame.midX, y: frame.minY + 2))
    }

    /// The window must be in sRGB first: a snapshot takes the window's space, Display P3 on a MacBook's own screen,
    /// and its pixels are then no longer the theme's sRGB components.
    private func snapshot(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}

private extension InlineReplyWindow {
    var onScreenReader: ReaderViewController? {
        window.contentView.flatMap { root in
            subviews(of: ReaderRootView.self, in: root).first { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }?.controller
        }
    }
}

private extension NSBitmapImageRep {
    func pixel(at point: NSPoint, in view: NSView) -> NSColor {
        let scale = CGFloat(pixelsWide) / view.bounds.width
        let y = view.isFlipped ? point.y : view.bounds.height - point.y
        return colorAt(x: Int(point.x * scale), y: Int(y * scale)) ?? .clear
    }
}

private extension NSColor {
    func isColor(_ token: ThemeColor) -> Bool {
        guard type == .componentBased, colorSpace.colorSpaceModel == .rgb else { return false }
        return abs(redComponent - token.red) < 0.02 && abs(greenComponent - token.green) < 0.02
            && abs(blueComponent - token.blue) < 0.02
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct NewMessagesPillSnapshotTests {
    @Test(arguments: [(640.0, AppearanceMode.light), (1100.0, .light), (640.0, .dark), (1100.0, .dark)])
    func pill(width: Double, mode: AppearanceMode) async throws {
        let w = try await InlineReplyWindow.make(size: NSSize(width: width, height: 820), mode: mode,
                                                 frameName: "dev.openhuman.tests.new-messages-shots")
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        let model = try await w.open(thread)
        model.noteInteraction()
        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.accounts.first?.id)
        for minutes in [1.0, 2, 3] {
            store.deliverMessage(account: account, to: thread, from: NewMessagesPillWindowTests.dana,
                                 at: Date().addingTimeInterval(minutes * 60))
        }
        try await until { model.pendingMessages.count == 3 }
        try await InlineReplySnapshotTests().shoot(w, "new-messages-\(Int(width))-\(mode.rawValue)")
    }
}
