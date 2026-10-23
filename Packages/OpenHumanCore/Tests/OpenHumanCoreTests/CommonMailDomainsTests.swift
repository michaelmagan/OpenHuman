import Foundation
import Testing
@testable import OpenHumanCore

@Suite struct CommonMailDomainsTests {
    @Test(arguments: ["gmail.com", "googlemail.com", "yahoo.com", "ymail.com", "rocketmail.com", "hey.com", "outlook.com",
                      "hotmail.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "proton.me",
                      "protonmail.com", "pm.me", "fastmail.com", "fastmail.fm", "messagingengine.com", "aol.com",
                      "gmx.net", "mail.com", "zoho.com", "yandex.ru", "mail.ru", "qq.com", "163.com", "126.com",
                      "sina.com", "naver.com", "daum.net", "libero.it", "web.de", "t-online.de", "orange.fr", "free.fr",
                      "comcast.net", "verizon.net", "att.net", "sbcglobal.net", "cox.net", "charter.net", "spectrum.net",
                      "btinternet.com", "sky.com", "tutanota.com", "posteo.de", "mailbox.org"])
    func mailboxProvidersAreCommon(_ domain: String) {
        #expect(CommonMailDomains.isCommonMailDomain(domain))
        #expect(CommonMailDomains.kind(of: domain) == .mailboxProvider)
    }

    @Test(arguments: ["amazonses.com", "sendgrid.net", "mcsv.net", "mailchimp.com", "mandrillapp.com", "substack.com",
                      "google.com", "docs.google.com", "github.com", "linkedin.com", "facebookmail.com", "notion.so",
                      "slack.com"])
    func sharedSendersAreCommon(_ domain: String) {
        #expect(CommonMailDomains.isCommonMailDomain(domain))
        #expect(CommonMailDomains.kind(of: domain) == .sharedSender)
    }

    @Test(arguments: ["GMAIL.COM", "gmail.com.", "gmail.com..", "@gmail.com", "  Gmail.Com\n", "dana@gmail.com",
                      "Dana Sample <Dana@Gmail.com>", "*.gmail.com", ".gmail.com"])
    func caseDotsAtSignsAndAddressesNormalize(_ raw: String) {
        #expect(CommonMailDomains.isCommonMailDomain(raw))
        #expect(CommonMailDomains.matchedEntry(raw) == "gmail.com")
    }

    @Test func subdomainsAreCoveredByTheListedDomain() {
        #expect(CommonMailDomains.matchedEntry("mail.yahoo.co.uk") == "yahoo.co.uk")
        #expect(CommonMailDomains.matchedEntry("email.substack.com") == "substack.com")
        #expect(CommonMailDomains.matchedEntry("us-west-2.amazonses.com") == "amazonses.com")
        #expect(CommonMailDomains.matchedEntry("notifications.github.com") == "github.com")
        #expect(CommonMailDomains.matchedEntry("calendar-server.google.com") == "google.com")
        #expect(CommonMailDomains.matchedEntry("vip.163.com") == "163.com")
        #expect(CommonMailDomains.kind(of: "mail.yahoo.co.uk") == .mailboxProvider)
    }

    @Test(arguments: ["yahoo.co.uk", "yahoo.fr", "yahoo.co.jp", "yahoo.com.br", "yahoo.com.au", "hotmail.co.uk",
                      "hotmail.fr", "outlook.com.au", "outlook.de", "live.co.uk", "live.com.mx", "gmx.at", "aol.de",
                      "yandex.com.tr", "zoho.eu", "posteo.org", "tutanota.de"])
    func regionalVariantsAreCommon(_ domain: String) {
        #expect(CommonMailDomains.isCommonMailDomain(domain))
        #expect(CommonMailDomains.kind(of: domain) == .mailboxProvider)
    }

    @Test(arguments: ["acme.example", "dana-design.example", "smallcompany.co.uk", "notgmail.com", "mygmail.com",
                      "gmail.com.lookalike.example", "yahoo.lookalike.example", "outlook.acme.example", "co.uk", "com",
                      "pages.github.io", "live.events", "hotmail.co.lookalike"])
    func otherDomainsAreNotCommon(_ domain: String) {
        #expect(!CommonMailDomains.isCommonMailDomain(domain))
        #expect(CommonMailDomains.matchedEntry(domain) == nil)
        #expect(CommonMailDomains.kind(of: domain) == nil)
    }

    @Test(arguments: ["", "   ", "gmail", "@", ".", "..", "gmail..com", "a b.com"])
    func unusableInputIsNeverCommon(_ raw: String) {
        #expect(!CommonMailDomains.isCommonMailDomain(raw))
    }

    @Test func listedDomainsAreAlreadyNormalizedAndNeverInBothLists() {
        for domain in CommonMailDomains.mailboxProviders.union(CommonMailDomains.sharedSenders) {
            #expect(CommonMailDomains.normalizedHost(domain) == domain, "\(domain)")
        }
        #expect(CommonMailDomains.mailboxProviders.isDisjoint(with: CommonMailDomains.sharedSenders))
        #expect(CommonMailDomains.regionalBrands.allSatisfy { !$0.contains(".") })
    }
}

