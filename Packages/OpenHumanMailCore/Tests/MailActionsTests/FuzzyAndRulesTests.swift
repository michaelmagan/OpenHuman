import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailActions

@Suite struct FuzzyMatcherTests {
    @Test func subsequenceCaseAndDiacriticInsensitive() throws {
        #expect(FuzzyMatcher("md").match("Mark done") != nil)
        #expect(FuzzyMatcher("MD").match("mark done") != nil)
        #expect(FuzzyMatcher("cafe").match("Café menu") != nil)
        #expect(FuzzyMatcher("xyz").match("Mark done") == nil)
        #expect(FuzzyMatcher("dm").match("Mark done") == nil, "order matters")
        #expect(FuzzyMatcher("").match("anything")?.score == 0)
        let match = try #require(FuzzyMatcher("md").match("Mark done"))
        #expect(match.positions == [0, 5], "word starts are preferred")
    }

    @Test func aFeasibleMatchIsFoundWhenWordStartsWouldStrandTheRest() throws {
        let match = try #require(FuzzyMatcher("ab").match("xab ac"))
        #expect(match.positions == [1, 2])
    }

    @Test func wordStartsAndPrefixesRankHigher() throws {
        let matcher = FuzzyMatcher("sn")
        let snooze = try #require(matcher.match("Snooze…"))
        let unsnooze = try #require(matcher.match("Wake now (unsnooze)"))
        #expect(snooze.score > unsnooze.score)
        let done = try #require(FuzzyMatcher("done").match("Mark done"))
        let scattered = try #require(FuzzyMatcher("done").match("Don't open everything"))
        #expect(done.score > scattered.score, "a contiguous word beats scattered letters")
    }

    @Test func keywordsMatchWithoutHighlighting() throws {
        let matcher = FuzzyMatcher("archive")
        let viaKeyword = try #require(matcher.match(title: "Mark done", keywords: ["archive", "clear"]))
        #expect(viaKeyword.positions.isEmpty)
        let viaTitle = try #require(FuzzyMatcher("mark").match(title: "Mark done", keywords: ["archive"]))
        #expect(viaTitle.positions == [0, 1, 2, 3])
        #expect(matcher.match(title: "Trash", keywords: ["delete"]) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1"))
    func fiveHundredEntriesUnderTwoMilliseconds() {
        let titles = (0..<500).map { "Action number \($0) with some longer title text \($0 % 7)" }
        let matcher = FuzzyMatcher("acn7")
        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { for title in titles { _ = matcher.match(title) } }
            best = min(best, elapsed)
        }
        print("perf: fuzzy match over 500 titles, best of 5: \(best)")
        #expect(best < .milliseconds(2), "500 entries took \(best)")
    }
}

