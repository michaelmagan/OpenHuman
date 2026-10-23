import AppKit
import MailActions
import MailFeatures
import Testing
@testable import MailUIMac

@MainActor
@Suite struct CalendarWindowKeyTests {
    @Test func theCalendarHasItsOwnKeysAndTheMailKeepsIts() {
        let table = KeyTable.build(ActionCatalog.all)
        #expect(table.bindings[.list]?[.char("2")] == .calendarOpen && table.bindings[.reader]?[.char("2")] == .calendarOpen)
        let calendar = table.bindings[.calendar] ?? [:]
        let expected: [(KeyChord, ActionID)] = [
            (.char("2"), .calendarShowWeek), (.char("w"), .calendarShowWeek), (.char("d"), .calendarShowDay),
            (.char("m"), .calendarShowMonth), (.char("t"), .calendarShowToday), (.char("-"), .calendarPreviousPeriod),
            (.char("k"), .calendarPreviousPeriod), (.char("="), .calendarNextPeriod), (.char("j"), .calendarNextPeriod),
            (.char("n"), .calendarNewEvent), (.char("b"), .calendarNewEvent), (.char("0"), .calendarCycleView),
            (.char("1"), .calendarBackToMail), (.named(.escape), .calendarClose),
        ]
        for (chord, action) in expected {
            #expect(calendar[chord] == action, "\(chord) in the calendar")
        }
        #expect(table.bindings[.list]?[.char("-")] == .neverImportantDomain)
        #expect(table.bindings[.list]?[.char("m")] == .toggleMute)
        #expect(table.bindings[.list]?[.char("j")] == .nextThread && table.bindings[.reader]?[.char("k")] == .previousThread)
        #expect(table.bindings[.reader]?[.char("n")] == .nextMessage)
        #expect(table.bindings[.list]?[.char("b")] == .calendarCreateEvent)
        #expect(table.bindings[.list]?[.char("0")] == .calendarToggleSidebar)
        #expect(table.bindings[.global]?[.char("2")] == nil && table.bindings[.global]?[.char("t")] == nil,
                "nothing of the calendar's is global")
    }
}

@MainActor
@Suite struct CalendarTimeGridDragTests {
    @Test func aSidewaysDragMovesByWholeDaysInsideTheGrid() {
        #expect(CalendarTimeGridView.dayIndex(3, shiftedBy: 140, columnWidth: 100, days: 7) == 4)
        #expect(CalendarTimeGridView.dayIndex(3, shiftedBy: 40, columnWidth: 100, days: 7) == 3, "less than half a column stays")
        #expect(CalendarTimeGridView.dayIndex(1, shiftedBy: -400, columnWidth: 100, days: 7) == 0, "never before the first day")
        #expect(CalendarTimeGridView.dayIndex(5, shiftedBy: 900, columnWidth: 100, days: 7) == 6, "never after the last day")
        #expect(CalendarTimeGridView.dayIndex(0, shiftedBy: 300, columnWidth: 0, days: 1) == 0)
    }
}
