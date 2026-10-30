import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import MailUI
import Testing
@testable import MailUIMac

extension RenderSweepTests {
    @Test(arguments: SweepTheme.builtIns + SweepTheme.accessibility)
    func readerPolish(_ theme: SweepTheme) async throws {
        let w = try await SweepWindow.make(SweepWindow.environment(), theme: theme)
        defer { w.close() }
        let (thread, _) = try await w.longestConversation()
        let model = try await w.open(thread)
        let reader = w.reader
        try await sweepShoot(w.window, screen: "reader-flat-rows", theme: theme)
        guard !theme.isAccessibilityVariant, ["light", "dark"].contains(theme.slug) else { return }

        let collapsed = try #require(model.messages.first { !$0.isExpanded }?.id)
        let row = try #require(reader.messageViews[collapsed])
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil))
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: w.window.windowNumber, context: nil, eventNumber: 0,
                                                       trackingNumber: 0, userData: nil))
        row.mouseEntered(with: enter)
        try await sweepShoot(w.window, screen: "reader-flat-row-hover", theme: theme)
        row.mouseExited(with: exit)

        let newest = model.focusedMessage
        model.focus(collapsed)
        try await until { row.isFocused }
        try await sweepShoot(w.window, screen: "reader-flat-row-focused", theme: theme)
        if let newest { model.focus(newest) }

        let open = try #require(model.messages.last { $0.isExpanded }?.id)
        let card = try #require(reader.messageViews[open])
        card.mouseEntered(with: enter)
        let reply = try #require(card.header?.actionButtons.first { $0.identifier?.rawValue == ActionID.reply.rawValue })
        reader.showTooltipNow(for: reply)
        try await sweepShoot(w.window, screen: "reader-tooltip-title", theme: theme)
        reader.hideTooltip()
        let chevron = try #require(card.header?.detailsButton)
        reader.showTooltipNow(for: chevron)
        try await sweepShoot(w.window, screen: "reader-tooltip-details", theme: theme)
        reader.hideTooltip()
        card.mouseExited(with: exit)
    }

    @Test(arguments: SweepTheme.lightAndDark)
    func readerBodyPastFooter(_ theme: SweepTheme) async throws {
        let corpus = FakeCorpus.small
        let thread = try #require(corpus.threads.first { candidate in
            candidate.detail.messages.last.map { candidate.bodyKinds[$0.id] == .cidImage } == true
        })
        let environment = AppEnvironment.fake(corpus: corpus, options: .init(remoteAck: .immediate), featureFlags: FeatureFlags())
        let w = try await SweepWindow.make(environment, theme: theme, size: NSSize(width: 1360, height: 620))
        defer { w.close() }
        _ = try await w.open(thread.row.id)
        try await sweepShoot(w.window, screen: "reader-body-past-footer", theme: theme)
    }
}