@Suite struct ActionRulesTests {
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))

    func context(_ scope: ActionScope = .list) -> ActionContext {
        ActionContext(scope: scope, account: AccountID(1), accountCount: 2, location: .system(.inbox), selection: [key],
                      focusedThread: key, sender: "dana@acme.example", hasRows: true)
    }

    func availability(_ id: ActionID, _ context: ActionContext) -> ActionAvailability {
        ActionRules.availability(ActionCatalog.descriptor(id)!, in: context)
    }

    @Test func scopesTargetsAndWritePort() {
        #expect(availability(.markDone, context(.composer)) == .hidden, "triage is not offered in a composer")
        #expect(availability(.reviewKeep, context(.list)) == .hidden)
        #expect(availability(.commandPalette, context(.composer)) == .enabled)
        var empty = context()
        empty.selection = []
        empty.focusedThread = nil
        #expect(availability(.markDone, empty) == .disabled(.noSelection))
        #expect(availability(.markDone, empty).reason?.announces == true, "an empty selection says why")
        #expect(DisabledReason.other("This is the newest message").announces == false, "↓ still scrolls")
        #expect(DisabledReason.nothingToUndo.announces == false, "⌘Z still reaches a text field")
        var noPort = context()
        noPort.canWrite = false
        #expect(availability(.markDone, noPort) == .disabled(.unavailable("Mark done")))
        #expect(availability(.markDone, noPort).reason?.description == "Mark done isn't available here")
        #expect(availability(.unsubscribe, context()) == .disabled(.other("Open the conversation first")))
    }

    @Test func stateDependentEntries() {
        var c = context()
        #expect(availability(.moveToInbox, c) == .hidden, "already in the inbox")
        #expect(availability(.notSpam, c) == .hidden)
        #expect(availability(.unsnooze, c) == .hidden)
        #expect(availability(.clearReminder, c) == .hidden)
        #expect(availability(.removeLabel, c) == .hidden)
        #expect(availability(.removeFromSplit, c) == .hidden)
        #expect(availability(.clearChecks, c) == .hidden)
        #expect(availability(.undo, c) == .disabled(.nothingToUndo))
        c.location = .system(.spam)
        #expect(availability(.notSpam, c) == .enabled)
        #expect(availability(.spam, c) == .hidden)
        #expect(availability(.moveToInbox, c) == .enabled)
        c.location = .label(GmailLabelID("Label_1"))
        #expect(availability(.removeLabel, c) == .enabled)
        c.location = .split(SplitKey("s1"))
        #expect(availability(.removeFromSplit, c) == .enabled)
        c.targets = TargetState(anySnoozed: true, anyReminder: true)
        c.checkedCount = 2
        c.canUndo = true
        #expect(availability(.unsnooze, c) == .enabled)
        #expect(availability(.clearReminder, c) == .enabled)
        #expect(availability(.clearChecks, c) == .enabled)
        #expect(availability(.undo, c) == .enabled)
        c.sender = nil
        #expect(availability(.alwaysImportantSender, c) == .disabled(.other("No sender address")))
        #expect(availability(.switchToAccount(2), c) == .enabled)
        #expect(availability(.switchToAccount(3), c) == .hidden)
    }

    @Test func togglesNameTheirDirection() {
        var c = context()
        let star = ActionCatalog.descriptor(.toggleStar)!
        let read = ActionCatalog.descriptor(.toggleRead)!
        #expect(ActionRules.title(for: star, in: c) == "Star")
        #expect(ActionRules.title(for: read, in: c) == "Mark unread")
        c.targets = TargetState(anyUnread: true, allStarred: true)
        #expect(ActionRules.title(for: star, in: c) == "Unstar")
        #expect(ActionRules.title(for: read, in: c) == "Mark read")
        #expect(c.senderDomain == "acme.example")
    }
}

@Suite struct KeymapTests {
    let catalog = ActionCatalog.all

    @Test func acceptedOverridesReplaceDefaults() throws {
        let keymap = Keymap.resolve(KeymapOverrides(bindings: ["thread.done": ["y", "e"]]), descriptors: catalog)
        #expect(keymap.issues.isEmpty)
        let done = try #require(keymap.apply(to: catalog).first { $0.id == .markDone })
        #expect(done.defaultBindings.map(\.description) == ["Y", "E"])
        #expect(keymap.asOverrides.bindings == ["thread.done": ["y", "e"]])
        #expect(Keymap.resolve(keymap.asOverrides, descriptors: catalog) == keymap, "round trip")
    }

    @Test func badOverridesAreRejectedAndDefaultsStay() throws {
        let user = KeymapOverrides(bindings: [
            "thread.done": ["⇧1"],
            "nope.unknown": ["q"],
            "thread.trash": ["e"],
            "app.commandPalette": ["⌘P"],
        ])
        let keymap = Keymap.resolve(user, descriptors: catalog)
        #expect(keymap.overrides.isEmpty)
        #expect(keymap.issues.count == 4)
        #expect(keymap.issues.contains(.unknownAction("nope.unknown")))
        #expect(keymap.issues.contains(.reserved(action: .commandPalette)))
        #expect(keymap.issues.contains { if case .conflict(let c) = $0 { c.kind == .sameKeys } else { false } })
        #expect(keymap.issues.contains { if case .unparsable(let id, _, _) = $0 { id == .markDone } else { false } })
        let trash = try #require(keymap.apply(to: catalog).first { $0.id == .trash })
        #expect(trash.defaultBindings.map(\.description) == ["#", "⌫"])
        #expect(Keymap.resolve(KeymapOverrides(version: 2), descriptors: catalog).issues == [.unsupportedVersion(2)])
    }

