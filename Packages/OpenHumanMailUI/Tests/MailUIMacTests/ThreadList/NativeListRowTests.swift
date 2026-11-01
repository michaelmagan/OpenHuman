import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct NativeListRowTests {
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    private static var format: ThreadRowFormatting {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return ThreadRowFormatting(calendar: calendar, locale: Locale(identifier: "en_US"))
    }

    private static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func datesUseTheSystemStyleAndAreNeverUpperCased() throws {
        let format = Self.format
        let calendar = format.calendar
        let today = try #require(calendar.date(bySettingHour: 10, minute: 42, second: 0, of: Self.now))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let earlier = try #require(calendar.date(byAdding: .day, value: -9, to: today))
        let lastYear = try #require(calendar.date(byAdding: .year, value: -1, to: today))
        #expect(Self.spaced(ThreadRowStyle.listDate(today, format: format, now: Self.now)) == "10:42 AM")
        #expect(ThreadRowStyle.listDate(yesterday, format: format, now: Self.now) == "Yesterday")
        let sameYear = ThreadRowStyle.listDate(earlier, format: format, now: Self.now)
        #expect(sameYear == format.spokenListDate(earlier, now: Self.now) && sameYear != sameYear.uppercased())
        let older = ThreadRowStyle.listDate(lastYear, format: format, now: Self.now)
        #expect(older.contains(String(calendar.component(.year, from: lastYear))) && older != older.uppercased())
    }

    @Test func theDateIsTwelvePointTertiaryWithMonospacedDigits() {
        let style = ThreadRowStyle(theme: .light)
        #expect(RenderReviewFixTests.sameFont(style.dateFont,
                                              NSFont.monospacedDigitSystemFont(ofSize: NativeMetrics.List.dateTextSize, weight: .regular)))
        #expect(style.dateFont.fontDescriptor.fontAttributes[.featureSettings] != nil, "tabular digits")
        let read = style.date("Oct 12", unread: false, upcoming: false)
        let unread = style.date("Oct 12", unread: true, upcoming: false)
        for text in [read, unread] {
            #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == style.tertiary)
            #expect(text.attribute(ThreadRowStyle.dimRun, at: 0, effectiveRange: nil) != nil, "a selected row lifts it")
        }
        let upcoming = style.date("Thu 9:00 AM", unread: false, upcoming: true)
        #expect(upcoming.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == style.warning)
    }

    @Test func theSenderIsSemiboldWhenUnreadAndMediumWhenRead() {
        let style = ThreadRowStyle(theme: .light)
        #expect(RenderReviewFixTests.sameFont(style.strongFont, NSFont.systemFont(ofSize: 13, weight: .semibold)))
        #expect(RenderReviewFixTests.sameFont(style.readSenderFont, NSFont.systemFont(ofSize: 13, weight: .medium)))
        #expect(!RenderReviewFixTests.sameFont(style.strongFont, style.readSenderFont))
        let row = RowActionsOverlapTests.shown(.long, style: style).row
        let read = ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 41, gmailThreadID: GmailThreadID("t41")),
                             subject: "Venue shortlist", snippet: "An invented snippet", participantsDisplay: "Dana Ruiz",
                             participants: [], messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0,
                             isUnread: false, isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: Self.now,
                             sortAt: Self.now)
        let format = Self.format
        let unreadSender = style.texts(for: row, chips: [], format: format, location: .system(.inbox)).sender
        let readSender = style.texts(for: read, chips: [], format: format, location: .system(.inbox)).sender
        #expect(unreadSender.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == style.strongFont)
        #expect(readSender.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == style.readSenderFont)
        #expect(style.snippet == style.secondary, "the snippet is secondary text")
    }

    @Test func chipsAreElevenPointCapsulesEighteenPointsHigh() {
        let style = ThreadRowStyle(theme: .light)
        #expect(style.chipFont.pointSize == NativeMetrics.Tag.textSize)
        #expect(style.chips.chipHeight == NativeMetrics.Tag.height)
        let image = style.chips.image("clients", hue: .sky, muted: false).image
        #expect(image.size.height == NativeMetrics.Tag.height)
        #expect(image.size.width >= 2 * NativeMetrics.Tag.paddingX)
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let dense = ThreadRowStyle(theme: theme)
            #expect(dense.chips.chipHeight <= dense.rowHeight - 2 * dense.plateInsetY, "\(density)")
        }
    }

    @Test func theUnreadDotIsAnEightPointAccentDot() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            #expect(style.unreadDotSize == NativeMetrics.List.unreadDotSize)
            #expect(RenderReviewFixTests.same(style.unreadDot, theme.accentRing.nsColor))
        }
    }

    @Test func thePlateIsInsetEightByOneWithSixPointCorners() {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let style = ThreadRowStyle(theme: theme)
            #expect(style.plateInsetX == 8 && style.plateInsetY == 1 && style.plateRadius == 6, "\(density)")
            let bounds = NSRect(x: 0, y: 0, width: 600, height: style.rowHeight)
            #expect(style.plateRect(in: bounds) == NSRect(x: 8, y: 1, width: 584, height: style.rowHeight - 2))
        }
    }

    @Test func theSelectionFollowsTheWindowsKeyState() {
        let style = ThreadRowStyle(theme: .light)
        let rowView = ThreadRowBackgroundView(style: style)
        rowView.frame = NSRect(x: 0, y: 0, width: 600, height: style.rowHeight)
        rowView.isSelected = true
        #expect(!rowView.isEmphasized, "a row outside a key window is not emphasized")
        #expect(RenderReviewFixTests.same(rowView.selectionFill, style.inactiveCursor))
        rowView.emphasisOverride = true
        #expect(rowView.isEmphasized)
        #expect(RenderReviewFixTests.same(rowView.selectionFill, style.cursor))
        rowView.emphasisOverride = false
        #expect(RenderReviewFixTests.same(rowView.selectionFill, style.inactiveCursor))
        rowView.isEmphasized = true
        #expect(!rowView.isEmphasized, "the table's first-responder emphasis does not grey or light the plate")
    }

    @Test func checkedAndHoveredRowsDrawTheirPlateOnlyWhenNotSelected() {
        let style = ThreadRowStyle(theme: .light)
        let rowView = ThreadRowBackgroundView(style: style)
        #expect(rowView.idleFill == nil)
        rowView.setHovering(true)
        #expect(RenderReviewFixTests.same(rowView.idleFill, style.hover))
        rowView.isChecked = true
        #expect(RenderReviewFixTests.same(rowView.idleFill, style.checked), "a checked row keeps its tint under the pointer")
    }

    @Test func theListPassesItsEmphasisOverrideToEveryRow() async throws {
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        model.moveCursor(by: 2)
        window.contentView?.layoutSubtreeIfNeeded()
        let table = controller.tableView
        try #require(table.selectedRow >= 0)
        func rows() -> [ThreadRowBackgroundView] {
            var result: [ThreadRowBackgroundView] = []
            table.enumerateAvailableRowViews { view, _ in if let view = view as? ThreadRowBackgroundView { result.append(view) } }
            return result
        }
        #expect(!rows().isEmpty && rows().allSatisfy { $0.emphasisOverride == nil })
        controller.selectionEmphasisOverride = true
        #expect(rows().allSatisfy { $0.emphasisOverride == true })
        let selected = try #require(table.rowView(atRow: table.selectedRow, makeIfNecessary: false) as? ThreadRowBackgroundView)
        #expect(selected.isEmphasized)
        controller.selectionEmphasisOverride = false
        #expect(!selected.isEmphasized && rows().allSatisfy { $0.emphasisOverride == false })
    }

    @Test func aKeyChangeRedrawsNoCell() async throws {
        let (controller, model, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        model.moveCursor(by: 2)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let table = controller.tableView
        var cells: [ThreadRowView] = []
        for row in controller.visibleRowRange {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadRowView { cells.append(cell) }
        }
        try #require(!cells.isEmpty)
        let before = cells.map(\.drawCount)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        window.displayIfNeeded()
        #expect(cells.map(\.drawCount) == before, "the plate is the row view's; the text is not drawn again")
    }

    @Test func theImportantSplitShowsNoImportantChip() {
        let row = RowActionsOverlapTests.shown(.chips, style: ThreadRowStyle(theme: .light)).row
        let inImportant = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(location: .system(.important),
                                                                                         impliesImportance: true))
        #expect(!inImportant.contains { $0.kind == .important || $0.kind == .gmailImportant })
        let inInbox = ThreadRowFormatting.chips(for: row, context: ThreadRowChipContext(location: .system(.inbox)))
        #expect(inInbox.contains { $0.kind == .important || $0.kind == .gmailImportant })
    }
}
