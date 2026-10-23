import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class DomainQuestions {
    var asked: [DomainWideRuleConfirmation] = []
    var answer: DomainWideRuleChoice

    init(_ answer: DomainWideRuleChoice) { self.answer = answer }

    var platform: SystemPlatform {
        var platform = SystemPlatform.inert()
        platform.confirmDomainWideRule = { [self] question in
            asked.append(question)
            return answer
        }
        return platform
    }
}

@MainActor
@Suite struct CommonDomainBlockTests {
    let account = AccountID(1)

    func fixture(_ questions: DomainQuestions?) async -> ActionFixture {
        let f = ActionFixture(corpus: .make(threadCount: 4, now: fixedNow), platform: questions?.platform)
        await f.loaded()
        return f
    }

    func deliver(_ f: ActionFixture, _ sender: String) async throws -> ThreadKey {
        f.store.deliverMessage(account: account, from: EmailAddress(name: nil, email: sender), subject: "Synthetic from \(sender)")
        await eventually { f.rows.contains { $0.participants.contains { $0.email == sender } } }
        return try #require(f.rows.first { $0.participants.contains { $0.email == sender } }?.id)
    }

    func context(_ f: ActionFixture, thread: ThreadKey, sender: String) -> ActionContext {
        var c = f.router.actionContext()
        c.account = account
        c.focusedThread = thread
        c.selection = [thread]
        c.sender = sender
        return c
    }

    func blockRules(_ f: ActionFixture) async -> [String] {
        ((try? await f.store.get(BlockKeys.rules(account))) ?? []).map(\.id)
    }

    @Test func blockingAProviderDomainAsksAndCanNarrowToTheAddress() async throws {
        let questions = DomainQuestions(.thisAddressOnly)
        let f = await fixture(questions)
        let thread = try await deliver(f, "dana@gmail.com")
        #expect(await f.run(.blockDomain, context: context(f, thread: thread, sender: "Dana+News@Gmail.com")))
        let asked = try #require(questions.asked.first)
        #expect(questions.asked.count == 1)
        #expect(asked.domain == "gmail.com" && asked.address == "dana@gmail.com" && asked.effect == .block)
        #expect(asked.defaultChoice == .thisAddressOnly)
        #expect(await blockRules(f) == ["sender:dana@gmail.com"])
        #expect(f.env.undo?.stack.map { String(localized: $0.title) } == ["Blocked dana@gmail.com"])
    }

    @Test func cancellingSavesNothingAndLeavesTheConversation() async throws {
        let questions = DomainQuestions(.cancel)
        let f = await fixture(questions)
        let thread = try await deliver(f, "dana@gmail.com")
        #expect(await f.run(.blockDomain, context: context(f, thread: thread, sender: "dana@gmail.com")))
        #expect(questions.asked.count == 1)
        #expect(await blockRules(f).isEmpty)
        #expect(f.rows.contains { $0.id == thread })
        #expect(f.env.undo?.stack.isEmpty == true)
    }

    @Test func choosingTheEntireDomainBlocksIt() async throws {
        let questions = DomainQuestions(.entireDomain)
        let f = await fixture(questions)
        let thread = try await deliver(f, "alerts@mail.yahoo.co.uk")
        #expect(await f.run(.blockDomain, context: context(f, thread: thread, sender: "alerts@mail.yahoo.co.uk")))
        #expect(questions.asked.map(\.domain) == ["mail.yahoo.co.uk"])
        #expect(await blockRules(f) == ["domain:mail.yahoo.co.uk"])
    }

    @Test func aDomainThatIsNotCommonIsBlockedWithoutAsking() async throws {
        let questions = DomainQuestions(.cancel)
        let f = await fixture(questions)
        let thread = try await deliver(f, "news@acme.example")
        #expect(await f.run(.blockDomain, context: context(f, thread: thread, sender: "news@acme.example")))
        #expect(questions.asked.isEmpty)
        #expect(await blockRules(f) == ["domain:acme.example"])
    }

    @Test func withNoWindowToAskInACommonDomainIsNeverBlocked() async throws {
        let f = await fixture(nil)
        let thread = try await deliver(f, "dana@gmail.com")
        #expect(await f.run(.blockDomain, context: context(f, thread: thread, sender: "dana@gmail.com")))
        #expect(await blockRules(f).isEmpty)
    }

    @Test func blockingASenderAtAProviderNeverAsks() async throws {
        let questions = DomainQuestions(.cancel)
        let f = await fixture(questions)
        let thread = try await deliver(f, "dana@gmail.com")
        #expect(await f.run(.blockSender, context: context(f, thread: thread, sender: "dana@gmail.com")))
        #expect(questions.asked.isEmpty)
        #expect(await blockRules(f) == ["sender:dana@gmail.com"])
    }

