import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func remindSheets(_ theme: SweepTheme) async throws {
        do {
            let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
            defer { w.close() }
            let overlays = w.environment.overlays
            SweepOverlayFixture.pinClock(overlays)
            w.router.perform(.nextThread)
            w.router.perform(.nextThread)
            #expect(w.router.perform(.remind))
            let picker = try SweepOverlayFixture.timePicker(overlays)
            try await sweepShoot(w.window, screen: "remind-sheet", theme: theme)
            guard !theme.isAccessibilityVariant else { return }

            picker.text = "in 3 days"
            try await sweepShoot(w.window, screen: "remind-sheet-typed", theme: theme)
            picker.text = "next blursday"
            try await sweepShoot(w.window, screen: "remind-sheet-unparsed", theme: theme)
            picker.text = ""
            picker.openDatePick()
            try await sweepShoot(w.window, screen: "remind-sheet-date-grid", theme: theme)
            overlays.dismiss()

            let thread = try #require(picker.targets.first)
            _ = await w.environment.actions.threadActions?.remind(thread, at: SweepOverlayFixture.reminderDue,
                                                                   kind: .ifNoReply, host: w.router)?.value
            SweepOverlayFixture.dismissToasts(w.environment)
            #expect(w.router.perform(.remind))
            let current = try SweepOverlayFixture.timePicker(overlays)
            try await until { current.currentLine != nil }
            try await sweepShoot(w.window, screen: "remind-sheet-current", theme: theme)
            overlays.dismiss()

            #expect(w.router.perform(.snooze))
            _ = try SweepOverlayFixture.timePicker(overlays)
            try await sweepShoot(w.window, screen: "snooze-sheet", theme: theme)
            overlays.dismiss()
        }
        do {
            let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
            defer { w.close() }
            let overlays = w.environment.overlays
            SweepOverlayFixture.pinClock(overlays)
            let (thread, _) = try await w.longestConversation()
            _ = try await w.open(thread)
            #expect(w.router.perform(.reply))
            _ = try await w.inlineComposer()
            overlays.presentSendLater(draftTargets: [thread]) { _, _ in }
            _ = try SweepOverlayFixture.timePicker(overlays)
            try await sweepShoot(w.window, screen: "send-later-sheet", theme: theme)
            overlays.dismiss()
        }
    }

    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func searchSheets(_ theme: SweepTheme) async throws {
        SearchDropdownPanel.drawsMaterial = true
        defer { SearchDropdownPanel.drawsMaterial = false }
        do {
            let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
            defer { w.close() }
            let search = w.environment.overlays.search
            let editor = try await openSearchField(w)
            try await until { search.isOpen && !search.suggestions.isEmpty }
            try await sweepShootWithChildWindows(w.window, screen: "search-sheet-empty", theme: theme)
            guard !theme.isAccessibilityVariant else { return }

            editor.insertText("da", replacementRange: editor.selectedRange())
            try await until {
                search.text == "da" && search.suggestions.contains { $0.kind == .person } && search.shownQuery == "da"
                    && w.router.list?.state == .loaded
            }
            try await sweepShootWithChildWindows(w.window, screen: "search-sheet-typed", theme: theme)

            editor.selectAll(nil)
            editor.insertText("from:da", replacementRange: editor.selectedRange())
            try await until {
                search.text == "from:da" && search.suggestions.contains { $0.kind == .person }
                    && search.shownQuery == "from:da" && w.router.list?.state == .loaded
            }
            try await sweepShootWithChildWindows(w.window, screen: "search-sheet-from", theme: theme)
        }
        guard !theme.isAccessibilityVariant else { return }
        do {
            let w = try await SweepWindow.make(SweepOverlayFixture.environment(ai: true), theme: theme)
            defer { w.close() }
            let search = w.environment.overlays.search
            let editor = try await openSearchField(w)
            editor.insertText("budget", replacementRange: editor.selectedRange())
            try await until { search.text == "budget" && search.shownQuery == "budget" && w.router.list?.state == .loaded }
            try await sweepShootWithChildWindows(w.window, screen: "search-sheet-ask-ai", theme: theme)

            search.submit()
            try await until {
                !(OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField) && search.shownQuery == "budget"
                    && w.router.list?.state == .loaded
            }
            try await sweepShoot(w.window, screen: "search-results", theme: theme)
        }
    }

    private func openSearchField(_ w: InlineReplyWindow) async throws -> NSTextView {
        #expect(w.router.perform(.search))
        try await until { OverlayFocusKeeper.control(of: w.window.firstResponder) is NSTextField }
        return try #require(w.window.firstResponder as? NSTextView)
    }

    @Test(arguments: SweepTheme.builtIns)
    func getMeToZeroCard(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepOverlayFixture.environment(), theme: theme)
        defer { w.close() }
        let overlays = w.environment.overlays
        SweepOverlayFixture.pinClock(overlays)
        #expect(w.router.perform(.getMeToZero))
        let card = try SweepOverlayFixture.zeroCard(overlays)
        try await until { !card.isLoading }
        try await sweepShoot(w.window, screen: "get-me-to-zero", theme: theme)

        card.keepUnread = false
        try await sweepShoot(w.window, screen: "get-me-to-zero-options", theme: theme)
        overlays.dismiss()

        let store = try #require(w.environment.data as? FakeMailStore)
        let account = try #require(w.router.accounts.first?.account)
        let inbox = try await w.environment.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 5000)
        store.removeThreads(Set(inbox.rows.map(\.id)))
        try await until { w.router.list?.state == .loaded && w.router.list?.rows.isEmpty == true }
        #expect(w.router.perform(.getMeToZero))
        let empty = try SweepOverlayFixture.zeroCard(overlays)
        try await until { !empty.isLoading }
        try await sweepShoot(w.window, screen: "get-me-to-zero-empty", theme: theme)
        overlays.dismiss()
    }
}
