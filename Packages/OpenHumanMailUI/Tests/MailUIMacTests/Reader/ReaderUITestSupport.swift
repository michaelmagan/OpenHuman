import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import OpenHumanCore
import Testing
import WebKit
@testable import MailUIMac

final class UITestSource: MailDataSource, @unchecked Sendable {
    private let details: [ThreadKey: ConversationDetail]
    private let bodies: [MessageKey: MessageContent]
    private let files: [Int64: URL]

    init(details: [ConversationDetail], bodies: [MessageKey: MessageContent], files: [Int64: URL] = [:]) {
        self.details = Dictionary(uniqueKeysWithValues: details.map { ($0.id, $0) })
        self.bodies = bodies
        self.files = files
    }

    func accounts() -> AsyncThrowingStream<[Account], Error> {
        AsyncThrowingStream { $0.yield([]); $0.finish() }
    }

    func threadWindow(_ location: MailLocation, account: AccountID, limit: Int) -> AsyncThrowingStream<ThreadListWindow, Error> {
        AsyncThrowingStream { $0.yield(ThreadListWindow(rows: [], hasMore: false, totalCount: 0)); $0.finish() }
    }

    func threadDetail(_ key: ThreadKey) -> AsyncThrowingStream<ConversationDetail?, Error> {
        let detail = details[key]
        return AsyncThrowingStream { $0.yield(detail); $0.finish() }
    }

    func body(_ key: MessageKey) -> AsyncThrowingStream<BodyLoadState, Error> {
        let content = bodies[key]
        return AsyncThrowingStream { $0.yield(content.map(BodyLoadState.available) ?? .failed("missing")); $0.finish() }
    }

    func attachmentData(_ key: MessageKey, attachment: AttachmentInfo) async throws -> URL {
        guard let url = files[attachment.id] else { throw MailPortError.notFound("attachment") }
        return url
    }
}

@MainActor
final class StubHost: ReaderHost {
    let router: AppRouter
    init(_ router: AppRouter) { self.router = router }
    var readerRouter: AppRouter? { router }
}

enum UIFixtures {
    static let account = AccountID(1)
    static let me = EmailAddress(name: "Robin Example", email: "robin@example.com")
    static let dana = EmailAddress(name: "Dana Ruiz", email: "dana@news.example.com")

    static func thread(_ row: Int64) -> ThreadKey { ThreadKey(account: account, rowID: row, gmailThreadID: GmailThreadID("t\(row)")) }
    static func message(_ row: Int64) -> MessageKey { MessageKey(account: account, rowID: row, gmailMessageID: GmailMessageID("m\(row)")) }

    static func summary(_ row: Int64, from: EmailAddress = dana, unread: Bool = false, minutesAgo: Double = 60,
                        attachments: [AttachmentInfo] = [], cc: [EmailAddress] = []) -> MessageSummary {
        MessageSummary(id: message(row), from: from, to: [me, EmailAddress(name: "Sam", email: "sam@example.com")], cc: cc, bcc: [],
                       date: Date().addingTimeInterval(-minutesAgo * 60), snippet: "Snippet \(row)", isUnread: unread,
                       attachments: attachments)
    }

    static func conversation(_ row: Int64, count: Int, unread: Set<Int> = [], subject: String = "Quarterly plan") -> ConversationDetail {
        ConversationDetail(id: thread(row), subject: subject, messages: (0..<count).map { i in
            summary(row * 100 + Int64(i), unread: unread.contains(i), minutesAgo: Double((count - i) * 60))
        })
    }

    static let newsletterHTML = """
    <table width="560"><tr><td style="background:#ffffff;color:#33415c"><p>This week in planning.</p>
    <img src="https://images.news.example/chart.png" width="400" height="200" alt="Chart">
    <img src="https://images.news.example/photo.png" width="400" height="200" alt="Photo">
    <img src="https://open.news.example/track/open?u=1" width="1" height="1" alt=""></td></tr></table>
    """

