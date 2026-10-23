#if os(macOS)
import AppKit
import MailFeatures
import MailTheme
import OpenHumanAI
import SwiftUI
import Testing
@testable import MailUI

private let fixedNow = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized)
struct SettingsPromptEntryTests {
    @Test func theAIOverviewOffersTheTriagePromptFirst() {
        let ids = AISettingsInstructions.prompts
        #expect(ids.first == PromptName.classify.rawValue, "the triage prompt has its own entry, first")
        #expect(ids.contains(PromptName.autoLabel.rawValue))
        #expect(Set(CategoriesTab.prompts) == Set(ids), "Importance & labels links the same two prompts")
        for id in ids {
            let info = PromptCatalog.entry(id)
            #expect(info != nil, "\(id) is a prompt Mail ships")
            #expect(info?.title.isEmpty == false && info?.usedBy.isEmpty == false, "\(id) has a title and a line under it")
        }
    }

    @Test func aRequestForTheTriagePromptOpensItsEditorOnce() async throws {
        let registry = PromptRegistry(provider: PromptLibraryProvider(bundled: .standard),
                                      store: InMemoryPromptOverrideStore(), now: { fixedNow })
        let model = PromptsSettingsModel(registry: registry)
        let navigator = SettingsNavigator()
        navigator.openPrompt(PromptName.classify.rawValue)
        let page = SettingsPageScaffold(title: "AI") {
            AISettingsTabs(prompts: model, navigator: navigator) { SettingsSection("Overview") { SettingsRow("A row") } }
        }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 560, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page.environment(\.theme, .light))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.contentView?.layoutSubtreeIfNeeded()
        await untilObserved { model.selectedID == PromptName.classify.rawValue }
        #expect(model.draft == model.originalText, "opening shows the text in use and saves nothing")
        #expect(navigator.requestedPrompt == nil, "the request is used once")
    }
}
#endif
