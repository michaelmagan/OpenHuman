import CoreGraphics
import Testing
@testable import MailUI

struct SearchDropdownLayoutTests {
    // Screen coordinates, y up: a 1100 × 800 window whose toolbar field sits near its trailing edge
    let window = CGRect(x: 100, y: 100, width: 1100, height: 760)
    let field = CGRect(x: 760, y: 870, width: 420, height: 28)

    @Test func itHangsUnderTheFieldInsideTheWindowWithTheTipsBeside() {
        let list = SearchDropdownLayout.listHeight(rows: 4, headers: 1, extraRows: 0)
        #expect(list == 4 * SearchDropdownLayout.rowHeight + SearchDropdownLayout.headerHeight
                + 2 * NativeMetrics.Search.panelPadding)
        let placement = SearchDropdownLayout.place(field: field, window: window, listHeight: list)
        #expect(placement.showsSide)
        #expect(placement.frame.maxY == field.minY - NativeMetrics.Search.panelGap, "a small gap under the field")
        #expect(!placement.frame.intersects(field), "never over the field")
        #expect(placement.frame.width == placement.listWidth + NativeMetrics.Search.panelSideWidth)
        #expect(placement.listWidth == field.width, "the list is as wide as the field")
        #expect(placement.frame.maxX <= window.maxX - NativeMetrics.Search.panelWindowMargin, "it moves left to stay inside")
        #expect(placement.frame.height == SearchDropdownLayout.sideHeight, "a short list keeps the tips' height")
        #expect(!placement.scrolls)
    }

    @Test func aFieldWithRoomKeepsTheListUnderIt() {
        let field = CGRect(x: 300, y: 870, width: 260, height: 28)
        let placement = SearchDropdownLayout.place(field: field, window: window,
                                                   listHeight: SearchDropdownLayout.listHeight(rows: 2, headers: 1, extraRows: 1))
        #expect(placement.frame.minX == field.minX)
        #expect(placement.listWidth == NativeMetrics.Search.panelListWidth, "a narrow field still gets a readable list")
    }

    @Test func aNarrowWindowDropsTheSideColumn() {
        let narrow = CGRect(x: 100, y: 100, width: 560, height: 760)
        let field = CGRect(x: 380, y: 870, width: 260, height: 28)
        let list = SearchDropdownLayout.listHeight(rows: 3, headers: 1, extraRows: 0)
        let placement = SearchDropdownLayout.place(field: field, window: narrow, listHeight: list)
        #expect(!placement.showsSide)
        #expect(placement.frame.width == placement.listWidth)
        #expect(placement.frame.height == list, "without the tips the panel is as tall as its rows")
        #expect(placement.frame.minX >= narrow.minX + NativeMetrics.Search.panelWindowMargin)
        #expect(placement.frame.maxX <= narrow.maxX - NativeMetrics.Search.panelWindowMargin)
        let tiny = SearchDropdownLayout.place(field: CGRect(x: 120, y: 870, width: 200, height: 28),
                                              window: CGRect(x: 100, y: 100, width: 300, height: 760), listHeight: list)
        #expect(tiny.frame.width == 300 - 2 * NativeMetrics.Search.panelWindowMargin, "it never leaves the window")
    }

    @Test func aShortWindowLimitsItsHeightAndTheListScrolls() {
        let list = SearchDropdownLayout.listHeight(rows: 8, headers: 3, extraRows: 2)
        let short = CGRect(x: 100, y: 600, width: 1100, height: 260)
        let placement = SearchDropdownLayout.place(field: field, window: short, listHeight: list)
        #expect(placement.frame.height < list)
        #expect(placement.scrolls)
        #expect(placement.frame.minY == short.minY + NativeMetrics.Search.panelWindowMargin, "it stops a margin above the bottom")
        let tiny = SearchDropdownLayout.place(field: field, window: CGRect(x: 100, y: 860, width: 1100, height: 40),
                                              listHeight: list)
        #expect(tiny.frame.height == SearchDropdownLayout.rowHeight, "one row at least")
    }

    @Test func escClosesTheDropDownBeforeTheModelsEsc() {
        var state = SearchDropdownState()
        #expect(state.shows(focused: true, hasContent: true))
        #expect(!state.shows(focused: false, hasContent: true), "only while the field has the keys")
        #expect(!state.shows(focused: true, hasContent: false), "nothing to show")
        let first = state.escape(showing: true)
        #expect(first, "the first Esc only closes the drop-down")
        #expect(!state.shows(focused: true, hasContent: true))
        let second = state.escape(showing: false)
        #expect(!second, "the second Esc goes to the model (clears the text)")
        #expect(!state.shows(focused: true, hasContent: true), "the cleared field's suggestions stay closed")
        let third = state.escape(showing: false)
        #expect(!third, "the third Esc goes to the model too (closes the field)")
        state.open()
        #expect(state.shows(focused: true, hasContent: true), "typing opens it again")
        let empty = state.escape(showing: false)
        #expect(!empty, "nothing showing (no suggestions): Esc is the model's at once")
    }

    @Test func theTipsUseOperatorsTheFieldKnows() {
        let known: Set<String> = ["from", "to", "subject", "has", "is", "in", "label", "after", "before"]
        for tip in SearchTips.all where tip.example.contains(":") {
            var name = tip.example.prefix { $0 != ":" }
            if name.hasPrefix("-") { name = name.dropFirst() }
            #expect(known.contains(String(name)), "\(tip.example)")
        }
        #expect(SearchDropdownView.title(.recent) == "Recent searches")
        #expect(SearchDropdownView.title(.people) == "People")
    }
}
