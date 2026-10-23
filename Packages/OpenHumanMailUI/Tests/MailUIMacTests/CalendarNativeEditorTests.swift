import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

private struct NativeFormHost: View {
    let box: CalendarFormBox

    var body: some View {
        CalendarEventFormView(form: Binding(get: { box.form }, set: { box.form = $0 }), rights: .all,
                              timeZone: TimeZone(identifier: "UTC") ?? .gmt, idPrefix: "test.form", meetLink: nil)
            .padding(12)
            .frame(width: 416)
    }
}

@MainActor
@Suite(.serialized)
struct CalendarNativeEditorTests {
    static let frameName = "dev.openhuman.tests.calendar-native"
    let start = Date(timeIntervalSince1970: 1_791_000_000)
    let utc = TimeZone(identifier: "UTC") ?? .gmt

    func host(_ box: CalendarFormBox) -> (NSWindow, NSHostingView<AnyView>) {
        let theme = ResolvedTheme.light
        let root = NativeFormHost(box: box).environment(\.theme, theme).background(theme.bgWindow.color)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 440, height: 1000), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    static func toolbarSegments(of window: NSWindow) -> [NSSegmentedControl] {
        var roots: [NSView] = window.toolbar?.items.compactMap(\.view) ?? []
        if let frame = window.contentView?.superview { roots.append(frame) }
        var seen = Set<ObjectIdentifier>()
        var found: [NSSegmentedControl] = []
        func walk(_ view: NSView) {
            if view === window.contentView { return }
            if let control = view as? NSSegmentedControl, control.segmentCount == CalendarViewKind.allCases.count,
               !control.isHiddenOrHasHiddenAncestor, seen.insert(ObjectIdentifier(control)).inserted {
                found.append(control)
            }
            for child in view.subviews { walk(child) }
        }
        for root in roots { walk(root) }
        return found
    }

    static func editableField(in root: NSView, where matches: (NSTextField) -> Bool) -> NSTextField? {
        root.layoutSubtreeIfNeeded()
        return subviews(of: NSTextField.self, in: root).first { field in
            field.isEditable && field.window != nil && !field.isHiddenOrHasHiddenAncestor && matches(field)
        }
    }

    @Test func thePopoverOpensBesideTheEventAndKeepsAwayFromItWhenNeitherSideFits() {
        let bounds = CGSize(width: 900, height: 700)
        let size = CGSize(width: 400, height: 500)
        let margin: CGFloat = 12
        let reach = CalendarPopoverPlacement.gap + CalendarPopoverPlacement.arrowSize
        func place(_ target: CGRect?) -> CalendarPopoverPlacement {
            CalendarPopoverPlacement.place(target: target, size: size, in: bounds, margin: margin)
        }

        let early = CGRect(x: 100, y: 200, width: 80, height: 44)
        let right = place(early)
        #expect(right.arrow == .leading, "room on the right: the card opens there, its arrow on its leading edge")
        #expect(right.origin.x == early.maxX + reach)
        #expect(right.origin.y == early.minY - CalendarPopoverPlacement.topLead, "the card's top stays near the event's")
        #expect(right.arrowY == early.midY - right.origin.y, "the arrow points at the event's middle")

        let late = CGRect(x: 700, y: 200, width: 80, height: 44)
        let left = place(late)
        #expect(left.arrow == .trailing)
        #expect(left.origin.x + size.width + reach == late.minX)

        let leftOfCentre = place(CGRect(x: 400, y: 200, width: 80, height: 44))
        #expect(leftOfCentre.arrow == nil && leftOfCentre.origin.x == bounds.width - margin - size.width,
                "no room either side: the card keeps to the edge away from the event")
        let rightOfCentre = place(CGRect(x: 420, y: 200, width: 80, height: 44))
        #expect(rightOfCentre.arrow == nil && rightOfCentre.origin.x == margin)

