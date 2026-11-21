import Foundation
import MailModel
import MailRender
import OpenHumanCore

public struct ReaderFormatting: Sendable {
    public var calendar: Calendar
    public var locale: Locale

    public init(calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) {
        self.calendar = calendar
        self.locale = locale
    }

    public struct HeaderLine: Sendable, Equatable {
        public let label: String
        public let addresses: [EmailAddress]
        public let text: String?

        public init(label: String, addresses: [EmailAddress] = [], text: String? = nil) {
            self.label = label
            self.addresses = addresses
            self.text = text
        }

        public var value: String { text ?? addresses.map(ReaderFormatting.display).joined(separator: ", ") }
    }

    public func headerLines(_ message: MessageSummary) -> [HeaderLine] {
        var lines: [HeaderLine] = []
        if let from = message.from { lines.append(HeaderLine(label: "From", addresses: [from])) }
        if !message.to.isEmpty { lines.append(HeaderLine(label: "To", addresses: message.to)) }
        if !message.cc.isEmpty { lines.append(HeaderLine(label: "Cc", addresses: message.cc)) }
        if !message.bcc.isEmpty { lines.append(HeaderLine(label: "Bcc", addresses: message.bcc)) }
        lines.append(HeaderLine(label: "Date", text: fullDate(message.date)))
        return lines
    }

    public func fullDate(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .complete, time: .shortened)
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    public static func display(_ address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.caseInsensitiveCompare(address.email) != .orderedSame else { return address.email }
        return "\(name) <\(address.email)>"
    }

    public static func copyText(_ address: EmailAddress, includingName: Bool) -> String {
        includingName ? display(address) : address.email
    }

    public static func titleMeta(_ messages: [MessageSummary], me: Set<String>, maximumNames: Int = 4) -> String {
        guard !messages.isEmpty else { return "" }
        let count = messages.count == 1 ? "1 message" : "\(messages.count) messages"
        var names: [String] = []
        var seen = Set<String>()
        var listedMe = false
        for message in messages {
            guard let from = message.from else { continue }
            let email = from.email.lowercased()
            guard seen.insert(email).inserted else { continue }
            if me.contains(email) {
                guard !listedMe else { continue }
                listedMe = true
                names.append("me")
            } else {
                names.append(firstName(from))
            }
        }
        guard !names.isEmpty else { return count }
        let shown = names.prefix(max(1, maximumNames)).joined(separator: ", ")
        let more = names.count > max(1, maximumNames) ? " +\(names.count - max(1, maximumNames))" : ""
        return "\(count) · \(shown)\(more)"
    }

    public static func firstName(_ address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.caseInsensitiveCompare(address.email) != .orderedSame else {
            return String(address.email.split(separator: "@").first ?? Substring(address.email))
        }
        if let comma = name.firstIndex(of: ",") {
            let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if let first = given.split(separator: " ").first { return String(first) }
        }
        return String(name.split(separator: " ").first ?? Substring(name))
    }

