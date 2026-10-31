import Foundation
import MailActions
import MailFakes
import MailModel
import Testing
@testable import MailFeatures

@MainActor
@Suite struct HintBarTests {
    func window() async -> (OverlayFixture, HintBarModel) {
        let f = OverlayFixture()
        await f.loaded()
        _ = f.env.compose
        let model = HintBarModel(router: f.router)
        model.start()
        return (f, model)
    }

    func line(_ hint: ShortcutHint) -> String { hint.keycaps.joined(separator: " ") + " " + hint.title }

    @Test func listShowsDoneRemindOpenAndCommandsFromTheCatalog() async {
        let (_, model) = await window()
        #expect(model.context == .list)
        #expect(model.hints.map(line) == ["E Mark done", "\(Self.remindKey) Remind me", "↵ Open", "⌘K Commands"])
    }

    static let remindKey = ActionCatalog.remindOnH ? "H" : "⇧H"

    static let returnTitle = ActionCatalog.returnRepliesAll ? "Reply all" : "Reply"

    @Test func aConversationRepliesWithEnter() async throws {
        let (f, model) = await window()
        let router = f.router
        #expect(await f.run(.openThread))
        await eventually { router.active?.reader != nil }
        #expect(model.context == .conversation)
        #expect(model.hints.map(line) == ["E Mark done", "\(Self.remindKey) Remind me", "↵ \(Self.returnTitle)",
                                          "⌘K Commands"])
    }

    @Test func searchHasItsOwnHints() async {
        let (f, model) = await window()
        let router = f.router
        #expect(await f.run(.search))
        await eventually { router.active?.searchOpen == true }
        #expect(model.context == .search)
        #expect(model.hints.count == 4 && model.hints.first?.action == .openThread)
    }

    @Test func everyHintIsABindingOfItsCatalogEntry() async {
        let (f, _) = await window()
        let env = f.env
        for context in HintContext.allCases {
            let hints = HintBar.hints(for: context, descriptors: env.actions.descriptors) { _ in .enabled }
            #expect(!hints.isEmpty && hints.count <= HintBar.limit, "\(context)")
            for hint in hints {
                let descriptor = env.actions.descriptor(hint.action)
                #expect(descriptor != nil, "\(context) \(hint.action)")
                #expect(descriptor?.defaultBindings.contains { $0.keycaps == hint.keycaps } == true, "\(context) \(hint.action)")
            }
        }
        let composer = HintBar.hints(for: .composer, descriptors: env.actions.descriptors) { _ in .enabled }
        #expect(composer.first.map(line) == "⌘↵ Send")
    }

    @Test func aReboundKeyShowsItsNewKeyAndAHiddenActionIsReplacedByTheNextCandidate() async {
        let (f, model) = await window()
        let env = f.env
        env.actions.applyKeymap(KeymapOverrides(bindings: ["thread.done": ["y"]]))
        #expect(model.hints.first.map(line) == "Y Mark done")
        let hints = HintBar.hints(for: .list, descriptors: env.actions.descriptors) { $0 == .remind ? .hidden : .enabled }
        #expect(hints.count == 4 && !hints.contains { $0.action == .remind })
        #expect(hints.map(\.action).contains(.snooze), "the next candidate fills the slot")
    }

    @Test func hintsUseShortTitlesButTogglesKeepTheirDirection() {
        let hints = HintBar.hints(for: .search, descriptors: ActionCatalog.all) { _ in .enabled }
        #expect(hints.map(\.title) == ["Open", "Search", "Commands", "Shortcuts"])
        let composer = HintBar.hints(for: .composer, descriptors: ActionCatalog.all) { _ in .enabled }
        #expect(composer.map(\.title) == ["Send", "Discard", "Attach", "Commands"])
        let muted = HintBar.hints(for: .muted, descriptors: ActionCatalog.all,
                                  title: { $0.id == .toggleMute ? "Unmute" : $0.title }) { _ in .enabled }
        #expect(muted.first?.title == "Unmute")
        #expect(ActionCatalog.all.filter { $0.shortTitle != nil }.allSatisfy { !$0.title.contains(" or ") },
                "no toggle has a short title")
    }

    @Test func checkedDraftsLeadWithSendingThemInPlaceOfOpen() {
        let hints = HintBar.hints(for: .list, checkedDrafts: true, descriptors: ActionCatalog.all,
                                  title: { $0.id == .sendDrafts ? "Send 2 drafts…" : $0.title }) { _ in .enabled }
        #expect(hints.map(line) == ["⌘↵ Send 2 drafts", "E Mark done", "\(Self.remindKey) Remind me", "⌘K Commands"])
        let plain = HintBar.hints(for: .list, descriptors: ActionCatalog.all) { _ in .enabled }
        #expect(!plain.contains { $0.action == .sendDrafts }, "nothing checked: the usual hints")
        let search = HintBar.hints(for: .search, checkedDrafts: true, descriptors: ActionCatalog.all) { _ in .enabled }
        #expect(!search.contains { $0.action == .sendDrafts }, "only the list itself")
    }

    @Test func aRefusedActionStaysButIsMarkedDisabled() async {
        let hints = HintBar.hints(for: .list, descriptors: ActionCatalog.all) {
            $0 == .markDone ? .disabled(.unavailable("Mark done")) : .enabled
        }
        #expect(hints.first?.action == .markDone && hints.first?.isEnabled == false)
    }

    @Test func theXTurnsTheSettingOffAndTheSwitchTurnsItBackOn() async throws {
        let (f, model) = await window()
        let env = f.env
        #expect(model.isVisible, "on by default")
        await model.dismiss()
        #expect(!model.isVisible)
        let store = try #require(env.commands as? FakeMailStore)
        #expect(try await store.get(AppSettings.showShortcutHints) == false)
        #expect(AppSettings.showShortcutHints.name == "ui.show_shortcut_hints")

        let general = GeneralSettingsModel(environment: env)
        general.start()
        await eventually { general.showShortcutHints.value == false }
        await general.showShortcutHints.set(true)
        await eventually { model.isVisible }
    }
}
