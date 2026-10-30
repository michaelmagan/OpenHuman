import MailActions
import MailFeatures
import MailModel
import SwiftUI

/// The calendar's items while it fills the window: the view switch in the centre, New event and Refresh at the
/// trailing edge beside Back to Mail. Previous, Today and Next sit over the calendar, beside the period it shows.
struct CalendarToolbarItems: ToolbarContent {
    enum ItemID {
        static let views = "calendar.views"
        static let newEvent = "calendar.newEvent"
        static let refresh = "calendar.refresh"
    }

    let router: AppRouter
    let calendar: CalendarWindowModel

    var body: some ToolbarContent {
        ToolbarItem(id: ItemID.views, placement: .principal) { viewPicker }
        ToolbarItem(id: ItemID.newEvent, placement: .primaryAction) { newEventButton }
        ToolbarItem(id: ItemID.refresh, placement: .primaryAction) { refreshButton }
        ToolbarSpacer(.fixed, placement: .primaryAction)
    }

    static func action(for kind: CalendarViewKind) -> ActionID {
        switch kind {
        case .day: .calendarShowDay
        case .threeDays: .calendarShowThreeDays
        case .week: .calendarShowWeek
        case .month: .calendarShowMonth
        }
    }

    @MainActor
    static func viewsHelp(_ router: AppRouter) -> String {
        CalendarViewKind.allCases.map { kind in
            ShellToolbar.help(router, action(for: kind), title: kind.title)
        }
        .joined(separator: " · ")
    }

    private var viewPicker: some View {
        Picker("View", selection: Binding(get: { calendar.kind }, set: { kind in
            _ = router.perform(Self.action(for: kind), source: .toolbar)
        })) {
            ForEach(CalendarViewKind.allCases, id: \.self) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(Self.viewsHelp(router))
        .accessibilityLabel("Calendar view")
        .accessibilityIdentifier("calendar.window.views")
    }

    private var newEventButton: some View {
        Button {
            _ = router.perform(.calendarNewEvent, source: .toolbar)
        } label: {
            NativeToolbarLabel("New Event", systemImage: "plus")
        }
        .help(ShellToolbar.help(router, .calendarNewEvent, title: "New event"))
        .accessibilityLabel("New event")
        .accessibilityIdentifier("calendar.window.newEvent")
    }

    private var refreshButton: some View {
        Button {
            _ = router.perform(.calendarRefresh, source: .toolbar)
        } label: {
            NativeToolbarLabel("Refresh", systemImage: "arrow.clockwise")
        }
        .help(calendar.updatedText.map { "Refresh · \($0)" } ?? "Refresh")
        .accessibilityLabel("Refresh calendar")
        .accessibilityIdentifier("calendar.window.refresh")
    }
}
