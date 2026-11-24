import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

private func person(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }

private let me = person("me@example.test", "Robin Example")
private let ana = person("ana@example.test", "Ana Diaz")
private let zoe = person("zoe@example.test", "Zoe Park")
private let yan = person("yan@example.test")

private func message(from: EmailAddress?, to: [EmailAddress], cc: [EmailAddress] = []) -> MessageSummary {
    MessageSummary(id: MessageKey(account: AccountID(1), rowID: 1, gmailMessageID: GmailMessageID("m1")), from: from, to: to, cc: cc,
                   bcc: [], date: fixedNow, snippet: "", isUnread: false, attachments: [])
}

@Suite struct InstantIntroPlanTests {
    @Test func theIntroducedAreTheOtherRecipientsOfTheOriginal() throws {
        let plan = try #require(InstantIntroPlan(original: message(from: ana, to: [me, zoe], cc: [yan]),
                                                 myAddresses: [me.email]))
        #expect(plan.introducer == ana && plan.introduced == [zoe, yan])
    }

    @Test func theGreetingThanksTheIntroducerByFirstName() throws {
        let plan = try #require(InstantIntroPlan(original: message(from: ana, to: [me, zoe]), myAddresses: [me.email]))
        #expect(plan.greeting == "Thanks Ana, moving you to Bcc.")
    }

    @Test func ownAddressesTheIntroducerAndRepeatsAreLeftOut() throws {
        let alias = person("Robin@Alias.test")
        let original = message(from: ana, to: [person("ME@example.test"), alias, zoe], cc: [ana, person("ZOE@example.test")])
        let plan = try #require(InstantIntroPlan(original: original, myAddresses: [me.email, "robin@alias.test"]))
        #expect(plan.introduced == [zoe])
    }

    @Test func withNoOtherRecipientThereIsNoPlan() {
        #expect(InstantIntroPlan(original: message(from: ana, to: [me]), myAddresses: [me.email]) == nil)
        #expect(InstantIntroPlan(original: message(from: nil, to: [me, zoe]), myAddresses: [me.email]) == nil)
        #expect(InstantIntroPlan(original: message(from: me, to: [zoe]), myAddresses: [me.email]) == nil,
                "a reply to my own message introduces no one")
    }
}

@MainActor
private final class IntroEditor: ComposeTextEditing {
    var text: String
    var caret = 0
    let undo = UndoManager()

    init(session: ComposeSession, text: String) {
        self.text = text
        undo.groupsByEvent = false
        session.editor = self
    }

    var editorText: String { text }
    var editorSelection: Range<Int> { caret..<caret }
    var editorUndoManager: UndoManager? { undo }

    func replaceText(in range: Range<Int>, with new: String) -> Bool {
        let ns = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= ns.length else { return false }
        set(ns.replacingCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: new))
        return true
    }

    private func set(_ new: String) {
        let old = text
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.set(old) }
        }
        text = new
    }

    func focusEditor() {}
    func placeCaret(at offset: Int) { caret = offset }
}

@MainActor
@Suite(.serialized) struct InstantIntroComposeTests {
    enum TestFailure: Error { case noMessage }

    static let needsReply = "Instant Intro only works when you are writing a reply to an introduction"

    /// A received message of the work account, with or without recipients other than the user and the sender.
    static func received(_ f: ComposeFixture, withOthers: Bool) async throws -> (ThreadKey, MessageSummary, [EmailAddress]) {
        let account = try #require(f.router.accounts.first { $0.id == ComposeFixture.work }?.account)
        let rows = try await f.store.threadPage(.system(.allMail), account: ComposeFixture.work, after: nil, limit: 1_000).rows
        for row in rows {
            var messages: [MessageSummary] = []
            for try await detail in f.store.threadDetail(row.id) {
                messages = detail?.messages ?? []
                break
            }
            for message in messages {
                guard let from = message.from, !account.isMe(from.email) else { continue }
                let others = (message.to + message.cc).filter {
                    !account.isMe($0.email) && $0.email.caseInsensitiveCompare(from.email) != .orderedSame
                }
                if others.isEmpty != withOthers { return (row.id, message, others) }
            }
        }
        throw TestFailure.noMessage
    }

    static func reply(_ f: ComposeFixture, withOthers: Bool) async throws
        -> (session: ComposeSession, introducer: EmailAddress, others: [EmailAddress]) {
        let (thread, message, others) = try await received(f, withOthers: withOthers)
        let session = try #require(f.compose.openReply(thread, mode: .reply, message: message.id))
        await session.settle()
        let introducer = try #require(message.from)
        #expect(session.to.tokens == [introducer] && session.bcc.tokens.isEmpty, "a reply starts with the sender in To")
        return (session, introducer, others)
    }

