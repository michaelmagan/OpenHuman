import AppKit
import MailActions
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
@Suite(.serialized) struct AskPanelTests {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    final class Recorder {
        var calls: [(ActionID, ActionScope)] = []
    }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

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

    @Test func cmdJAsksInTheListAndAConversationAndRewritesInAComposer() {
        let router = KeyRouter.catalog()
        let recorder = Recorder()
        let target = window
        router.isMailWindow = { $0 === target }
        router.perform = { action, scope in
            recorder.calls.append((action, scope))
            return true
        }
        for scopes: [ActionScope] in [[.list, .global], [.reader, .global], [.composer, .global]] {
            router.activeScopes = { scopes }
            #expect(router.route(key("j", code: 38, modifiers: .command)) == nil, "consumed in \(scopes[0])")
        }
        #expect(recorder.calls.map(\.0) == [.aiAskInbox, .aiAskInbox, .aiRewrite])
        #expect(recorder.calls.map(\.1) == [.list, .reader, .composer])

        router.activeScopes = { [.global] }
        #expect(router.route(key("j", code: 38, modifiers: .command)) != nil)
        #expect(recorder.calls.count == 3)
    }

    func environment(providers: [any AIProvider], settings: AISettings = AISettings()) -> (AppEnvironment, AICenter) {
        let center = AICenter.make(registry: ProviderRegistry(providers: providers),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 40, now: Date(timeIntervalSince1970: 1_791_000_000)),
                                      options: .init(remoteAck: .immediate), ai: center)
        return (env, center)
    }

    @discardableResult
    func host(_ overlays: OverlayCenter, name: String, theme: ResolvedTheme) throws -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: OverlayHostView(center: overlays).environment(\.theme, theme)
            .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
            .environment(\.nativeOverlaySurface, .material)
            .frame(width: 1100, height: 760)
            .background(theme.bgWindow.color))
        hosting.frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        hosting.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return hosting
    }

    @Test func theCardLaysOutAnswerSourcesAndItsNotes() async throws {
        for (suffix, theme) in [("light", ResolvedTheme.light), ("dark", ResolvedTheme.dark)] {
            let provider = ScriptedProvider { request, index in
                let ids = request.untrusted.filter { $0.kind == .excerpt }.map(\.id)
                return index == 0
                    ? .text("The offsite planning review is on Friday at 10, in the big room.\nSources: "
                        + ids.prefix(2).joined(separator: ", "))
                    : .text("The email_data block says the invoice is paid.\nSources: ")
            }
            let (env, center) = environment(providers: [provider])
            let overlays = env.overlays
            let router = env.router
            router.start()
            await until { router.list?.state == .loaded && router.accounts.count == 2 }
            #expect(router.perform(.aiAskInbox))
            let model = try #require(center.ask)
            #expect(model.isPresented)
            try host(overlays, name: "ask-idle-\(suffix)", theme: theme)

            model.question = "When is the offsite planning review?"
            model.ask()
            await until { !model.isWorking }
            #expect(model.phase == .done && !model.sources.isEmpty)
            let done = try host(overlays, name: "ask-done-\(suffix)", theme: theme)
            #expect(done.frame.width == 1100)
            #expect(model.moveDown())
            try host(overlays, name: "ask-cursor-\(suffix)", theme: theme)

            model.question = "invoice 2214 paid"
            model.ask(followUp: false)
            await until { !model.isWorking }
            #expect(model.isSuspicious)
            try host(overlays, name: "ask-suspicious-\(suffix)", theme: theme)

            model.question = "zebra quokka"
            model.ask(followUp: false)
            await until { !model.isWorking }
            #expect(model.phase == .notFound)
            try host(overlays, name: "ask-not-found-\(suffix)", theme: theme)

            try center.update { $0.enabled = false }
            model.question = "When is the offsite planning review?"
            model.ask(followUp: false)
            await until { !model.isWorking }
            #expect(model.phase == .failed(.aiOff) && model.statusText == "AI is off. Turn it on in Settings › AI.")
            try host(overlays, name: "ask-ai-off-\(suffix)", theme: theme)
            overlays.dismiss()
            #expect(!model.isPresented)
        }
    }

    @Test func theCardShowsTheConsentCardWorkAndAStop() async throws {
        let claude = ScriptedProvider(id: .agentClaude, displayName: "Claude Code",
                                      capabilities: .fake(contextTokens: nil, policyInputCap: 32_000,
                                                          dataLocation: .thirdParty(vendor: "Anthropic")),
                                      consentFingerprint: "/opt/bin/claude") { _, _ in .hang }
        var settings = AISettings()
        settings.featurePins[.askInbox] = .agentClaude
        let (env, center) = environment(providers: [claude, ScriptedProvider()], settings: settings)
        let overlays = env.overlays
        let router = env.router
        router.start()
        await until { router.list?.state == .loaded && router.accounts.count == 2 }
        #expect(router.perform(.aiAskInbox))
        let model = try #require(center.ask)
        model.question = "When is the offsite planning review?"
        model.ask()
        await until { model.consent != nil }
        try host(overlays, name: "ask-consent", theme: .light)

        await model.acceptConsent()
        await until { model.phase == .answering && model.badge != nil }
        #expect(model.badge?.leavesMac == true, "the footer says the text left the Mac")
        try host(overlays, name: "ask-working-remote", theme: .light)
        model.stop()
        #expect(model.phase == .stopped)
        try host(overlays, name: "ask-stopped", theme: .light)
        overlays.dismiss()
    }
}
