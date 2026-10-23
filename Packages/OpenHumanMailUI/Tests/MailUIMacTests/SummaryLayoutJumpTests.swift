import AppKit
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Synchronization
import Testing
@testable import MailUIMac

final class GatedSummaryProvider: AIProvider, Sendable {
    let id: AIProviderID = .fake
    let displayName = "Gated model"
    let gatesLine: Bool
    private let open = Mutex<[AsyncThrowingStream<AIEvent, Error>.Continuation]>([])
    private let lines = Mutex<[AsyncThrowingStream<AIEvent, Error>.Continuation]>([])

    init(gatesLine: Bool = false) { self.gatesLine = gatesLine }

    func capabilities() async -> AICapabilities { .fake() }
    func availability() async -> AIAvailability { .available }
    func countTokens(_ text: String) async -> Int { TokenHeuristic.count(text) }
    func modelVersion() async -> String? { nil }
    func consentFingerprint() async -> String? { nil }

    func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        let isLine: Bool
        switch (request.task, request.promptID.name) {
        case (.summarize, PromptName.summarizeThread.rawValue): isLine = false
        case (.summarize, PromptName.summarizeLine.rawValue) where gatesLine: isLine = true
        default: return FakeAIProvider.stream(FakeAIProvider.cannedScript(request), providerID: id)
        }
        let (stream, continuation) = AsyncThrowingStream<AIEvent, Error>.makeStream()
        continuation.yield(.started(providerID: id, model: "gated"))
        if isLine {
            lines.withLock { $0.append(continuation) }
        } else {
            open.withLock { $0.append(continuation) }
        }
        return stream
    }

    var isWritingLine: Bool { lines.withLock { !$0.isEmpty } }

    func finishLine(_ text: String) {
        lines.withLock { runs in
            for run in runs {
                run.yield(.textDelta(text))
                run.yield(.finished(usage: nil))
                run.finish()
            }
            runs.removeAll()
        }
    }

    var isWaiting: Bool { open.withLock { !$0.isEmpty } }

    func write(_ text: String) {
        open.withLock { $0.last?.yield(.textDelta(text)) }
    }

    func finish() {
        open.withLock { runs in
            runs.last?.yield(.finished(usage: nil))
            runs.last?.finish()
            runs.removeAll()
        }
    }
}

@MainActor
@Suite(.serialized) struct SummaryLayoutJumpTests {
    nonisolated static let sentence = "The team agreed on the plan and asks for the budget by Friday. "

    @MainActor final class Kept {
        var hosts: [StubHost] = []
        var windows: [NSWindow] = []
    }
    let kept = Kept()

    @MainActor struct Reader {
        let controller: ReaderViewController
        let model: ReaderModel
        let center: AICenter
        let line: ThreadSummaryLineView
        let card: NSView

        var summary: ThreadSummaryModel { center.summary(for: model.thread) }

        func layout() { controller.view.layoutSubtreeIfNeeded() }

        func onScreen(_ view: NSView) -> NSRect {
            layout()
            return view.convert(view.bounds, to: nil)
        }

        var textToCard: CGFloat { onScreen(line.textLabel).minY - onScreen(card).maxY }

        var oneLineSettled: Bool {
            let lines = center.threadLines
            return !lines.isGenerating(model.thread) && line.oneLine.isHidden == (lines.line(for: model.thread) == nil)
        }
    }

    func reader(_ provider: any AIProvider, settings: AISettings = AISettings()) async throws -> Reader {
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                      options: .init(remoteAck: .immediate), featureFlags: FeatureFlags(), ai: center)
        let router = env.router
        router.start()
        try await wait("the list and both accounts") { router.list?.state == .loaded && router.accounts.count == 2 }
        let rows = try await env.data.threadPage(.system(.inbox), account: AccountID(1), after: nil, limit: 500).rows
        var thread: ThreadKey?
        for row in rows {
            for try await detail in env.data.threadDetail(row.id) {
                if (detail?.messages.count ?? 0) >= 3 { thread = row.id }
                break
            }
            if thread != nil { break }
        }
        let controller = ReaderViewController(theme: .light, webKit: TestWebKit.noNetwork,
                                              preferences: ReaderPreferences(defaults: nil))
        let host = StubHost(router)
        controller.host = host
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1200, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrame(NSRect(x: -5000, y: -5000, width: 1200, height: 900), display: false)
        kept.hosts.append(host)
        kept.windows.append(window)
        let model = ReaderModel(thread: try #require(thread), data: env.data, renderQueue: env.renderQueue)
        controller.model = model
        model.start()
        try await wait("the conversation and its summary block") {
            model.state == .loaded && controller.aiAccessory != nil
        }
        let line = try #require(controller.aiAccessory as? ThreadSummaryLineView)
        let column = try #require(line.superview as? NSStackView)
        let index = try #require(column.arrangedSubviews.firstIndex { $0 === line })
        try await wait("the first card") { column.arrangedSubviews.count > index + 1 }
        return Reader(controller: controller, model: model, center: center, line: line,
                      card: column.arrangedSubviews[index + 1])
    }

    func wait(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
              _ condition: @MainActor () async -> Bool) async throws {
        do {
            try await until(condition)
        } catch {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            throw error
        }
    }

    static var oneLine: CGFloat {
        let probe = NSTextField(labelWithString: "Xg")
        probe.font = ThemeTokens.light.typeReader.font
        return probe.fittingSize.height
    }