    public func attachmentsSummary(_ attachments: [AttachmentInfo]) -> String {
        let count = attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments"
        let total = attachments.reduce(0) { $0 + max(0, $1.size) }
        return "\(count) · \(Self.size(total))"
    }

    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .file)
    }

    public static func tiles(_ attachments: [AttachmentInfo], shownInline contentIDs: [String]) -> [AttachmentInfo] {
        attachments.filter { info in
            guard info.isInline, let id = info.contentID else { return true }
            return !contentIDs.contains { InlineParts.matches($0, id) }
        }
    }

    public static let maxFilenameBytes = 255 - 32

    static func filenameBytes(_ name: some StringProtocol) -> Int {
        String(name).decomposedStringWithCanonicalMapping.utf8.count
    }

    static func fittingFilename(_ name: String, maxBytes: Int = maxFilenameBytes) -> String {
        guard filenameBytes(name) > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.count <= 16 && filenameBytes(ext) < maxBytes / 4
        let suffix = keepsExtension ? "." + ext : ""
        let base = keepsExtension ? (name as NSString).deletingPathExtension : name
        let budget = maxBytes - filenameBytes(suffix)
        var kept = ""
        var used = 0
        for character in base {
            let size = filenameBytes(String(character))
            guard used + size <= budget else { break }
            used += size
            kept.append(character)
        }
        if kept.isEmpty {
            var scalars = String.UnicodeScalarView()
            for scalar in base.unicodeScalars {
                let size = filenameBytes(String(scalar))
                guard used + size <= budget else { break }
                used += size
                scalars.append(scalar)
            }
            kept = String(scalars)
        }
        return kept + suffix
    }

    static let maxCombiningRun = 30

    public static func safeFilename(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var combiningRun = 0
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F: continue
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C: continue
            case 0x200B...0x200D, 0xFEFF: continue
            case 0x2F, 0x5C, 0x3A:
                combiningRun = 0
                scalars.append("-")
            default:
                let parts = String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars
                let marks = parts.reversed().prefix { $0.properties.canonicalCombiningClass != .notReordered }.count
                if marks == parts.count {
                    guard combiningRun + marks <= maxCombiningRun else { continue }
                    combiningRun += marks
                } else {
                    combiningRun = marks
                }
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 200 {
            let ext = (name as NSString).pathExtension
            let keep = ext.isEmpty || ext.count > 16 ? 200 : 200 - ext.count - 1
            name = String(name.prefix(keep)) + (ext.isEmpty || ext.count > 16 ? "" : "." + ext)
        }
        name = fittingFilename(name)
        return name.isEmpty ? "attachment" : name
    }

    public static let missingConversationText = "This conversation is no longer here."
    public static let failedConversationText = "Couldn't open this conversation."

    /// The reader's heading: the subject, or what went wrong when there is no conversation to show.
    public static func conversationTitle(subject: String, state: ReaderModel.LoadState, hasMessages: Bool) -> String {
        switch state {
        case .missing: missingConversationText
        case .failed where !hasMessages: failedConversationText
        case .loading, .loaded, .failed: subject
        }
    }

    public static func newMessagesTitle(_ count: Int) -> String {
        count == 1 ? "Show new message" : "Show \(count) new messages"
    }

    public static func imagesHiddenText(blockedCount: Int) -> String {
        switch blockedCount {
        case ...0: "Remote images hidden for privacy."
        case 1: "1 remote image hidden for privacy."
        default: "\(blockedCount) remote images hidden for privacy."
        }
    }

    public static func imagesShownText(source: RemoteContentPolicy.Source, trackerCount: Int) -> String {
        var text = switch source {
        case .once: "Images shown"
        case .policy: "Images shown (Settings › Privacy)"
        case .allowlist(let entry): "Images always shown for \(RemoteContentPolicy.displayName(ofEntry: entry))"
        }
        if trackerCount > 0 { text += trackerCount == 1 ? " · 1 tracker blocked" : " · \(trackerCount) trackers blocked" }
        return text
    }

    public struct LinkWarning: Sendable, Equatable {
        public let title: String
        public let lines: [String]
    }

    public static func warning(for link: SuspiciousLink) -> LinkWarning {
        var lines: [String] = []
        if let shown = link.displayedDestination {
            lines.append("The text shows \(shown)")
        }
        var goes = "It opens \(link.actualDestination)"
        if let host = link.actualHost, host.lowercased() != link.actualDestination.lowercased() { goes += " (\(host))" }
        lines.append(goes)
        for reason in link.reasons {
            switch reason {
            case .domainMismatch, .addressMismatch: continue
            case .credentialsInURL: lines.append("The address hides its real destination behind a name.")
            case .ipAddressHost: lines.append("The address is a bare IP address.")
            case .punycodeHost: lines.append("The address uses look-alike characters.")
            }
        }
        return LinkWarning(title: "This link may not go where it says", lines: lines)
    }

    public static func hoverText(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        if text.count > 120 { text = String(text.prefix(80)) + "…" + String(text.suffix(39)) }
        return text
    }
}
