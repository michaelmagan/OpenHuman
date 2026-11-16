import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct KeymapFixesTests {
    @MainActor
    final class RecordingEditor: ComposeTextEditing, ComposeFormatting {
        var applied: [ActionID] = []
        var editorText: String { "" }
        var editorSelection: Range<Int> { 0..<0 }
        func replaceText(in range: Range<Int>, with text: String) -> Bool { false }
        func focusEditor() {}
        func applyFormatting(_ action: ActionID) -> Bool {
            guard ActionCatalog.formatIDs.contains(action) else { return false }
            applied.append(action)
            return true
        }
    }

    static let fieldKeys: [ActionID] = [.showCc, .showBcc, .focusTo, .closeComposer]

    @Test func theComposerFieldKeysShowFocusAndClose() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let registry = f.env.actions
        for id in Self.fieldKeys {
            #expect(registry.availability(id, host: f.router) == .hidden, "\(id) with no composer")
        }
        let session = try #require(f.compose.openNew(placement: .modal))
        for id in Self.fieldKeys {
            #expect(registry.availability(id, host: session) == .enabled, "\(id)")
            #expect(registry.availability(id, host: f.router) == .enabled, "\(id): the window's keys are the composer's")
        }
        #expect(await f.run(.showCc, in: session))
        #expect(session.showsCc && session.cc.focusRequest == 1, "⇧⌘C shows Cc and puts the caret in it")
        #expect(await f.run(.showBcc, in: session))
        #expect(session.showsBcc && session.bcc.focusRequest == 1)
        let toRequests = session.to.focusRequest
        #expect(await f.run(.focusTo, in: session))
        #expect(session.to.focusRequest == toRequests + 1, "⇧⌘T")
        #expect(await f.run(.closeComposer, in: session))
        #expect(!session.isOpen && f.compose.windowSession == nil, "closed like the close button")
    }

    @Test func formattingReachesTheEditorFromThePaletteAndTheMenus() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let registry = f.env.actions
        #expect(registry.availability(.formatBold, host: session) == .hidden, "no body editor on screen yet")
        let editor = RecordingEditor()
        session.editor = editor
        for id in ActionCatalog.formatIDs {
            #expect(registry.availability(id, host: session) == .enabled, "\(id)")
            #expect(await f.run(id, in: session), "\(id)")
        }
        #expect(editor.applied == ActionCatalog.formatIDs)
        #expect(ActionCatalog.formatIDs.allSatisfy { ActionCatalog.descriptor($0)?.changesMail == false })
        f.compose.close(session)
        #expect(registry.availability(.formatBold, host: f.router) == .hidden)
    }

    @Test func escLeavesTheReviewQueueForTheInbox() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let registry = f.env.actions
        #expect(registry.availability(.reviewLeave, host: f.router) == .hidden, "outside the queue Esc is the list's")
        #expect(await f.run(.goReview))
        let review = f.env.review
        await soon { review.isOpen }
        #expect(f.router.actionContext().scope == .review)
        #expect(registry.descriptor(.reviewLeave)?.defaultBindings.map(\.description) == ["Esc"])
        #expect(await f.run(.reviewLeave))
        await soon { !review.isOpen }
        #expect(f.router.actionContext().scope == .list && f.router.actionContext().isInInbox)
        #expect(f.recorder.calls.filter { ReviewQueueTests.mutations.contains($0) }.isEmpty, "leaving writes nothing")
    }

    @Test func commandFInAConversationOpensItsFindBar() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let registry = f.env.actions
        #expect(registry.availability(.findInConversation, host: f.router) == .hidden, "in the list ⌘F is Search")
        let thread = try #require(f.router.list?.cursor)
        f.router.open(thread)
        await soon { f.router.reader?.state == .loaded }
        let reader = try #require(f.router.reader)
        #expect(registry.availability(.findInConversation, host: f.router) == .enabled)
        #expect(await f.run(.findInConversation))
        #expect(reader.findRequest == 1, "the view opens its find bar once per request")
        #expect(registry.descriptor(.findInConversation)?.menuKeyEquivalent == nil, "the key router owns ⌘F")
        #expect(registry.descriptor(.search)?.menuKeyEquivalent == nil, "Search's ⌘F is the list's only")
    }

    @Test func theHintBarAndTheEmptyStatesNameTheCurrentKeys() {
        let conversation = HintBar.hints(for: .conversation, descriptors: ActionCatalog.all) { _ in .enabled }
        let returnHint = conversation.first { $0.keycaps == ["↵"] }
        #expect(returnHint?.action == .openMessageOrReply, "the hint is what ↵ does")
        #expect(returnHint?.title == (ActionCatalog.returnRepliesAll ? "Reply all" : "Reply"))
        let list = HintBar.hints(for: .list, descriptors: ActionCatalog.all) { _ in .enabled }
        #expect(list.first { $0.action == .remind }?.keycaps == [ActionCatalog.remindOnH ? "H" : "⇧H"])

        func empty(_ location: MailLocation) -> ThreadListEmptyState? {
            ThreadListEmptyState.make(location: location, locationTitle: "", state: .loaded, hasRows: false,
                                      loadingShown: false, connectivity: nil, day: 0)
        }
        let remindKey = ActionCatalog.descriptor(.remind)?.shortcutHint ?? "?"
        let snoozeKey = ActionCatalog.descriptor(.snooze)?.shortcutHint ?? "?"
        #expect(empty(.system(.reminders))?.title.contains("Press \(remindKey) on") == true)
        #expect(empty(.system(.snoozed))?.subtitle?.contains("Press \(snoozeKey) on") == true)
    }
}
