import Foundation
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing

@testable import MailFeatures

@MainActor @Suite struct AIComposerContextTests {
    @Test func cmdJOnAReplySendsTheConversationItAnswers() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 128_000))
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 2)
        let (session, editor) = try await f.reply(thread)
        editor.text = "sounds good, see you then"
        let panel = try #require(f.center.togglePanel(session))
        #expect(panel.scope == .wholeDraft)
        panel.instruction = "Make it friendlier"
        panel.generate()
        await panel.settle()
        #expect(panel.phase == .done)
        let request = try #require(provider.requests.last { $0.task == .rewrite })
        #expect(request.promptID.name == "rewrite.instruct")
        #expect(request.untrusted.filter { $0.kind == .emailBody }.count >= 2)
        #expect(request.untrusted.last { $0.kind == .draft }?.text == "sounds good, see you then")
        #expect(!request.untrusted.contains { $0.kind == .summary }, "the conversation fits, so no summary stands in")
    }

    @Test func writingFromNotesOnAReplyUsesTheNotesPromptWithTheConversation() async throws {
        let provider = ScriptedProvider(capabilities: .fake(contextTokens: 128_000))
        let f = AIFixture(providers: [provider])
        await f.loaded()
        let thread = try await f.thread(minimumMessages: 2)
        let (session, _) = try await f.reply(thread)
        let panel = try #require(f.center.togglePanel(session))
        #expect(panel.scope == .notes)
        panel.instruction = "confirm tuesday at ten"
        panel.generate()
        await panel.settle()
        let request = try #require(provider.requests.last { $0.task == .rewrite })
        #expect(request.promptID.name == "compose.write")
        #expect(!request.untrusted.contains { $0.kind == .draft })
        #expect(request.untrusted.contains { $0.kind == .emailBody })
        #expect(request.trusted.first?.text.contains("confirm tuesday at ten") == true)
    }

    @Test func aRatingIsKeptOnTheTraceOfThatVersion() async throws {
        let store = InMemoryAITraceStore()
        let f = AIFixture(providers: [ScriptedProvider()], traces: store)
        await f.loaded()
        let (session, _) = try f.newMessage("thx for the notes")
        let panel = try #require(f.center.togglePanel(session))
        panel.run(try #require(AIComposerModel.presets.first { $0.id == "friendlier" }))
        await panel.settle()
        let traceID = try #require(panel.currentVersion?.traceID)
        let trace = try #require(try await store.trace(traceID))
        #expect(trace.feature == .rewrite && trace.inputText?.contains("thx for the notes") == true)

        panel.rate(up: true)
        await f.center.pendingRating?.value
        #expect(try await store.trace(traceID)?.rating == 1)
        panel.rate(up: true)
        await f.center.pendingRating?.value
        #expect(try await store.trace(traceID)?.rating == nil, "a second press takes it back")
        panel.rate(up: false)
        await f.center.pendingRating?.value
        #expect(try await store.trace(traceID)?.rating == -1)
    }

    @Test func signingOutForgetsThatAccountsTraces() async throws {
        let store = InMemoryAITraceStore()
        let f = AIFixture(providers: [ScriptedProvider()], traces: store)
        await f.loaded()
        let (session, _) = try f.newMessage("thx for the notes")
        let panel = try #require(f.center.togglePanel(session))
        panel.run(try #require(AIComposerModel.presets.first { $0.id == "shorter" }))
        await panel.settle()
        let key = try #require(f.center.policyKey(session.account.id))
        let kept = try await store.recent(limit: 10)
        #expect(!kept.isEmpty && kept.allSatisfy { $0.accountKeys == [key] })
        await f.center.forgetTraces(for: session.account.id)
        #expect(try await store.recent(limit: 10).isEmpty)
    }

    @Test func signingOutForgetsTracesByEmailOnceTheAccountHasLeftTheList() async throws {
        let store = InMemoryAITraceStore()
        let f = AIFixture(providers: [ScriptedProvider()], traces: store)
        await f.loaded()
        let (session, _) = try f.newMessage("thx for the notes")
        let panel = try #require(f.center.togglePanel(session))
        panel.run(try #require(AIComposerModel.presets.first { $0.id == "shorter" }))
        await panel.settle()
        let email = try #require(f.center.account(session.account.id)).email
        #expect(try await store.recent(limit: 10).allSatisfy { $0.accountKeys == [AICenter.policyKey(email: email)] })
        await f.center.forgetTraces(for: AccountID(9_999))
        #expect(try await store.recent(limit: 10).isEmpty == false, "an account that is not listed resolves to no key")
        await f.center.forgetTraces(email: email.uppercased())
        #expect(try await store.recent(limit: 10).isEmpty)
    }
}