    @Test func theBlockCenterRefusesACommonDomainUnlessTheWholeDomainWasChosen() async throws {
        let center = BlockCenter(settings: FakeMailStore(corpus: .make(threadCount: 3)), finds: { _, _ in false })
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let gmail = try #require(BlockRule(kind: .domain, value: "gmail.com", createdAt: created))
        await #expect(throws: DomainWideRuleError.needsConfirmation(domain: "gmail.com")) {
            try await center.add(gmail, account: account)
        }
        #expect(await center.rules(account).isEmpty)
        _ = try await center.add(gmail, account: account, allowingCommonDomain: true)
        _ = try await center.add(try #require(BlockRule(kind: .sender, value: "dana@yahoo.com", createdAt: created)),
                                 account: account)
        _ = try await center.add(try #require(BlockRule(kind: .domain, value: "acme.example", createdAt: created)),
                                 account: account)
        #expect(Set(await center.rules(account).map(\.id)) == ["domain:gmail.com", "sender:dana@yahoo.com",
                                                               "domain:acme.example"])
    }

    @Test func typingACommonDomainInSettingsAsksFirst() async throws {
        let questions = DomainQuestions(.cancel)
        let f = SettingsFixture()
        f.env.installPlatform(questions.platform)
        let model = BlockedSettingsModel(environment: f.env)
        model.start()
        await eventually { model.account != nil && model.hasLoaded }
        let account = try #require(model.account)
        func stored() async -> [String] { ((try? await f.store.get(BlockKeys.rules(account))) ?? []).map(\.id) }

        model.newValue = "Gmail.com"
        await model.addTyped()
        #expect(questions.asked.map(\.domain) == ["gmail.com"])
        #expect(questions.asked.first?.address == nil, "a typed domain has no single address to narrow to")
        #expect(questions.asked.first?.defaultChoice == .cancel)
        #expect(await stored().isEmpty)
        #expect(model.pendingConfirmation == nil)

        questions.answer = .entireDomain
        await model.addTyped()
        if model.pendingConfirmation != nil { await model.confirmPending() }
        #expect(await stored() == ["domain:gmail.com"])
    }
}

@MainActor
@Suite struct CommonDomainImportanceTests {
    @Test func aProviderDomainRuleAsksAndCanNarrowToTheSender() async throws {
        let questions = DomainQuestions(.thisAddressOnly)
        let f = ActionFixture(corpus: .make(threadCount: 12, now: fixedNow), platform: questions.platform)
        await f.loaded()
        var c = f.router.actionContext()
        c.sender = "dana@gmail.com"
        #expect(c.senderDomain == "gmail.com")
        let rules = try #require(f.env.importance as? FakeImportanceRules)

        #expect(await f.run(.neverImportantDomain, context: c))
        #expect(questions.asked.map(\.effect) == [.neverImportant])
        #expect(rules.allRules.map(\.kind) == [.neverSender])
        #expect(rules.allRules.first?.value == "dana@gmail.com")

        questions.answer = .cancel
        #expect(await f.run(.alwaysImportantDomain, context: c))
        #expect(rules.allRules.map(\.kind) == [.neverSender], "Cancel adds nothing")

        questions.answer = .entireDomain
        #expect(await f.run(.alwaysImportantDomain, context: c))
        #expect(Set(rules.allRules.map(\.kind)) == [.neverSender, .alwaysDomain])
        #expect(questions.asked.count == 3)
    }

    @Test func typingACommonDomainRuleInSettingsAsksFirst() async throws {
        let questions = DomainQuestions(.cancel)
        let f = SettingsFixture()
        let port = try #require(f.env.importance)
        let model = ImportanceSettingsModel(data: f.env.data, port: port, undo: f.env.undo,
                                            availability: f.availability, askDomainWide: questions.platform.confirmDomainWideRule)
        model.start()
        await eventually { model.account != nil }
        model.beginAdd(.domain)
        model.draft?.effect = .neverImportant
        model.draft?.value = "hotmail.co.uk"
        await model.save()
        #expect(questions.asked.map(\.domain) == ["hotmail.co.uk"])
        #expect(model.draft != nil, "the draft stays open after Cancel")

        questions.answer = .entireDomain
        await model.save()
        #expect(model.draft == nil)
        await eventually { model.rules.contains { $0.kind == .neverDomain && $0.value == "hotmail.co.uk" } }
    }
}

@MainActor
@Suite struct CommonDomainCleanupTests {
    @Test func alwaysIncludingACommonDomainAsksButNeverIncludingDoesNot() async throws {
        let questions = DomainQuestions(.cancel)
        let store = FakeMailStore(corpus: .make(threadCount: 1, now: fixedNow))
        let model = CleanupRulesModel(settings: store, askDomainWide: questions.platform.confirmDomainWideRule)
        model.start()
        #expect(await model.add("gmail.com", choice: .always) == false)
        #expect(questions.asked.map(\.effect) == [.alwaysInCleanup])
        #expect(await model.add("@outlook.com", choice: .never))
        #expect(await model.add("dana@gmail.com", choice: .always))
        #expect(questions.asked.count == 1)
        questions.answer = .entireDomain
        #expect(await model.add("gmail.com", choice: .always))
        #expect(try await store.get(AppSettings.archiveSuggestionOverrides)
                == ["@gmail.com": "always", "@outlook.com": "never", "dana@gmail.com": "always"])
    }
}
