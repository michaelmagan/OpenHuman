import AppKit
import Testing
@testable import MailUIMac

struct ThreadListHoverModelTests {
    @Test func aNewRowUnderThePointerReplacesTheOldOne() {
        var hover = ThreadListHover()
        let first = hover.pointer(over: 2)
        #expect(first)
        #expect(hover.row == 2)
        let second = hover.pointer(over: 5)
        #expect(second)
        #expect(hover.row == 5)
        let same = hover.pointer(over: 5)
        #expect(!same, "the same row again is not a change")
        let cleared = hover.pointer(over: nil)
        #expect(cleared)
        #expect(hover.row == nil)
    }

    @Test func leavingTheListClearsTheHover() {
        var hover = ThreadListHover()
        _ = hover.pointer(over: 3)
        let exited = hover.pointerExited()
        #expect(exited)
        #expect(hover.row == nil)
        let exitedAgain = hover.pointerExited()
        #expect(!exitedAgain)
    }

    @Test func aScrollClearsTheHoverAndTheRowUnderThePointerTakesItWhenItEnds() {
        var hover = ThreadListHover()
        _ = hover.pointer(over: 3)
        let began = hover.scrollBegan()
        #expect(began)
        #expect(hover.row == nil && hover.isScrolling)
        let passing = hover.pointer(over: 7)
        #expect(!passing, "rows passing under the pointer while scrolling stay plain")
        #expect(hover.row == nil)
        let ended = hover.scrollEnded(pointerOver: 9)
        #expect(ended)
        #expect(hover.row == 9 && !hover.isScrolling)
        _ = hover.scrollBegan()
        let endedOutside = hover.scrollEnded(pointerOver: nil)
        #expect(!endedOutside, "a pointer outside the list leaves no row hovered")
        #expect(hover.row == nil)
        let moved = hover.pointer(over: 4)
        #expect(moved)
    }
}

@MainActor
@Suite(.serialized)
struct ListHoverTests {
    func hoveredRows(_ table: NSTableView) -> [Int] {
        var rows: [Int] = []
        table.enumerateAvailableRowViews { view, row in
            if (view as? ThreadRowBackgroundView)?.isHovering == true { rows.append(row) }
        }
        return rows.sorted()
    }

    func center(_ table: NSTableView, _ row: Int) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    func cell(_ table: NSTableView, _ row: Int) -> ThreadRowView? {
        table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThreadRowView
    }

    @Test func onlyTheRowUnderThePointerShowsTheHover() async throws {
        let (controller, _, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        controller.pointerMoved(to: center(table, 2))
        #expect(controller.hoveredRow == 2)
        #expect(hoveredRows(table) == [2])
        #expect(cell(table, 2)?.isPointerInside == true)
        controller.pointerMoved(to: center(table, 5))
        #expect(hoveredRows(table) == [5])
        #expect(cell(table, 2)?.isPointerInside == false, "the old row gives back its checkbox")
        #expect(cell(table, 5)?.isPointerInside == true)
    }

    @Test func aRowThatMissedItsExitIsClearedByTheNextMove() async throws {
        let (controller, _, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        controller.pointerMoved(to: center(table, 1))
        let stale = try #require(table.rowView(atRow: 3, makeIfNecessary: false) as? ThreadRowBackgroundView)
        stale.setHovering(true)
        controller.pointerMoved(to: center(table, 4))
        #expect(hoveredRows(table) == [4])
    }

    @Test func aLiveScrollClearsTheHoverUntilItEnds() async throws {
        let (controller, _, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        let scrollView = try #require(table.enclosingScrollView)
        controller.pointerMoved(to: center(table, 3))
        #expect(hoveredRows(table) == [3])
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        #expect(hoveredRows(table).isEmpty)
        #expect(cell(table, 3)?.isPointerInside == false)
        controller.pointerMoved(to: center(table, 6))
        #expect(controller.hoveredRow == nil && hoveredRows(table).isEmpty)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        #expect(controller.hoveredRow == nil, "the pointer is not over this window")
        controller.pointerMoved(to: center(table, 6))
        #expect(hoveredRows(table) == [6])
    }

    @Test func leavingTheListClearsTheHover() async throws {
        let (controller, _, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        controller.pointerMoved(to: center(table, 2))
        controller.pointerExited()
        #expect(controller.hoveredRow == nil && hoveredRows(table).isEmpty)
        controller.pointerMoved(to: center(table, 2))
        controller.pointerMoved(to: NSPoint(x: table.visibleRect.midX, y: table.visibleRect.maxY + 40))
        #expect(controller.hoveredRow == nil && hoveredRows(table).isEmpty, "a point outside the visible rows hovers nothing")
    }

    @Test func theCursorRowKeepsItsBandUnderThePointer() async throws {
        let (controller, _, _, window) = try await ThreadListViewTests.list(threads: 12)
        defer { window.close() }
        let table = controller.tableView
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        controller.pointerMoved(to: center(table, 2))
        let rowView = try #require(table.rowView(atRow: 2, makeIfNecessary: false) as? ThreadRowBackgroundView)
        #expect(rowView.isSelected && rowView.isHovering)
        controller.pointerMoved(to: center(table, 4))
        #expect(rowView.isSelected && !rowView.isHovering)
        #expect(hoveredRows(table) == [4])
    }
}
