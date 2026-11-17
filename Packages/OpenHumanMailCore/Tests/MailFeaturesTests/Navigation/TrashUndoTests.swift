import Foundation
import MailActions
import MailFakes
import MailModel
import Testing
@testable import MailFeatures

@MainActor
@Suite struct TrashUndoTests {
    @Test func zAfterTrashPutsTheConversationBack() async throws {
        let env = AppEnvironment.fake(corpus: .small)
        let store = try #require(env.data as? FakeMailStore)
        let router = env.router
        router.start()
        await eventually { router.list?.state == .loaded && (router.list?.rows.count ?? 0) > 3 }
        router.perform(.nextThread)
        let target = try #require(router.list?.cursor)
        let count = try #require(router.list?.rows.count)
        #expect(router.perform(.trash))
        await eventually { env.notices.toasts.contains { $0.message == "Moved to Trash" } }
        await eventually { router.list?.rows.count == count - 1 }
        // The bug showed only once the server had taken the trash, not while it was still queued
        await eventually { store.pendingOperationCount == 0 }
        let account = try #require(router.active?.account.id)
        let trash = try await env.data.threadPage(.system(.trash), account: account, after: nil, limit: 500).rows
        #expect(trash.contains { $0.id == target }, "the conversation is in Trash")
        #expect(router.list?.rows.count == count - 1, "and stays out of the list")
        #expect(router.perform(.undo))
        await eventually { router.list?.rows.count == count }
        #expect(router.list?.index(of: target) != nil)
    }
}
