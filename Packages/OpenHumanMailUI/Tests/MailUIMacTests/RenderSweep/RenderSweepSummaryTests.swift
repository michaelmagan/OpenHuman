import AppKit
import MailFakes
import MailFeatures
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.lightAndDark)
    func readerSummaryWrittenAndDone(_ theme: SweepTheme) async throws {
        let provider = GatedSummaryProvider()
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
        let env = AppEnvironment.fake(corpus: .small, options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), ai: center)
        let w = try await SweepWindow.make(env, theme: theme)
        defer { w.close() }
        let account = try #require(w.router.accounts.first?.account)
        let rows = try await env.data.threadPage(.system(.inbox), account: account.id, after: nil, limit: 500).rows
        var threads: [ThreadKey] = []
        for row in rows where threads.count < 2 {
            for try await detail in env.data.threadDetail(row.id) {
                if (detail?.messages.count ?? 0) >= 3 { threads.append(row.id) }
                break
            }
        }
        try #require(threads.count == 2)
        let sentence = SummaryLayoutJumpTests.sentence
        for (thread, (sentences, name)) in zip(threads, [(2, "reader-summary"), (9, "reader-summary-long")]) {
            _ = try await w.open(thread)
            let line = try await Self.summaryLine(w)
            try await until {
                provider.isWaiting && line.stage == .generating && !center.threadLines.isGenerating(thread)
                    && line.oneLine.isHidden == (center.threadLines.line(for: thread) == nil)
            }
            let text = String(repeating: sentence, count: sentences)
            provider.write(text)
            try await until { line.textLabel.stringValue == text }
            let column = try #require(line.superview as? NSStackView)
            let index = try #require(column.arrangedSubviews.firstIndex { $0 === line })
            let card = column.arrangedSubviews[index + 1]
            w.window.contentView?.layoutSubtreeIfNeeded()
            let before = card.convert(card.bounds, to: nil)
            try await sweepShoot(w.window, screen: name + "-writing", theme: theme)

            provider.finish()
            try await until { line.stage == .settled }
            w.window.contentView?.layoutSubtreeIfNeeded()
            #expect(card.convert(card.bounds, to: nil) == before, "the first card did not move when it settled")
            try await sweepShoot(w.window, screen: name + "-done", theme: theme)
        }
    }

    private static func summaryLine(_ w: InlineReplyWindow) async throws -> ThreadSummaryLineView {
        try await until { w.reader.aiAccessory is ThreadSummaryLineView }
        return try #require(w.reader.aiAccessory as? ThreadSummaryLineView)
    }
}
