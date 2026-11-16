import Testing
@testable import MailActions

@Test func catalogIDsAreUniqueAndFollowTheNamingRule() {
    let ids = ActionCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for id in ids {
        let parts = id.rawValue.split(separator: ".")
        let isAccent = parts.count == 3 && parts[0] == "theme" && parts[1] == "accent"
        #expect(parts.count == 2 || isAccent, "\(id) is not <noun>.<verb>")
        #expect(parts.allSatisfy { $0.first?.isLowercase == true }, "\(id) is not lowerCamel")
        #expect(ActionCatalog.descriptor(id)?.id == id)
    }
}

@Test func designKeysAreBound() throws {
    func hint(_ id: ActionID) -> String? { ActionCatalog.descriptor(id)?.shortcutHint }
    #expect(hint(.markDone) == "E")
    #expect(hint(.trash) == "#")
    #expect(hint(.nextThread) == "J")
    #expect(hint(.openThread) == "↵")
    #expect(hint(.backToList) == "Esc")
    #expect(hint(.nextSplit) == "⇥")
    #expect(hint(.previousSplit) == "⇧⇥")
    #expect(hint(.goInbox) == "G I")
    #expect(hint(.goAllMail) == "G A")
    #expect(hint(.goTrash) == "G #" && hint(.goSpam) == "G !", "Superhuman's go-to keys for Trash and Spam")
    #expect(hint(.goReview) == "G R")
    #expect(hint(.goReminders) == "G H" && hint(.goMuted) == "G M", "Superhuman's chords since the keymap fixes")
    #expect(hint(.goScheduled) == "G Y")
    #expect(hint(.switchToAccount(2)) == "⌃2")
    #expect(hint(.toggleLabelSidebar) == "⌃⌘S")
    #expect(hint(.undo) == "⌘Z")
    #expect(hint(.redo) == "⇧⌘Z")
    #expect(hint(.nextMessage) == "N" && hint(.previousMessage) == "P")
    #expect(ActionCatalog.descriptor(.nextMessage)?.defaultBindings.map(\.description) == ["N", "↓"])
    #expect(ActionCatalog.descriptor(.previousMessage)?.defaultBindings.map(\.description) == ["P", "↑"])
    #expect(hint(.toggleMessage) == "O" && hint(.expandAllMessages) == "⇧O")
    #expect(hint(.toggleQuotedText) == "." && hint(.showImages) == "⇧I")
    #expect(hint(.showNewMessages) == "⇧N", "the new-messages pill's key")
    for id in [ActionID.nextMessage, .previousMessage, .toggleMessage, .expandAllMessages, .toggleQuotedText, .showImages,
               .showNewMessages] {
        let descriptor = ActionCatalog.descriptor(id)
        #expect(descriptor?.scopes == [.reader] && descriptor?.changesMail == false && descriptor?.appearsInMenu == true)
        #expect(descriptor?.defaultBindings.contains { $0.chords.first?.key == .named(.tab) } == false,
                "⇥ stays the key-view loop (and the quick replies)")
    }
    #expect(ActionCatalog.descriptor(.nextThread)?.scopes(of: .named(.down, onlyIn: [.list])) == [.list],
            "↓ still moves the list cursor in the list")
    // ↵ in a conversation opens the message the keys selected, then replies; ⇧↵ is the other reply, straight away
    let (shiftReturn, plainReturn): (ActionID, ActionID) = ActionCatalog.returnRepliesAll ? (.reply, .replyAll) : (.replyAll, .reply)
    #expect(ActionCatalog.descriptor(shiftReturn)?.defaultBindings.map(\.description).last == "⇧↵")
    #expect(ActionCatalog.descriptor(plainReturn)?.defaultBindings.map(\.description).count == 1, "its ↵ is the next action's")
    let openOrReply = try #require(ActionCatalog.descriptor(.openMessageOrReply))
    #expect(openOrReply.defaultBindings.map(\.description) == ["↵"] && openOrReply.scopes == [.reader])
    #expect(openOrReply.shortTitle == (ActionCatalog.returnRepliesAll ? "Reply all" : "Reply") && !openOrReply.appearsInMenu)
    for id in [ActionID.reply, .replyAll] {
        let descriptor = try #require(ActionCatalog.descriptor(id))
        #expect(descriptor.defaultBindings.first?.description == (id == .reply ? "R" : "A") && descriptor.appearsInMenu)
    }
    #expect(ActionCatalog.descriptor(.forward)?.appearsInMenu == true)
    #expect(ActionCatalog.descriptor(.openThread)?.scopes == [.list])
    #expect(ActionID.switchToAccount(7).accountPosition == 7)
    #expect(ActionID("account.switch0").accountPosition == nil)
    #expect(ActionID.markDone.accountPosition == nil)
}

