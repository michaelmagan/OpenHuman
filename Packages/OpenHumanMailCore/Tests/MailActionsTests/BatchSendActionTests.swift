import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailActions

@Suite struct BatchSendActionTests {
    func key(_ row: Int64) -> ThreadKey {
        ThreadKey(account: AccountID(1), rowID: row, gmailThreadID: GmailThreadID("t\(row)"))
    }

    func context(_ location: MailLocation, selection: [ThreadKey], scope: ActionScope = .list,
                 canWrite: Bool = true) -> ActionContext {
        ActionContext(scope: scope, account: AccountID(1), accountCount: 1, location: location, selection: selection,
                      checkedCount: selection.count, focusedThread: selection.first, hasRows: true, canWrite: canWrite)
    }

    func availability(_ c: ActionContext) -> ActionAvailability {
        ActionRules.availability(ActionCatalog.descriptor(.sendDrafts)!, in: c)
    }

    @Test func itIsAListActionOnTheCheckedRowsBoundToCommandReturn() throws {
        let send = try #require(ActionCatalog.descriptor(.sendDrafts))
        #expect(send.scopes == [.list] && send.target == .threads && send.category == .thread)
        #expect(send.effect == .external && send.module == nil && send.appearsInPalette)
        #expect(send.defaultBindings == [.named(.enter, .command)])
        #expect(send.shortcutHint == ActionCatalog.descriptor(.send)?.shortcutHint, "the same key as Send in the composer")
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty)
    }

    @Test func onlyInTheDraftsList() {
        let rows = [key(1), key(2)]
        #expect(availability(context(.system(.drafts), selection: rows)) == .enabled)
        for location: MailLocation in [.system(.inbox), .system(.scheduled), .system(.sent), .system(.done)] {
            #expect(availability(context(location, selection: rows)) == .hidden, "\(location)")
        }
        #expect(availability(context(.system(.drafts), selection: rows, scope: .reader)) == .hidden)
        #expect(availability(context(.system(.drafts), selection: rows, scope: .calendar)) == .hidden)
        #expect(availability(context(.system(.drafts), selection: [])) == .disabled(.noSelection))
        #expect(availability(context(.system(.drafts), selection: rows, canWrite: false))
                == .disabled(.unavailable("Send drafts…")))
    }

    @Test func theTitleCountsTheCheckedDrafts() throws {
        let send = try #require(ActionCatalog.descriptor(.sendDrafts))
        #expect(ActionRules.title(for: send, in: context(.system(.drafts), selection: [key(1)])) == "Send draft…")
        #expect(ActionRules.title(for: send, in: context(.system(.drafts), selection: [key(1), key(2), key(3)]))
                == "Send 3 drafts…")
    }
}
