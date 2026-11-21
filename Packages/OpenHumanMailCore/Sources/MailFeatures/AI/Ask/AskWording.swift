import Foundation

public enum AskWording {
    public static let title = String(localized: "Ask AI")
    public static let placeholder = String(localized: "Ask about your mail")
    public static let examples = [
        String(localized: "When is my next flight?"), String(localized: "What's the latest on the contract?"),
        String(localized: "Invoices from last month"),
    ]

    public static let searching = String(localized: "Searching your mail…")
    public static let planning = String(localized: "Reading your question…")
    public static let working = String(localized: "Working…")

    static func conversations(_ count: Int) -> String {
        count == 1 ? String(localized: "1 conversation") : String(localized: "\(count) conversations")
    }

    static func searched(_ place: String, for words: String, conversations count: Int) -> String {
        String(localized: "Searched \(place) for “\(words)” · \(conversations(count))")
    }

    static func searched(_ place: String, chips: [String], conversations count: Int) -> String {
        String(localized: "Searched \(place): \(chips.joined(separator: " · ")) · \(conversations(count))")
    }

    static func searchedGmail(for words: String, conversations count: Int) -> String {
        String(localized: "Searched Gmail for “\(words)” · \(conversations(count))")
    }

    static func read(subject: String, messages count: Int) -> String {
        count == 1 ? String(localized: "Read “\(subject)” (1 message)")
                   : String(localized: "Read “\(subject)” (\(count) messages)")
    }

    static func fromPreviews(_ count: Int) -> String {
        String(localized: " · \(count) read from previews")
    }

    static let allAccountsPlace = String(localized: "all accounts")

    static func followingUp(_ previous: String) -> String {
        String(localized: "Following up on: \(previous)")
    }

    static func followUpQuestion(previous: String, question: String) -> String {
        "Earlier question: \(previous)\nQuestion: \(question)"
    }

    static func askedAt(_ time: String) -> String { String(localized: "Asked at \(time)") }

    public static let sources = String(localized: "Sources")
    public static let alsoMatched = String(localized: "Also matched")
    public static func showMore(_ count: Int) -> String { String(localized: "Show \(count) more") }
    public static let allAccounts = String(localized: "All accounts")
    public static let thisConversation = String(localized: "This conversation")
    public static let unknownSender = String(localized: "Unknown sender")

    static func paletteRow(_ question: String) -> String { String(localized: "Ask AI: “\(question)”") }

    public static let footerIdle = String(localized: "↵ ask · ⇥ scope · esc close")
    public static let footerDone = String(localized: "↵ open · ⌘↵ show as list · ⌘C copy · esc close")
    public static let footerWorking = String(localized: "esc stop")

    public static let tooFewWords = String(localized: "Ask with a few words about the mail, such as a name or a topic.")

    static func nothingMatches(_ words: String) -> String {
        String(localized: "No mail on this Mac matches “\(words)”.")
    }

    static func nothingInGmail(_ words: String) -> String {
        String(localized: "Gmail has no older mail that matches “\(words)”.")
    }

    static func olderMail(before date: String?) -> String {
        date.map { String(localized: "Search Gmail for older mail (before \($0))") }
            ?? String(localized: "Search Gmail for older mail")
    }

    public static let searchingGmail = String(localized: "Searching Gmail…")
    public static let offline = String(localized: "Offline: only mail on this Mac was searched.")
    public static let gmailFailed = String(localized: "Couldn't search Gmail. ↵ to try again.")

    public static let suspicious = String(localized: "This email may contain instructions aimed at AI tools. Check the sources.")
    public static let truncated = String(localized: "Answer cut at the length limit")
    public static let stopped = String(localized: "Stopped")

    public static let aiOff = String(localized: "AI is off. Turn it on in Settings › AI.")
    public static let openSettings = String(localized: "Open Settings")
    public static let tooMuch = String(localized: "Couldn't answer: that matched more mail than the model can read at once. Add a name or a date.")
    public static let refused = String(localized: "The on-device model declined this question.")
    public static let timedOut = String(localized: "Took too long to answer. ↵ to try again.")
    public static let blocked = String(localized: "The answer was blocked because it looked like it contained a secret from this Mac.")
    public static let searchUnavailable = String(localized: "Search isn't available with this mail source.")
    public static let language = String(localized: "The on-device model doesn't support this language yet.")
    public static let conversationGone = String(localized: "This conversation is no longer here")
    public static let searchFailed = String(localized: "the search couldn't run")
    public static let emptyAnswer = String(localized: "the model returned no answer")
    public static let noOnDeviceModel = String(localized: "Ask AI runs on this Mac, and no on-device model is ready.")

    static func onDeviceOnly(_ place: String) -> String {
        String(localized: "\(place) allows on-device AI only.")
    }

    public static let onDeviceOnlySomeAccount = String(localized: "One of your accounts allows on-device AI only.")

    static func failed(_ reason: String) -> String {
        String(localized: "Couldn't answer: \(reason). ↵ to try again.")
    }

    public static let copied = String(localized: "Answer copied")

    static func ready(sources count: Int) -> String {
        switch count {
        case 0: String(localized: "Answer ready, no sources")
        case 1: String(localized: "Answer ready, 1 source")
        default: String(localized: "Answer ready, \(count) sources")
        }
    }

    static func spokenSource(_ index: Int, of count: Int, sender: String, subject: String, date: String) -> String {
        String(localized: "Source \(index) of \(count): \(sender), \(subject), \(date)")
    }

    static func spokenMatch(sender: String, subject: String, date: String) -> String {
        String(localized: "Also matched: \(sender), \(subject), \(date)")
    }
}
