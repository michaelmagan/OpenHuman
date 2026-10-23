import AppKit
import MailActions
import MailFakes
@testable import MailFeatures
import MailModel
import MailRender
import MailTheme
import MailUI
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized) struct AIViewTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 700), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    func until(_ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let deadline = clock.now + testBackstop
        while !condition() {
            if clock.now > deadline {
                Issue.record("condition not met within 15 s", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func environment(providers: [any AIProvider] = [ScriptedProvider()], flags: FeatureFlags = FeatureFlags())
        -> (AppEnvironment, AICenter) {
        let center = AICenter.make(registry: ProviderRegistry(providers: providers),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore()))
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                      options: .init(remoteAck: .immediate), featureFlags: flags, ai: center)
        return (env, center)
    }

    @Test func acceptingARewriteIsOneUndoStep() throws {
        let text = ComposerTextView.make()
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView?.addSubview(text)
        text.insertText("Hello there, Dana", replacementRange: NSRange(location: 0, length: 0))
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        undo.removeAllActions()
        #expect(text.replaceText(in: NSRange(location: 0, length: 5), with: "Hi"))
        #expect(text.string == "Hi there, Dana")
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "Hi", "the new text is selected")
        #expect(undo.canUndo)
        undo.undo()
        #expect(text.string == "Hello there, Dana", "⌘Z restores what was there in one step")
        #expect(!undo.canUndo)
        #expect(!text.replaceText(in: NSRange(location: 10, length: 50), with: "x"), "a range past the text changes nothing")
        #expect(text.string == "Hello there, Dana")
    }

    @Test func cmdJInTheEditorReachesTheComposer() {
        let text = ComposerTextView.make()
        var commands: [ActionID] = []
        text.onCommand = { commands.append($0); return true }
        #expect(text.handleCommandKey(key("j", code: 38, modifiers: .command)))
        #expect(commands == [.aiRewrite])
    }

    @Test func theComposerEditorIsThePanelsBridgeAndUndoRestoresTheOriginal() async throws {
        let (env, center) = environment()
        env.router.start()
        await until { env.router.list?.state == .loaded }
        let manager = env.compose
        #expect(manager.aiCenter === center, "the card shows the AI button")
        let session = try #require(manager.openNew(placement: .modal))
        let host = NSHostingView(rootView: ComposerHostView(manager: manager).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let text = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerTextView }.first)
        #expect(session.editor != nil, "the editor registered itself")
        text.insertText("Hello there, Dana", replacementRange: NSRange(location: 0, length: 0))
        text.setSelectedRange(NSRange(location: 0, length: 5))
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        undo.removeAllActions()

        #expect(text.handleCommandKey(key("j", code: 38, modifiers: .command)), "⌘J opens the panel")
        let panel = try #require(session.aiPanel)
        #expect(panel.scope == .selection && panel.original == "Hello")
        host.layoutSubtreeIfNeeded()
        panel.instruction = "Shorter"
        panel.generate()
        await until { panel.phase == .done }
        panel.replace()
        #expect(text.string == "Rewritten: Hello there, Dana")
        #expect(session.plainText == "Rewritten: Hello there, Dana", "the session follows the edit like typing")
        #expect(session.aiPanel == nil)
        undo.undo()
        #expect(text.string == "Hello there, Dana")
        manager.close(session)
    }

    @Test func thePanelRendersItsStates() async throws {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code",
                                      capabilities: .fake(contextTokens: nil, policyInputCap: 32_000,
                                                          dataLocation: .thirdParty(vendor: "Anthropic")),
                                      consentFingerprint: "/opt/bin/claude")
        let (env, center) = environment(providers: [ScriptedProvider(), claude])
        env.router.start()
        await until { env.router.list?.state == .loaded }
        let session = try #require(env.compose.openNew(placement: .modal))
        let panel = try #require(center.togglePanel(session))
        func render() -> NSSize {
            let host = NSHostingView(rootView: AIComposerPanel(model: panel, center: center).environment(\.theme, .light))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        #expect(render().width == AIComposerPanel.width)
        #expect(panel.showsExamples)
        let withExamples = render().height
        panel.dismissExamples()
        let empty = render().height
        #expect(withExamples > empty, "the example list shows under an empty prompt")
        panel.instruction = "Write a short hello"
        panel.generate()
        await until { panel.phase == .done }
        #expect(render().height > empty, "the preview and the footer's actions show")
        panel.showsDiff = true
        #expect(render().height > empty)
        let consent = try #require(await center.consentRequest(for: .agentClaude))
        let sheet = NSHostingView(rootView: AIConsentView(request: consent, center: center, accept: {}, decline: {})
            .frame(width: 440).environment(\.theme, .dark))
        sheet.layoutSubtreeIfNeeded()
        #expect(sheet.fittingSize.height > 100)
        env.compose.close(session)
    }

    // Narrower is never shorter, so a legacy scroll bar that shows when the panel grows cannot make it flip between
    // side by side and one above the other
    @Test func theComparisonIsNeverShorterWhenNarrower() async throws {
        let short = ScriptedProvider { request, _ in
            request.task == .rewrite ? .text("Shorter.") : FakeAIProvider.cannedScript(request)
        }
        let (env, center) = environment(providers: [short])
        env.router.start()
        await until { env.router.list?.state == .loaded }
        let session = try #require(env.compose.openNew(placement: .modal))
        let lines = (1...40).map { "Line \($0) of a long draft about the plan for the next quarter and who does what." }
        session.updateBody(RichTextDocument(blocks: lines.map { .paragraph([.text($0, [])]) }))
        let panel = try #require(center.togglePanel(session))
        #expect(panel.scope == .wholeDraft)
        panel.dismissExamples()
        panel.instruction = "Shorter"
        panel.generate()
        await panel.settle()
        #expect(panel.phase == .done)
        #expect(panel.currentVersion != nil)
        var previous = CGFloat.infinity
        for width in stride(from: CGFloat(560), through: 700, by: 4) {
            let host = NSHostingView(rootView: AIComposerPanel(model: panel, center: center).frame(width: width)
                .environment(\.theme, .light))
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            #expect(height <= previous + 0.5, "at \(width) pt the panel is \(height) pt, after \(previous) pt narrower")
            previous = height
        }
        env.compose.close(session)
    }

    @Test func theEditorOffersWritingToolsOnlyWhenAllowed() {
        let text = ComposerTextView.make()
        #expect(!text.allowsWritingTools)
        #expect(text.writingToolsBehavior == NSWritingToolsBehavior.none, "off until the composer allows it")
        text.allowsWritingTools = true
        #expect(text.writingToolsBehavior == NSWritingToolsBehavior.complete)
        text.allowsWritingTools = false
        #expect(text.writingToolsBehavior == NSWritingToolsBehavior.none)
    }

    @Test func theComposerCardFollowsTheWritingToolsSettingLive() async throws {
        let (env, center) = environment()
        env.router.start()
        await until { env.router.list?.state == .loaded }
        let manager = env.compose
        let session = try #require(manager.openNew(placement: .modal))
        let host = NSHostingView(rootView: ComposerHostView(manager: manager).frame(width: 900, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let text = try #require(Self.descendants(of: host).compactMap { $0 as? ComposerTextView }.first)
        #expect(!text.allowsWritingTools, "off by default")

        try center.update { $0.allowWritingTools = true }
        await until {
            host.layoutSubtreeIfNeeded()
            return text.allowsWritingTools
        }
        #expect(text.writingToolsBehavior == NSWritingToolsBehavior.complete)
        try center.update { $0.enabled = false }
        await until {
            host.layoutSubtreeIfNeeded()
            return !text.allowsWritingTools
        }
        #expect(text.writingToolsBehavior == NSWritingToolsBehavior.none)
        manager.close(session)
        host.removeFromSuperview()
    }

    @Test func theReaderShowsTheSummaryLineUnderTheSubject() async throws {
        let long = String(repeating: "The team agreed on the plan and asks for the budget by Friday. ", count: 6)
        let provider = ScriptedProvider { request, _ in
            request.task == .summarize ? .text(long) : FakeAIProvider.cannedScript(request)
        }
        let (env, center) = environment(providers: [provider])
        let (controller, model) = try await reader(env, minimumMessages: 3)
        await until { controller.aiAccessory != nil }
        let summary = center.summary(for: model.thread)
        await until { summary.phase == .done }
        #expect(summary.text == long)
        let column = try #require(controller.aiAccessory?.superview as? NSStackView)
        #expect(column.arrangedSubviews.firstIndex { $0 === controller.aiAccessory } == 1, "right under the subject")
        let accessory = try #require(controller.aiAccessory as? ThreadSummaryLineView)
        #expect(!accessory.isHidden)
        await until {
            accessory.superview?.layoutSubtreeIfNeeded()
            return accessory.frame.height > 60
        }
        #expect(accessory.frame.width <= AIViewTests.columnMaxWidth, "it wraps inside the column")
        #expect(accessory.textLabel.stringValue == long && accessory.textLabel.isSelectable)
        #expect(accessory.textLabel.attributedStringValue.attribute(.link, at: 0, effectiveRange: nil) == nil,
                "plain text, never a link")
        controller.model = nil
    }

    @Test func theSummaryLineIsAbsentWithTheModuleOff() async throws {
        let (env, _) = environment(flags: FeatureFlags().with(.ai, false))
        let (controller, model) = try await reader(env, minimumMessages: 3)
        await until { model.state == .loaded }
        #expect(controller.aiAccessory == nil)
        controller.model = nil
    }

    static let columnMaxWidth: CGFloat = 760

    func reader(_ env: AppEnvironment, minimumMessages: Int) async throws -> (ReaderViewController, ReaderModel) {
        let router = env.router
        router.start()
        await until { router.list?.state == .loaded && router.accounts.count == 2 }
        let rows = try await env.data.threadPage(.system(.inbox), account: AccountID(1), after: nil, limit: 500).rows
        var thread: ThreadKey?
        for row in rows {
            for try await detail in env.data.threadDetail(row.id) {
                if (detail?.messages.count ?? 0) >= minimumMessages { thread = row.id }
                break
            }
            if thread != nil { break }
        }
        let key = try #require(thread)
        let controller = ReaderViewController(theme: .light, webKit: TestWebKit.noNetwork,
                                              preferences: ReaderPreferences(defaults: nil))
        let host = StubHost(router)
        controller.host = host
        let readerWindow = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1200, height: 900),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        readerWindow.isReleasedWhenClosed = false
        readerWindow.contentViewController = controller
        kept.hosts.append(host)
        kept.windows.append(readerWindow)
        let model = ReaderModel(thread: key, data: env.data, renderQueue: env.renderQueue)
        controller.model = model
        model.start()
        await until { model.state == .loaded }
        return (controller, model)
    }

    @MainActor final class Kept {
        var hosts: [StubHost] = []
        var windows: [NSWindow] = []
    }
    let kept = Kept()

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
