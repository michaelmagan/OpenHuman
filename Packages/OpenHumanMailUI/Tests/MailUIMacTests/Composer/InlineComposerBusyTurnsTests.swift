import Testing
@testable import MailUIMac

struct InlineComposerBusyTurnsTests {
    @Test func aLayoutThatNeverSettlesIsReportedOnce() {
        var turns = InlineComposerBusyTurns()
        let reports = (0..<(InlineComposerBusyTurns.reportAfter * 3)).filter { _ in turns.turnEnded(busy: true) }
        #expect(reports == [InlineComposerBusyTurns.reportAfter - 1])
        #expect(turns.inARow == InlineComposerBusyTurns.reportAfter * 3)
    }

    @Test func aQuietTurnStartsTheCountAgain() {
        var turns = InlineComposerBusyTurns()
        for _ in 0..<5 {
            for _ in 0..<(InlineComposerBusyTurns.reportAfter - 1) {
                let reported = turns.turnEnded(busy: true)
                #expect(!reported)
            }
            let settled = turns.turnEnded(busy: false)
            #expect(!settled)
            #expect(turns.inARow == 0)
        }
        #expect(!turns.reported, "a busy stretch that settles is not reported")
    }
}