@Test func writesAreMarkedAndCarryTheirCLIPath() {
    #expect(ActionCatalog.descriptor(.markDone)?.changesMail == true)
    #expect(ActionCatalog.descriptor(.markDone)?.cliCommand == ["gmail", "done"])
    #expect(ActionCatalog.descriptor(.trash)?.isDestructive == true)
    #expect(ActionCatalog.descriptor(.nextSplit)?.changesMail == false)
    #expect(ActionID.markDone.isViewOnly == false)
    #expect(ActionID.goInbox.isViewOnly)
    #expect(!ActionID("not.inTheCatalog").isViewOnly, "unknown ids fail closed")
    #expect(ActionID.viewOnly.isSuperset(of: [.nextThread, .previousThread, .openThread, .backToList, .nextSplit, .goInbox]))
    #expect(!ActionID.viewOnly.contains(.markDone))
}

@Test func noKeyIsBoundTwiceInOverlappingScopes() {
    var entries: [(id: ActionID, scope: ActionScope, binding: KeyBinding)] = []
    for descriptor in ActionCatalog.all {
        for binding in descriptor.defaultBindings {
            for scope in descriptor.scopes(of: binding) { entries.append((descriptor.id, scope, binding)) }
        }
    }
    for (i, a) in entries.enumerated() {
        for b in entries[(i + 1)...] where a.id != b.id {
            guard a.scope == b.scope || a.scope == .global || b.scope == .global else { continue }
            #expect(a.binding.chords != b.binding.chords, "\(a.binding) is bound to \(a.id) and \(b.id)")
            #expect(!(a.binding.chords.count == 2 && b.binding.chords == [a.binding.chords[0]]))
            #expect(!(b.binding.chords.count == 2 && a.binding.chords == [b.binding.chords[0]]))
        }
    }
}

