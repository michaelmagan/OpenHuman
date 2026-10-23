import Foundation

public enum PreSendIssue: String, Hashable, Sendable {
    case noSubject
    case noBody
    case missingAttachment
}

public struct PreSendWarning: Equatable, Sendable {
    public let kind: ComposeSession.SendConfirmation.Kind
    public let issues: [PreSendIssue]
    public let title: String
    public let message: String
    public let confirmTitle: String

    public static let keepWritingTitle = String(localized: "Keep Writing")

    public init?(issues: [PreSendIssue], kind: ComposeSession.SendConfirmation.Kind) {
        guard !issues.isEmpty else { return nil }
        let set = Set(issues)
        self.kind = kind
        self.issues = issues
        if set.contains(.missingAttachment) {
            title = String(localized: "Send without an attachment?")
            message = set.contains(.noSubject)
                ? String(localized: "The message mentions an attachment, but nothing is attached. It also has no subject.")
                : String(localized: "The message mentions an attachment, but nothing is attached.")
        } else if set == [.noSubject, .noBody] {
            title = String(localized: "Send without a subject or text?")
            message = String(localized: "This message has no subject and nothing in the body.")
        } else if set.contains(.noBody) {
            title = String(localized: "Send without any text?")
            message = String(localized: "Nothing is written in the body of this message.")
        } else {
            title = String(localized: "Send without a subject?")
            message = String(localized: "This message has no subject.")
        }
        if case .schedule = kind {
            confirmTitle = String(localized: "Schedule Anyway")
        } else {
            confirmTitle = String(localized: "Send Anyway")
        }
    }
}

public enum PreSendCheck {
    public static let attachmentWords: Set<String> = [
        "attach", "attached", "attaching", "attachment", "attachments", "enclosed", "enclosure", "enclosures",
    ]

    public static func issues(subject: String, body: String, quote: String, forwards: Bool,
                              hasAttachments: Bool) -> [PreSendIssue] {
        let (own, rest) = split(body)
        var found: [PreSendIssue] = []
        if isBlank(subject) { found.append(.noSubject) }
        let carriesOriginal = forwards && !(isBlank(quote) && isBlank(rest))
        if isBlank(own), !hasAttachments, !carriesOriginal { found.append(.noBody) }
        if !hasAttachments, mentionsAttachment(own) { found.append(.missingAttachment) }
        return found
    }

    public static func mentionsAttachment(_ text: String) -> Bool {
        split(text).own.lowercased().split { !$0.isLetter }.contains { attachmentWords.contains(String($0)) }
    }

    // What the sender wrote: the lines before a forwarded block or a signature, without "> " quoted lines
    static func split(_ body: String) -> (own: String, rest: String) {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let end = lines.firstIndex { line in
            line == "-- " || line.trimmingCharacters(in: .whitespaces).hasPrefix("---------- Forwarded message")
        } ?? lines.endIndex
        let own = lines[..<end].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        return (own.joined(separator: "\n"), lines[end...].joined(separator: "\n"))
    }

    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension ComposeSession {
    public var preSendIssues: [PreSendIssue] {
        PreSendCheck.issues(subject: subject, body: plainText, quote: quotedText.isEmpty ? quotedHTML : quotedText,
                            forwards: mode == .forward, hasAttachments: !outgoingAttachments.isEmpty)
    }

    public func cancelPreSendWarning() {
        preSendWarning = nil
        preSendChecked = false
    }
}
