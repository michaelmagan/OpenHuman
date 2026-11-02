import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
struct OneSuggestionStage {
    let w: InlineReplyWindow
    let store: FakeMailStore
    let calendar: FakeCalendar
    let assistant: SchedulingAssistant
    let center: AICenter?
    let thread: ThreadKey
    let message: MessageKey

    var environment: AppEnvironment { w.environment }
    var router: AppRouter { w.router }
    var reader: ReaderViewController { w.reader }

    nonisolated static let zone = TimeZone(identifier: "America/Los_Angeles")!

    nonisolated static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    nonisolated static let sent = at(12, 9)
    nonisolated static let meeting = CalendarEvent(id: "ev-review", title: "Design review", start: at(13, 12), end: at(13, 13),
                                       attendees: [EmailAddress(name: "Sam Rivera", email: "sam@example.org")],
                                       organizerIsMe: true)
    nonisolated static let proposal = "Hi, thanks for sending this over. How about 12pm tomorrow?"

    static func make(busy: Bool = true, ai: Bool = true, composerStrip: Bool = false, theme: SweepTheme? = nil,
                     text: String = proposal, frameName: String,
                     size: NSSize = NSSize(width: 1100, height: 900)) async throws -> OneSuggestionStage {
        let center: AICenter? = ai ? AICenter.make(
            registry: ProviderRegistry(providers: [ScriptedProvider(displayName: "Apple on-device model")]),
            settings: AISettingsBox(store: InMemoryAISettingsStore(
                AISettings(draftReplies: .onDeviceAuto, instantReplyStrip: composerStrip)))) : nil
        let calendar = FakeCalendar(events: busy ? [meeting] : [])
        // Why: a corpus dated from today buries the fixed-date message further down the inbox every day
        let environment = AppEnvironment.fake(corpus: .rich(threadCount: 200, now: sent),
                                              options: .init(remoteAck: .immediate, now: { OneSuggestionStage.sent }),
                                              featureFlags: FeatureFlags(), ai: center, calendar: calendar)
        let store = try #require(environment.data as? FakeMailStore)
        let assistant = try #require(environment.scheduling)
        assistant.timeZone = zone
        assistant.now = { sent }
        let w: InlineReplyWindow
        if let theme {
            w = try await SweepWindow.make(environment, theme: theme, size: size)
        } else {
            w = try await InlineReplyWindow.make(size: size, frameName: frameName, exclusive: true,
                                                 environment: environment)
        }
        do {
            let account = try #require(environment.router.accounts.first?.account)
            let message = store.deliverMessage(account: account.id, from: EmailAddress(name: "Dana Ruiz", email: "dana@example.org"),
                                               subject: "Sync up", text: text, unread: false, at: sent)
            let thread = try #require(try await Self.thread(of: message, in: store, account: account.id))
            return OneSuggestionStage(w: w, store: store, calendar: calendar, assistant: assistant, center: center,
                                      thread: thread, message: message)
        } catch {
            // Why: the caller gets no stage to close, and an open window holds the focus gate
            w.close()
            throw error
        }
    }

    private static func thread(of message: MessageKey, in store: FakeMailStore, account: AccountID) async throws -> ThreadKey? {
        let rows = try await store.threadPage(.system(.inbox), account: account, after: nil, limit: 50).rows
        for row in rows {
            for try await detail in store.threadDetail(row.id) {
                if detail?.messages.contains(where: { $0.id == message }) == true { return row.id }
                break
            }
        }
        return nil
    }

    func close() { w.close() }

    func open() async throws {
        _ = try await w.open(thread)
        _ = w.window.makeFirstResponder(reader.focusView)
        let assistant = self.assistant
        let thread = self.thread
        await assistant.analyze(thread)
        try await until { assistant.status[thread] != .checking }
        if let center {
            try await until(timeout: .seconds(20)) {
                guard let row = center.inlineReplies.current else { return false }
                return row.decision != .undecided && (row.state == .ready || row.state == .none)
            }
        }
        w.window.contentView?.layoutSubtreeIfNeeded()
    }

    func body() async throws -> ComposerTextView {
        let composer = try await w.inlineComposer()
        try await until {
            w.window.contentView?.layoutSubtreeIfNeeded()
            return subviews(of: ComposerTextView.self, in: composer).first != nil
        }
        return try #require(subviews(of: ComposerTextView.self, in: composer).first)
    }
}