        let wide = place(CGRect(x: 0, y: 200, width: 880, height: 44))
        #expect(wide.arrow == nil && wide.origin.x == bounds.width - margin - size.width,
                "a day-wide event keeps the card at the trailing edge, clear of its title")

        #expect(place(nil) == CalendarPopoverPlacement(origin: CGPoint(x: bounds.width - margin - size.width, y: margin)))
        #expect(place(CGRect(x: 100, y: -300, width: 80, height: 44)).arrow == nil, "an event scrolled out of view")

        let low = CGRect(x: 100, y: 650, width: 80, height: 30)
        let raised = place(low)
        #expect(raised.origin.y == bounds.height - margin - size.height, "the card stays inside the grid")
        #expect(raised.arrowY == 665 - raised.origin.y)
    }

    @Test func theLengthReadsUnderEnds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let timed = try #require(CalendarFormSummary.duration(start: start, end: start.addingTimeInterval(4_500),
                                                              isAllDay: false, calendar: calendar))
        #expect(timed.contains("1") && timed.contains("15"), "an hour and a quarter: \(timed)")
        #expect(CalendarFormSummary.duration(start: start, end: start, isAllDay: false, calendar: calendar) == nil)
        let day = calendar.startOfDay(for: start)
        let days = try #require(CalendarFormSummary.duration(start: day, end: day.addingTimeInterval(3 * 86_400),
                                                             isAllDay: true, calendar: calendar))
        #expect(days.contains("3"), "three days: \(days)")
    }

    @Test func aDateTypedInFullCommitsAndAHalfTypedOneWaits() {
        let locale = Locale(identifier: "en_US")
        let shown = CalendarDateField.text(start, zone: utc, locale: locale)
        #expect(CalendarDateFieldView.complete(shown, keepingTimeOf: start, zone: utc, locale: locale) == start)
        let next = CalendarDateField.stepped(start, byDays: 1, zone: utc)
        let typed = CalendarDateField.text(next, zone: utc, locale: locale)
        #expect(CalendarDateFieldView.complete(typed, keepingTimeOf: start, zone: utc, locale: locale) == next,
                "a whole date commits while typing, so saving from the field keeps it")
        #expect(CalendarDateFieldView.complete(String(shown.dropLast()), keepingTimeOf: start, zone: utc,
                                               locale: locale) == nil, "a year still being typed waits")
        #expect(CalendarDateFieldView.complete("10/3/2026", keepingTimeOf: start, zone: utc, locale: locale) == nil,
                "a day not yet in the field's own form waits for Return")
    }

    @Test func aGuestRowShowsTheAddressAndTheAnswer() {
        let dana = CalendarGuest(email: "dana@example.com", name: "Dana Ruiz", response: .accepted)
        #expect(CalendarEventFormView.secondLine(dana) == "dana@example.com · Accepted")
        #expect(CalendarEventFormView.secondLine(CalendarGuest(email: "sam@example.org")) == nil)
        #expect(CalendarEventFormView.secondLine(CalendarGuest(email: "sam@example.org", response: .needsAction)) == nil)
        #expect(CalendarEventFormView.secondLine(CalendarGuest(email: "sam@example.org", response: .declined)) == "Declined")
        #expect(CalendarEventFormView.spoken(CalendarGuest(email: "sam@example.org", isOptional: true, response: .tentative))
                == "sam@example.org, Maybe, optional")
        #expect(CalendarFormSummary.permissions(CalendarGuestPermissions()) == "Invite others, See guests")
        #expect(CalendarFormSummary.permissions(CalendarGuestPermissions(canModify: false, canInviteOthers: false,
                                                                         canSeeGuestList: false)) == "None")
    }

    @Test func theEditorIsAGroupedFormWithFieldStyleTimesAndNoSteppers() async throws {
        let box = CalendarFormBox(CalendarEventForm(title: "Planning", start: start, end: start.addingTimeInterval(4_500),
                                                    timeZone: "UTC"))
        let (window, hosting) = host(box)
        defer {
            window.orderOut(nil)
            window.close()
        }
        try await until {
            hosting.layoutSubtreeIfNeeded()
            return subviews(of: NSDatePicker.self, in: hosting).count == 2
        }
        let times = subviews(of: NSDatePicker.self, in: hosting)
        #expect(times.allSatisfy { $0.datePickerStyle == .textField }, "times are fields without a stepper")
        #expect(subviews(of: NSStepper.self, in: hosting).isEmpty, "no stepper beside the dates either")

        let title = try #require(Self.editableField(in: hosting) { $0.stringValue == "Planning" })
        #expect(!title.isBezeled, "the title is a plain field on its group, not a box with a heavy ring")
        let day = CalendarDateField.text(start, zone: utc)
        let days = subviews(of: NSTextField.self, in: hosting).filter { $0.isEditable && $0.stringValue == day }
        #expect(days.count == 2, "a start and an end date")
        let frames = days.map { $0.convert($0.bounds, to: hosting) }.sorted { $0.minY < $1.minY }
        if frames.count == 2 {
            #expect(abs(frames[0].minX - frames[1].minX) < 1, "Starts and Ends line up (\(frames))")
            #expect(frames[0].maxY <= frames[1].minY, "on rows of their own")
        }
        let location = try #require(Self.editableField(in: hosting) { $0.placeholderString == "Add location" })
        #expect(!location.isBezeled, "location is a plain field in its row")

        box.form.setAllDay(true)
        try await until {
            hosting.layoutSubtreeIfNeeded()
            return subviews(of: NSDatePicker.self, in: hosting).isEmpty
        }
    }

    @Test func theViewSwitchIsInTheToolbarAndTheCardOpensUnderThePeriod() async throws {
        let (environment, now) = CalendarWindowSweep.environment()
        let w = try await InlineReplyWindow.make(frameName: Self.frameName, environment: environment)
        defer { w.close() }
        let model = try #require(environment.calendarWindow)
        let sidebar = try #require(environment.calendarSidebar)
        model.now = { now }
        sidebar.now = { now }
        await model.open(.week, source: .keyboard)
        try await until { model.state == .loaded && model.events.count > 10 }
        let content = try #require(w.window.contentView)

        try await until { Self.toolbarSegments(of: w.window).count == 1 }
        let views = try #require(Self.toolbarSegments(of: w.window).first)
        #expect((0..<views.segmentCount).compactMap { views.label(forSegment: $0) } == CalendarViewKind.allCases.map(\.title))
        #expect(views.selectedSegment == CalendarViewKind.allCases.firstIndex(of: .week))
        #expect(!views.isDescendant(of: content), "the switch is a toolbar item, not a band over the calendar")
        #expect(subviews(of: NSSegmentedControl.self, in: content).allSatisfy {
            $0.segmentCount != CalendarViewKind.allCases.count
        }, "no second switch over the calendar")
        await model.setKind(.month)
        try await until { Self.toolbarSegments(of: w.window).first?.selectedSegment == 3 }
        await model.setKind(.week)

        let headerBottom = w.window.contentLayoutRect.maxY - CalendarWindowHeader.height
        let review = try #require(model.events.first { $0.id == "review" })
        model.openEvent(review)
        try await until { Self.editableField(in: content) { $0.stringValue == review.title } != nil }
        let title = try #require(Self.editableField(in: content) { $0.stringValue == review.title })
        let frame = title.convert(title.bounds, to: nil)
        #expect(frame.maxY <= headerBottom, "the card opens over the grid, under the period and its buttons")
        model.closeCard()

        let calendar = CalendarDateMentions.calendar(model.timeZone)
        let free = try #require(calendar.date(bySettingHour: 16, minute: 0, second: 0, of: model.period.days[1]))
        await model.newEvent(start: free, end: free.addingTimeInterval(3_600))
        try await until {
            model.showsPendingCard && Self.editableField(in: content) { $0.placeholderString == "Add title" } != nil
        }
        let draftTitle = try #require(Self.editableField(in: content) { $0.placeholderString == "Add title" })
        #expect(draftTitle.convert(draftTitle.bounds, to: nil).maxY <= headerBottom)
        await model.cancelPending()
        await model.close()
    }
}