    static let gmailReplyHTML = """
    <div dir="ltr">Sounds good, Thursday works.</div><br><div class="gmail_quote"><div class="gmail_attr">On Tue, Sam wrote:</div>
    <blockquote class="gmail_quote">\(String(repeating: "<p>Can we move the review? Wednesday is packed.</p>", count: 8))</blockquote></div>
    """
}

// Images-allowed mode also blocks remote loads, so tests never make a network request
@MainActor
enum TestWebKit {
    static let noNetwork: ReaderWebKit = ReaderWebKit(imagesRules: ReaderWebKit.blockAllRemoteRules,
                                                       imagesIdentifier: "dev.openhuman.mail.tests.images-blocked.v1")
}

@MainActor
struct ReaderHarness {
    let environment: AppEnvironment
    let router: AppRouter
    let controller: ReaderViewController
    let window: NSWindow
    let model: ReaderModel
    let store: FakeMailStore
    let pasteboard: NSPasteboard
    let host: StubHost

    static func make(_ source: UITestSource, thread: ThreadKey, theme: ThemeTokens = .light,
                     webKit: ReaderWebKit = TestWebKit.noNetwork, windowRouter: Bool = false) async throws -> ReaderHarness {
        await webKit.prepare()
        let store = FakeMailStore(corpus: .make(threadCount: 3, now: Date()), options: .init())
        let environment = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true)
        let router = windowRouter ? environment.router : AppRouter(environment: environment)
        router.start()
        // A window reads a conversation only through its active account, so the reader is never bound before one
        try await until { router.active != nil }
        let controller = ReaderViewController(theme: theme, webKit: webKit, preferences: ReaderPreferences(defaults: nil))
        let host = StubHost(router)
        controller.host = host
        controller.openInBrowser = { _, _ in Issue.record("opened a browser") }
        controller.openFile = { _ in Issue.record("opened a file") }
        controller.quickLook = { _, _ in Issue.record("opened Quick Look") }
        controller.confirmRiskyAttachment = { _, _ in
            Issue.record("asked before opening an attachment")
            return false
        }
        let frame = (NSScreen.main ?? NSScreen.screens.first).map {
            NSRect(x: $0.visibleFrame.minX, y: $0.visibleFrame.minY, width: 1200, height: 900)
        } ?? NSRect(x: -5000, y: -5000, width: 1200, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentViewController = controller
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        let model = ReaderModel(thread: thread, data: source, renderQueue: environment.renderQueue)
        controller.model = model
        model.start()
        try await until { model.state == .loaded }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.openhuman.mail.tests.\(UUID().uuidString)"))
        return ReaderHarness(environment: environment, router: router, controller: controller, window: window, model: model,
                             store: store, pasteboard: pasteboard, host: host)
    }

    func close() {
        controller.model = nil
        window.close()
        pasteboard.releaseGlobally()
    }

    func container(_ key: MessageKey) -> MessageContainerView? { controller.messageViews[key] }

    func header(_ key: MessageKey) async throws -> MessageHeaderView {
        try await until { container(key)?.header != nil }
        return try #require(container(key)?.header)
    }

    func shownWebView(_ key: MessageKey) async throws -> ReaderWebView {
        try await until { container(key)?.htmlBody?.current?.isShown == true && container(key)?.htmlBody?.incoming == nil }
        return try #require(container(key)?.htmlBody?.current)
    }

    var toasts: [String] { environment.notices.toasts.map(\.message) }
}

@MainActor
enum Keys {
    static func event(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    enum Arrow { case up, down }

    static func arrow(_ arrow: Arrow, modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        let character = arrow == .up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey
        return event(String(Character(UnicodeScalar(UInt16(character))!)), code: arrow == .up ? 126 : 125,
                     modifiers: modifiers.union([.numericPad, .function]), window: window)
    }

    static func tab(modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        event("\t", code: 48, modifiers: modifiers, window: window)
    }
}

@MainActor
func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { subviews(of: type, in: $0) }
}
