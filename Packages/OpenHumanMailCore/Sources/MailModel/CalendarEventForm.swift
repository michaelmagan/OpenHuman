import Foundation
import OpenHumanCore


public enum CalendarBusyStatus: String, Sendable, Hashable, CaseIterable {
    case busy, free
    public var title: String { self == .busy ? String(localized: "Busy") : String(localized: "Free") }
}

public enum CalendarVisibility: String, Sendable, Hashable, CaseIterable {
    case calendarDefault = "default", `public`, `private`
    public var title: String {
        switch self {
        case .calendarDefault: String(localized: "Default visibility")
        case .public: String(localized: "Public")
        case .private: String(localized: "Private")
        }
    }
}

public struct CalendarReminder: Sendable, Hashable, Identifiable {
    public enum Method: String, Sendable, Hashable, CaseIterable { case popup, email }
    public var method: Method
    public var minutesBefore: Int
    public var id: String { "\(method.rawValue)-\(minutesBefore)" }

    public init(method: Method = .popup, minutesBefore: Int) {
        self.method = method
        self.minutesBefore = minutesBefore
    }

    public var text: String {
        let (value, unit): (Int, String)
        switch minutesBefore {
        case 0: return String(localized: "At the start")
        case let m where m % 1_440 == 0: (value, unit) = (m / 1_440, m / 1_440 == 1 ? "day" : "days")
        case let m where m % 60 == 0: (value, unit) = (m / 60, m / 60 == 1 ? "hour" : "hours")
        default: (value, unit) = (minutesBefore, minutesBefore == 1 ? "minute" : "minutes")
        }
        return String(localized: "\(value) \(unit) before")
    }

    public static let presets: [Int] = [0, 5, 10, 30, 60, 1_440]
    public static let maxCount = 5
    public static let maxMinutesBefore = 40_320
}

public enum CalendarReminders: Sendable, Hashable {
    case calendarDefault
    case custom([CalendarReminder])
}

public struct CalendarGuestPermissions: Sendable, Hashable {
    public var canModify: Bool
    public var canInviteOthers: Bool
    public var canSeeGuestList: Bool

    public init(canModify: Bool = false, canInviteOthers: Bool = true, canSeeGuestList: Bool = true) {
        self.canModify = canModify
        self.canInviteOthers = canInviteOthers
        self.canSeeGuestList = canSeeGuestList
    }
}

public struct CalendarGuest: Sendable, Hashable, Identifiable {
    public var email: String
    public var name: String?
    public var isOptional: Bool
    public var response: CalendarResponse?
    public var isOrganizer: Bool?

    public var id: String { email.lowercased() }

    public init(email: String, name: String? = nil, isOptional: Bool = false, response: CalendarResponse? = nil,
                isOrganizer: Bool? = false) {
        self.email = email
        self.name = name
        self.isOptional = isOptional
        self.response = response
        self.isOrganizer = isOrganizer
    }

    public init(_ address: EmailAddress, isOptional: Bool = false) {
        self.init(email: address.email, name: address.name, isOptional: isOptional)
    }

    public var address: EmailAddress { EmailAddress(name: name, email: email) }
}

public struct CalendarEventExtras: Sendable, Hashable {
    public var guests: [CalendarGuest]
    public var permissions: CalendarGuestPermissions?
    public var recurrence: [String]
    public var reminders: CalendarReminders
    public var busy: CalendarBusyStatus
    public var visibility: CalendarVisibility
    public var colorID: String?

    public init(guests: [CalendarGuest] = [], permissions: CalendarGuestPermissions? = nil, recurrence: [String] = [],
                reminders: CalendarReminders = .calendarDefault, busy: CalendarBusyStatus = .busy,
                visibility: CalendarVisibility = .calendarDefault, colorID: String? = nil) {
        self.guests = guests
        self.permissions = permissions
        self.recurrence = recurrence
        self.reminders = reminders
        self.busy = busy
        self.visibility = visibility
        self.colorID = colorID
    }
}

