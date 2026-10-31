import MailFeatures
import MailModel
import SwiftUI

// An event's right-click menu: the answers and, beside them, Delete for the user's own event or Remove for an
// invitation, plus Remove for each other invited copy of a meeting on several calendars. Each item opens the event's
// card first, so the confirmation and the held change are the card's own.
struct CalendarEventContextMenu: ViewModifier {
    let model: CalendarWindowModel
    let event: CalendarEvent

    func body(content: Content) -> some View {
        content.contextMenu {
            if !event.id.isEmpty {
                Button("Show Details") { model.openEvent(event) }
                if model.canRespond(to: event) {
                    Divider()
                    ForEach(CalendarCardMode.rsvpOrder, id: \.self) { choice in
                        Toggle(choice.title, isOn: Binding(
                            get: { event.myResponse == choice },
                            set: { _ in
                                let model = model
                                let event = event
                                Task { await model.respond(choice, to: event) }
                            }))
                        .accessibilityIdentifier("calendar.event.menu.rsvp.\(choice.rawValue)")
                    }
                }
                let copies = model.copyRemovals(for: event)
                if let removal = model.removalTitle(for: event) {
                    Divider()
                    Button(removal, role: .destructive) { model.askToRemove(event) }
                        .accessibilityIdentifier("calendar.event.menu.remove")
                }
                if !copies.isEmpty {
                    if model.removalTitle(for: event) == nil { Divider() }
                    ForEach(Array(copies.enumerated()), id: \.element.id) { index, removal in
                        Button(removal.title, role: .destructive) { model.askToRemove(event, copy: removal.copyKey) }
                            .accessibilityIdentifier("calendar.event.menu.remove.copy.\(index)")
                    }
                }
            }
        }
    }
}

extension View {
    func calendarEventContextMenu(_ model: CalendarWindowModel, _ event: CalendarEvent) -> some View {
        modifier(CalendarEventContextMenu(model: model, event: event))
    }
}
