import Foundation
import MailModel
import Observation

public struct AIConsentRequest: Equatable, Sendable {
    public let connectionID: String
    public let title: String
    public let headline: String
    public let leaves: [String]
    public let stays: [String]
}

@MainActor @Observable
public final class AIConnectionsModel {
    public private(set) var connections: [AIConnection] = []
    public private(set) var consent: AIConsentRequest?
    public private(set) var errorMessage: String?
    public static let sendsNote = "On this Mac, nothing leaves your Mac. A connection below sends the text of the email it "
        + "works on to that provider, only after you press Use and accept."

    @ObservationIgnored private let port: any AIConnectionsPort
    @ObservationIgnored private let secrets: any SecretStoring
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(port: any AIConnectionsPort, secrets: any SecretStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.port = port
        self.secrets = secrets
        self.now = now
    }

    public func load() async { connections = await port.connections() }

    public static func secretName(_ id: String) -> String { "ai.connection.\(id)" }

    @discardableResult
    public func save(_ draft: AIConnectionDraft, apiKey: String? = nil) async -> AIConnection? {
        errorMessage = nil
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else {
            errorMessage = "Give the connection a name."
            return nil
        }
        var draft = draft
        draft.title = title
        do {
            let hadKey = draft.id.map { secrets.hasSecret(for: Self.secretName($0)) } ?? false
            var saved = try await port.save(draft, hasKey: hadKey || !(apiKey ?? "").isEmpty)
            if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                try secrets.setSecret(key, for: Self.secretName(saved.id))
                saved.hasKey = true
            }
            await load()
            return saved
        } catch {
            errorMessage = "That connection couldn't be saved."
            return nil
        }
    }

    public func remove(_ id: String) async {
        errorMessage = nil
        do {
            try await port.remove(id)
            try secrets.removeSecret(for: Self.secretName(id))
            await load()
        } catch {
            errorMessage = "That connection couldn't be removed."
        }
    }

    public func askToUse(_ id: String) {
        guard let connection = connections.first(where: { $0.id == id }), !connection.isInUse else { return }
        consent = Self.consentRequest(for: connection)
    }

    public func accept() async {
        guard let request = consent else { return }
        consent = nil
        errorMessage = nil
        do {
            try await port.setInUse(request.connectionID, inUse: true, consentGrantedAt: now())
            await load()
        } catch {
            errorMessage = "That connection couldn't be turned on."
        }
    }

    public func decline() { consent = nil }

    public func stopUsing(_ id: String) async {
        errorMessage = nil
        do {
            try await port.setInUse(id, inUse: false, consentGrantedAt: nil)
            await load()
        } catch {
            errorMessage = "That connection couldn't be turned off."
        }
    }

    static func consentRequest(for connection: AIConnection) -> AIConsentRequest {
        let leaves: [String]
        let who: String
        switch connection.kind {
        case .agentCLI:
            who = "the company behind the command-line tool"
            leaves = ["The text of the email the feature works on (subject, sender names and the body), sent to the tool you run.",
                      "The tool sends it on to its provider; Mail can't see or control what happens next."]
        case .privateCloud:
            who = "Apple's servers (Private Cloud Compute)"
            leaves = ["The text of the email the feature works on, sent to Apple's servers."]
        case .apiKey:
            who = "the provider you added"
            leaves = ["The text of the email the feature works on, sent to the provider's servers with your API key."]
        }
        return AIConsentRequest(
            connectionID: connection.id, title: "Use \(connection.title)?",
            headline: "Mail will send email text to \(who) whenever an AI feature uses it.",
            leaves: leaves,
            stays: ["Nothing is sent until you use an AI feature that picks this connection.",
                    "Your API key stays in the Keychain on this Mac.", "Turn it off here at any time."])
    }
}
