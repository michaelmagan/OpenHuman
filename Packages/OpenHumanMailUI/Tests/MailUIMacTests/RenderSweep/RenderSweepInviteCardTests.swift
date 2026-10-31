import AppKit
import MailFakes
@testable import MailFeatures
import MailModel
import OpenHumanCore
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func readerInviteCard(_ theme: SweepTheme) async throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-13T10:00:00Z")!
        let corpus = FakeCorpus.small
        do {
            let busy = CalendarEvent(id: "busy", title: "Design review", start: start.addingTimeInterval(-900),
                                     end: start.addingTimeInterval(900))
            let calendar = FakeCalendar(events: [busy], info: CalendarProviderInfo(name: "Google Calendar",
                                                                                    account: corpus.accounts[0].email))
            let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate),
                                          calendar: calendar,
                                          calendarConnections: FakeCalendarConnections(providers: [corpus.accounts[0].email: calendar]))
            let w = try await SweepWindow.make(env, theme: theme)
            defer { w.close() }
            let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
            _ = try await w.open(thread)
            try await until { w.reader.messageViews[message.id]?.inviteHost?.showsCard == true }
            try await sweepShoot(w.window, screen: "reader-invite-card", theme: theme)

            let card = try #require(env.invites.card(for: message.id))
            calendar.add(CalendarEvent(id: "ev", title: card.title, start: card.invite.start, end: card.invite.end,
                                       attendees: [FakeCorpus.me], organizerIsMe: false, myResponse: .accepted))
            await env.calendarEvents.revalidate(CalendarEventStore.key(for: calendar), provider: calendar,
                                                visible: DateInterval(start: card.invite.start, end: card.invite.end),
                                                today: start, calendar: Calendar(identifier: .gregorian), now: start,
                                                force: true)
            await InviteFixtures.loadCard(env, thread, message)
            try await sweepShoot(w.window, screen: "reader-invite-card-answered-conflict", theme: theme)

            let part = try #require(InviteCenter.calendarPart(of: message.attachments))
            let text = try InviteCenter.readText(try await env.data.attachmentData(message.id, attachment: part))
            env.invites.readFile = { _ in text.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL") }
            await InviteFixtures.loadCard(env, thread, message)
            try await sweepShoot(w.window, screen: "reader-invite-card-cancelled", theme: theme)

            env.invites.toggleOriginal(message.id)
            try await until { w.reader.messageViews[message.id]?.inviteHost?.showsCard == false }
            try await sweepShoot(w.window, screen: "reader-invite-card-original", theme: theme)
        }
        do {
            // Removing the invitation without answering: the control, the question, the held change and the result.
            let calendar = FakeCalendar(info: CalendarProviderInfo(name: "Google Calendar", account: corpus.accounts[0].email),
                                        abilities: [.respond, .remove, .removeInvite])
            let env = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), calendar: calendar,
                                          calendarConnections: FakeCalendarConnections(providers: [corpus.accounts[0].email: calendar]))
            let w = try await SweepWindow.make(env, theme: theme)
            defer { w.close() }
            let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
            _ = try await w.open(thread)
            try await until { w.reader.messageViews[message.id]?.inviteHost?.showsCard == true }
            try await until { env.invites.offersRemoval(message.id) }
            try await sweepShoot(w.window, screen: "reader-invite-card-remove", theme: theme)
            let card = try #require(env.invites.card(for: message.id))
            calendar.add(CalendarEvent(id: "ev", title: card.title, start: card.invite.start, end: card.invite.end,
                                       attendees: [FakeCorpus.me], organizerIsMe: false, myResponse: .needsAction))
            calendar.setICalUID(card.invite.uid, for: "ev")
            env.invites.askToRemove(message.id)
            try await sweepShoot(w.window, screen: "reader-invite-card-remove-question", theme: theme)
            env.invites.holdWindow = .seconds(3600)
            await env.invites.confirmRemoval(.thisEvent, question: try #require(env.invites.removalQuestion).id)
            try await sweepShoot(w.window, screen: "reader-invite-card-removing", theme: theme)
            await env.undo?.undoLast()
            env.invites.holdWindow = .zero
            env.invites.askToRemove(message.id)
            await env.invites.confirmRemoval(.thisEvent, question: try #require(env.invites.removalQuestion).id)
            try await until { env.invites.removalStates[message.id] == .removed }
            try await sweepShoot(w.window, screen: "reader-invite-card-removed", theme: theme)
        }
        do {
            let env = SweepWindow.environment()
            let w = try await SweepWindow.make(env, theme: theme)
            defer { w.close() }
            let (thread, message) = try await InviteFixtures.invitation(env, corpus: corpus)
            _ = try await w.open(thread)
            try await until { w.reader.messageViews[message.id]?.inviteHost?.showsCard == true }
            await env.invites.respond(.accepted, to: message.id)
            try await sweepShoot(w.window, screen: "reader-invite-card-connect", theme: theme)
        }
    }
}
