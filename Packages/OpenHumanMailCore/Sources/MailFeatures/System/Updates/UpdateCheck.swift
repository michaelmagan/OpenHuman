import Foundation

public struct UpdateRelease: Sendable, Equatable {
    public var version: AppVersion
    public var name: String?
    public var noteLines: [String]
    public var page: URL
    public var isPreRelease: Bool

    public init(version: AppVersion, name: String? = nil, noteLines: [String] = [], page: URL, isPreRelease: Bool = false) {
        self.version = version
        self.name = name
        self.noteLines = noteLines
        self.page = page
        self.isPreRelease = isPreRelease
    }
}

public enum UpdateCheckProblem: Sendable, Equatable {
    case offline
    case rateLimited(retryAt: Date?)
    case unreadable
    case unavailable
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate(newest: UpdateRelease)
    case available(UpdateRelease)
    case notPublishedYet
    case couldNotCheck(UpdateCheckProblem)
}

public struct UpdateCheckMessage: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case neutral, good, news, attention }

    public var headline: String
    public var detail: String
    public var tone: Tone

    public init(headline: String, detail: String, tone: Tone) {
        self.headline = headline
        self.detail = detail
        self.tone = tone
    }
}

public enum UpdateCheck {
    public static let maxReplyBytes = 4 * 1024 * 1024
    public static let noteLineLimit = 4
    public static let noteLineLength = 160

    public static let earlyDevelopmentNote = "This is an early-development release."
    public static let privacyNote = "Mail asks GitHub for the newest release only when you click. It sends one request with "
        + "nothing about you or your mail, and never downloads or installs anything itself."
    public static let updaterPrivacyNote = "Mail reads OpenHuman's update feed on GitHub when you click, and once a day if "
        + "you allow automatic checks. It sends the app's version and nothing about you or your mail. An update is "
        + "installed only after its signature matches OpenHuman's signing key."
    public static let automaticNote = "Looks for a new release once a day and shows it when there is one."
    public static let checking = UpdateCheckMessage(headline: "Checking for updates…",
                                                    detail: "Asking GitHub for the newest release.", tone: .neutral)

    public static func evaluate(_ outcome: Result<UpdateFeedReply, UpdateFeedFailure>, current: BuildLabel, feed: UpdateFeed,
                                now: Date) -> UpdateCheckResult {
        let reply: UpdateFeedReply
        switch outcome {
        case .failure(.offline): return .couldNotCheck(.offline)
        case .failure: return .couldNotCheck(.unavailable)
        case .success(let answer): reply = answer
        }
        switch reply.status {
        case 200:
            guard let published = releases(in: reply.body, feed: feed) else { return .couldNotCheck(.unreadable) }
            guard let latest = newest(published) else { return .notPublishedYet }
            guard let running = AppVersion(current.version, build: current.build), !latest.version.isNewer(than: running) else {
                return .available(latest)
            }
            return .upToDate(newest: latest)
        case 404, 410, 451:
            return .notPublishedYet
        case 403, 429:
            guard reply.status == 429 || isRateLimited(reply) else { return .couldNotCheck(.unavailable) }
            return .couldNotCheck(.rateLimited(retryAt: retryAt(reply, now: now)))
        default:
            return .couldNotCheck(.unavailable)
        }
    }

    public static func releases(in data: Data, feed: UpdateFeed) -> [UpdateRelease]? {
        guard data.count <= maxReplyBytes else { return nil }
        let decoder = JSONDecoder()
        let entries: [Entry]
        if let list = try? decoder.decode([Entry].self, from: data) {
            entries = list
        } else if let one = try? decoder.decode(Entry.self, from: data) {
            entries = [one]
        } else {
            return nil
        }
        return entries.compactMap { entry in
            guard entry.draft != true, let tag = entry.tag, let version = AppVersion(tag) else { return nil }
            let name = entry.name.map(cleaned).flatMap { $0.isEmpty ? nil : $0 }
            return UpdateRelease(version: version, name: name, noteLines: noteLines(entry.body),
                                 page: feed.downloadPage(for: entry.page),
                                 isPreRelease: entry.prerelease == true || version.isPreRelease)
        }
    }

    public static func newest(_ releases: [UpdateRelease]) -> UpdateRelease? {
        var best: UpdateRelease?
        for release in releases where best.map({ release.version.isNewer(than: $0.version) }) ?? true { best = release }
        return best
    }

