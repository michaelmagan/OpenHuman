import Foundation
import MailModel
import Observation
import OpenHumanAI

public enum AutocorrectChoice: String, Sendable, Hashable, CaseIterable {
    case system, on, off

    public var title: String {
        switch self {
        case .system: "Same as macOS"
        case .on: "On"
        case .off: "Off"
        }
    }
}

public enum FollowSystemChoice: String, Sendable, Hashable, CaseIterable {
    case system, off

    public var title: String { self == .system ? "Same as macOS" : "Off" }
}

public struct ComposeTextFlags: Sendable, Hashable {
    public var continuousSpelling: Bool
    public var autocorrect: Bool
    public var grammar: Bool
    public var textReplacement: Bool
    public var quoteSubstitution: Bool
    public var dashSubstitution: Bool
    public var linkDetection: Bool
    public var writingTools: Bool
    public var autoLists: Bool

    public init(continuousSpelling: Bool, autocorrect: Bool, grammar: Bool, textReplacement: Bool,
                quoteSubstitution: Bool, dashSubstitution: Bool, linkDetection: Bool = true, writingTools: Bool,
                autoLists: Bool = true) {
        self.continuousSpelling = continuousSpelling
        self.autocorrect = autocorrect
        self.grammar = grammar
        self.textReplacement = textReplacement
        self.quoteSubstitution = quoteSubstitution
        self.dashSubstitution = dashSubstitution
        self.linkDetection = linkDetection
        self.writingTools = writingTools
        self.autoLists = autoLists
    }

    public static let standard = ComposeTextFlags(continuousSpelling: true, autocorrect: true, grammar: false,
                                                  textReplacement: true, quoteSubstitution: true, dashSubstitution: true,
                                                  writingTools: false)
}

@MainActor @Observable
public final class ComposeTextSettings {
    public static let autocorrectKey = "compose.spelling.autocorrect"
    public static let continuousKey = "compose.spelling.continuous"
    public static let grammarKey = "compose.spelling.grammar"
    public static let textReplacementKey = "compose.spelling.textReplacement"
    public static let smartPunctuationKey = "compose.spelling.smartPunctuation"
    public static let writingToolsKey = "compose.allow_writing_tools"
    public static let autoListsKey = "compose.auto_lists"
    public static let pastedImageSizeKey = "compose.pasted_image_size"

    public static let replacementsNote = "Uses the text replacements you set up in macOS."
    public static let autoListsNote = "Typing 1. or - or * and a space at the start of a line starts a list. "
        + "Return adds the next item; Return on an empty item ends the list."
    public static let pastedImageSizeNote = "Pictures you paste or drop into a message start at this size, never larger "
        + "than the picture itself. Click a picture in a draft to change its size."
    public static let protectedNote = "Autocorrect never changes email addresses, links, snippet shortcuts or fill-in fields."

    public var autocorrect: AutocorrectChoice { didSet { defaults.set(autocorrect.rawValue, forKey: Self.autocorrectKey) } }
    public var continuousSpelling: Bool { didSet { defaults.set(continuousSpelling, forKey: Self.continuousKey) } }
    public var grammar: Bool { didSet { defaults.set(grammar, forKey: Self.grammarKey) } }
    public var textReplacement: FollowSystemChoice {
        didSet { defaults.set(textReplacement.rawValue, forKey: Self.textReplacementKey) }
    }
    public var smartPunctuation: FollowSystemChoice {
        didSet { defaults.set(smartPunctuation.rawValue, forKey: Self.smartPunctuationKey) }
    }
    public var allowWritingTools: Bool { didSet { defaults.set(allowWritingTools, forKey: Self.writingToolsKey) } }
    public var autoLists: Bool { didSet { defaults.set(autoLists, forKey: Self.autoListsKey) } }
    public var pastedImageSize: InlineImageSize {
        didSet { defaults.set(pastedImageSize.rawValue, forKey: Self.pastedImageSizeKey) }
    }
    public private(set) var system: SystemTextValues

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let onDeviceOnly: @MainActor (Account) -> Bool

    public init(defaults: UserDefaults, system port: any SystemTextSettings,
                onDeviceOnly: @escaping @MainActor (Account) -> Bool = { _ in false }) {
        self.defaults = defaults
        self.onDeviceOnly = onDeviceOnly
        autocorrect = defaults.string(forKey: Self.autocorrectKey).flatMap(AutocorrectChoice.init(rawValue:)) ?? .system
        continuousSpelling = defaults.object(forKey: Self.continuousKey) as? Bool ?? true
        grammar = defaults.object(forKey: Self.grammarKey) as? Bool ?? false
        textReplacement = defaults.string(forKey: Self.textReplacementKey).flatMap(FollowSystemChoice.init(rawValue:)) ?? .system
        smartPunctuation = defaults.string(forKey: Self.smartPunctuationKey).flatMap(FollowSystemChoice.init(rawValue:))
            ?? .system
        allowWritingTools = defaults.object(forKey: Self.writingToolsKey) as? Bool ?? false
        autoLists = defaults.object(forKey: Self.autoListsKey) as? Bool ?? true
        pastedImageSize = defaults.string(forKey: Self.pastedImageSizeKey).flatMap(InlineImageSize.init(rawValue:))
            ?? .pastedDefault
        system = port.current()
        port.observe { [weak self] values in self?.system = values }
    }

    public func flags(for account: Account) -> ComposeTextFlags {
        ComposeTextFlags(continuousSpelling: continuousSpelling,
                         autocorrect: autocorrect == .system ? system.autocorrect : autocorrect == .on,
                         grammar: grammar,
                         textReplacement: textReplacement == .system && system.textReplacement,
                         quoteSubstitution: smartPunctuation == .system && system.quoteSubstitution,
                         dashSubstitution: smartPunctuation == .system && system.dashSubstitution,
                         writingTools: writingToolsAllowed(for: account), autoLists: autoLists)
    }

    public func writingToolsAllowed(for account: Account) -> Bool {
        allowWritingTools && !onDeviceOnly(account)
    }

    public var autocorrectNote: String { system.autocorrect ? "macOS is set to on." : "macOS is set to off." }

    public static func writingToolsConsent(accounts: [Account],
                                           onDeviceOnly: @MainActor (Account) -> Bool) -> AIProviderConsentRequest {
        AIProviderConsentRequest(
            providerID: AIProviderID("apple.writingTools"), providerName: "Apple Writing Tools", location: .appleCloud,
            accounts: accounts.map { account in
                AIProviderConsentRequest.AccountChoice(id: account.id, title: StatusBanner.name(account),
                                                       onDeviceOnly: onDeviceOnly(account))
            },
            paragraphsOverride: [
                "What may be sent: the draft text you use Writing Tools on, when you use it. Writing Tools is part of Apple "
                    + "Intelligence; whether it sends draft text to Apple's servers is not confirmed.",
                "Mail never offers it for accounts set to On-device AI only.",
                "Turn it off any time in Settings › Platform features.",
            ])
    }
}