public enum CalendarFormField: String, Sendable, Hashable, CaseIterable {
    case title, time, timeZone, guests, guestPermissions, location, meet, notes, calendar, repeats, reminders, busy,
         visibility, color

    public var isPersonal: Bool { self == .reminders || self == .busy || self == .color }

    public var label: String {
        switch self {
        case .title: String(localized: "title")
        case .time: String(localized: "time")
        case .timeZone: String(localized: "time zone")
        case .guests: String(localized: "guests")
        case .guestPermissions: String(localized: "guest permissions")
        case .location: String(localized: "location")
        case .meet: String(localized: "video link")
        case .notes: String(localized: "notes")
        case .calendar: String(localized: "calendar")
        case .repeats: String(localized: "repeat")
        case .reminders: String(localized: "reminders")
        case .busy: String(localized: "busy or free")
        case .visibility: String(localized: "visibility")
        case .color: String(localized: "colour")
        }
    }
}


public enum CalendarMeetChange: Sendable, Hashable { case add, remove }

public struct CalendarTimeChange: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var timeZone: String

    public init(start: Date, end: Date, isAllDay: Bool, timeZone: String) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZone = timeZone
    }
}

public struct CalendarEventPatch: Sendable, Hashable {
    public var title: String?
    public var location: String?
    public var notes: String?
    public var time: CalendarTimeChange?
    public var guests: [CalendarGuest]?
    public var guestsAdded: [String] = []
    public var guestsRemoved: [String] = []
    public var guestOptionalChanged = false
    public var permissions: CalendarGuestPermissions?
    public var meet: CalendarMeetChange?
    public var recurrence: [String]?
    public var reminders: CalendarReminders?
    public var busy: CalendarBusyStatus?
    public var visibility: CalendarVisibility?
    public var colorID: String?
    public var calendarKey: String?
    public var zoneChanged = false

    public init() {}

    public var fields: Set<CalendarFormField> {
        var set: Set<CalendarFormField> = []
        if title != nil { set.insert(.title) }
        if location != nil { set.insert(.location) }
        if notes != nil { set.insert(.notes) }
        if time != nil {
            set.insert(zoneChanged && !timeInstantsChanged ? .timeZone : .time)
            if zoneChanged { set.insert(.timeZone) }
        }
        if guests != nil { set.insert(.guests) }
        if permissions != nil { set.insert(.guestPermissions) }
        if meet != nil { set.insert(.meet) }
        if recurrence != nil { set.insert(.repeats) }
        if reminders != nil { set.insert(.reminders) }
        if busy != nil { set.insert(.busy) }
        if visibility != nil { set.insert(.visibility) }
        if colorID != nil { set.insert(.color) }
        if calendarKey != nil { set.insert(.calendar) }
        return set
    }

    public internal(set) var timeInstantsChanged = false

    public var isEmpty: Bool { fields.isEmpty }

    public var touchesGuests: Bool { !fields.subtracting([.reminders, .busy, .color]).isEmpty }
}


public struct CalendarEventForm: Sendable, Hashable {
    public var title: String
    public var isAllDay: Bool
    public var start: Date
    public var end: Date
    public var timeZone: String
    public var guests: [CalendarGuest]
    public var permissions: CalendarGuestPermissions
    public var location: String
    public var notes: String
    public var wantsMeet: Bool
    public var recurrence: [String]
    public var reminders: CalendarReminders
    public var busy: CalendarBusyStatus
    public var visibility: CalendarVisibility
    public var colorID: String?
    public var calendarKey: String

    public init(title: String = "", isAllDay: Bool = false, start: Date, end: Date, timeZone: String,
                guests: [CalendarGuest] = [], permissions: CalendarGuestPermissions = .init(), location: String = "",
                notes: String = "", wantsMeet: Bool = false, recurrence: [String] = [],
                reminders: CalendarReminders = .calendarDefault, busy: CalendarBusyStatus = .busy,
                visibility: CalendarVisibility = .calendarDefault, colorID: String? = nil, calendarKey: String = "") {
        self.title = title
        self.isAllDay = isAllDay
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.guests = guests
        self.permissions = permissions
        self.location = location
        self.notes = notes
        self.wantsMeet = wantsMeet
        self.recurrence = recurrence
        self.reminders = reminders
        self.busy = busy
        self.visibility = visibility
        self.colorID = colorID
        self.calendarKey = calendarKey
    }

