import Foundation
import MailActions
import MailFakes
import MailModel
import MailRender
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
final class ComposeFixture {
    let env: AppEnvironment
    let store: FakeMailStore
    let recorder: RecordingCommands
    let router: AppRouter
    let compose: ComposeManager
    let discardGate = TestGate()
    let heldGate = TestGate()
    let stagingDirectory = TemporaryDirectory("oh-compose-fixture")
    private(set) var postedToasts: [String] = []
    static let utc = TimeZone(identifier: "UTC")!

    init(corpus: FakeCorpus = .rich(threadCount: 60, now: fixedNow), flags: FeatureFlags = FeatureFlags(),
         writePort: Bool = true, isLiveAccount: Bool = false, ai: AICenter? = nil, liveConnectivity: Bool = false) {
        store = FakeMailStore(corpus: corpus, options: .init(remoteAck: .immediate, heldSends: .manual,
                                                             liveConnectivity: liveConnectivity, now: { fixedNow }))
        recorder = RecordingCommands(store)
        env = AppEnvironment(data: store, commands: writePort ? recorder : nil, accounts: store, settings: store,
                             isFake: true, featureFlags: flags, ai: ai, isLiveAccount: isLiveAccount)
        router = env.router
        compose = env.compose
        compose.staging = DirectoryAttachmentStaging(directory: stagingDirectory.url)
        let discard = discardGate
        let held = heldGate
        compose.timing = ComposeTiming(autosaveDelay: .milliseconds(1), discardWindow: .seconds(6), now: { fixedNow },
                                       sleep: { duration in
                                           if duration == .milliseconds(1) { return }
                                           if duration == .seconds(6) { await discard.wait() } else { await held.wait() }
                                       })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        compose.calendar = calendar
        compose.locale = Locale(identifier: "en_US_POSIX")
        env.overlays.timeZone = Self.utc
        env.overlays.locale = Locale(identifier: "en_US_POSIX")
        env.overlays.now = { fixedNow }
        env.notices.onPost = { [weak self] toast in self?.postedToasts.append(toast.message) }
        router.start()
    }

    static let work = AccountID(1)

    func loaded() async {
        await eventually(timeout: .seconds(15)) { router.active != nil && router.list?.state == .loaded }
    }

    @discardableResult
    func run(_ id: ActionID, in session: ComposeSession) async -> Bool {
        await env.actions.run(id, source: .keyboard, host: session)
    }

    @discardableResult
    func run(_ id: ActionID) async -> Bool {
        await env.actions.run(id, source: .keyboard, host: router)
    }

    func toast(_ prefix: String) async {
        await eventually(timeout: .seconds(15)) { env.notices.toasts.contains { $0.message.hasPrefix(prefix) } }
    }

    var toasts: [String] { env.notices.toasts.map(\.message) }

    func posted(_ prefixes: String...) async {
        await eventually(timeout: .seconds(15)) {
            var rest = postedToasts[...]
            for prefix in prefixes {
                guard let index = rest.firstIndex(where: { $0.hasPrefix(prefix) }) else { return false }
                rest = rest[(index + 1)...]
            }
            return true
        }
    }

    func draftRow(_ key: DraftKey) async -> DraftSummary? {
        do { for try await row in store.draft(key) { return row } } catch {}
        return nil
    }

    func thread(subject: String) async throws -> ThreadKey {
        let rows = try await store.threadPage(.system(.allMail), account: Self.work, after: nil, limit: 1_000).rows
        return try #require(rows.first { $0.subject == subject }).id
    }

    var timePicker: TimePickerModel? {
        if case .time(let model) = env.overlays.overlay { model } else { nil }
    }
}

func doc(_ text: String) -> RichTextDocument {
    RichTextDocument(blocks: [.paragraph([.text(text, [])])])
}

final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for c in pending { c.resume() }
    }
}

final class Checkpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private var watchers: [CheckedContinuation<Void, Never>] = []
    private let gate = TestGate()

    func pass() async {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            reached = true
            defer { watchers = [] }
            return watchers
        }
        for c in waiting { c.resume() }
        await gate.wait()
    }

    func arrived() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if reached { return true }
                watchers.append(c)
                return false
            }
            if now { c.resume() }
        }
    }

    func release() { gate.release() }
}
