import AppKit
import MailActions
import MailFeatures
import MailUIMac
import OpenHumanCore
import SwiftUI
import Testing
@testable import OpenHumanMail

@MainActor
@Suite struct DevFeedbackShortcutTests {
    static let chords = [KeyChord(.character("f"), modifiers: [.command, .option, .control]),
                         KeyChord(.character("t"), modifiers: [.command, .option, .control])]

    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: chars,
                                      charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    @Test func shortcutsMatchTheMenuDeclarations() {
        #expect(DevFeedbackShortcuts.giveFeedback.key == KeyEquivalent("f"))
        #expect(DevFeedbackShortcuts.giveFeedback.modifiers == [.command, .option, .control])
        #expect(DevFeedbackShortcuts.checklist.key == KeyEquivalent("t"))
        #expect(DevFeedbackShortcuts.checklist.modifiers == [.command, .option, .control])
    }

    @Test func keyRouterHasNoBindingForThemAndPassesThemToTheMenu() throws {
        for table in KeyRouter.sliceBindings.values {
            for chord in Self.chords { #expect(table[chord] == nil) }
        }
        window.isReleasedWhenClosed = false
        let router = KeyRouter()
        let target = window
        router.isMailWindow = { $0 === target }
        var performed = 0
        router.perform = { _, _ in performed += 1; return true }
        for scopes: [ActionScope] in [[.list, .global], [.reader, .global]] {
            router.activeScopes = { scopes }
            #expect(router.route(try key("f", code: 3, modifiers: [.command, .option, .control])) != nil)
            #expect(router.route(try key("t", code: 17, modifiers: [.command, .option, .control])) != nil)
        }
        #expect(performed == 0)
    }

    @Test func designKeyMapDoesNotUseThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let design = root.appendingPathComponent("Apps/Mail/Tests/MailAppTests/Fixtures/keyboard-shortcuts.md")
        let text = try String(contentsOf: design, encoding: .utf8)
        #expect(text.contains("### 4.1"))
        for spelling in ["⌃⌥⌘F", "⌃⌘⌥F", "⌃⌥⌘T", "⌃⌘⌥T", "ctrl+opt+cmd+f", "ctrl+cmd+opt+f", "ctrl+opt+cmd+t", "ctrl+cmd+opt+t"] {
            #expect(!text.contains(spelling), "the shortcut reference binds \(spelling)")
        }
    }

    @Test func noOtherMenuItemUsesThem() {
        var conflicts: [String] = []
        var ours: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                let mods = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
                let key = item.keyEquivalent.lowercased()
                let feedbackKey = mods == [.command, .option, .control] && key == "f"
                let checklistKey = mods == [.command, .option, .control] && key == "t"
                let isOurs = ["Give feedback…", "Test checklist…"].contains(item.title)
                if isOurs {
                    ours.append(item.title)
                    let expectedKey = item.title == "Give feedback…" ? feedbackKey : checklistKey
                    #expect(expectedKey, "\(item.title): key=\(String(reflecting: item.keyEquivalent)), modifiers=\(mods.rawValue)")
                }
                guard feedbackKey || checklistKey else { continue }
                if !isOurs { conflicts.append(item.title) }
            }
        }
        if let menu = NSApp.mainMenu { walk(menu) }
        #expect(conflicts.isEmpty, "other menu items on ⌃⌥⌘F/⌃⌥⌘T: \(conflicts)")
        #expect(ours.sorted() == ["Give feedback…", "Test checklist…"], "menu bar: \(NSApp.mainMenu?.items.map(\.title) ?? [])")
    }

    @Test func keyIdentifiersAreShortAndContentFree() {
        #expect(DevFeedbackRuntime.keyIdentifier(.char("e")) == "e")
        #expect(DevFeedbackRuntime.keyIdentifier(.char("E")) == "E")
        #expect(DevFeedbackRuntime.keyIdentifier(.char("#")) == "#")
        #expect(DevFeedbackRuntime.keyIdentifier(KeyChord(.character("F"), modifiers: [.command, .option])) == "cmd+opt+f")
        #expect(DevFeedbackRuntime.keyIdentifier(.named(.returnKey)) == "returnKey")
        #expect(DevFeedbackRuntime.keyIdentifier(.char("é")) == "other")
        #expect(DevFeedbackRuntime.keyIdentifier(.char("ab")) == "other")
    }

    @Test func attachConnectsTheWindowAndRecordsKeysButNotTyping() throws {
        let center = DevFeedbackRuntime.start(arguments: ["-UseFakeData"],
                                              environment: ["XCTestConfigurationFilePath": "x"], app: { nil })
        let controller = MainContentViewController(environment: .fake(corpus: .make(threadCount: 5)))
        DevFeedbackRuntime.attach(controller, to: center)
        #expect(center.window === controller.windowModel)
        controller.keyRouter.didRoute?(.char("e"), nil)
        controller.keyRouter.didRoute?(.char("j"), .nextThread)
        #expect(center.history.commands.map(\.id) == ["key:e", "nav.nextThread"])

        window.isReleasedWhenClosed = false
        let router = KeyRouter()
        let target = window
        router.isMailWindow = { $0 === target }
        var seen: [KeyChord] = []
        router.didRoute = { chord, _ in seen.append(chord) }
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView = field
        window.makeFirstResponder(field)
        #expect(router.route(try key("s", code: 1)) != nil)
        #expect(seen.isEmpty)
        window.makeFirstResponder(nil)
        _ = router.route(try key("s", code: 1))
        #expect(seen == [.char("s")])
        Log.setMirror(MailApp.devFeedback.availability.isAvailable ? MailApp.devFeedback.logs.sink : nil)
    }
}
