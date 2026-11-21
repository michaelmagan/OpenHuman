import Foundation
import MailModel
import Observation
import OpenHumanCore

public enum SnippetBody {
    public static func html(fromPlain text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return escaped.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }

    public static func plain(fromHTML html: String) -> String {
        var text = html
        for breaker in ["<br>", "<br/>", "<br />", "</p>", "</div>"] {
            text = text.replacingOccurrences(of: breaker, with: "\n", options: .caseInsensitive)
        }
        var out = ""
        var inTag = false
        for character in text {
            if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag { out.append(character) }
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .newlines)
    }

    public static func isFormatted(_ html: String) -> Bool {
        let lower = html.lowercased()
        for tag in ["<b>", "<strong", "<i>", "<em", "<u>", "<a ", "<ul", "<ol", "<li", "<span", "<font", "<img", "<table"]
        where lower.contains(tag) { return true }
        return false
    }
}

@MainActor @Observable
public final class SnippetSettingsModel {
    public struct Draft: Hashable {
        public var id: String
        public var account: AccountID?
        public var name: String
        public var shortcut: String
        public var subject: String
        public var body: String
        public var defaults: [String: String]
        public var hadFormatting: Bool
        public var useCount: Int
        public var to = ""
        public var cc = ""
        public var bcc = ""
        public var attachments: [SnippetAttachmentInfo] = []

        public var isNew: Bool { id.isEmpty }
    }

    public static let builtInVariables = ["first_name", "last_name", "full_name", "my_name"]

    public private(set) var snippets: [SnippetInfo] = []
    public var searchText = ""
    public var draft: Draft?
    public private(set) var errorMessage: String?
    public private(set) var confirmingDelete: SnippetInfo.ID?
    public let availability: SettingsAvailability

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let commands: (any MailCommanding)?
    @ObservationIgnored private var task: Task<Void, Never>?

    public private(set) var isAddingFiles = false