    static func greeting(_ introducer: EmailAddress) -> String {
        "Thanks \(ReaderFormatting.firstName(introducer)), moving you to Bcc."
    }

    @Test func itMovesTheIntroducerToBccAndPutsTheIntroducedInTo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (session, introducer, others) = try await Self.reply(f, withOthers: true)
        #expect(await f.run(.instantIntro, in: session))
        #expect(session.to.tokens == others && session.bcc.tokens == [introducer] && session.showsBcc)
        #expect(session.cc.tokens.isEmpty)
        #expect(session.assembledFields().to == others && session.assembledFields().bcc == [introducer],
                "what is saved and sent")
        #expect(session.plainText.hasPrefix(Self.greeting(introducer)), "the reply starts with the greeting")
        #expect(!f.toasts.contains("No one to introduce"))
    }

    @Test func textAlreadyTypedIsKeptBelowTheGreeting() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (session, introducer, _) = try await Self.reply(f, withOthers: true)
        session.updateBody(doc("Happy to meet."))
        let revision = session.documentRevision
        #expect(await f.run(.instantIntro, in: session))
        #expect(session.document == RichTextDocument(blocks: [.paragraph([.text(Self.greeting(introducer), [])]),
                                                              .paragraph([]), .paragraph([.text("Happy to meet.", [])])]))
        #expect(session.documentRevision > revision, "an editor that is showing the body reloads it")
    }

    @Test func aSecondPressAddsNothing() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (session, introducer, others) = try await Self.reply(f, withOthers: true)
        #expect(await f.run(.instantIntro, in: session))
        let once = session.document
        #expect(await f.run(.instantIntro, in: session))
        #expect(session.document == once && session.to.tokens == others && session.bcc.tokens == [introducer])
    }

    @Test func inAnOpenEditorItIsOneUndoStep() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (session, introducer, others) = try await Self.reply(f, withOthers: true)
        let editor = IntroEditor(session: session, text: "Happy to meet.")
        #expect(await f.run(.instantIntro, in: session))
        let greeting = Self.greeting(introducer)
        #expect(editor.text == greeting + "\n\nHappy to meet.")
        #expect(editor.caret == (greeting as NSString).length + 2, "the caret is where the note continues")
        #expect(session.to.tokens == others && session.bcc.tokens == [introducer] && session.showsBcc)
        #expect(editor.undo.undoActionName == "Instant Intro")

        editor.undo.undo()
        #expect(editor.text == "Happy to meet.")
        #expect(session.to.tokens == [introducer] && session.bcc.tokens.isEmpty && !session.showsBcc)
        #expect(!editor.undo.canUndo, "one step")

        editor.undo.redo()
        #expect(editor.text == greeting + "\n\nHappy to meet.")
        #expect(session.to.tokens == others && session.bcc.tokens == [introducer])
    }

    @Test func withNoOtherRecipientItSaysSoAndChangesNothing() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let (session, introducer, _) = try await Self.reply(f, withOthers: false)
        session.updateBody(doc("Typed"))
        #expect(await f.run(.instantIntro, in: session), "handled: the key is consumed")
        #expect(f.toasts.contains("No one to introduce"))
        #expect(session.to.tokens == [introducer] && session.cc.tokens.isEmpty && session.bcc.tokens.isEmpty)
        #expect(!session.showsBcc && session.plainText == "Typed")

        #expect(await f.run(.instantIntro, in: session))
        #expect(f.toasts.filter { $0 == "No one to introduce" }.count == 1, "a repeat replaces the notice")
    }

    @Test func inANewMessageItSaysWhereItWorks() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        session.to.setTokens([ana])
        session.updateBody(doc("Typed"))
        #expect(f.env.actions.availability(.instantIntro, host: session, context: session.actionContext())
            == .disabled(.instantIntroNeedsReply))
        #expect(await f.run(.instantIntro, in: session))
        #expect(f.toasts.contains(Self.needsReply))
        #expect(session.to.tokens == [ana] && session.bcc.tokens.isEmpty && session.plainText == "Typed")
    }

    @Test func outsideAComposerTheReasonIsUnchanged() async {
        let f = ComposeFixture()
        await f.loaded()
        #expect(await f.run(.instantIntro))
        #expect(f.toasts.contains(Self.needsReply))
    }
}
