import Foundation
import MailModel
import OpenHumanCore
import OpenHumanGmail

extension GoogleCalendarProvider {
    func invitedEvent(_ query: CalendarInviteQuery, wholeSeries: Bool) async throws -> CalendarEvent? {
        let (from, to) = query.window
        do {
            var picked = Self.pick(await uidCandidates(query.uid, from: from, to: to, singleEvents: true), query)
            if case .missing = picked {
                let moved = await uidCandidates(query.uid, from: nil, to: nil, singleEvents: false)
                switch Self.pickMoved(moved, query, wholeSeries: wholeSeries) {
                case .found(let candidate): return Self.event(candidate.event)
                case .ambiguous: throw CalendarError.refused(CalendarInviteQuery.ambiguousRefusal)
                case .missing: break
                }
                guard query.matchesTitle else { return nil }
                picked = Self.pick(try await client.inviteCandidates(iCalUID: nil, from: from, to: to), query)
            }
            switch picked {
            case .found(let candidate):
                let event = Self.event(candidate.event)
                return wholeSeries ? event.seriesReference : event
            case .missing:
                return nil
            case .ambiguous:
                throw CalendarError.refused(CalendarInviteQuery.ambiguousRefusal)
            }
        } catch let error as CalendarError {
            throw error
        } catch {
            throw Self.calendarError(error, doing: "find the invitation")
        }
    }

    // Why: a failed UID read falls back to the next read, but says so instead of passing for an empty answer
    private func uidCandidates(_ uid: String, from: Date?, to: Date?, singleEvents: Bool) async -> [GoogleInviteCandidate] {
        do {
            return try await client.inviteCandidates(iCalUID: uid, from: from, to: to, singleEvents: singleEvents)
        } catch {
            Log(.calendar).notice("invitation read by UID failed (\(Self.reasonCode(error)))")
            return []
        }
    }

    static func pick(_ candidates: [GoogleInviteCandidate], _ query: CalendarInviteQuery)
        -> CalendarInviteQuery.Pick<GoogleInviteCandidate> {
        query.pick(candidates, start: \.event.start, uid: \.iCalUID,
                   looksLike: { query.looksLike(title: $0.event.title, organizer: $0.organizerEmail) })
    }

    static func pickMoved(_ candidates: [GoogleInviteCandidate], _ query: CalendarInviteQuery, wholeSeries: Bool)
        -> CalendarInviteQuery.Pick<GoogleInviteCandidate> {
        query.pickMoved(candidates, wholeSeries: wholeSeries, uid: \.iCalUID, role: { candidate in
            if candidate.isSeries { return .series }
            if candidate.event.recurringEventID != nil { return .occurrence(originalStart: candidate.originalStart) }
            return .single
        })
    }
}
