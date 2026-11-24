extension ActionID {
    public static let instantIntro = ActionID("compose.instantIntro")
}

extension DisabledReason {
    public static let instantIntroNeedsReply = DisabledReason.needs(
        action: "Instant Intro", context: "you are writing a reply to an introduction")
}
