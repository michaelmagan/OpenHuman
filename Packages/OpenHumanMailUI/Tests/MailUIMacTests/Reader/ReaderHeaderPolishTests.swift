import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct ReaderHeaderPolishTests {
    typealias F = UIFixtures

    private func harness(subject: String) async throws -> ReaderHarness {
        let detail = F.conversation(2, count: 1, subject: subject)
        let source = UITestSource(details: [detail], bodies: [detail.messages[0].id: MessageContent(html: nil, text: "Hi")])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        try await until { !h.controller.toolbarActions.primary.isEmpty }
        h.controller.view.layoutSubtreeIfNeeded()
        return h
    }

    private let longSubject = "Re: Fwd: The quarterly planning review for the whole platform organisation, with the budget "
        + "assumptions, hiring plan and the open questions from last week's leadership sync"

    @Test(arguments: [(640.0, "narrow"), (1500.0, "wide")])
    func subjectSpansTheTextColumnWithNoGlyphRowInTheConversation(width: Double, name: String) async throws {
        let h = try await harness(subject: longSubject)
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: width, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        let subject = h.controller.subjectView
        let row = h.controller.subjectContainer
        try await until {
            h.controller.view.layoutSubtreeIfNeeded()
            return row.frame.width > 300 && (width >= 700 || subject.frame.height > 40)
        }
        #expect(subject.alignmentRect(forFrame: subject.frame).width == row.frame.width, "\(name): the subject is the container width")
        #expect(row.frame.width > 300, "\(name)")
        let inset = ReaderViewController.contentInset(.light)
        #expect(row.frame.width <= NativeMetrics.Reader.maxColumnWidth - 2 * inset + 0.5, "\(name): inside the 720 pt column")
        #expect(subviews(of: ReaderButton.self, in: row).isEmpty, "\(name): the conversation actions are in the toolbar")
        let ids = Set(subviews(of: ReaderButton.self, in: h.controller.view).compactMap { $0.identifier?.rawValue })
        for id in ReaderToolbarActions.primaryIDs + ReaderActions.navigationActionIDs {
            #expect(!ids.contains(id.rawValue), "\(name): \(id.rawValue) is not drawn inside the reader")
        }
        if width < 700 { #expect(subject.frame.height > 40) }
    }

    @Test func everyToolbarActionHasASymbolATitleAndAHelpText() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        let actions = h.controller.toolbarActions
        #expect(!actions.primary.isEmpty && !actions.navigation.isEmpty)
        for item in actions.primary + actions.navigation {
            let symbol = try #require(item.symbol, "\(item.id.rawValue) has no symbol")
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(item.id.rawValue): \(symbol)")
            #expect(!item.title.isEmpty && !item.help.isEmpty, "\(item.id.rawValue)")
        }
    }

    @Test func theTitleBlockIsASemiboldSubjectAndAMetaLine() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        try await until {
            h.controller.view.layoutSubtreeIfNeeded()
            let subject = h.controller.subjectContainer.convert(h.controller.subjectView.bounds, from: h.controller.subjectView)
            let meta = h.controller.metaLabelView
            let metaFrame = h.controller.subjectContainer.convert(meta.bounds, from: meta)
            guard subject.height > 0, metaFrame.height > 0 else { return false }
            return h.controller.subjectContainer.isFlipped ? metaFrame.minY >= subject.maxY : metaFrame.maxY <= subject.minY
        }
        let font = try #require((h.controller.subjectView as? NSTextField)?.font)
        #expect(font.pointSize == NativeMetrics.Reader.subjectSize)
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        #expect((weight ?? 0) >= NSFont.Weight.semibold.rawValue - 0.01, "semibold, was \(String(describing: weight))")
        let meta = h.controller.metaLabelView
        let metaFont = meta.attributedStringValue.length > 0
            ? meta.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : meta.font
        #expect(metaFont?.pointSize == NativeMetrics.Reader.metaSize)
        let subject = h.controller.subjectContainer.convert(h.controller.subjectView.bounds, from: h.controller.subjectView)
        let metaFrame = h.controller.subjectContainer.convert(meta.bounds, from: meta)
        #expect(h.controller.subjectContainer.isFlipped ? metaFrame.minY >= subject.maxY : metaFrame.maxY <= subject.minY,
                "the meta line is under the subject")
        let ids = h.controller.toolbarActions.primary.map(\.id)
        #expect(ids == ReaderToolbarActions.primaryIDs.filter { ids.contains($0) })
    }

    @Test func previousAndNextAreTheToolbarsNavigationPair() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        let nav = h.controller.toolbarActions.navigation
        #expect(nav.map(\.id) == ReaderActions.navigationActionIDs)
        #expect(nav.map(\.title) == ["Previous conversation", "Next conversation"])
        #expect(nav.allSatisfy { $0.symbol != nil })
    }

    @Test func theReplyTipShowsUnderItsButtonAndAScrollHidesIt() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        let done = try #require(h.controller.toolbarActions.item(.markDone))
        #expect(done.title == "Mark done" && done.help == "Mark done  E" && done.isEnabled)
        let key = try #require(h.model.messages.last?.id)
        let header = try await h.header(key)
        let reply = try #require(header.actionButtons.first { $0.identifier?.rawValue == ActionID.reply.rawValue })
        #expect(reply.tip?.keycaps == ["R"] && reply.toolTip == nil)
        let tip = h.controller.tooltipView
        #expect(tip.isHidden)
        h.controller.showTooltipNow(for: reply)
        #expect(!tip.isHidden && tip.content == reply.tip)
        let root = h.controller.view
        let button = reply.convert(reply.bounds, to: root)
        let pill = tip.pillFrame
        #expect(!pill.intersects(button), "never over its button")
        #expect(root.bounds.insetBy(dx: KeycapTooltipView.margin - 0.5, dy: KeycapTooltipView.margin - 0.5).contains(pill),
                "inside the reader")
        #expect(root.isFlipped ? pill.minY >= button.maxY : pill.maxY <= button.minY, "under the button")
        h.controller.userScrolled()
        #expect(tip.isHidden, "a scroll hides it")
    }

    @Test func everyActionThePolicyOffersHasASymbol() {
        for action in ReaderActions.threadActions + ReaderActions.messageActions {
            #expect(ReaderActions.symbol(for: action.id) != nil, "\(action.id.rawValue)")
        }
    }

    @Test(arguments: [true, false])
    func theStarItemShowsTheStarredState(starred: Bool) async throws {
        let base = F.conversation(3, count: 1, subject: "Plan")
        let detail = ConversationDetail(id: base.id, subject: base.subject, messages: base.messages, isStarred: starred)
        let source = UITestSource(details: [detail], bodies: [detail.messages[0].id: MessageContent(html: nil, text: "Hi")])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        try await until { !h.controller.toolbarActions.primary.isEmpty && h.model.isStarred == starred }
        let actions = h.controller.toolbarActions
        #expect(!actions.primary.contains { $0.id == .toggleStar }, "Star is not in the primary group")
        let star = try #require(actions.more.flatMap { $0 }.first { $0.id == .toggleStar })
        #expect(star.title.hasPrefix(starred ? "Unstar" : "Star"), "\(star.title)")
        #expect(star.isOn == starred)
        #expect(star.symbol == (starred ? "star.fill" : "star"))
    }

    @Test func theToolbarTitleIsNeverABareCount() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        let title = ShellToolbar.conversationTitle(h.model)
        #expect(title.isEmpty || title.contains("·") || title.hasSuffix("messages"), "\(title)")
        #expect(ShellToolbar.conversationTitle(nil).isEmpty)
    }
}
