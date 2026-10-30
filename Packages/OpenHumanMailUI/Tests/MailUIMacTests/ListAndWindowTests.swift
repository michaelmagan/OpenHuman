import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailRender
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

private let now = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized)
struct ListAndWindowTests {
    @Test func rowColumnsFollowTheDesignGeometry() {
        let c = ThreadRowView.columns(width: 1000)
        #expect(c.dotCenterX == 21, "plate inset 8, checkbox clearance 6, half the 14 pt box; no cursor bar")
        #expect(c.sender == 40...260)
        #expect(c.subject.lowerBound == 276)
        #expect(c.date == 904...976)
        #expect(c.indicators == 864...904)
        #expect(c.subject.upperBound == 848)
        #expect(ThreadRowView.columns(width: 500).sender == 40...200)
        #expect(ThreadRowView.columns(width: 2000).sender == 40...280)
    }

    @Test func listShowsTheWindowAndMirrorsTheCursor() async throws {
        let store = FakeMailStore(corpus: .make(threadCount: 150, now: now))
        let model = ThreadListModel(data: store, location: .system(.inbox), account: AccountID(1))
        let controller = ThreadListViewController(theme: .light)
        let window = Self.window(controller.view)
        controller.model = model
        model.start()
        try await until { controller.tableView.numberOfRows == 150 && model.rows.count == 100 }
        #expect(controller.tableView.rowHeight == 40)
        try await until { controller.tableView.selectedRow == 0 }
        model.moveCursor(by: 3)
        try await until { controller.tableView.selectedRow == 3 }
        let cell = try #require(controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? ThreadRowView)
        #expect(Self.containsHostingView(cell) == false, "no NSHostingView inside cells")
        #expect(cell.accessibilityLabel()?.isEmpty == false)
        store.removeThreads([model.rows[3].id])
        try await until { controller.tableView.numberOfRows == 149 && model.totalCount == 149 }
        #expect(controller.tableView.selectedRow == 3)
        window.close()
    }

    @Test func returnOpensTheReaderAndEscapeComesBack() async throws {
        let environment = AppEnvironment.fake(corpus: .make(threadCount: 20, now: now))
        let content = MainContentViewController(router: AppRouter(environment: environment))
        let window = Self.window(content.view)
        content.keyRouter.isMailWindow = { $0 === window }
        try await until { content.windowModel.list?.rows.count == 20 }
        func key(_ chars: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        #expect(content.keyRouter.route(key("j", 38)) == nil)
        #expect(content.keyRouter.route(key("\r", 36)) == nil)
        #expect(content.windowModel.mode == .reader)
        let reader = try #require(content.windowModel.reader)
        #expect(reader.thread == content.windowModel.list?.rows[1].id)
        try await until { reader.state == .loaded }
        #expect(content.keyRouter.route(key("j", 38)) == nil)
        #expect(content.windowModel.reader?.thread == content.windowModel.list?.rows[2].id)
        #expect(content.keyRouter.route(key("\u{1B}", 53)) == nil)
        #expect(content.windowModel.mode == .list)
        #expect(content.windowModel.list?.cursorIndex == 2)
        window.close()
    }

    @Test func plainTextBodyLaysOutWithLinks() throws {
        let document = PlainTextDocument.parse("Hello https://example.com/x\n\n> quoted\n-- \nDana")
        let view = PlainTextMessageView(document, theme: .light)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: 500),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let window = Self.window(container)
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        #expect(view.measuredHeight >= 4 * 22)
        #expect(view.frame.height == view.measuredHeight)
        #expect(view.textView.frame.height == view.measuredHeight)
        let storage = try #require(view.textView.textStorage)
        let link = storage.attribute(.link, at: storage.string.distance(of: "https") ?? 0, effectiveRange: nil) as? URL
        #expect(link == URL(string: "https://example.com/x"))
        #expect(!view.textView.isEditable)
        window.close()
    }

    @Test func plainTextKeepsItsLinesAndDrawsQuoteBars() throws {
        let document = PlainTextDocument.parse("> Can you send it?\nAttached.\n> > And the deck?\nTomorrow.")
        let view = PlainTextMessageView(document, theme: .light)
        #expect(view.textView.string == "Can you send it?\nAttached.\nAnd the deck?\nTomorrow.")
        #expect(!view.hasFoldedText, "quotes between answers stay visible")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: 500),
            view.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        let window = Self.window(container)
        container.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        let storage = try #require(view.textView.textStorage)
        let nested = (storage.string as NSString).range(of: "And the deck?")
        let style = try #require(storage.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent == 24 && style.firstLineHeadIndent == 24, "two levels of 12 pt")
        let answer = (storage.string as NSString).range(of: "Attached.")
        let plain = try #require(storage.attribute(.paragraphStyle, at: answer.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(plain.headIndent == 0)
        let bars = view.quoteBarRects
        #expect(bars.count == 3, "one bar beside the first quote, two beside the nested one")
        #expect(Set(bars.map(\.minX)) == [0, 12])
        #expect(bars.allSatisfy { $0.width == 2 && $0.height > 0 })
        window.close()
    }

    static func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    static func containsHostingView(_ view: NSView) -> Bool {
        if String(describing: type(of: view)).contains("NSHostingView") { return true }
        return view.subviews.contains(where: containsHostingView)
    }
}

private extension String {
    func distance(of needle: String) -> Int? {
        guard let range = range(of: needle) else { return nil }
        return utf16.distance(from: startIndex, to: range.lowerBound)
    }
}
