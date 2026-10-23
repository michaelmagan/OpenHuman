import Foundation
import MailModel
import MailRender
import OpenHumanCore

public struct CalendarThreadText: Sendable, Hashable {
    public var subject: String
    public var texts: [String]
    public var participants: [EmailAddress]
    public var senders: Set<String>
    public var htmls: [String]

    public init(subject: String, texts: [String], participants: [EmailAddress], senders: Set<String> = [],
                htmls: [String] = []) {
        self.subject = subject
        self.texts = texts
        self.participants = participants
        self.senders = senders
        self.htmls = htmls
    }
}

struct CalendarThreadLoader: Sendable {
    let data: any MailDataSource
    var bodyTimeout: Duration = .seconds(3)
    static let maxMessages = 20
    static let maxBodyCharacters = 8_000

    func load(_ thread: ThreadKey) async -> CalendarThreadText? {
        guard let detail = await AIThreadLoader.first(data.threadDetail(thread)) ?? nil, !detail.messages.isEmpty else {
            return nil
        }
        let messages = Array(detail.messages.suffix(Self.maxMessages))
        let newest = messages.last?.id
        var texts = [detail.subject]
        var htmls: [String] = []
        for summary in messages {
            let wanted = summary.isUnread || summary.id == newest
            if wanted {
                let read = await read(summary)
                texts.append(read.text)
                if let html = read.html { htmls.append(html) }
            } else {
                texts.append(summary.snippet)
            }
        }
        var seen = Set<String>()
        var participants: [EmailAddress] = []
        for summary in detail.messages {
            for address in [summary.from].compactMap({ $0 }) + summary.to + summary.cc {
                let key = address.email.lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                participants.append(address)
            }
        }
        let senders = Set(detail.messages.compactMap { $0.from?.email.lowercased() })
        return CalendarThreadText(subject: detail.subject, texts: texts, participants: participants, senders: senders,
                                  htmls: htmls)
    }

    static let maxHTMLCharacters = 200_000

    private func read(_ summary: MessageSummary) async -> (text: String, html: String?) {
        let stream = data.body(summary.id)
        let timeout = bodyTimeout
        let content: MessageContent? = await withTaskGroup(of: MessageContent?.self) { group in
            group.addTask {
                do {
                    for try await state in stream {
                        switch state {
                        case .available(let content): return content
                        case .failed: return nil
                        case .fetching: continue
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let content else { return (summary.snippet, nil) }
        let html = content.html.map { String($0.prefix(Self.maxHTMLCharacters)) }
        let text = PlainTextExtractor.extract(content, format: AIThreadLoader.format(content.textFormat),
                                              maxCharacters: Self.maxBodyCharacters)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? summary.snippet : trimmed, html)
    }
}

public enum CalendarEventDraftBuilder {
    public static let defaultDuration: TimeInterval = 30 * 60
    public static let defaultHour = 10

    public static func draft(from thread: CalendarThreadText?, mentions: [CalendarDateMention], myAddresses: Set<String>,
                             timeZone: TimeZone, now: Date) -> CalendarEventDraft {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let facts = EmailEventExtractor.extract(texts: thread?.texts ?? [], htmls: thread?.htmls ?? [],
                                                timeZone: timeZone, now: now)
        let attendees = Self.attendees(thread: thread, myAddresses: myAddresses, announcement: facts?.strongSignal ?? false)
        if let facts, facts.start >= now || !hasFutureTimedMention(mentions, now: now) {
            let end = facts.end.map { $0 > facts.start ? $0 : facts.start.addingTimeInterval(defaultDuration) }
                ?? facts.start.addingTimeInterval(defaultDuration)
            return CalendarEventDraft(title: title(thread?.subject ?? ""), start: facts.start, end: end,
                                      timeZone: timeZone.identifier, attendees: attendees,
                                      sendUpdates: CalendarEventDraft.defaultSendUpdates(attendees: attendees),
                                      location: facts.location, provenance: facts.provenance)
        }
        let (start, duration) = time(mentions: mentions, calendar: calendar, now: now)
        return CalendarEventDraft(title: title(thread?.subject ?? ""), start: start, end: start.addingTimeInterval(duration),
                                  timeZone: timeZone.identifier, attendees: attendees,
                                  sendUpdates: CalendarEventDraft.defaultSendUpdates(attendees: attendees))
    }

    static func hasFutureTimedMention(_ mentions: [CalendarDateMention], now: Date) -> Bool {
        mentions.contains { $0.hasTime && $0.date >= now }
    }

    static func attendees(thread: CalendarThreadText?, myAddresses: Set<String>, announcement: Bool) -> [EmailAddress] {
        let senders = thread?.senders ?? []
        return (thread?.participants ?? []).filter { person in
            let key = person.email.lowercased()
            if myAddresses.contains(key) || isAutomated(key) { return false }
            return !(announcement && senders.contains(key))
        }
    }

    static func isAutomated(_ email: String) -> Bool {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let squashed = local.replacingOccurrences(of: "[-_.+]", with: "", options: .regularExpression)
        let markers = ["noreply", "donotreply", "notification", "notifications", "notify", "mailerdaemon", "postmaster",
                       "bounce", "bounces", "automated", "alerts", "newsletter", "invitations", "invitation", "invites"]
        return markers.contains { squashed == $0 || squashed.hasPrefix($0) }
    }

    public static func title(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = #"(?i)^(re|fwd?|aw|wg|sv|tr)\s*(\[\d+\])?\s*:\s*"#
        while let range = text.range(of: prefix, options: .regularExpression) {
            text.removeSubrange(range)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? String(localized: "Meeting") : text
    }

    public static func peopleTitle(me: Account?, others: [EmailAddress]) -> String? {
        guard !others.isEmpty else { return nil }
        func first(_ name: String?, _ email: String) -> String {
            let words = (name ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            if let word = words.first(where: { $0.contains(where: \.isLetter) }) { return word }
            let local = email.split(separator: "@").first.map(String.init) ?? email
            let part = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).first.map(String.init) ?? local
            return part.prefix(1).uppercased() + part.dropFirst()
        }
        let mine = me.map { first($0.displayName, $0.email) } ?? String(localized: "Me")
        var them = others.prefix(2).map { first($0.name, $0.email) }.joined(separator: ", ")
        if others.count > 2 { them += " +\(others.count - 2)" }
        return "\(mine) <> \(them)"
    }

    public static let summaryTitleLimit = 80

    public static func title(fromSummary summary: String) -> String? {
        let line = summary.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var sentence = line
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            sentence = String(line[..<end.lowerBound])
        }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return nil }
        guard sentence.count > summaryTitleLimit else { return sentence }
        let cut = String(sentence.prefix(summaryTitleLimit - 1))
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }

    static func time(mentions: [CalendarDateMention], calendar: Calendar, now: Date) -> (Date, TimeInterval) {
        let today = calendar.startOfDay(for: now)
        let timed = mentions.filter(\.hasTime)
        if let pick = timed.first(where: { $0.date >= now }) ?? timed.first {
            return (pick.date, pick.duration ?? defaultDuration)
        }
        let days = mentions.map { calendar.startOfDay(for: $0.date) }
        if let day = days.first(where: { $0 >= today }) ?? days.first,
           let start = calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) {
            return (start, defaultDuration)
        }
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return (hour, defaultDuration)
    }
}
