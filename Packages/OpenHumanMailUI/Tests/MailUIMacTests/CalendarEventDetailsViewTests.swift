import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

private let utc = TimeZone(identifier: "UTC")!

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    CalendarDateMentions.calendar(utc).date(from: DateComponents(year: 2026, month: 10, day: 14, hour: hour, minute: minute))!
}

@MainActor
@Suite(.serialized)
struct CalendarEventDetailsViewTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    static func events() -> [CalendarEvent] {
        let sam = EmailAddress(name: "Sam Rivera", email: "sam@example.test")
        let robin = EmailAddress(name: "Robin Example", email: "robin@example.test")
        var extras = CalendarEventExtras()
        extras.guests = [CalendarGuest(email: sam.email, name: sam.name, response: .accepted),
                         CalendarGuest(email: robin.email, name: robin.name, response: .needsAction)]
        return [
            CalendarEvent(id: "sync", title: "Design sync", start: at(10), end: at(10, 30), attendees: [sam],
                          meetLink: URL(string: "https://meet.example.test/dsn-sync-001"), organizerIsMe: true),
            CalendarEvent(id: "review", title: "Vendor review", start: at(14), end: at(15),
                          timeZone: "America/Los_Angeles", attendees: [sam, robin],
                          meetLink: URL(string: "https://meet.example.test/vnd-rvw-001"), organizerIsMe: false,
                          location: "Juniper room, 200 Example Avenue",
                          notes: "Agenda for the hour\nPre-read: https://docs.example.test/plan", myResponse: .needsAction,
                          extras: extras),
        ]
    }

    func environment() -> AppEnvironment {
        let calendar = FakeCalendar(events: Self.events(),
                                    info: CalendarProviderInfo(name: "Google Calendar", account: "robin@example.test"))
        return AppEnvironment.fake(corpus: .make(threadCount: 3, now: at(9)), options: .init(remoteAck: .immediate),
                                   featureFlags: FeatureFlags(), calendar: calendar)
    }

    func sidebar(_ env: AppEnvironment) async throws -> CalendarSidebarModel {
        let model = try #require(env.calendarSidebar)
        model.timeZone = utc
        model.now = { at(9) }
        await model.show(thread: nil)
        return model
    }

    func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func theArrowsChooseAnEventReturnOpensItAndEscapeClosesItBeforeGivingTheKeysBack() async throws {
        let env = environment()
        let model = try await sidebar(env)
        #expect(model.focusableEvents.map(\.id) == ["sync", "review"])
        let firstEvent = try #require(model.focusableEvents.first)
        let view = CalendarDayKeyView()
        view.model = model
        #expect(view.handle(key(125, "\u{F701}")))
        #expect(model.isFocused(firstEvent) && model.openedEvent == nil, "down chooses the first event")
        #expect(view.handle(key(36, "\r")))
        #expect(model.openedEvent?.id == "sync")
        #expect(view.handle(key(125, "\u{F701}")))
        #expect(model.openedEvent?.id == "review", "the open details follow the arrows")
        #expect(view.handle(key(126, "\u{F700}")))
        #expect(model.openedEvent?.id == "sync")
        #expect(view.handle(key(53, "\u{1b}")))
        #expect(model.openedEvent == nil && model.isFocused(firstEvent), "the first Escape closes the details")
        #expect(view.handle(key(76, "\u{3}")))
        #expect(model.openedEvent?.id == "sync", "keypad Enter opens it too")
        #expect(!view.handle(key(36, "\r", .command)), "a Command key is not the sidebar's")
        #expect(view.handle(key(53, "\u{1b}")) && model.openedEvent == nil)
        #expect(view.handle(key(53, "\u{1b}")), "the next Escape gives the keys back")
        #expect(!view.handle(key(38, "j")), "other keys are still not the sidebar's")
        withExtendedLifetime(env) {}
    }

    @Test func theDetailsCardSitsOverTheSidebarAtItsWidthInBothThemes() async throws {
        let env = environment()
        let model = try await sidebar(env)
        model.openEvent(try #require(model.focusableEvents.first { $0.id == "review" }))
        let details = try #require(model.openedDetails)
        #expect(details.joinLink?.absoluteString == "https://meet.example.test/vnd-rvw-001" && !details.canOpenEditor)
        for theme in [ResolvedTheme.light, .dark] {
            let hosting = NSHostingView(rootView: CalendarSidebarView(model: model, router: env.router)
                .environment(\.theme, theme).frame(height: 700))
            hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width == CGFloat(theme.component.sidebar.width))
            snapshot(hosting, name: "calendar-sidebar-event-details-\(theme.appearance)")
        }
        model.openEvent(try #require(model.focusableEvents.first { $0.id == "sync" }))
        let own = try #require(model.openedDetails)
        #expect(own.canOpenEditor && own.joinLink != nil, "my own event offers the editor")
        let width = CGFloat(ResolvedTheme.light.component.sidebar.width)
        let card = NSHostingView(rootView: CalendarEventDetailsView(details: own, onEdit: {})
            .environment(\.theme, ResolvedTheme.light).frame(width: width))
        card.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        card.layoutSubtreeIfNeeded()
        snapshot(card, name: "calendar-event-details-own-light")
        withExtendedLifetime(env) {}
    }

    @Test func theJoinCaptionDropsTheScheme() throws {
        let link = try #require(URL(string: "https://meet.example.test/vnd-rvw-001"))
        #expect(CalendarEventDetailsView.shortLink(link) == "meet.example.test/vnd-rvw-001")
        let plain = try #require(URL(string: "http://video.example.test/room"))
        #expect(CalendarEventDetailsView.shortLink(plain) == "video.example.test/room")
    }

    private func snapshot(_ view: NSView, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