    public init(event: CalendarEvent, calendarKey: String, defaultZone: String) {
        let extras = event.extras
        let people = extras.guests.isEmpty ? event.attendees.map { CalendarGuest($0) } : extras.guests
        self.init(title: event.title, isAllDay: event.isAllDay, start: event.start, end: event.end,
                  timeZone: event.timeZone ?? defaultZone, guests: people,
                  permissions: extras.permissions ?? .init(), location: event.location ?? "", notes: event.notes ?? "",
                  wantsMeet: event.meetLink != nil, recurrence: extras.recurrence, reminders: extras.reminders,
                  busy: extras.busy, visibility: extras.visibility, colorID: extras.colorID, calendarKey: calendarKey)
    }

    public init(draft: CalendarEventDraft, calendarKey: String = "") {
        let extras = draft.extras
        let people = extras.guests.isEmpty ? draft.attendees.map { CalendarGuest($0) } : extras.guests
        self.init(title: draft.title, isAllDay: draft.isAllDay, start: draft.start, end: draft.end,
                  timeZone: draft.timeZone, guests: people, permissions: extras.permissions ?? .init(),
                  location: draft.location, notes: draft.notes, wantsMeet: draft.addMeetLink,
                  recurrence: extras.recurrence, reminders: extras.reminders, busy: extras.busy,
                  visibility: extras.visibility, colorID: extras.colorID, calendarKey: calendarKey)
    }

    public func applying(to draft: CalendarEventDraft) -> CalendarEventDraft {
        var made = draft
        made.title = title
        made.start = start
        made.end = end
        made.isAllDay = isAllDay
        made.timeZone = timeZone
        made.setAttendees(guests.map(\.address))
        made.location = location
        made.notes = notes
        made.addMeetLink = wantsMeet
        made.extras = CalendarEventExtras(guests: guests, permissions: permissions, recurrence: recurrence,
                                          reminders: reminders, busy: busy, visibility: visibility, colorID: colorID)
        return made
    }

