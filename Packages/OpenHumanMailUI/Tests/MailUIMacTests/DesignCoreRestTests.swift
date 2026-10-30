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
@Suite(.serialized)
struct DesignCoreRestTests {
    @Test func dateHeadersAreRowsTheCursorAndClicksSkip() async throws {
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 60)
        defer { window.close() }
        let table = controller.tableView
        #expect(model.groups.isEmpty && table.numberOfRows == model.displayCount, "off for a list built on its own")

        controller.showsDateGroups = true
        try await until { !model.groups.isEmpty && table.numberOfRows == model.displayCount }
        window.contentView?.layoutSubtreeIfNeeded()
        let headers = model.groups.headers
        for (index, header) in headers.enumerated() {
            let display = model.groups.displayIndex(ofHeader: index)
            #expect(!controller.tableView(table, shouldSelectRow: display), "\(header.title)")
            if let view = table.view(atColumn: 0, row: display, makeIfNecessary: true) as? ThreadGroupHeaderView {
                #expect(view.title == header.title)
            } else {
                Issue.record("row \(display) is not a header view")
            }
        }
        for _ in 0..<12 { model.moveCursor(by: 1) }
        let cursor = try #require(model.cursor)
        #expect(table.selectedRow == model.displayIndex(of: cursor))
        #expect(model.header(atDisplay: table.selectedRow) == nil)
        let firstHeader = model.groups.displayIndex(ofHeader: 0)
        controller.handleClick(row: firstHeader, extending: false, toggling: false)
        #expect(model.cursor == cursor)

        controller.showsDateGroups = false
        try await until { model.groups.isEmpty && table.numberOfRows == model.rows.count + model.placeholderCount }
    }

    @Test func aRowLeavingKeepsHeadersAndRowsInStep() async throws {
        let host = StubListHost()
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 40, host: host)
        defer { window.close() }
        controller.showsDateGroups = true
        let table = controller.tableView
        try await until { !model.groups.isEmpty && table.numberOfRows == model.displayCount }
        let header = try #require(model.groups.headers.dropFirst().first ?? model.groups.headers.first)
        let target = model.rows[header.row].id
        #expect(controller.performRowAction(.markDone, key: target))
        #expect(table.numberOfRows == model.displayCount)
        #expect(model.index(of: target) == nil)
        if let cursor = model.cursor { #expect(table.selectedRow == model.displayIndex(of: cursor)) }
    }


    @Test func aRunOfCollapsedMessagesIsHairlineRowsWithNoGaps() async throws {
        let detail = UIFixtures.conversation(4, count: 6)
        var bodies: [MessageKey: MessageContent] = [:]
        for message in detail.messages { bodies[message.id] = MessageContent(html: nil, text: "Hi") }
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id)
        defer { h.close() }
        try await until { h.model.messages.count == 6 }
        h.model.showAllMessages()
        try await until { h.controller.messageViews.count == 6 }
        h.controller.view.layoutSubtreeIfNeeded()
        let views = h.model.messages.compactMap { h.controller.messageViews[$0.id] }
        #expect(views.count == 6)
        for view in views {
            #expect(view.separator.superview === view, "every message starts with a hairline")
            if !view.isExpanded, !view.isFocused {
                #expect(view.plateLook == .none, "an idle collapsed row is flat on the canvas")
            }
        }
        for (upper, lower) in zip(views, views.dropFirst()) {
            let a = upper.convert(upper.bounds, to: nil), b = lower.convert(lower.bounds, to: nil)
            #expect(abs(a.minY - b.maxY) < 0.5, "rows meet at their hairline, no gap between messages")
        }
    }

    @Test func theListAndTheReaderFollowTheDensity() {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let style = ThreadRowStyle(theme: theme)
            #expect(style.plateInsetY == NativeMetrics.List.plateInsetY && style.hoverTarget == CGFloat(theme.listHoverTarget))
            let pill = OlderMessagesPillView(count: 3, theme: theme)
            pill.layoutSubtreeIfNeeded()
            #expect(pill.fittingSize.height == CollapsedMessageView.rowHeight(theme) + 1, "\(density)")
        }
    }
}
