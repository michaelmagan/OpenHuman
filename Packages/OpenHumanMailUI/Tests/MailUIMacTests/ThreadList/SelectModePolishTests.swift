import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

@MainActor
@Suite struct SelectModePolishTests {
    private static let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func checkedRowsDrawTheirOwnFillApartFromTheCursor() {
        for (label, t) in RowBandTests.everyTheme() {
            let style = ThreadRowStyle(theme: t)
            #expect(RenderReviewFixTests.same(style.checked, ThreadRowStyle.checkedFill(t).nsColor), "\(label)")
            #expect(!RenderReviewFixTests.same(style.checked, style.cursor), "\(label)")
            #expect(!RenderReviewFixTests.same(style.checked, style.inactiveCursor), "\(label)")
            #expect(!RenderReviewFixTests.same(style.checked, style.hover), "\(label)")
        }
    }

    @Test func aCheckedRowDrawsTheSameChipImagesWithoutMovingTheLine() throws {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let row = RowActionsOverlapTests.shown(.long, style: style).row
            let chips = [ThreadRowChip(kind: .label, title: "Atlas", color: "#a479e2"), ThreadRowChip(kind: .vip, title: "VIP"),
                         ThreadRowChip(kind: .label, title: "Travel", color: "#16a766")]
            let line = style.texts(for: row, chips: chips, format: ThreadRowFormatting(), location: .system(.inbox)).line
            let shown = LabelChipRenderer.shown(chips, maximum: ThreadRowStyle.maximumFilledChips)
            #expect(shown.map(\.title) == ["atlas", "vip", "+1"])
            let texts = style.texts(for: row, chips: chips, format: ThreadRowFormatting(), location: .system(.inbox))
            var drawn: [[NSTextAttachment]] = []
            for checked in [false, true] {
                let cell = ThreadRowView(style: style)
                cell.frame = NSRect(x: 0, y: 0, width: 1200, height: style.rowHeight)
                cell.configure(row, texts: texts, date: style.date("Oct 8", unread: false, upcoming: false), indicators: [],
                               isChecked: checked)
                drawn.append(Self.attachments(try #require(cell.drawnLine(cell.drawnFrames()))))
            }
            let plain = Self.attachments(line)
            #expect(plain.count == shown.count && drawn.allSatisfy { $0.count == shown.count })
            for (index, chip) in shown.enumerated() where index < plain.count {
                let image = style.chips.image(chip.title, hue: chip.hue, muted: chip.muted).image
                #expect(plain[index].image === image)
                #expect(drawn.allSatisfy { $0[index].image === image && $0[index].bounds == plain[index].bounds },
                        "one translucent image on every plate: \(chip.title)")
            }
        }
    }

    @Test func chipTextReadsOnItsTintOverEveryPlateInEveryTheme() {
        var themes = RowBandTests.everyTheme()
        for themeID in RowActionsOverlapTests.themeIDs {
            let t = ThemeLibrary.builtIn.resolve(themeID: themeID,
                                                 appearance: RowActionsOverlapTests.darkThemeIDs.contains(themeID) ? .dark : .light,
                                                 increaseContrast: true).tokens
            themes.append(("\(themeID) increaseContrast", t))
        }
        for (label, t) in themes {
            let renderer = LabelChipRenderer(theme: t)
            let plates = [t.bgWindow, ThreadRowStyle.hoverFill(t), ThreadRowStyle.checkedFill(t), ThreadRowStyle.cursorFill(t),
                          ThreadRowStyle.inactiveCursorFill(t)]
            #expect(renderer.plates == plates, "\(label)")
            for hue in LabelChipHue.allCases {
                let colors = renderer.colors(hue: hue, muted: false)
                #expect(colors.fill == LabelChipRenderer.tint(t.labelChip(hue).text), "\(hue) tint: \(label)")
                for plate in plates {
                    #expect(colors.ink.contrastRatio(on: colors.fill.composited(over: plate)) >= 4.5, "\(hue) chip text: \(label)")
                }
            }
            let muted = renderer.colors(hue: .neutral, muted: true)
            #expect(muted == (LabelChipRenderer.tint(t.textTertiary), t.textTertiary), "a muted chip stays quiet: \(label)")
        }
    }

