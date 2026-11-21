import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private func person(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }

private let ana = person("ana@example.test", "Ana Diaz")
private let ben = person("ben@example.test")
private let cy = person("cy@example.test", "Cy")

@Suite struct RecipientMoveTests {
    @Test func aMoveTakesTheAddressOutOfOneFieldAndAppendsItToTheOther() {
        let moved = RecipientMove.moving(ana, from: [ben, ana], to: [cy])
        #expect(moved?.source == [ben] && moved?.target == [cy, ana])
    }

    @Test func anAddressAlreadyInTheTargetIsNotAddedTwice() {
        let shouting = person("ANA@example.test")
        let moved = RecipientMove.moving(ana, from: [ana, ben], to: [shouting])
        #expect(moved?.source == [ben] && moved?.target == [shouting])
    }

    @Test func anAddressThatIsNotInTheSourceMovesNothing() {
        #expect(RecipientMove.moving(cy, from: [ana], to: []) == nil)
        #expect(RecipientMove.moving(person("Ben@Example.test"), from: [ben], to: [])?.target == [ben], "matched by address")
    }

    @Test func theDraggedTextIsAnAddressTheFieldsCanReadBack() {
        #expect(RecipientMove.dragText(ben) == "ben@example.test")
        #expect(RecipientMove.dragText(ana) == "Ana Diaz <ana@example.test>")
        let comma = person("x@example.test", "Diaz, Ana")
        #expect(RecipientMove.dragText(comma) == "\"Diaz, Ana\" <x@example.test>")
        #expect(RecipientParser.parseOne(RecipientMove.dragText(comma)) == comma)
    }

    @Test func theActionsAreNamedForTheirField() {
        #expect(RecipientMove.title(movingTo: .to) == "Move to To")
        #expect(RecipientMove.title(movingTo: .cc) == "Move to Cc")
        #expect(RecipientMove.title(movingTo: .bcc) == "Move to Bcc")
    }
}

@MainActor @Suite struct RecipientMoveSessionTests {
    @Test func aMoveIsOneUndoStepAndShowsTheTargetRow() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.setTokens([ana, ben])
        #expect(!session.showsCc)
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(session.moveRecipient(ana, from: .to, to: .cc, undoManager: undo))
        undo.endUndoGrouping()
        #expect(session.to.tokens == [ben] && session.cc.tokens == [ana] && session.showsCc)
        #expect(session.hasUserEdits)
        #expect(session.assembledFields().cc == [ana] && session.assembledFields().to == [ben], "what is saved and sent")
        #expect(undo.undoActionName == "Move Recipient")
        undo.undo()
        #expect(session.to.tokens == [ana, ben] && session.cc.tokens.isEmpty && !session.showsCc)
        #expect(!undo.canUndo, "one step")
        undo.redo()
        #expect(session.to.tokens == [ben] && session.cc.tokens == [ana] && session.showsCc)
    }

    @Test func undoingAMoveKeepsRecipientsAddedAfterIt() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let dee = person("dee@example.test")
        session.to.setTokens([ana, ben])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(session.moveRecipient(ana, from: .to, to: .cc, undoManager: undo))
        undo.endUndoGrouping()
        session.to.accept(cy)
        session.cc.accept(dee)
        undo.undo()
        #expect(session.to.tokens == [ana, ben, cy], "back in its place, with the later recipient kept")
        #expect(session.cc.tokens == [dee] && session.showsCc, "the row stays while it has someone")
        undo.redo()
        #expect(session.to.tokens == [ben, cy] && session.cc.tokens == [dee, ana])
    }

    @Test func undoingAMoveDoesNotBringBackARecipientRemovedSince() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.setTokens([ana, ben])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        #expect(session.moveRecipient(ana, from: .to, to: .cc, undoManager: undo))
        undo.endUndoGrouping()
        session.cc.remove(ana)
        undo.undo()
        #expect(session.to.tokens == [ben] && session.cc.tokens.isEmpty)
    }

    @Test func movingIntoAFieldThatHasTheAddressOnlyTakesItOutOfTheSource() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let shouting = person("Ana@Example.test")
        session.to.setTokens([ana, ben])
        session.bcc.setTokens([shouting])
        session.showBcc()
        #expect(session.moveRecipient(ana, from: .to, to: .bcc, undoManager: nil))
        #expect(session.to.tokens == [ben] && session.bcc.tokens == [shouting])
        #expect(!session.moveRecipient(cy, from: .to, to: .cc, undoManager: nil), "not there")
        #expect(!session.moveRecipient(ben, from: .to, to: .to, undoManager: nil), "same field")
        #expect(session.to.tokens == [ben] && session.cc.tokens.isEmpty)
    }

    @Test func aDragShowsTheHiddenRowsUntilItEndsOrDrops() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.setTokens([ana, ben])
        #expect(session.isRecipientRowShown(.to))
        #expect(!session.isRecipientRowShown(.cc) && !session.isRecipientRowShown(.bcc))
        session.beginRecipientDrag(ana, from: .to)
        #expect(session.isRecipientRowShown(.cc) && session.isRecipientRowShown(.bcc), "drop targets while dragging")
        session.endRecipientDrag()
        #expect(session.recipientDrag == nil && !session.isRecipientRowShown(.cc), "a cancelled drag hides them again")

        session.beginRecipientDrag(ben, from: .to)
        #expect(session.dropRecipient(on: .bcc, undoManager: nil))
        #expect(session.recipientDrag == nil && session.bcc.tokens == [ben] && session.to.tokens == [ana])
        #expect(session.isRecipientRowShown(.bcc) && !session.isRecipientRowShown(.cc), "only the row that got it stays")
        #expect(!session.dropRecipient(on: .cc, undoManager: nil), "no drag in flight")

        session.beginRecipientDrag(ana, from: .to)
        #expect(!session.dropRecipient(on: .to, undoManager: nil), "dropped back where it started")
        #expect(session.to.tokens == [ana] && session.recipientDrag == nil)
    }

    @Test func everyChipCanMoveToTheOtherTwoFields() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        #expect(session.moveTargets(from: .to) == [.cc, .bcc])
        #expect(session.moveTargets(from: .cc) == [.to, .bcc])
        #expect(session.moveTargets(from: .bcc) == [.to, .cc])
        #expect(session.field(.to) === session.to && session.field(.cc) === session.cc && session.field(.bcc) === session.bcc)
    }
}
