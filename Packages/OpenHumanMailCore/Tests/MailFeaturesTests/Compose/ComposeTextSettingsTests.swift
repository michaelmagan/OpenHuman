import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct ComposeTextSettingsTests {
    static let work = Account(id: AccountID(1), email: "robin@example.com", displayName: "Work", alias: "Work", health: .active)
    static let personal = Account(id: AccountID(2), email: "robin@example.org", displayName: "Personal", alias: "Personal",
                                  health: .active)

    func suite() -> ScopedDefaults { ScopedDefaults("openhuman.test.compose-text") }

    @Test func defaultsFollowMacOSWithGrammarAndWritingToolsOff() {
        let settings = ComposeTextSettings(defaults: suite(), system: FakeSystemTextSettings())
        #expect(settings.autocorrect == .system && settings.continuousSpelling && !settings.grammar)
        #expect(settings.textReplacement == .system && settings.smartPunctuation == .system)
        #expect(!settings.allowWritingTools, "D1: off by default")
        let flags = settings.flags(for: Self.work)
        #expect(flags == ComposeTextFlags(continuousSpelling: true, autocorrect: true, grammar: false, textReplacement: true,
                                          quoteSubstitution: true, dashSubstitution: true, writingTools: false))
        #expect(ComposeTextFlags.standard.writingTools == false)
        #expect(settings.autoLists && flags.autoLists && ComposeTextFlags.standard.autoLists, "automatic lists start on")
    }

    @Test func automaticListsCanBeTurnedOffAndStayOff() {
        let defaults = suite()
        defer { defaults.cleanup() }
        let a = ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings())
        a.autoLists = false
        #expect(!a.flags(for: Self.work).autoLists)
        let b = ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings())
        #expect(!b.autoLists && !b.flags(for: Self.work).autoLists)
        #expect(defaults.object(forKey: "compose.auto_lists") as? Bool == false, "the documented key")
    }

    @Test func thePastedImageSizeStartsAtMediumAndStays() {
        let defaults = suite()
        defer { defaults.cleanup() }
        let a = ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings())
        #expect(a.pastedImageSize == .medium)
        a.pastedImageSize = .small
        let b = ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings())
        #expect(b.pastedImageSize == .small)
        #expect(defaults.string(forKey: "compose.pasted_image_size") == "small", "the documented key")
        defaults.set("huge", forKey: "compose.pasted_image_size")
        #expect(ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings()).pastedImageSize == .medium,
                "an unknown value falls back to the default")
    }

    @Test func sameAsMacOSFollowsTheSystemAndOnOrOffOverride() {
        let system = FakeSystemTextSettings(SystemTextValues(autocorrect: false, textReplacement: false,
                                                             quoteSubstitution: true, dashSubstitution: false))
        let settings = ComposeTextSettings(defaults: suite(), system: system)
        var flags = settings.flags(for: Self.work)
        #expect(!flags.autocorrect && !flags.textReplacement && flags.quoteSubstitution && !flags.dashSubstitution)
        #expect(settings.autocorrectNote == "macOS is set to off.")
        settings.autocorrect = .on
        #expect(settings.flags(for: Self.work).autocorrect, "On overrides macOS")
        settings.autocorrect = .system
        system.set(SystemTextValues(autocorrect: true, textReplacement: true, quoteSubstitution: true, dashSubstitution: true))
        flags = settings.flags(for: Self.work)
        #expect(flags.autocorrect && flags.textReplacement && flags.dashSubstitution)
        #expect(settings.autocorrectNote == "macOS is set to on.")
        settings.autocorrect = .off
        settings.textReplacement = .off
        settings.smartPunctuation = .off
        flags = settings.flags(for: Self.work)
        #expect(!flags.autocorrect && !flags.textReplacement && !flags.quoteSubstitution && !flags.dashSubstitution)
    }

    @Test func choicesPersistInTheirSuite() {
        let defaults = suite()
        defer { defaults.cleanup() }
        let a = ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings())
        a.autocorrect = .off
        a.continuousSpelling = false
        a.grammar = true
        a.textReplacement = .off
        a.smartPunctuation = .off
        a.allowWritingTools = true
        let b = ComposeTextSettings(defaults: defaults, system: FakeSystemTextSettings())
        #expect(b.autocorrect == .off && !b.continuousSpelling && b.grammar)
        #expect(b.textReplacement == .off && b.smartPunctuation == .off && b.allowWritingTools)
        #expect(defaults.object(forKey: "compose.allow_writing_tools") as? Bool == true, "the documented key")
    }

    @Test func writingToolsNeedsTheSwitchAndIsNeverOfferedToAnOnDeviceOnlyAccount() {
        let settings = ComposeTextSettings(defaults: suite(), system: FakeSystemTextSettings(),
                                           onDeviceOnly: { $0.id == Self.personal.id })
        #expect(!settings.flags(for: Self.work).writingTools && !settings.flags(for: Self.personal).writingTools)
        settings.allowWritingTools = true
        #expect(settings.flags(for: Self.work).writingTools)
        #expect(!settings.flags(for: Self.personal).writingTools, "on-device AI only")
    }

    @Test func theConsentSheetIsWordedForWritingTools() {
        let request = ComposeTextSettings.writingToolsConsent(accounts: [Self.work, Self.personal],
                                                              onDeviceOnly: { $0.id == Self.personal.id })
        #expect(request.providerName == "Apple Writing Tools" && request.location.leavesDevice)
        #expect(request.accounts.map(\.onDeviceOnly) == [false, true])
        #expect(request.paragraphs.contains { $0.contains("not confirmed") })
        #expect(request.paragraphs.contains { $0.contains("Settings › Platform features") })
        #expect(!request.paragraphs.contains { $0.contains("Settings › AI") })
    }

    @Test func thePlatformRowAsksForConsentBeforeAllowing() async {
        let env = AppEnvironment.fake(corpus: .make(threadCount: 3, now: fixedNow), featureFlags: FeatureFlags())
        env.router.start()
        await eventually(timeout: .seconds(15)) { env.router.accountsLoaded }
        let row = WritingToolsSettingsModel(environment: env)
        #expect(!row.isOn && row.status == "Off.")
        row.setOn(true)
        #expect(row.consent != nil && !row.isOn, "nothing is allowed before the sheet's Allow")
        row.decline()
        #expect(row.consent == nil && !row.isOn)
        row.setOn(true)
        row.allow()
        #expect(row.isOn && env.composeText.allowWritingTools && row.status.hasPrefix("On"))
        row.setOn(false)
        #expect(!row.isOn && row.consent == nil)
    }

    @Test func findsTriggersPlaceholdersAddressesAndLinksInMixedText() {
        let text = "Hi 😀 ;;sig and {{first_name}}, 日本語 write teh@exmaple.com or see https://exmaple.com/teh-pth "
            + "and mailto:dana@example.org. שלום {{frist_name"
        let ns = text as NSString
        let found = ProtectedTextRanges.find(in: text).map { ns.substring(with: $0) }
        #expect(found.contains(";;sig"))
        #expect(found.contains("{{first_name}}"))
        #expect(found.contains("teh@exmaple.com"))
        #expect(found.contains("https://exmaple.com/teh-pth"))
        #expect(found.contains { $0.hasPrefix("mailto:dana@example.org") })
        #expect(found.contains("{{frist_name"), "also while the braces are not closed")
        #expect(!found.contains { $0.contains("write") || $0.contains("Hi") })
    }

    @Test func aCorrectionTouchingAProtectedRangeIsDroppedOthersAreKept() {
        let text = "teh ;;teh {{frist_name}} teh@exmaple.com teh"
        let ns = text as NSString
        let corrections = [ns.range(of: "teh"),
                           NSRange(location: ns.range(of: ";;teh").location + 2, length: 3),
                           NSRange(location: ns.range(of: "frist").location, length: 5),
                           NSRange(location: ns.range(of: "exmaple").location, length: 7),
                           ns.range(of: "teh", options: .backwards)]
        let kept = ProtectedTextRanges.filter(corrections, in: text) { $0 }
        #expect(kept == [corrections[0], corrections[4]])
        #expect(ProtectedTextRanges.touches(NSRange(location: ns.range(of: ";;teh").location, length: 0),
                                            ProtectedTextRanges.find(in: text)), "an insertion at a trigger")
        #expect(ProtectedTextRanges.find(in: "plain words only").isEmpty)
    }
}