@Suite struct DomainWideRuleGuardTests {
    @Test func aDomainThatIsNotCommonNeedsNoQuestion() {
        #expect(DomainWideRuleGuard.confirmation(domain: "acme.example", address: "news@acme.example", effect: .block) == nil)
        #expect(DomainWideRuleGuard.confirmation(domain: "mail.acme.example", address: nil, effect: .neverImportant) == nil)
    }

    @Test func aCommonDomainAsksAndDefaultsToTheOneAddress() throws {
        let question = try #require(DomainWideRuleGuard.confirmation(domain: "Gmail.com.", address: " Dana@Gmail.com ",
                                                                     effect: .block))
        #expect(question.domain == "gmail.com")
        #expect(question.address == "dana@gmail.com")
        #expect(question.kind == .mailboxProvider)
        #expect(question.choices == [.thisAddressOnly, .entireDomain, .cancel])
        #expect(question.defaultChoice == .thisAddressOnly)
        #expect(question.choices.map(question.buttonTitle) == ["Block This Address Only", "Block Entire Domain", "Cancel"])
        #expect(question.title == "Block everyone at gmail.com?")
        #expect(question.message == "gmail.com is a shared email provider, so this covers everyone with an address "
                + "there, not just dana@gmail.com. New mail from any of them will skip the Inbox.")
    }

    @Test func withoutAnAddressTheDefaultIsCancel() throws {
        let typed = try #require(DomainWideRuleGuard.confirmation(domain: "yahoo.co.uk", address: nil, effect: .block))
        #expect(typed.choices == [.cancel, .entireDomain])
        #expect(typed.defaultChoice == .cancel)
        #expect(typed.message.hasSuffix("everyone with an address there. New mail from any of them will skip the Inbox."))
        let notAnAddress = try #require(DomainWideRuleGuard.confirmation(domain: "gmail.com", address: "gmail.com",
                                                                         effect: .block))
        #expect(notAnAddress.address == nil)
        #expect(notAnAddress.choices == [.cancel, .entireDomain])
    }

    @Test func eachEffectSaysWhatItDoes() throws {
        func question(_ effect: DomainWideRuleEffect, _ domain: String = "gmail.com") throws -> DomainWideRuleConfirmation {
            try #require(DomainWideRuleGuard.confirmation(domain: domain, address: "dana@\(domain)", effect: effect))
        }
        #expect(try question(.neverImportant).title == "Make all mail from gmail.com not important?")
        #expect(try question(.alwaysImportant).title == "Make all mail from gmail.com important?")
        #expect(try question(.autoLabel("Newsletter")).title == "Label all mail from gmail.com as Newsletter?")
        #expect(try question(.alwaysInCleanup).title == "Always include all of gmail.com in cleanup?")
        #expect(try question(.neverImportant).buttonTitle(.thisAddressOnly) == "Apply to This Address Only")
        #expect(try question(.neverImportant).buttonTitle(.entireDomain) == "Apply to Entire Domain")
        #expect(try question(.alwaysInCleanup).buttonTitle(.entireDomain) == "Include Entire Domain")
        let shared = try question(.block, "github.com")
        #expect(shared.kind == .sharedSender)
        #expect(shared.message.hasPrefix("github.com sends mail for many unrelated people and companies"))
    }

    @Test func eachAnswerResolvesToWhatIsApplied() throws {
        let question = try #require(DomainWideRuleGuard.confirmation(domain: "gmail.com", address: "dana@gmail.com",
                                                                     effect: .block))
        #expect(DomainWideRuleGuard.resolution(of: .entireDomain, for: question) == .entireDomain("gmail.com"))
        #expect(DomainWideRuleGuard.resolution(of: .thisAddressOnly, for: question) == .thisAddressOnly("dana@gmail.com"))
        #expect(DomainWideRuleGuard.resolution(of: .cancel, for: question) == nil)
        let typed = try #require(DomainWideRuleGuard.confirmation(domain: "gmail.com", address: nil, effect: .block))
        #expect(DomainWideRuleGuard.resolution(of: .thisAddressOnly, for: typed) == nil, "no address to narrow to")
    }

    @Test func callersThatCannotAskAreRefusedUnlessConfirmed() throws {
        #expect(throws: DomainWideRuleError.needsConfirmation(domain: "gmail.com")) {
            try DomainWideRuleGuard.requireConfirmation(domain: "GMAIL.com", confirmed: false)
        }
        #expect(throws: DomainWideRuleError.needsConfirmation(domain: "mail.yahoo.co.uk")) {
            try DomainWideRuleGuard.requireConfirmation(domain: "mail.yahoo.co.uk", confirmed: false)
        }
        try DomainWideRuleGuard.requireConfirmation(domain: "gmail.com", confirmed: true)
        try DomainWideRuleGuard.requireConfirmation(domain: "acme.example", confirmed: false)
        let message = DomainWideRuleError.needsConfirmation(domain: "gmail.com").errorDescription ?? ""
        #expect(message.hasPrefix("gmail.com is a common email domain"))
    }
}