    public static func noteLines(_ body: String?) -> [String] {
        guard let body else { return [] }
        var lines: [String] = []
        for raw in body.split(whereSeparator: \.isNewline) {
            var line = cleaned(String(raw))
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + String(line.dropFirst(2)) }
            guard !line.isEmpty, !line.allSatisfy({ "-*_=".contains($0) }) else { continue }
            if line.count > noteLineLength { line = String(line.prefix(noteLineLength - 1)) + "…" }
            lines.append(line)
            if lines.count == noteLineLimit { break }
        }
        return lines
    }

    public static func message(for result: UpdateCheckResult, current: BuildLabel, now: Date) -> UpdateCheckMessage {
        let running = "\(current.version) (\(current.build))"
        switch result {
        case .upToDate(let newest):
            let same = AppVersion(current.version, build: current.build).map { AppVersion.order($0, newest.version) == .orderedSame }
            let detail = same == true ? "You have version \(running), the newest release."
                : "You have version \(running). The newest release is \(newest.version.displayName)."
            return UpdateCheckMessage(headline: "OpenHuman Mail is up to date", detail: detail, tone: .good)
        case .available(let release):
            return UpdateCheckMessage(headline: "Version \(release.version.displayName) is available",
                                      detail: "You have version \(running).", tone: .news)
        case .notPublishedYet:
            return UpdateCheckMessage(headline: "Couldn't check yet", detail: notPublishedDetail, tone: .neutral)
        case .couldNotCheck(let problem):
            return UpdateCheckMessage(headline: "Couldn't check for updates", detail: detail(problem, now: now), tone: .attention)
        }
    }

    public static func summary(for result: UpdateCheckResult, now: Date) -> String {
        switch result {
        case .upToDate(let newest): "Up to date. The newest release is \(newest.version.displayName)."
        case .available(let release): "Version \(release.version.displayName) is available."
        case .notPublishedYet: "Couldn't check yet. " + notPublishedDetail
        case .couldNotCheck(let problem): "Couldn't check. " + detail(problem, now: now)
        }
    }

    public static func earlyDevelopmentLine(for result: UpdateCheckResult?, current: BuildLabel) -> String? {
        if case .available(let release) = result, release.isPreRelease {
            return "Version \(release.version) is an early-development release."
        }
        return current.isEarlyDevelopment ? earlyDevelopmentNote : nil
    }

    public static func lastCheckedLine(_ date: Date?, now: Date) -> String {
        guard let date else { return "Not checked yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return "Last checked " + formatter.localizedString(for: min(date, now), relativeTo: now) + "."
    }

    static let notPublishedDetail = "There's no published release to compare with yet. Try again later."

    static func detail(_ problem: UpdateCheckProblem, now: Date) -> String {
        switch problem {
        case .offline:
            return "Mail couldn't reach GitHub. Check your internet connection, then try again."
        case .rateLimited(let retryAt):
            return "GitHub is answering too many checks from this network right now. " + wait(until: retryAt, now: now)
        case .unreadable:
            return "GitHub's answer couldn't be read. Try again later."
        case .unavailable:
            return "GitHub didn't answer the check. Try again later."
        }
    }

    static func wait(until retryAt: Date?, now: Date) -> String {
        guard let retryAt else { return "Try again later." }
        let minutes = Int((retryAt.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 1 { return "Try again in a minute." }
        return "Try again in about \(minutes) minutes."
    }

    static func isRateLimited(_ reply: UpdateFeedReply) -> Bool {
        reply.header("x-ratelimit-remaining")?.trimmingCharacters(in: .whitespaces) == "0" || reply.header("retry-after") != nil
    }

    static func retryAt(_ reply: UpdateFeedReply, now: Date) -> Date? {
        func seconds(_ name: String) -> Int? {
            reply.header(name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
        }
        if let after = seconds("retry-after") { return now.addingTimeInterval(TimeInterval(after)) }
        if let reset = seconds("x-ratelimit-reset"), reset > 0 { return Date(timeIntervalSince1970: TimeInterval(reset)) }
        return nil
    }

    // Why: release text is shown verbatim, so control and invisible formatting characters are dropped first
    static func cleaned(_ text: String) -> String {
        let kept = text.unicodeScalars.filter {
            let category = $0.properties.generalCategory
            return category != .control && category != .format
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }

    private struct Entry: Decodable {
        let tag: String?
        let name: String?
        let body: String?
        let page: String?
        let prerelease: Bool?
        let draft: Bool?

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", name, body, page = "html_url", prerelease, draft
        }
    }
}