    @Test func greyTextOnCheckedAndCursorRowsIsDrawnInTextSecondary() throws {
        for (label, t) in RowBandTests.everyTheme() {
            let style = ThreadRowStyle(theme: t)
            #expect(t.textSecondary.contrastRatio(on: ThreadRowStyle.checkedFill(t)) >= 4.5, "checked fill: \(label)")
            #expect(t.textSecondary.contrastRatio(on: ThreadRowStyle.cursorFill(t)) >= 4.5, "cursor fill: \(label)")
            for state in [Self.RowState.checked, .cursor, .idle] {
                let cell = Self.cell(style, state: state)
                let texts = try [#require(cell.drawnSender()), #require(cell.drawnLine(cell.drawnFrames())),
                                 #require(cell.drawnDate())]
                var dim = 0
                for text in texts {
                    text.enumerateAttribute(ThreadRowStyle.dimRun, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                        guard value != nil else { return }
                        dim += 1
                        let color = text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                        let expected: NSColor? = state == .idle ? nil : style.secondary
                        let piece = text.attributedSubstring(from: range).string
                        if let expected {
                            #expect(color == expected, "\(state) \(piece): \(label)")
                        } else if piece.contains("invented snippet") {
                            #expect(color == style.snippet, "the snippet is secondary text: \(label)")
                        } else {
                            #expect(color != style.secondary || t.textTertiary == t.textSecondary,
                                    "an idle row keeps its quieter grey: \(label)")
                        }
                    }
                }
                #expect(dim == 3, "the count, the snippet and the read date: \(state) \(label)")
            }
        }
    }

    enum RowState { case checked, cursor, idle }

    static func cell(_ style: ThreadRowStyle, state: RowState) -> ThreadRowView {
        let row = ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("g7")),
                            subject: "Venue shortlist", snippet: "An invented snippet", participantsDisplay: "Dana Ruiz",
                            participants: [], messageCount: 2, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                            isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now)
        let texts = style.texts(for: row, chips: [], format: ThreadRowFormatting(), location: .system(.inbox))
        let rowView = ThreadRowBackgroundView(style: style)
        rowView.frame = NSRect(x: 0, y: 0, width: 900, height: style.rowHeight)
        let cell = ThreadRowView(style: style)
        cell.frame = rowView.bounds
        rowView.addSubview(cell)
        cell.configure(row, texts: texts, date: style.date("Oct 8", unread: false, upcoming: false), indicators: [],
                       isChecked: state == .checked)
        rowView.isChecked = state == .checked
        rowView.isSelected = state == .cursor
        return cell
    }

    @Test func theRowBoxUsesTheSharedSizeAndColours() {
        #expect(ThreadRowView.checkboxSize == SelectCheckbox.side)
        for resolved in [ResolvedTheme.light, ResolvedTheme.dark] {
            let t = resolved.tokens
            let style = ThreadRowStyle(theme: t)
            let colors = SelectCheckbox.colors(t)
            #expect(RenderReviewFixTests.same(style.accentFill, colors.fill.nsColor))
            #expect(RenderReviewFixTests.same(style.accentOnFill, colors.tick.nsColor))
            #expect(RenderReviewFixTests.same(style.tertiary, colors.outline.nsColor))
        }
    }

    @Test func theHeaderBoxIsMixedWhileSomeRowsAreCheckedAndClickingChecksThemAll() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: Self.now))
        let list = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        list.start()
        defer { list.stop() }
        try await until { list.rows.count == 3 }
        let rows = list.rows.map(\.id)
        list.selection.toggle(rows[0])
        #expect(list.headerCheck == .some)
        #expect(SelectAllCheckbox.sources(list.headerCheck, list: list).map(\.wrappedValue) == [true, false],
                "one on and one off: the system box shows its dash")
        list.selection.toggle(rows[1])
        list.selection.toggle(rows[2])
        #expect(list.headerCheck == .all)
        #expect(SelectAllCheckbox.sources(list.headerCheck, list: list).map(\.wrappedValue) == [true])

        list.clearChecks()
        list.selection.toggle(rows[1])
        for source in SelectAllCheckbox.sources(list.headerCheck, list: list) { source.wrappedValue = true }
        #expect(list.selection.checked == Set(rows) && list.headerCheck == .all, "a click on the dash checks every row")
        for source in SelectAllCheckbox.sources(list.headerCheck, list: list) { source.wrappedValue = false }
        #expect(list.selection.checked.isEmpty && list.headerCheck == .hidden, "a click on the full box clears them")
    }

    @Test func theHeaderCheckboxSlotKeepsItsWidthSoTheTabsNeverMove() {
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: Self.now))
        let list = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        func width() -> CGFloat {
            let host = NSHostingView(rootView: SelectAllCheckbox(list: list, descriptors: []).environment(\.theme, ResolvedTheme.light))
            return host.fittingSize.width
        }
        #expect(list.headerCheck == .hidden)
        let empty = width()
        list.selection.toggle(ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1")))
        #expect(list.headerCheck == .some)
        let shown = width()
        #expect(empty > 0)
        #expect(empty == shown)
        #expect(empty == ShellMetrics.toolbarControlHeight, "a toolbar item; the toolbar spaces it from the title")
    }

    @Test func thePanelCloseGlyphReadsOnTheSidebarInEveryTheme() {
        for (label, t) in RowBandTests.everyTheme() {
            #expect(RightPaneTabs.closeTint(t).contrastRatio(on: t.bgSidebar) >= 3, "\(label)")
        }
    }

    private static func attachments(_ line: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }
}
