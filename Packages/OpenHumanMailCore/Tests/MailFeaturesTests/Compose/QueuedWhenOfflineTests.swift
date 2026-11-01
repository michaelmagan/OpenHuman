import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct QueuedWhenOfflineTests {
    private func reply(_ f: ComposeFixture) async throws -> ComposeSession {
        await f.loaded()
        #expect(await f.run(.reply))
        let session = try #require(f.compose.windowSession)
        await session.settle()
        session.updateBody(doc("On it"))
        return session
    }

    private func state(_ f: ComposeFixture, _ session: ComposeSession) -> SendingMessage.State? {
        f.compose.sending.first { $0.id == session.id }?.state
    }

    @Test func onlineASendStillGoingOutAfterItsWindowIsNeverCalledQueued() async throws {
        let f = ComposeFixture(liveConnectivity: true)
        let session = try await reply(f)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        f.heldGate.release()
        await soon { state(f, session) == .sending }
        let going = try #require(f.compose.sending.first { $0.id == session.id })
        #expect(f.compose.sendingStatus(going, now: fixedNow) == "Sending…")
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(!f.postedToasts.contains(QueuedSendNotice.text), "online: no 'back online' toast")
        #expect(state(f, session) == .sent)
    }

    @Test func offlineAtTheEndOfTheWindowSaysQueuedAndBackOnlineTakesItAway() async throws {
        let f = ComposeFixture(liveConnectivity: true)
        let session = try await reply(f)
        f.store.setConnectivity(.offline(since: fixedNow), for: ComposeFixture.work)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        f.heldGate.release()
        await f.toast(QueuedSendNotice.text)
        #expect(state(f, session) == .waitingForConnection)

        f.store.setConnectivity(.online(syncing: false, lastSyncAt: fixedNow), for: ComposeFixture.work)
        await soon { !f.toasts.contains(QueuedSendNotice.text) && state(f, session) == .sending }
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(f.postedToasts.filter { $0 == QueuedSendNotice.text }.count == 1)
    }

    @Test func goingOfflineWhileTheSendWaitsSaysQueuedOnce() async throws {
        let f = ComposeFixture(liveConnectivity: true)
        let session = try await reply(f)
        #expect(await f.run(.send, in: session))
        await f.toast("Reply sent.")
        f.heldGate.release()
        await soon { state(f, session) == .sending }
        #expect(!f.postedToasts.contains(QueuedSendNotice.text))
        f.store.setConnectivity(.offline(since: fixedNow), for: ComposeFixture.work)
        await f.toast(QueuedSendNotice.text)
        f.store.setConnectivity(.offline(since: fixedNow.addingTimeInterval(5)), for: ComposeFixture.work)
        f.store.completeHeldSends()
        await f.posted("Sent.")
        #expect(f.postedToasts.filter { $0 == QueuedSendNotice.text }.count == 1)
        #expect(!f.toasts.contains(QueuedSendNotice.text), "the outcome takes the queued toast away")
    }
}