    @Test func theSummaryTextEnds16PointsAboveTheFirstCard() async throws {
        let provider = ScriptedProvider { request, _ in
            request.task == .summarize ? .text(Self.sentence) : FakeAIProvider.cannedScript(request)
        }
        let reader = try await reader(provider)
        try await wait("the summary settled") { reader.summary.phase == .done && reader.line.stage == .settled }
        #expect(reader.onScreen(reader.card).width == 720, "the column is 720 pt wide in this window")
        #expect(abs(reader.textToCard - 16) < 0.5, "16 pt from the text to the first card, was \(reader.textToCard)")
        #expect(abs(reader.onScreen(reader.line).minY - reader.onScreen(reader.line.textLabel).minY) < 0.5,
                "nothing under the text inside the block")
        reader.controller.model = nil
    }

    @Test func withNoBlockTheCardsSit32PointsUnderTheSubject() async throws {
        let reader = try await reader(GatedSummaryProvider(), settings: AISettings(enabled: false))
        try await Task.sleep(for: .milliseconds(200))
        #expect(reader.line.isHidden && reader.line.stage == .absent)
        let subject = reader.onScreen(reader.controller.subjectContainer)
        let gap = subject.minY - reader.onScreen(reader.card).maxY
        #expect(abs(gap - 32) < 0.5, "32 pt under the subject row, was \(gap)")
        reader.controller.model = nil
    }

    @Test func whileWrittenTheTextHoldsFourLinesAndTheCardStays() async throws {
        let provider = GatedSummaryProvider()
        let reader = try await reader(provider)
        try await wait("the summary being written") {
            provider.isWaiting && reader.line.stage == .generating && reader.oneLineSettled
        }
        let label = reader.line.textLabel
        let card = reader.onScreen(reader.card)
        let box = reader.onScreen(label).height
        #expect(box >= 3.5 * Self.oneLine && box <= 4.5 * Self.oneLine, "4 lines held while Thinking, was \(box)")

        provider.write("The team ")
        try await wait("the first chunk") { reader.summary.phase == .streaming && label.stringValue == "The team " }
        #expect(reader.onScreen(reader.card) == card, "the first card does not move for a chunk")
        #expect(reader.onScreen(label).height == box)

        provider.write(String(repeating: Self.sentence, count: 9))
        try await wait("the long chunk") { label.stringValue.count > 500 }
        #expect(reader.onScreen(reader.card) == card, "nor for a long one")
        #expect(reader.onScreen(label).height == box)
        #expect(label.maximumNumberOfLines == SummaryBlockLayout.reservedLines)
        let natural = label.intrinsicContentSize.height
        #expect(natural >= 3.5 * Self.oneLine && natural <= 4.5 * Self.oneLine,
                "it wraps to 4 lines (and truncates the last one), not 1: \(natural)")
        #expect(abs(reader.textToCard - 16) < 0.5)
        provider.finish()
        reader.controller.model = nil
    }

    @Test func settlingShorterThanFourLinesKeepsTheFirstCardInPlace() async throws {
        let provider = GatedSummaryProvider()
        let reader = try await reader(provider)
        try await wait("the summary being written") {
            provider.isWaiting && reader.line.stage == .generating && reader.oneLineSettled
        }
        provider.write(Self.sentence)
        try await wait("the text") { reader.line.textLabel.stringValue == Self.sentence }
        let card = reader.onScreen(reader.card)
        let subject = reader.onScreen(reader.controller.subjectContainer)

        provider.finish()
        try await wait("the summary settled") { reader.summary.phase == .done && reader.line.stage == .settled }
        #expect(reader.onScreen(reader.card) == card, "the first card stays where it was on screen")
        #expect(abs(reader.textToCard - 16) < 0.5, "and the text still ends 16 pt above it")
        #expect(reader.onScreen(reader.controller.subjectContainer).maxY < subject.maxY - Self.oneLine,
                "the subject and the summary moved down to it instead")
        reader.controller.model = nil
    }

    @Test func theOneLineSummaryComingInDoesNotMoveTheCards() async throws {
        let provider = GatedSummaryProvider(gatesLine: true)
        let reader = try await reader(provider)
        try await wait("the summary and the one-line summary being written") {
            provider.isWaiting && provider.isWritingLine && reader.line.stage == .generating
                && !reader.line.oneLinePlaceholder.isHidden
        }
        let card = reader.onScreen(reader.card)
        provider.finishLine("Dana and Robin move the launch review to Thursday.")
        try await wait("the one-line summary shown") { !reader.line.oneLine.isHidden }
        #expect(reader.onScreen(reader.card) == card, "the line takes its placeholder's place: nothing under it moves")
        provider.finish()
        reader.controller.model = nil
    }

    @Test func settlingLongerThanFourLinesKeepsTheFirstCardInPlace() async throws {
        let provider = GatedSummaryProvider()
        let reader = try await reader(provider)
        try await wait("the summary being written") {
            provider.isWaiting && reader.line.stage == .generating && reader.oneLineSettled
        }
        let long = String(repeating: Self.sentence, count: 9)
        provider.write(long)
        try await wait("the text") { reader.line.textLabel.stringValue == long }
        let card = reader.onScreen(reader.card)

        provider.finish()
        try await wait("the summary settled") { reader.summary.phase == .done && reader.line.stage == .settled }
        #expect(reader.onScreen(reader.card) == card, "the first card stays where it was on screen")
        #expect(reader.onScreen(reader.line.textLabel).height > 4.5 * Self.oneLine, "the whole summary shows")
        #expect(abs(reader.textToCard - 16) < 0.5)
        #expect(reader.controller.visibleDocumentRect.minY > 0, "the conversation scrolled by what the text grew")
        reader.controller.model = nil
    }
}