    public func duplicateDraft(sendUpdates: CalendarSendUpdates = .none) -> CalendarEventDraft {
        let fresh = guests.map { CalendarGuest(email: $0.email, name: $0.name, isOptional: $0.isOptional) }
        var draft = CalendarEventDraft(title: title, start: start, end: end, timeZone: timeZone,
                                       attendees: fresh.map(\.address), sendUpdates: sendUpdates, addMeetLink: wantsMeet,
                                       location: location, notes: notes)
        draft.isAllDay = isAllDay
        draft.extras = CalendarEventExtras(guests: fresh, permissions: permissions, recurrence: recurrence,
                                           reminders: reminders, busy: busy, visibility: visibility, colorID: colorID)
        return draft
    }


    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    public mutating func setStart(_ new: Date) {
        if isAllDay {
            let days = max(calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                   to: calendar.startOfDay(for: end)).day ?? 1, 1)
            start = calendar.startOfDay(for: new)
            end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(86_400)
        } else {
            let length = max(end.timeIntervalSince(start), 15 * 60)
            start = new
            end = new.addingTimeInterval(length)
        }
    }

    public mutating func setEnd(_ new: Date) {
        end = isAllDay ? max(new, start.addingTimeInterval(86_400)) : max(new, start.addingTimeInterval(60))
    }

    public var lastDay: Date {
        isAllDay ? (calendar.date(byAdding: .day, value: -1, to: end) ?? end) : calendar.startOfDay(for: end)
    }

    public mutating func setLastDay(_ day: Date) {
        let last = max(calendar.startOfDay(for: day), calendar.startOfDay(for: start))
        end = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
    }

    public mutating func setAllDay(_ on: Bool) {
        guard on != isAllDay else { return }
        let calendar = self.calendar
        if on {
            let first = calendar.startOfDay(for: start)
            var last = calendar.startOfDay(for: end)
            if end > last { last = calendar.date(byAdding: .day, value: 1, to: last) ?? last }
            start = first
            end = max(last, calendar.date(byAdding: .day, value: 1, to: first) ?? first.addingTimeInterval(86_400))
            isAllDay = true
        } else {
            let lastDay = self.lastDay
            let first = calendar.startOfDay(for: start)
            start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: first) ?? first
            end = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: max(lastDay, first)) ?? start.addingTimeInterval(3_600)
            isAllDay = false
        }
    }

    public var isMultiDay: Bool {
        let calendar = self.calendar
        let last = isAllDay ? lastDay : calendar.startOfDay(for: max(end.addingTimeInterval(-1), start))
        return last > calendar.startOfDay(for: start)
    }

    public mutating func setTimeZone(_ identifier: String) {
        guard TimeZone(identifier: identifier) != nil else { return }
        timeZone = identifier
    }


    public mutating func addGuest(_ address: EmailAddress) {
        guard !guests.contains(where: { $0.id == address.email.lowercased() }) else { return }
        guests.append(CalendarGuest(address))
    }

    public mutating func removeGuest(_ email: String) {
        guests.removeAll { $0.id == email.lowercased() }
    }

    public mutating func setOptional(_ email: String, _ value: Bool) {
        guard let index = guests.firstIndex(where: { $0.id == email.lowercased() }) else { return }
        guests[index].isOptional = value
    }


    public var problem: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(localized: "Add a title.") }
        if end <= start { return String(localized: "The event must end after it starts.") }
        if TimeZone(identifier: timeZone) == nil { return String(localized: "Unknown time zone.") }
        if guests.contains(where: { !$0.email.contains("@") }) { return String(localized: "A guest needs an email address.") }
        if case .custom(let list) = reminders {
            if list.contains(where: { $0.minutesBefore < 0 }) { return String(localized: "A reminder can't be after the start.") }
            if list.contains(where: { $0.minutesBefore > CalendarReminder.maxMinutesBefore }) {
                return String(localized: "A reminder can be at most four weeks before.")
            }
            if list.count > CalendarReminder.maxCount { return String(localized: "Up to five reminders.") }
        }
        return nil
    }


    public func patch(from event: CalendarEvent, defaultZone: String) -> CalendarEventPatch {
        diff(against: CalendarEventForm(event: event, calendarKey: calendarKey, defaultZone: defaultZone))
    }

    public func diff(against original: CalendarEventForm) -> CalendarEventPatch {
        var patch = CalendarEventPatch()
        if title != original.title { patch.title = title }
        if location != original.location { patch.location = location }
        if notes != original.notes { patch.notes = notes }
        let instants = start != original.start || end != original.end || isAllDay != original.isAllDay
        if instants || timeZone != original.timeZone {
            patch.time = CalendarTimeChange(start: start, end: end, isAllDay: isAllDay, timeZone: timeZone)
            patch.timeInstantsChanged = instants
            patch.zoneChanged = timeZone != original.timeZone
        }
        let before = Dictionary(original.guests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Dictionary(guests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = guests.filter { before[$0.id] == nil }.map(\.email)
        let removed = original.guests.filter { now[$0.id] == nil }.map(\.email)
        let optionalChanged = guests.contains { guest in before[guest.id].map { $0.isOptional != guest.isOptional } ?? false }
        if !added.isEmpty || !removed.isEmpty || optionalChanged {
            patch.guests = guests
            patch.guestsAdded = added
            patch.guestsRemoved = removed
            patch.guestOptionalChanged = optionalChanged
        }
        if permissions != original.permissions { patch.permissions = permissions }
        if wantsMeet != original.wantsMeet { patch.meet = wantsMeet ? .add : .remove }
        if recurrence != original.recurrence { patch.recurrence = recurrence }
        if reminders != original.reminders { patch.reminders = reminders }
        if busy != original.busy { patch.busy = busy }
        if visibility != original.visibility { patch.visibility = visibility }
        if colorID != original.colorID { patch.colorID = colorID ?? "" }
        if calendarKey != original.calendarKey, !calendarKey.isEmpty { patch.calendarKey = calendarKey }
        return patch
    }
}


public enum CalendarFieldAccess: Sendable, Hashable {
    case editable
    case addOnly
    case readOnly(String)

    public var isEditable: Bool { self == .editable }
    public var reason: String? { if case .readOnly(let why) = self { why } else { nil } }
}

public enum CalendarDeleteRight: Sendable, Hashable {
    case delete
    case declineInstead(String)
    case unavailable(String)
}

public struct CalendarFieldRights: Sendable, Hashable {
    public var access: [CalendarFormField: CalendarFieldAccess]
    public var delete: CalendarDeleteRight
    public var summary: String?

    public func access(_ field: CalendarFormField) -> CalendarFieldAccess { access[field] ?? .editable }

    public static let all = CalendarFieldRights(access: [:], delete: .delete, summary: nil)

    public static func locked(_ reason: String) -> CalendarFieldRights {
        CalendarFieldRights(access: Dictionary(uniqueKeysWithValues: CalendarFormField.allCases.map { ($0, .readOnly(reason)) }),
                            delete: .unavailable(reason), summary: reason)
    }

    public var hasAnyEditable: Bool { CalendarFormField.allCases.contains { access($0) == .editable || access($0) == .addOnly } }

    public func firstViolation(of patch: CalendarEventPatch) -> String? {
        for field in CalendarFormField.allCases where patch.fields.contains(field) {
            switch access(field) {
            case .editable: continue
            case .addOnly:
                if field == .guests, patch.guestsRemoved.isEmpty, !patch.guestOptionalChanged { continue }
                return String(localized: "You can add guests here, not remove them.")
            case .readOnly(let why): return why
            }
        }
        return nil
    }

    public static func forNewEvent(refusal: String?) -> CalendarFieldRights {
        if let refusal { return .locked(refusal) }
        return CalendarFieldRights(access: [.calendar: .readOnly(String(localized: "An event goes to the calendar of the account it came from."))],
                                   delete: .unavailable(String(localized: "Not saved yet.")), summary: nil)
    }

    public static func make(for event: CalendarEvent, abilities: CalendarAbilities, refusal: String?,
                            isNew: Bool = false) -> CalendarFieldRights {
        if let refusal { return .locked(refusal) }
        var access: [CalendarFormField: CalendarFieldAccess] = [:]
        let sees = abilities.contains(.editFull)
        let calendarMove = String(localized: "Mail can't move events between calendars on this connection.")
        if isNew {
            if !abilities.contains(.moveCalendar) { access[.calendar] = .readOnly(String(localized: "An event goes to the calendar of the account it came from.")) }
            return CalendarFieldRights(access: access, delete: .unavailable(String(localized: "Not saved yet.")), summary: nil)
        }
        let organizes = event.organizerIsMe == true || (event.organizerIsMe == nil && event.attendees.isEmpty)
        let permissions = event.extras.permissions ?? .init()
        let someoneElse = String(localized: "Someone else organizes this event: only they can change it.")
        let notAllowedHere = String(localized: "This calendar can't change this from Mail yet. Change it in your calendar.")
        let canEditContent = organizes || permissions.canModify
        func content(_ field: CalendarFormField, needs ability: Bool = true) {
            if !sees && field != .time { access[field] = .readOnly(notAllowedHere); return }
            if !canEditContent { access[field] = .readOnly(someoneElse); return }
            if !ability { access[field] = .readOnly(notAllowedHere) }
        }
        if sees {
            content(.title); content(.time); content(.timeZone); content(.location); content(.notes); content(.meet)
            if access[.meet] == nil, event.meetLink != nil, !abilities.contains(.removeMeet) {
                access[.meet] = .readOnly(String(localized: "Mail can't remove a Meet link from this calendar yet. Remove it in your calendar."))
            }
        } else {
            if !(event.isMovableByMe) { access[.time] = .readOnly(organizes ? notAllowedHere : someoneElse) }
            access[.timeZone] = .readOnly(notAllowedHere)
            access[.meet] = .readOnly(notAllowedHere)
            let detailsOK = organizes && abilities.contains(.editDetails)
            for field in [CalendarFormField.title, .location, .notes] where !detailsOK {
                access[field] = .readOnly(organizes ? notAllowedHere : someoneElse)
            }
        }
        if !sees {
            access[.guests] = .readOnly(organizes ? notAllowedHere : someoneElse)
        } else if !organizes && !permissions.canModify {
            access[.guests] = permissions.canInviteOthers ? .addOnly
                : .readOnly(String(localized: "The organizer didn't let guests invite others."))
        }
        access[.guestPermissions] = (sees && organizes) ? .editable
            : .readOnly(organizes ? notAllowedHere : String(localized: "Only the organizer changes what guests can do."))
        if !sees || !canEditContent {
            access[.repeats] = .readOnly(sees ? someoneElse : notAllowedHere)
        } else if event.isRecurring, event.extras.recurrence.isEmpty {
            access[.repeats] = .readOnly(String(localized: "Change how this series repeats from its first event."))
        }
        if !sees || !canEditContent { access[.visibility] = .readOnly(sees ? someoneElse : notAllowedHere) }
        if !sees {
            for field in [CalendarFormField.reminders, .busy, .color] { access[field] = .readOnly(notAllowedHere) }
        }
        if !abilities.contains(.moveCalendar) || !organizes { access[.calendar] = .readOnly(calendarMove) }
        let delete: CalendarDeleteRight
        if organizes, abilities.contains(.remove) {
            delete = .delete
        } else if !organizes, event.canRespond, abilities.contains(.respond) {
            delete = .declineInstead(String(localized: "Someone else organizes this event. Mail can't delete it: say No to leave it."))
        } else {
            delete = .unavailable(organizes ? notAllowedHere : someoneElse)
        }
        return CalendarFieldRights(access: access, delete: delete, summary: canEditContent ? nil : someoneElse)
    }
}


public enum CalendarSendUpdatesPolicy {
    public static func needsChoice(hasOtherGuests: Bool, patch: CalendarEventPatch) -> Bool {
        hasOtherGuests && patch.touchesGuests
    }

    public static func preselected(for patch: CalendarEventPatch) -> CalendarSendUpdates {
        (patch.guests != nil || patch.time != nil) ? .all : .none
    }

    public static let options: [CalendarSendUpdates] = [.none, .all]

    public static func title(_ value: CalendarSendUpdates) -> String {
        value == .all ? String(localized: "Send to guests") : String(localized: "Don't send")
    }

    public static func effective(chosen: CalendarSendUpdates?, hasOtherGuests: Bool,
                                 patch: CalendarEventPatch) -> CalendarSendUpdates {
        guard hasOtherGuests, patch.touchesGuests else { return .none }
        return chosen ?? preselected(for: patch)
    }
}


public enum CalendarRecurrenceScope: String, Sendable, Hashable, CaseIterable {
    case thisEvent, thisAndFollowing, allEvents

    public var title: String {
        switch self {
        case .thisEvent: String(localized: "This event")
        case .thisAndFollowing: String(localized: "This and following events")
        case .allEvents: String(localized: "All events")
        }
    }

    public static func options(for event: CalendarEvent, patch: CalendarEventPatch) -> [CalendarRecurrenceScope] {
        guard event.isRecurring else { return [] }
        if patch.recurrence != nil { return [.thisAndFollowing, .allEvents] }
        if patch.calendarKey != nil { return [.allEvents] }
        return CalendarRecurrenceScope.allCases
    }
}

public enum CalendarRepeat {
    public enum Preset: String, Sendable, Hashable, CaseIterable {
        case none, daily, weekdays, weekly, monthly, yearly, custom

        public var title: String {
            switch self {
            case .none: String(localized: "Does not repeat")
            case .daily: String(localized: "Every day")
            case .weekdays: String(localized: "Every weekday")
            case .weekly: String(localized: "Every week")
            case .monthly: String(localized: "Every month")
            case .yearly: String(localized: "Every year")
            case .custom: String(localized: "Custom (kept as it is)")
            }
        }
    }

    public static func rules(_ preset: Preset) -> [String] {
        switch preset {
        case .none, .custom: []
        case .daily: ["RRULE:FREQ=DAILY"]
        case .weekdays: ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]
        case .weekly: ["RRULE:FREQ=WEEKLY"]
        case .monthly: ["RRULE:FREQ=MONTHLY"]
        case .yearly: ["RRULE:FREQ=YEARLY"]
        }
    }

    public static func preset(of rules: [String]) -> Preset {
        if rules.isEmpty { return .none }
        for preset in Preset.allCases where preset != .none && preset != .custom && self.rules(preset) == rules { return preset }
        return .custom
    }

    public static func endingBefore(_ rules: [String], instantStart: Date, isAllDay: Bool, zone: TimeZone) -> [String] {
        let until: String
        if isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let before = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: instantStart)) ?? instantStart
            until = format(before, pattern: "yyyyMMdd", zone: zone)
        } else {
            until = format(instantStart.addingTimeInterval(-1), pattern: "yyyyMMdd'T'HHmmss'Z'", zone: TimeZone(identifier: "UTC")!)
        }
        return rules.map { line in
            guard line.uppercased().hasPrefix("RRULE:") else { return line }
            let parts = line.dropFirst(6).split(separator: ";").map(String.init).filter {
                let key = $0.split(separator: "=").first.map { $0.uppercased() }
                return key != "COUNT" && key != "UNTIL"
            }
            return "RRULE:" + (parts + ["UNTIL=\(until)"]).joined(separator: ";")
        }
    }

    // nil when the rule ends after a number of times: the count left after the split is not known here
    public static func continuing(_ rules: [String], from instantStart: Date, isAllDay: Bool, zone: TimeZone) -> [String]? {
        var out: [String] = []
        for line in rules {
            let upper = line.uppercased()
            if upper.hasPrefix("RRULE:") {
                let parts = line.dropFirst(6).split(separator: ";")
                if parts.contains(where: { $0.split(separator: "=").first?.uppercased() == "COUNT" }) { return nil }
                out.append(line)
            } else if upper.hasPrefix("EXDATE") || upper.hasPrefix("RDATE") {
                if let kept = dates(line, onOrAfter: instantStart, isAllDay: isAllDay, zone: zone,
                                    keepsUnreadable: upper.hasPrefix("EXDATE")) {
                    out.append(kept)
                }
            }
        }
        return out
    }

    static func dates(_ line: String, onOrAfter instantStart: Date, isAllDay: Bool, zone: TimeZone,
                      keepsUnreadable: Bool) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return keepsUnreadable ? line : nil }
        let head = line[..<colon]
        let params = head.split(separator: ";").dropFirst().map { $0.uppercased() }
        let tzid = head.split(separator: ";").dropFirst().first { $0.uppercased().hasPrefix("TZID=") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        let valueZone = tzid.flatMap(TimeZone.init(identifier:)) ?? zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let firstDay = calendar.startOfDay(for: instantStart)
        let values = line[line.index(after: colon)...].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let kept = values.filter { value in
            let isDate = params.contains("VALUE=DATE") || value.count == 8
            if isDate {
                guard let day = parse(value, pattern: "yyyyMMdd", zone: zone) else { return keepsUnreadable }
                return day >= firstDay
            }
            let date = value.uppercased().hasSuffix("Z")
                ? parse(value.uppercased(), pattern: "yyyyMMdd'T'HHmmss'Z'", zone: TimeZone(identifier: "UTC")!)
                : parse(value, pattern: "yyyyMMdd'T'HHmmss", zone: valueZone)
            guard let date else { return keepsUnreadable }
            return isAllDay ? calendar.startOfDay(for: date) >= firstDay : date >= instantStart
        }
        return kept.isEmpty ? nil : String(head) + ":" + kept.joined(separator: ",")
    }

    private static func parse(_ text: String, pattern: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        formatter.isLenient = false
        return formatter.date(from: text)
    }

    private static func format(_ date: Date, pattern: String, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}