@Test func refreshAddAccountAndTheSettingsPagesArePaletteEntriesThatChangeNoMail() throws {
    let refresh = try #require(ActionCatalog.descriptor(.refresh))
    #expect(refresh.title == "Refresh" && refresh.category == .view && refresh.appearsInMenu && refresh.appearsInPalette)
    #expect(refresh.effect == .view && refresh.defaultBindings.map(\.description) == ["⌘R"] && refresh.cliCommand == nil)
    let add = try #require(ActionCatalog.descriptor(.addAccount))
    #expect(add.title == "Add account…" && add.effect == .view && !add.appearsInMenu && add.appearsInPalette)
    #expect(add.id.accountPosition == nil, "not an account switch")
    let pages = ActionCatalog.settingsPages
    #expect(pages.count == 16 && Set(pages.map(\.id)).count == pages.count)
    for page in pages {
        #expect(ActionCatalog.descriptor(page.id) == page, "\(page.id) is in the catalog")
        #expect(page.title.hasPrefix("Settings: ") && page.paletteKeywords.contains("settings"))
        #expect(page.effect == .view && page.defaultBindings.isEmpty && !page.appearsInMenu && page.appearsInPalette)
        #expect(page.id.settingsPageID.map(ActionID.settingsPage) == page.id)
    }
    #expect(ActionID.settingsPage("notifications").rawValue == "settings.notifications")
    #expect(ActionID.markDone.settingsPageID == nil && ActionID("settings.").settingsPageID == nil)
    for id in [ActionID.refresh, .addAccount, .settingsPage("general")] { #expect(id.isViewOnly) }
}

@Test func accountSwitchTitlesNameTheAccount() throws {
    var context = ActionContext(accountCount: 2)
    context.accountTitles = ["Work", "robin@example.com"]
    let second = try #require(ActionCatalog.descriptor(.switchToAccount(2)))
    #expect(ActionRules.title(for: second, in: context) == "Switch to robin@example.com")
    #expect(ActionRules.title(for: try #require(ActionCatalog.descriptor(.switchToAccount(1))), in: context) == "Switch to Work")
    #expect(ActionRules.title(for: try #require(ActionCatalog.descriptor(.switchToAccount(3))), in: context) == "Account 3")
    #expect(ActionRules.title(for: second, in: ActionContext()) == "Account 2")
    #expect(ActionRules.title(for: try #require(ActionCatalog.descriptor(.markDone)), in: context) == "Mark done")
    #expect(context.accountTitle(at: 0) == nil && context.accountTitle(at: 2) == "robin@example.com")
}

@Test func onlyCommandAndControlChordsAreMenuKeyEquivalents() {
    for descriptor in ActionCatalog.all {
        for binding in descriptor.defaultBindings where binding.isMenuKeyEquivalent {
            #expect(binding.chords.count == 1)
            #expect(!binding.chords[0].modifiers.intersection([.command, .control]).isEmpty)
        }
    }
    #expect(KeyBinding.key("e").isMenuKeyEquivalent == false)
    #expect(KeyBinding.chord("1", .control).isMenuKeyEquivalent)
    #expect(KeyBinding.sequence("g", "i").isMenuKeyEquivalent == false)
}

@Test func scopedAndRouterOwnedChordsAreNeverMenuKeyEquivalents() {
    func equivalent(_ id: ActionID) -> String? { ActionCatalog.descriptor(id)?.menuKeyEquivalent?.description }
    #expect(equivalent(.search) == nil, "⌘F is the list's only")
    #expect(equivalent(.findInConversation) == nil, "⌘F in a conversation is the key router's")
    #expect(equivalent(.unsubscribe) == nil, "⌘U is Underline in the composer")
    #expect(equivalent(.undo) == nil && equivalent(.redo) == nil && equivalent(.checkAll) == nil)
    for id in ActionCatalog.formatIDs { #expect(equivalent(id) == nil, "\(id): the body's own key") }
    #expect(equivalent(.compose) == "⌘N", "File › New message")
    #expect(equivalent(.toggleLabelSidebar) == "⌃⌘S", "← is the list's, ⌃⌘S the menu's")
    #expect(equivalent(.calendarToggleSidebar) == "⌃⌘C", "0 is the list's and the conversation's, ⌃⌘C the menu's")
    #expect(equivalent(.switchToAccount(1)) == "⌃1")
    for descriptor in ActionCatalog.all {
        if let binding = descriptor.menuKeyEquivalent {
            #expect(binding.onlyIn == nil && descriptor.allowsMenuKeyEquivalent, "\(descriptor.id)")
        }
    }
}

@Test func onlyMovementRepeats() {
    let movement: Set<ActionID> = [.nextThread, .previousThread, .nextSplit, .previousSplit, .extendSelectionDown,
                                   .extendSelectionUp, .nextMessage, .previousMessage, .reviewNext, .reviewPrevious,
                                   .sidebarNext, .sidebarPrevious]
    for descriptor in ActionCatalog.all {
        #expect(descriptor.allowsKeyRepeat == movement.contains(descriptor.id), "\(descriptor.id)")
    }
    for id in [ActionID.compose, .composeInWindow, .search, .reply, .replyAll, .forward, .commandPalette, .shortcutHelp] {
        #expect(ActionCatalog.descriptor(id)?.allowsKeyRepeat == false, "\(id) runs once per press")
    }
    #expect(ActionCatalog.descriptor(.reviewNext)?.rebound([.key("y")]).allowsKeyRepeat == true, "a keymap keeps it")
}

@Test func superhumanKeysAreBound() throws {
    func keys(_ id: ActionID) -> [String]? { ActionCatalog.descriptor(id)?.defaultBindings.map(\.description) }
    #expect(keys(.unsubscribe) == ["⌘U"])
    #expect(keys(.toggleMute) == ["⇧M", "M"], "⇧M, and `m` keeps working")
    #expect(keys(.goMuted) == ["G M"] && keys(.goReminders) == ["G H"] && keys(.goDone) == ["G E"])
    #expect(keys(.aiSummarize) == ["I"] && keys(.showImages) == ["⇧I"], "`i` and ⇧I are two keys")
    #expect(keys(.calendarToggleSidebar) == ["0", "⌃⌘C"] && keys(.calendarCreateEvent) == ["B"])
    #expect(keys(.chooseFrom) == ["⇧⌘F", "⇧⌘E"] && keys(.attachFiles) == ["⇧⌘U"])
    #expect(keys(.calendarInsertAvailability) == ["⇧⌘A"])
    let availability = try #require(ActionCatalog.descriptor(.calendarInsertAvailability))
    #expect(availability.scopes == [.composer] && !availability.changesMail && availability.module == .calendar)
    for id in [ActionID.calendarPreviousDay, .calendarNextDay, .calendarToday] {
        #expect(keys(id) == [] && ActionCatalog.descriptor(id)?.module == .calendar, "\(id): palette only")
    }
    #expect(keys(.toggleLabelSidebar) == ["⌃⌘S"] && keys(.focusLabelSidebar) == ["←"])
    #expect(keys(.compose) == ["C", "⌘N"])
    let (remindKey, snoozeKey) = ActionCatalog.remindOnH ? ("H", "⇧H") : ("⇧H", "H")
    #expect(keys(.remind) == [remindKey] && keys(.snooze) == [snoozeKey])
    let sidebar = try #require(ActionCatalog.descriptor(.calendarToggleSidebar))
    #expect(sidebar.scopes(of: sidebar.defaultBindings[0]) == [.list, .reader], "a bare 0 never acts in an overlay")
    let labels = try #require(ActionCatalog.descriptor(.focusLabelSidebar))
    #expect(labels.scopes(of: labels.defaultBindings[0]) == [.list], "← moves to the sidebar from the list only")
    let unsubscribe = try #require(ActionCatalog.descriptor(.unsubscribe))
    #expect(unsubscribe.scopes == [.list, .reader] && unsubscribe.effect == .external)
}

@Test func theComposerKeysAreCatalogEntries() {
    func keys(_ id: ActionID) -> [String]? { ActionCatalog.descriptor(id)?.defaultBindings.map(\.description) }
    #expect(ActionCatalog.formatIDs.compactMap { keys($0)?.first }
            == ["⌘B", "⌘I", "⌘U", "⇧⌘X", "⇧⌘7", "⇧⌘8", "⌘]", "⌘[", "⇧⌘9", "⇧⌘K", "⌘\\"])
    #expect(keys(.showCc) == ["⇧⌘C"] && keys(.showBcc) == ["⇧⌘B"] && keys(.focusTo) == ["⇧⌘T"])
    #expect(keys(.closeComposer) == ["Esc"])
    for id in ActionCatalog.formatIDs + [.showCc, .showBcc, .focusTo, .closeComposer] {
        let descriptor = ActionCatalog.descriptor(id)
        #expect(descriptor?.scopes == [.composer] && descriptor?.changesMail == false, "\(id)")
        #expect(descriptor?.appearsInMenu == ActionCatalog.formatIDs.contains(id), "\(id): Format menu or none")
    }
    #expect(ActionCatalog.descriptor(.findInConversation)?.scopes == [.reader])
    #expect(ActionCatalog.descriptor(.reviewLeave)?.scopes == [.review] && ActionCatalog.descriptor(.reviewLeave)?.module == .review)
}
