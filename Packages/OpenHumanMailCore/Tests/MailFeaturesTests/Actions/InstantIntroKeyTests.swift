import Foundation
import MailActions
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct InstantIntroKeyTests {
    @Test func inTheListItIsHandledWithANotice() async {
        let f = ActionFixture()
        await f.loaded(10)
        #expect(await f.run(.instantIntro, source: .keyboard), "handled: the key is consumed, no beep")
        #expect(f.env.notices.toasts.contains {
            $0.message == "Instant Intro only works when you are writing a reply to an introduction"
        })
        #expect(f.registry.performCount == 0, "nothing was performed")
    }

    @Test func inAComposerContextWithoutAReplyItSaysWhereItWorks() async {
        let f = ActionFixture()
        await f.loaded(10)
        let composer = ActionContext(scope: .composer)
        #expect(await f.run(.instantIntro, source: .keyboard, context: composer))
        #expect(f.env.notices.toasts.map(\.message)
            == ["Instant Intro only works when you are writing a reply to an introduction"])
        #expect(f.registry.performCount == 0, "nothing was performed")
    }

    @Test func aRepeatedPressReplacesTheNoticeInsteadOfStackingThem() async {
        let f = ActionFixture()
        await f.loaded(10)
        for _ in 0..<3 { _ = await f.run(.instantIntro, source: .keyboard) }
        #expect(f.env.notices.toasts.filter { $0.message.hasPrefix("Instant Intro") }.count == 1)
    }

    @Test func aTriageKeyWithNothingSelectedSaysSo() async {
        let f = ActionFixture()
        await f.loaded(10)
        let empty = ActionContext(scope: .list)
        #expect(await f.run(.markDone, source: .keyboard, context: empty))
        #expect(f.env.notices.toasts.contains { $0.message == "No conversation selected" })
    }
}