public enum CalendarDateField {
    public static func pattern(locale: Locale) -> String {
        pad(DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? "M/d/y")
    }

    public static func pad(_ pattern: String) -> String {
        var result = ""
        var quoted = false
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'" { quoted.toggle(); result.append(character); index += 1; continue }
            guard !quoted, "MdyLu".contains(character) else { result.append(character); index += 1; continue }
            var end = index
            while end < characters.count, characters[end] == character { end += 1 }
            let run = end - index
            switch character {
            case "M", "L": result += String(repeating: character, count: max(run, 2))
            case "d": result += String(repeating: character, count: max(run, 2))
            case "y", "u": result += run <= 2 ? String(repeating: character, count: 4) : String(repeating: character, count: run)
            default: result += String(repeating: character, count: run)
            }
            index = end
        }
        return result
    }

    public static func text(_ date: Date, zone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar
        }()
        formatter.timeZone = zone
        formatter.dateFormat = pattern(locale: locale)
        return formatter.string(from: date)
    }

    public static func parse(_ text: String, keepingTimeOf reference: Date, zone: TimeZone,
                             locale: Locale = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.isLenient = false
        formatter.dateFormat = pattern(locale: locale)
        guard let day = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        let time = calendar.dateComponents([.hour, .minute, .second], from: reference)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = time.second
        return calendar.date(from: parts)
    }

    public static func stepped(_ date: Date, byDays days: Int, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(Double(days) * 86_400)
    }

    public static func isOnDay(_ date: Date, day: Date, zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(date, inSameDayAs: day)
    }
}


