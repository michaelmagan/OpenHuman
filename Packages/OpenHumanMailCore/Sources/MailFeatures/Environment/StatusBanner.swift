import Foundation
import MailModel
import OpenHumanCore

public struct StatusBanner: Hashable, Sendable {
    public enum Kind: Int, Comparable, Hashable, Sendable {
        case auth = 1, offline, rateLimited, syncFailing

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Tone: Hashable, Sendable { case danger, warning, neutral }

    public let kind: Kind
    public let account: AccountID?
    public let message: String
    public let actionTitle: String?
    public let symbol: String
    public let detail: String?

    public var tone: Tone {
        switch kind {
        case .auth: .danger
        case .rateLimited, .syncFailing: .warning
        case .offline: .neutral
        }
    }

    public init(kind: Kind, account: AccountID?, message: String, actionTitle: String? = nil, symbol: String,
                detail: String? = nil) {
        self.kind = kind
        self.account = account
        self.message = message
        self.actionTitle = actionTitle
        self.symbol = symbol
        self.detail = detail
    }

    public static func current(active: Account?, connectivity: [AccountID: ConnectivityState], now: Date,
                               canReauthorize: Bool) -> StatusBanner? {
        var candidates: [StatusBanner] = []
        if let active {
            let state = connectivity[active.id]
            if active.health == .needsSignIn || state == .needsReauth {
                candidates.append(StatusBanner(
                    kind: .auth, account: active.id, message: "\(name(active)) needs you to sign in again.",
                    actionTitle: canReauthorize ? "Sign in" : nil, symbol: "exclamationmark.triangle"))
            }
            switch state {
            case .rateLimited(let until):
                candidates.append(StatusBanner(kind: .rateLimited, account: active.id,
                                               message: "Gmail asked us to slow down. " + retry(until, now: now),
                                               symbol: "exclamationmark.triangle"))
            case .syncFailing(let code, _, _):
                candidates.append(StatusBanner(kind: .syncFailing, account: active.id,
                                               message: StatusModel.syncFailureText(code, account: name(active)),
                                               symbol: "exclamationmark.triangle", detail: code))
            default:
                break
            }
        }
        if connectivity.values.contains(where: { if case .offline = $0 { true } else { false } }) {
            candidates.append(StatusBanner(kind: .offline, account: nil,
                                           message: "Offline. Changes are saved and sync when you're back.",
                                           symbol: "wifi.slash"))
        }
        return candidates.min { $0.kind < $1.kind }
    }

    static func name(_ account: Account) -> String {
        if let alias = account.alias, !alias.isEmpty { return "\(alias) account" }
        return account.email
    }

    static func retry(_ until: Date?, now: Date) -> String {
        guard let until else { return "Retrying." }
        let seconds = Int(until.timeIntervalSince(now).rounded(.up))
        if seconds <= 0 { return "Retrying." }
        if seconds < 60 { return "Retrying in \(seconds) s." }
        return "Retrying in \(Int((Double(seconds) / 60).rounded(.up))) min."
    }
}
