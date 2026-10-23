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
@Suite(.serialized) struct OverlayResultsShrinkTests {
    static let frameName = "dev.openhuman.tests.overlay-shrink"

    static let queries = ["a", "ar", "arc", "archive", "zzqqxx", "", "s", "sn", "snooze", "re", "remind me tomorrow",
                          "x", "", "go", "go to", "mark done", "q", "label", ""]

    private func draw(_ w: InlineReplyWindow) {
        w.window.contentView?.layoutSubtreeIfNeeded()
        w.window.displayIfNeeded()
    }

    private func drawnFrame(of input: NSTextField, in w: InlineReplyWindow) async throws -> NSRect {
        let size = NativeMetrics.Overlay.paletteFieldTextSize
        try await until {
            draw(w)
            return input.font?.pointSize == size && input.frame.height == input.intrinsicContentSize.height
        }
        return input.convert(input.bounds, to: nil)
    }

    private func type(_ text: String, into input: NSTextField, in w: InlineReplyWindow) async throws {
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) === input }
        let editor = try #require(w.window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        editor.selectAll(nil)
        if text.isEmpty {
            editor.deleteBackward(nil)
        } else {
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
    }

    private func focusedField(_ w: InlineReplyWindow) -> NSTextField? {
        OverlayFocusKeeper.control(of: w.window.firstResponder) as? NSTextField
    }

    @Test func thePalettesResultsShrinkWhileDrawnFromTheComposer() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.hasKeyboardFocus }
        #expect(w.router.perform(.commandPalette))
        guard case .palette(let palette) = w.environment.overlays.overlay else {
            Issue.record("the palette is up")
            return
        }
        try await until { focusedField(w).map { !$0.isDescendant(of: composer) } ?? false }
        let input = try #require(focusedField(w))
        let inputFrame = try await drawnFrame(of: input, in: w)
        for round in 0..<3 {
            for query in Self.queries {
                try await type(query, into: input, in: w)
                try await until { palette.query == query }
                draw(w)
                if round > 0 {
                    await palette.loadMail()
                    draw(w)
                }
                let ids = palette.entries.map(\.id)
                #expect(Set(ids).count == ids.count, "one row per id for “\(query)”")
                #expect(palette.entries.indices.contains(palette.cursor) || palette.entries.isEmpty)
                if let cursor = palette.entries.indices.contains(palette.cursor) ? palette.entries[palette.cursor] : nil {
                    #expect(cursor.isAvailable, "the cursor never sits on a Not available row")
                }
                #expect(input.convert(input.bounds, to: nil) == inputFrame,
                        "the input row does not move for “\(query)” (round \(round); font \(input.font?.pointSize ?? 0) pt, intrinsic height \(input.intrinsicContentSize.height), fitting height \(input.fittingSize.height), host height \(input.superview?.frame.height ?? -1))")
            }
        }
    }

    @Test func theSendLaterPickersRowsShrinkWhileDrawnFromTheComposer() async throws {
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true)
        defer { w.close() }
        let (thread, _) = try await w.conversationWithAMiddleSender()
        _ = try await w.open(thread)
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.hasKeyboardFocus }
        #expect(w.environment.compose.perform(.sendLater, in: composer.session, source: .keyboard))
        guard case .time(let picker) = w.environment.overlays.overlay else {
            Issue.record("the send-later picker is up")
            return
        }
        try await until { focusedField(w).map { !$0.isDescendant(of: composer) } ?? false }
        let input = try #require(focusedField(w))
        let inputFrame = try await drawnFrame(of: input, in: w)
        var counts = Set<Int>()
        for text in ["", "tomorrow 9am", "zzqq", "in 2 days", "", "fri 3pm", "yesterday", "dec 1", ""] {
            try await type(text, into: input, in: w)
            try await until { picker.text == text }
            draw(w)
            #expect(picker.rows.indices.contains(picker.cursor), "the cursor is on a row for “\(text)”")
            #expect(input.convert(input.bounds, to: nil) == inputFrame)
            counts.insert(picker.rows.count)
        }
        #expect(counts.count > 1, "the rows grew and shrank")
        picker.openDatePick()
        draw(w)
        picker.closeDatePick()
        draw(w)
        picker.moveCursor(by: -1)
        picker.text = "tomorrow 9am"
        draw(w)
        #expect(picker.cursor == 0, "a new list starts at its first row")
    }
}