public struct CalendarPendingMove: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case moved, resized, movedAndResized, unchanged }

    public let eventID: String
    public let originalStart: Date
    public let originalEnd: Date
    public private(set) var proposedStart: Date
    public private(set) var proposedEnd: Date

    public init(event: CalendarEvent, proposedStart: Date, proposedEnd: Date) {
        eventID = event.id
        originalStart = event.start
        originalEnd = event.end
        self.proposedStart = proposedStart
        self.proposedEnd = max(proposedEnd, proposedStart.addingTimeInterval(60))
    }

    public var kind: Kind {
        let movedStart = proposedStart != originalStart
        let resized = proposedEnd.timeIntervalSince(proposedStart) != originalEnd.timeIntervalSince(originalStart)
        switch (movedStart, resized) {
        case (false, false): return .unchanged
        case (true, false): return .moved
        case (false, true): return .resized
        case (true, true): return .movedAndResized
        }
    }

    public mutating func adopt(start: Date, end: Date) {
        proposedStart = start
        proposedEnd = max(end, start.addingTimeInterval(60))
    }

    public var originalLength: TimeInterval { originalEnd.timeIntervalSince(originalStart) }
    public var proposedLength: TimeInterval { proposedEnd.timeIntervalSince(proposedStart) }

    public static func lengthText(_ length: TimeInterval) -> String {
        let minutes = Int((length / 60).rounded())
        let (hours, rest) = (minutes / 60, minutes % 60)
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest) min"
        }
    }

    public static func line(_ start: Date, _ end: Date, zone: TimeZone, locale: Locale = .current) -> String {
        let day = start.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day())
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
        return "\(day) \(start.formatted(clock)) - \(end.formatted(clock)) (\(lengthText(end.timeIntervalSince(start))))"
    }

    public func sendUpdatesDefault(hasOtherGuests: Bool) -> CalendarSendUpdates {
        hasOtherGuests && kind != .unchanged ? .all : .none
    }
}
