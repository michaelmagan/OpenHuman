extension ActionID {
    public static let calendarOpen = ActionID("calendar.open")
    public static let calendarBackToMail = ActionID("calendar.backToMail")
    public static let calendarCycleView = ActionID("calendar.cycleView")
    public static let calendarClose = ActionID("calendar.close")
    public static let calendarShowToday = ActionID("calendar.showToday")
    public static let calendarPreviousPeriod = ActionID("calendar.previousPeriod")
    public static let calendarNextPeriod = ActionID("calendar.nextPeriod")
    public static let calendarShowDay = ActionID("calendar.showDay")
    public static let calendarShowThreeDays = ActionID("calendar.showThreeDays")
    public static let calendarShowWeek = ActionID("calendar.showWeek")
    public static let calendarShowMonth = ActionID("calendar.showMonth")
    public static let calendarNewEvent = ActionID("calendar.newEvent")
    public static let calendarRefresh = ActionID("calendar.refresh")
    public static let calendarRemoveEvent = ActionID("calendar.removeEvent")
}

extension ActionCatalog {
    private static let inCalendar: Set<ActionScope> = [.calendar]
    private static let anywhereAndCalendar: Set<ActionScope> = [.global, .calendar]

    static let calendarWindow: [ActionDescriptor] = [
        ActionDescriptor(.calendarOpen, "Go to Calendar", category: .view,
                         bindings: [.key("2", onlyIn: [.list, .reader])], scopes: [.global, .list, .reader],
                         keywords: ["calendar", "week", "full calendar", "schedule", "events", "agenda", "meetings"],
                         module: .calendar),
        ActionDescriptor(.calendarBackToMail, "Back to Mail", category: .view, bindings: [.key("1")], scopes: inCalendar,
                         keywords: ["inbox", "mail", "back", "close calendar", "leave calendar"], appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarCycleView, "Calendar: Day, then Week, then Mail", category: .view,
                         bindings: [.key("0")], scopes: inCalendar, keywords: ["calendar", "cycle", "day", "week"],
                         appearsInPalette: false, appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarClose, "Close calendar", category: .view, bindings: [.named(.escape)], scopes: inCalendar,
                         keywords: ["close", "cancel", "back"], appearsInPalette: false, appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarShowToday, "Calendar: Go to today", category: .view, bindings: [.key("t")],
                         scopes: inCalendar, keywords: ["today", "now"], appearsInPalette: false, appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarPreviousPeriod, "Calendar: Previous", category: .view,
                         bindings: [.key("-"), .key("k")], scopes: inCalendar,
                         keywords: ["previous week", "previous day", "previous month", "back"], appearsInPalette: false,
                         appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarNextPeriod, "Calendar: Next", category: .view, bindings: [.key("="), .key("j")],
                         scopes: inCalendar, keywords: ["next week", "next day", "next month", "forward"],
                         appearsInPalette: false, appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarShowDay, "Calendar: Day view", category: .view,
                         bindings: [.key("d", onlyIn: [.calendar])], scopes: anywhereAndCalendar,
                         keywords: ["calendar", "day", "today's schedule"], appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarShowThreeDays, "Calendar: 3-day view", category: .view, scopes: anywhereAndCalendar,
                         keywords: ["calendar", "three days", "3 days"], appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarShowWeek, "Calendar: Week view", category: .view,
                         bindings: [.key("w", onlyIn: [.calendar]), .key("2", onlyIn: [.calendar])],
                         scopes: anywhereAndCalendar, keywords: ["calendar", "week", "this week"], appearsInMenu: false,
                         module: .calendar),
        ActionDescriptor(.calendarShowMonth, "Calendar: Month view", category: .view,
                         bindings: [.key("m", onlyIn: [.calendar])], scopes: anywhereAndCalendar,
                         keywords: ["calendar", "month"], appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarNewEvent, "New event", category: .view,
                         bindings: [.key("n", onlyIn: [.calendar]), .key("b", onlyIn: [.calendar])],
                         scopes: anywhereAndCalendar,
                         keywords: ["calendar", "create event", "meeting", "schedule", "invite", "add event"],
                         appearsInMenu: false, module: .calendar),
        ActionDescriptor(.calendarRefresh, "Calendar: Refresh", category: .view, scopes: inCalendar,
                         keywords: ["calendar", "reload", "update", "sync"], appearsInMenu: false, module: .calendar),
        // ⇧X matches the reader's invitation shortcut; ⌫ is the system Calendar's key. Neither is a menu equivalent.
        ActionDescriptor(.calendarRemoveEvent, "Calendar: Delete the open event…", shortTitle: "Delete",
                         category: .view, bindings: [.named(.delete), .key("X")], scopes: inCalendar,
                         effect: .external, isDestructive: true,
                         keywords: ["delete event", "remove event", "remove invitation", "remove from calendar", "trash"],
                         appearsInMenu: false, module: .calendar),
    ]
}