    @Test func swappingTwoActionsKeysWorksInEitherOrder() {
        let user = KeymapOverrides(bindings: ["thread.done": ["#"], "thread.trash": ["e", "⌫"]])
        let keymap = Keymap.resolve(user, descriptors: catalog)
        #expect(keymap.issues.isEmpty, "\(keymap.issues)")
        #expect(keymap.bindings(for: ActionCatalog.descriptor(.markDone)!).map(\.description) == ["#"])
        #expect(KeyBindingConflicts.find(in: keymap.apply(to: catalog)).isEmpty)
    }

    @Test func emptyAndUnbindingOverrides() {
        #expect(Keymap.resolve(KeymapOverrides(), descriptors: catalog) == .defaults)
        let keymap = Keymap.resolve(KeymapOverrides(bindings: ["thread.spam": []]), descriptors: catalog)
        #expect(keymap.bindings(for: ActionCatalog.descriptor(.spam)!).isEmpty, "an empty list unbinds")
    }

    @Test func overridesKeepTheDefaultScopeRestriction() throws {
        let keymap = Keymap.resolve(KeymapOverrides(bindings: ["nav.nextThread": ["B", "↓"]]), descriptors: catalog)
        #expect(keymap.issues.isEmpty)
        let next = try #require(keymap.apply(to: catalog).first { $0.id == .nextThread })
        #expect(next.defaultBindings.last?.onlyIn == [.list])
    }
}

@Suite struct ShortcutGuideTests {
    @Test func gPrefixListsItsCompletions() {
        let hint = SequenceHint.make(prefix: KeyBinding.Chord(.character("g")), scopes: [.list, .global],
                                     descriptors: ActionCatalog.all)
        #expect(hint.text == "G…")
        #expect(hint.completions.map { $0.keys[0] }
                == ["!", "#", ";", "A", "D", "E", "H", "I", "L", "M", "R", "S", "T", "U", "W", "Y", "Z"])
        #expect(hint.completions.first { $0.keys == ["#"] }?.title == "Go to Trash")
        #expect(hint.completions.first { $0.keys == ["!"] }?.title == "Go to Spam")
        #expect(hint.completions.first { $0.keys == ["A"] }?.title == "Go to All mail")
        let withoutModules = ActionCatalog.all.filter { $0.module == nil }
        let core = SequenceHint.make(prefix: KeyBinding.Chord(.character("g")), scopes: [.global],
                                     descriptors: withoutModules)
        #expect(!core.completions.contains { $0.keys == ["Z"] }, "a disabled module's chord is not offered")
    }

    @Test func sheetGroupsAndFilters() {
        let sheet = ShortcutSheet(descriptors: ActionCatalog.all)
        #expect(sheet.sections.map(\.title) == ["Navigate", "Act", "Write"])
        let act = sheet.sections[1].lines
        #expect(act.first { $0.action == .trash }?.keys == ["#", "⌫"])
        #expect(!act.contains { $0.action == .notSpam }, "palette-only actions have no line")
        #expect(act.first { $0.action == .unsubscribe }?.keys == ["⌘U"], "⌘U since the keymap fixes")
        let filtered = sheet.filtered("snooze")
        #expect(filtered.flatMap(\.lines).map(\.action).contains(.snooze))
        #expect(sheet.filtered("⇧H").flatMap(\.lines).map(\.action) == [ActionCatalog.remindOnH ? .snooze : .remind])
        #expect(sheet.filtered("").count == 3)
    }
}