    public init(data: any MailDataSource, commands: (any MailCommanding)?, availability: SettingsAvailability) {
        self.data = data
        self.commands = commands
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, commands: environment.commands,
                  availability: SettingsAvailability(environment: environment))
    }

    isolated deinit {
        task?.cancel()
    }

    public var canEdit: Bool { availability.hasCommands }

    public func start() {
        guard task == nil else { return }
        let data = self.data
        task = Task { [weak self] in
            do {
                for try await list in data.snippets(nil) {
                    guard !Task.isCancelled else { return }
                    self?.snippets = list
                }
            } catch {}
        }
    }

    public var visible: [SnippetInfo] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = snippets.sorted { ($0.useCount, $1.name) > ($1.useCount, $0.name) }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.lowercased().contains(needle) || ($0.shortcut ?? "").lowercased().contains(needle)
                || SnippetBody.plain(fromHTML: $0.bodyHTML).lowercased().contains(needle)
        }
    }

    public func beginNew() {
        guard canEdit else { return }
        draft = Draft(id: "", account: nil, name: "", shortcut: "", subject: "", body: "", defaults: [:],
                      hadFormatting: false, useCount: 0)
        errorMessage = nil
    }

    public func beginEdit(_ snippet: SnippetInfo) {
        draft = Draft(id: snippet.id, account: snippet.account, name: snippet.name, shortcut: snippet.shortcut ?? "",
                      subject: snippet.subject ?? "", body: SnippetBody.plain(fromHTML: snippet.bodyHTML),
                      defaults: Dictionary(snippet.variables.compactMap { v in v.defaultValue.map { (v.name, $0) } },
                                           uniquingKeysWith: { first, _ in first }),
                      hadFormatting: SnippetBody.isFormatted(snippet.bodyHTML), useCount: snippet.useCount,
                      to: Self.recipientText(snippet.to), cc: Self.recipientText(snippet.cc),
                      bcc: Self.recipientText(snippet.bcc), attachments: snippet.attachments)
        errorMessage = nil
    }

    public static func recipientText(_ list: [EmailAddress]) -> String {
        list.map { (address: EmailAddress) -> String in
            guard let name = address.name, !name.isEmpty else { return address.email }
            let quoted = name.contains(",") || name.contains(";") ? "\"\(name)\"" : name
            return "\(quoted) <\(address.email)>"
        }.joined(separator: ", ")
    }

    public static func recipients(_ text: String) -> [EmailAddress] {
        var seen = Set<String>()
        return RecipientParser.parse(text).filter { seen.insert($0.email.lowercased()).inserted }
    }

    public var recipientProblem: String? {
        guard let draft else { return nil }
        for (name, text) in [("To", draft.to), ("Cc", draft.cc), ("Bcc", draft.bcc)] {
            if let bad = RecipientParser.parse(text).first(where: { !RecipientParser.isValid($0.email) }) {
                return "Check the \(name) line: \(bad.email) isn't a valid address."
            }
        }
        return nil
    }

    public var attachmentBytes: Int { draft?.attachments.reduce(0) { $0 + $1.size } ?? 0 }

    public func addFiles(_ urls: [URL]) async {
        guard canEdit, draft != nil, let commands else { return }
        errorMessage = nil
        isAddingFiles = true
        defer { isAddingFiles = false }
        for url in urls {
            guard let current = draft else { return }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let size = values?.fileSize ?? 0
            if values?.isDirectory == true {
                errorMessage = "\(name) is a folder. Add files only."
                continue
            }
            guard current.attachments.count < SnippetAttachmentRules.maxFiles else {
                errorMessage = "A snippet can carry at most \(SnippetAttachmentRules.maxFiles) files."
                break
            }
            guard size <= SnippetAttachmentRules.maxFileBytes else {
                errorMessage = "\(name) is over the 10 MB limit for a snippet file."
                continue
            }
            guard attachmentBytes + size <= SnippetAttachmentRules.maxTotalBytes else {
                errorMessage = "\(name) would take this snippet's files over 25 MB together."
                continue
            }
            do {
                let stored = try await commands.storeSnippetAttachment(url, mimeType: DirectoryAttachmentStaging.mimeType(for: url))
                guard draft?.attachments.contains(where: { $0.contentHash == stored.contentHash && $0.filename == stored.filename }) == false
                else { continue }
                draft?.attachments.append(stored)
            } catch {
                errorMessage = (error as? MailPortError)?.description ?? "\(name) couldn't be added."
            }
        }
    }

    public func removeAttachment(_ attachment: SnippetAttachmentInfo) {
        draft?.attachments.removeAll { $0 == attachment }
    }

    public func cancelEdit() { draft = nil }

    public var variables: [(name: String, isBuiltIn: Bool)] {
        guard let draft else { return [] }
        var seen = Set<String>()
        return (SnippetExpander.variableNames(in: draft.body) + SnippetExpander.variableNames(in: draft.subject))
            .filter { seen.insert($0).inserted }
            .map { ($0, Self.isBuiltIn($0)) }
    }

    static func isBuiltIn(_ name: String) -> Bool { builtInVariables.contains(name) || name.hasPrefix("date") }

    public func setDefault(_ value: String, for name: String) { draft?.defaults[name] = value }

    public static func normalizedShortcut(_ text: String) -> String? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        if cleaned.hasPrefix(";;") { cleaned.removeFirst(2) }
        let allowed = cleaned.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
        let result = String(String.UnicodeScalarView(allowed))
        return result.isEmpty ? nil : result
    }

    public var shortcutConflict: String? {
        guard let draft, let shortcut = Self.normalizedShortcut(draft.shortcut) else { return nil }
        let clash = snippets.contains { $0.id != draft.id && $0.shortcut?.lowercased() == shortcut
            && ($0.account == draft.account || $0.account == nil || draft.account == nil) }
        return clash ? "Another snippet already uses ;;\(shortcut)." : nil
    }

    public var canSave: Bool {
        guard canEdit, let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && shortcutConflict == nil
            && recipientProblem == nil && !isAddingFiles && attachmentBytes <= SnippetAttachmentRules.maxTotalBytes
    }

    public func save() async {
        guard canSave, let draft, let commands else { return }
        errorMessage = nil
        let subject = draft.subject.trimmingCharacters(in: .whitespaces)
        let variables = self.variables.filter { !$0.isBuiltIn }.map {
            SnippetVariableInfo(name: $0.name, defaultValue: draft.defaults[$0.name].flatMap { $0.isEmpty ? nil : $0 })
        }
        let snippet = SnippetInfo(id: draft.id, account: draft.account, name: draft.name.trimmingCharacters(in: .whitespaces),
                                  shortcut: Self.normalizedShortcut(draft.shortcut), subject: subject.isEmpty ? nil : subject,
                                  bodyHTML: SnippetBody.html(fromPlain: draft.body), variables: variables,
                                  useCount: draft.useCount, to: Self.recipients(draft.to), cc: Self.recipients(draft.cc),
                                  bcc: Self.recipients(draft.bcc), attachments: draft.attachments)
        do {
            _ = try await commands.upsertSnippet(snippet)
            self.draft = nil
        } catch {
            errorMessage = (error as? MailPortError)?.description ?? "That snippet couldn't be saved."
        }
    }

    public func askToDelete(_ id: SnippetInfo.ID) { confirmingDelete = id }
    public func cancelDelete() { confirmingDelete = nil }

    public func confirmDelete() async {
        guard canEdit, let id = confirmingDelete, let commands else { return }
        confirmingDelete = nil
        do {
            try await commands.deleteSnippet(id)
            if draft?.id == id { draft = nil }
        } catch {
            errorMessage = (error as? MailPortError)?.description ?? "That snippet couldn't be deleted."
        }
    }

    public static let emptyText = "No snippets yet. Snippets are reusable text you insert with ;; or ⌘;."
}
