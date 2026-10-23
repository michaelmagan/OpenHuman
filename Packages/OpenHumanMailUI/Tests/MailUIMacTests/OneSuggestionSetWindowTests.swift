import AppKit
import MailFeatures
import MailModel
import MailRender
@testable import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct OneSuggestionSetWindowTests {
    @Test func exactlyOneStripUnderTheMessageAndAboveTheOpenReply() async throws {
        let stage = try await OneSuggestionStage.make(busy: true, composerStrip: true,
                                                      frameName: "dev.openhuman.tests.one-suggestion-strip")
        defer { stage.close() }
        try await stage.open()
        let center = try #require(stage.center)
        let row = try #require(center.inlineReplies.current)
        try await until { row.items.contains { $0.kind == .quickReply } }
        #expect(row.items.first?.kind == .busy && row.items.prefix(3).allSatisfy { $0.kind != .quickReply },
                "one ordered set: the calendar's answer first, then the AI's")
        let slot = try #require(subviews(of: SchedulingSlotHostView.self, in: stage.w.window.contentView!).first)
        let root = slot.hosting.rootView
        #expect(root.quickReplies != nil && root.assistant != nil)
        #expect(!root.drawsCalendarChips, "the calendar's chips are not a second row")
        let strip = { QuickReplyMessageRow(center: center, environment: stage.environment, thread: stage.thread,
                                           message: row.message) }
        #expect(strip().shown == .ready)

        #expect(stage.router.perform(.reply))
        _ = try await stage.body()
        let session = try #require(stage.reader.inlineComposer?.session)
        try await until { session.instantReply?.phase == .ready }
        #expect(strip().shown == .ready, "the strip stays above the docked reply")
        #expect(!ComposerCard<EmptyView>.drawsQuickReplies(session, manager: stage.environment.compose),
                "no second set inside the docked reply")
        #expect(!slot.hosting.rootView.drawsCalendarChips)

        session.placement = .modal
        #expect(strip().shown == .none)
        #expect(ComposerCard<EmptyView>.drawsQuickReplies(session, manager: stage.environment.compose))
        let composerSet = try #require(session.instantReply).suggestions.map(\.id)
        #expect(composerSet == row.items.filter(\.isReply).map(\.id), "the same replies, in the same order")
    }

    @Test func withoutTheAIOnlyTheCalendarsChipsShowAndTheyUseTheSamePath() async throws {
        let stage = try await OneSuggestionStage.make(busy: true, ai: false,
                                                      frameName: "dev.openhuman.tests.one-suggestion-no-ai")
        defer { stage.close() }
        try await stage.open()
        let slot = try #require(subviews(of: SchedulingSlotHostView.self, in: stage.w.window.contentView!).first)
        #expect(slot.hosting.rootView.quickReplies == nil && slot.hosting.rootView.drawsCalendarChips)
        let chips = stage.assistant.suggestions(for: stage.thread)
        #expect(chips.first?.kind == .busy && !chips.contains { $0.schedulingOption == .accept })
        let ask = try #require(chips.first { $0.schedulingOption == .askForOtherTimes })
        let session = try #require(await stage.assistant.use(ask, in: stage.thread))
        let body = try await stage.body()
        try await until { body.string == ask.body }
        #expect(session.plainText == ask.body && session.scheduling?.option == .askForOtherTimes)
        let undo = try #require(body.undoManager)
        undo.undo()
        try await until { body.string.isEmpty }
    }

    @Test func aThankYouNoteShowsNoCalendarChipsAndWednesdayAtThreeDoes() async throws {
        let thanks = try await OneSuggestionStage.make(text: "Ofc. So glad you're part of our community!!",
                                                       frameName: "dev.openhuman.tests.one-suggestion-thanks")
        try await thanks.open()
        let row = try #require(thanks.center?.inlineReplies.current)
        try await until { row.decision != .undecided && (row.state == .ready || row.state == .none) }
        await thanks.assistant.analyze(thanks.thread, force: true)
        #expect(thanks.assistant.analyses[thanks.thread] == nil && thanks.assistant.status[thanks.thread] == nil)
        #expect(thanks.assistant.suggestions(for: thanks.thread).isEmpty)
        #expect(!row.items.contains { $0.kind != .quickReply }, "no calendar chip in the strip")
        thanks.close()

        let wednesday = try await OneSuggestionStage.make(text: "Thanks! Could we meet Wednesday at 3?",
                                                          frameName: "dev.openhuman.tests.one-suggestion-wednesday")
        defer { wednesday.close() }
        try await wednesday.open()
        let asked = try #require(wednesday.center?.inlineReplies.current)
        try await until { asked.items.contains { $0.kind != .quickReply } }
        #expect(asked.items.first?.kind != .quickReply, "the calendar's chips lead the one strip")
        #expect(wednesday.assistant.analyses[wednesday.thread]?.proposal.start == OneSuggestionStage.at(14, 15))
    }

    @Test(arguments: [false, true])
    func theCommandJPanelIsDockedAboveTheSendBarAndScrolledIntoView(longBody: Bool) async throws {
        let stage = try await OneSuggestionStage.make(busy: true,
                                                      frameName: "dev.openhuman.tests.one-suggestion-cmdj-\(longBody)")
        defer { stage.close() }
        try await stage.open()
        #expect(stage.router.perform(.reply))
        let body = try await stage.body()
        let composer = try await stage.w.inlineComposer()
        let session = composer.session
        try await until { body.window?.firstResponder === body }
        let text = longBody ? (1...60).map { "Line \($0) of a long reply." }.joined(separator: "\n") : "Hi Dana, one line."
        body.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        let scroll = try #require(composer.enclosingScrollView)
        stage.w.window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let center = try #require(stage.center)
        _ = try #require(center.togglePanel(session))
        func panelIsVisible() -> Bool {
            stage.w.window.contentView?.layoutSubtreeIfNeeded()
            guard let frame = composer.revealedPanelFrame, let document = scroll.documentView else { return false }
            let panel = composer.convert(frame, to: document)
            return scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(panel)
        }
        let editor = try #require(body.enclosingScrollView)
        // The panel opens with an animation, so the frames are read once the panel, the text and the card have all
        // held still for longer than it lasts
        var last: [NSRect] = []
        var stillSince = ContinuousClock.now
        try await until {
            guard panelIsVisible(), let now = composer.revealedPanelFrame else { return false }
            let frames = [now, editor.convert(editor.bounds, to: composer), composer.bounds]
            if frames != last { last = frames; stillSince = .now }
            return ContinuousClock.now - stillSince >= .milliseconds(400)
        }
        let frame = try #require(composer.revealedPanelFrame)
        #expect(frame.height > 20, "the panel has its size: \(frame)")
        let editorInWindow = editor.convert(editor.bounds, to: nil)
        let panelInWindow = composer.convert(frame, to: nil)
        let cardInWindow = composer.convert(composer.cardFrame, to: nil)
        #expect(panelInWindow.maxY <= editorInWindow.minY + 0.5, "below the text, never over it: \(panelInWindow) vs \(editorInWindow)")
        let underPanel = panelInWindow.minY - cardInWindow.minY
        #expect(underPanel >= ComposerMetrics.actionBarHeight && underPanel <= ComposerMetrics.actionBarHeight + 32,
                """
                docked right above the Send bar, with only the bar under it: \(underPanel) \
                (card \(composer.bounds.height), fits \(composer.fittingSize.height))
                """)
        try await until {
            guard let responder = stage.w.window.firstResponder as? NSView, responder !== body else { return false }
            return responder.isDescendant(of: composer)
        }
        let origin = scroll.contentView.bounds.origin
        session.aiPanel?.instruction = "Shorter please"
        try await Task.sleep(for: .milliseconds(150))
        #expect(panelIsVisible())
        #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 0.5, "no jump while typing")
    }

    @Test func aBusyTimeNeverOffersWorksForMeAnywhere() async throws {
        let stage = try await OneSuggestionStage.make(busy: true, composerStrip: true,
                                                      frameName: "dev.openhuman.tests.one-suggestion-busy")
        defer { stage.close() }
        try await stage.open()
        let row = try #require(stage.center?.inlineReplies.current)
        try await until { row.items.contains { $0.kind == .quickReply } }
        for item in row.items {
            let words = item.label + "\n" + (item.body ?? "")
            #expect(!ReplySuggestions.acceptsTime(words) && !words.lowercased().contains("works for me"), "\(item.label)")
        }
        #expect(stage.router.perform(.reply))
        _ = try await stage.body()
        let session = try #require(stage.reader.inlineComposer?.session)
        try await until { session.instantReply?.phase == .ready }
        let strip = try #require(session.instantReply)
        #expect(strip.suggestions.map(\.id) == row.items.filter(\.isReply).map(\.id))
        #expect(!strip.options.contains { ReplySuggestions.acceptsTime($0.label + "\n" + $0.body) })
    }

    @Test func everySuggestionGoesInAsOneUndoableEditWithTheCaretAtTheEnd() async throws {
        let stage = try await OneSuggestionStage.make(busy: true, frameName: "dev.openhuman.tests.one-suggestion-every")
        defer { stage.close() }
        try await stage.open()
        let row = try #require(stage.center?.inlineReplies.current)
        try await until { row.items.contains { $0.kind == .quickReply } }
        #expect(stage.router.perform(.reply))
        let body = try await stage.body()
        let session = try #require(stage.reader.inlineComposer?.session)
        try await until { body.window?.firstResponder === body }
        let undo = try #require(body.undoManager)
        let items = row.items
        _ = stage.w.window.makeFirstResponder(stage.reader.focusView)
        let previewed = try #require(row.preview)
        #expect(previewed.id == "calendar.counter")
        Self.press(tab: stage)
        try await until { body.string == previewed.body }
        #expect(session.scheduling?.option == previewed.schedulingOption, "it carries its times to the send")
        #expect(body.selectedRange() == NSRange(location: (body.string as NSString).length, length: 0))
        undo.undo()
        try await until { body.string.isEmpty && session.plainText.isEmpty }
        let replies = items.indices.filter { items[$0].isReply }
        #expect(replies.count >= 4, "the calendar's two replies and the AI's")
        for index in replies {
            let text = try #require(items[index].body)
            row.select(index)
            try await until { body.string == text }
            #expect(session.plainText == text, "exactly \(items[index].id)")
            #expect(body.selectedRange() == NSRange(location: (text as NSString).length, length: 0), "caret at the end")
            #expect(session.isAutoDraft == (items[index].kind == .quickReply))
            let html = session.assembledFields().bodyHTML
            #expect(QuoteSplit.quoteBlockCount(html) == 1)
            let words = try #require(html.range(of: Self.firstWords(text)))
            let quote = try #require(html.range(of: "gmail_quote"))
            #expect(words.lowerBound < quote.lowerBound, "the suggestion is above the quote")
            undo.undo()
            try await until { body.string.isEmpty && session.plainText.isEmpty }
        }
        _ = stage.w.window.makeFirstResponder(body)
        body.insertText("Hi Dana, ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(row.state == .none)
        let ask = try #require(items.firstIndex { $0.id == "calendar.ask" })
        row.select(ask)
        try await Task.sleep(for: .milliseconds(100))
        #expect(body.string == "Hi Dana, ")
        #expect(stage.calendar.createCalls == 0 && stage.calendar.moveCalls == 0, "the calendar is not written")
        #expect(stage.store.sentMessages.isEmpty, "nothing is sent")
    }

    @Test func tabAndReturnInTheEmptyBodyUseTheSameSet() async throws {
        let stage = try await OneSuggestionStage.make(busy: true, composerStrip: true,
                                                      frameName: "dev.openhuman.tests.one-suggestion-keys")
        defer { stage.close() }
        try await stage.open()
        #expect(stage.router.perform(.reply))
        let body = try await stage.body()
        let session = try #require(stage.reader.inlineComposer?.session)
        try await until { session.instantReply?.isLive == true }
        let strip = try #require(session.instantReply)
        try await until { body.window?.firstResponder === body }
        body.insertTab(nil)
        #expect(strip.selectedSuggestionID == "calendar.counter")
        try await until { body.ghostText == strip.suggestions.first?.body }
        let text = try #require(strip.suggestions.first?.body)
        body.insertNewline(nil)
        try await until { body.string == text }
        #expect(session.scheduling?.option == strip.suggestions.first?.schedulingOption)
        let undo = try #require(body.undoManager)
        undo.undo()
        try await until { body.string.isEmpty && session.plainText.isEmpty }
    }

    @Test func theBodysHintIsNeverDrawnUnderText() async throws {
        let stage = try await OneSuggestionStage.make(busy: true, frameName: "dev.openhuman.tests.one-suggestion-hint")
        defer { stage.close() }
        try await stage.open()
        #expect(stage.router.perform(.reply))
        let body = try await stage.body()
        let hint = body.hintView
        try await until {
            stage.w.window.contentView?.layoutSubtreeIfNeeded()
            return !hint.isHidden && hint.text?.string == ComposerEditor.placeholder(for: .reply)
        }
        let placeholderInk = try #require(ComposerTests.inkBounds(of: body), "the empty body shows the placeholder")

        stage.assistant.language = nil
        let moves = try #require(stage.assistant.analyses[stage.thread]?.moves)
        await stage.assistant.draft(.acceptAndMove(moves), in: stage.thread)
        try await until { !body.string.isEmpty }
        #expect(hint.isHidden, "a suggestion went in: the hint is gone")
        #expect(body.string.hasPrefix("Hi Dana,"))
        try Self.expectNoHintInk(in: body, beyond: "Hi Dana,", placeholderWidth: placeholderInk.width)

        body.load(RichTextDocument(blocks: [.paragraph([.text("Hi Dana,", [])])]))
        #expect(hint.isHidden, "a reload")
        try Self.expectNoHintInk(in: body, beyond: "Hi Dana,", placeholderWidth: placeholderInk.width)

        body.textStorage?.setAttributedString(NSAttributedString(string: ""))
        #expect(!hint.isHidden, "empty again: the placeholder is back")
        body.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hi Dana,")
        #expect(hint.isHidden, "a raw edit of the storage")

        let undo = try #require(body.undoManager)
        body.load(RichTextDocument())
        _ = body.replaceText(in: NSRange(location: 0, length: 0), with: "Hi Dana,")
        undo.undo()
        try await until { body.string.isEmpty }
        #expect(!hint.isHidden)
        let origin = body.textContainerOrigin
        #expect(abs(hint.frame.minX - origin.x) < 0.5 && abs(hint.frame.minY - origin.y) < 0.5,
                "the hint sits where the first line goes")
        #expect(hint.hitTest(NSPoint(x: hint.bounds.midX, y: hint.bounds.midY)) == nil, "it takes no clicks")
    }

    static func expectNoHintInk(in body: ComposerTextView, beyond text: String, placeholderWidth: CGFloat,
                                sourceLocation: SourceLocation = #_sourceLocation) throws {
        body.layoutSubtreeIfNeeded()
        let font = body.bridge.font
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let start = body.textContainerOrigin.x + textWidth + 6
        let end = body.textContainerOrigin.x + placeholderWidth
        guard end > start + 4 else { return }
        let rep = try #require(body.bitmapImageRepForCachingDisplay(in: body.bounds))
        body.cacheDisplay(in: body.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / body.bounds.width
        let top = body.textContainerOrigin.y
        let lineHeight = body.bridge.lineHeightValue
        var ink = 0
        for y in Int(top * scale)..<Int((top + lineHeight) * scale) {
            for x in Int(start * scale)..<min(Int(end * scale), rep.pixelsWide) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.2 { ink += 1 }
            }
        }
        #expect(ink == 0, "nothing drawn on the first line after the text (\(ink) pixels)", sourceLocation: sourceLocation)
    }

    static func firstWords(_ text: String) -> String {
        String(text.split(separator: "\n").first?.prefix(12) ?? "")
    }

    static func press(tab stage: OneSuggestionStage) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 100,
                                           windowNumber: stage.w.window.windowNumber, context: nil, characters: "\t",
                                           charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { return }
        if stage.w.content.keyRouter.route(event) != nil { stage.w.window.sendEvent(event) }
    }
}
