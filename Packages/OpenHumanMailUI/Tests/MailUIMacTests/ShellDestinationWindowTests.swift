import AppKit
import MailFakes
import MailFeatures
import MailModel
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct ShellDestinationWindowTests {
    static let frameName = "dev.openhuman.tests.shell-destination"
    private enum Place: Hashable { case mailList, allInboxes, calendar }

    private func make() async throws -> InlineReplyWindow {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let environment = AppEnvironment.fake(
            corpus: .rich(threadCount: 40, now: now), options: .init(remoteAck: .immediate),
            featureFlags: FeatureFlags(), calendar: FakeCalendar(), notices: NoticeCenter(autoExpire: false))
        let calendar = try #require(environment.calendarWindow)
        calendar.now = { now }
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, reduceMotion: true,
                                                exclusive: true, environment: environment)
        try await wait("both accounts") { w.router.accounts.count == 2 }
        return w
    }

    private func wait(_ what: @autoclosure () -> String, _ condition: @MainActor () -> Bool) async throws {
        do {
            // Long enough for a loaded machine, short enough that a place that never shows fails fast
            try await until(timeout: .seconds(30), condition)
        } catch {
            Issue.record("timed out waiting for \(what())")
            throw error
        }
    }

    // SwiftUI's accessibility nodes are not all views or `NSAccessibilityElement`s, so any object that answers the
    // accessibility protocol is walked
    private func elements(in node: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 40, let element = node as? any NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { elements(in: $0, depth: depth + 1) }
    }

    private func views(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(views)
    }

    /// All Inboxes' filter field, which only All Inboxes draws. Found in the window's views rather than through
    /// accessibility, which a locked session does not build.
    private func allInboxesField(in w: InlineReplyWindow) -> NSTextField? {
        guard let root = w.window.contentView else { return nil }
        let prompts: Set<String> = ["Filter these inboxes", "Search all mail in every account"]
        return views(in: root).lazy.compactMap { $0 as? NSTextField }.first { field in
            field.window === w.window && !field.isHiddenOrHasHiddenAncestor
                && prompts.contains(field.placeholderString ?? field.placeholderAttributedString?.string ?? "")
        }
    }

    private func shown(in w: InlineReplyWindow) -> Set<Place> {
        w.window.contentView?.layoutSubtreeIfNeeded()
        w.window.displayIfNeeded()
        var places: Set<Place> = []
        let mail = !w.content.view.isHiddenOrHasHiddenAncestor
        if mail && !w.content.tableView.isHiddenOrHasHiddenAncestor {
            places.insert(.mailList)
        }
        if allInboxesField(in: w) != nil {
            places.insert(.allInboxes)
        }
        // The Calendar is drawn over the mail column, which is hidden under it
        if w.environment.calendarWindowIfStarted?.isOpen == true, !mail {
            places.insert(.calendar)
        }
        return places
    }

    private func toolbarMatches(_ place: Place, in w: InlineReplyWindow) -> Bool {
        let items = w.window.toolbar?.items ?? []
        let calendarID = ShellToolbar.ItemID.calendar
        guard let calendar = items.first(where: { $0.itemIdentifier.rawValue.contains(calendarID) }) else {
            return false
        }
        let title = place == .calendar ? "Back to Mail" : "Calendar"
        // The item's own label carries its title even where accessibility is not built (a locked session)
        let spoken = calendar.view.map { elements(in: $0).compactMap { $0.accessibilityLabel() } } ?? []
        let labels = [calendar.label] + spoken
        guard labels.contains(title) else { return false }
        if place == .calendar {
            let absent = [ShellToolbar.searchFieldIdentifier, ShellToolbar.ItemID.selectAll, ShellToolbar.ItemID.splits]
            guard !items.contains(where: { item in
                absent.contains { item.itemIdentifier.rawValue.contains($0) }
            }) else { return false }
            guard !items.contains(where: { item in
                item.view.map { elements(in: $0).contains {
                    $0.accessibilityIdentifier() == ShellToolbar.searchFieldIdentifier
                } } ?? false
            }) else { return false }
        }
        return true
    }

    private func expect(_ place: Place, in w: InlineReplyWindow) async throws {
        try await wait("only \(place) to show (shown: \(shown(in: w)))") { shown(in: w) == [place] }
        try await wait("the toolbar for \(place)") { toolbarMatches(place, in: w) }
        switch place {
        case .mailList:
            try await wait("the mail list to take the keys") { w.window.firstResponder === w.content.tableView }
        case .allInboxes:
            let model = try #require(w.router.unifiedInbox)
            try await wait("All Inboxes rows") { !model.isLoading && model.rows.count >= 2 }
            model.setCursor(model.rows[0].id)
            let next = model.rows[1].id
            _ = try typingKey("j", in: w)
            try await wait("J to move the cursor (keys: \(String(describing: w.window.firstResponder)))") {
                model.cursor == next
            }
        case .calendar:
            let model = try #require(w.router.unifiedInbox)
            let cursor = model.cursor
            _ = try typingKey("j", in: w)
            await w.environment.actions.lastTask?.value
            #expect(model.cursor == cursor)
        }
    }

    @Test func switchingPlacesShowsOneAtATime() async throws {
        let w = try await make()
        defer { w.close() }
        w.router.go(to: .system(.inbox))
        try await expect(.mailList, in: w)
        #expect(w.router.goToAllInboxes())
        try await expect(.allInboxes, in: w)
        #expect(w.router.perform(.calendarOpen))
        try await expect(.calendar, in: w)
        #expect(w.router.goToAllInboxes())
        try await expect(.allInboxes, in: w)
        w.router.go(to: .system(.inbox))
        try await expect(.mailList, in: w)
    }

    @Test func backToMailFromTheCalendarReturnsToAllInboxes() async throws {
        let w = try await make()
        defer { w.close() }
        #expect(w.router.goToAllInboxes())
        try await expect(.allInboxes, in: w)
        let model = try #require(w.router.unifiedInbox)
        #expect(w.router.perform(.calendarOpen))
        try await expect(.calendar, in: w)
        #expect(w.router.perform(.calendarBackToMail))
        try await expect(.allInboxes, in: w)
        #expect(w.router.unifiedInbox === model)
    }
}
