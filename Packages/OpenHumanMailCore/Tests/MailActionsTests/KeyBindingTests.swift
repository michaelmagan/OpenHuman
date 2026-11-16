import Testing
@testable import MailActions

@Suite struct KeyBindingGrammarTests {
    func parse(_ text: String) throws -> KeyBinding { try KeyBinding(parsing: text) }

    @Test func printableKeysAndShift() throws {
        #expect(try parse("e") == .key("e"))
        #expect(try parse("E") == .key("E"))
        #expect(try parse("⇧e") == .key("E"), "⇧ on a letter is the capital letter")
        #expect(try parse("shift+e") == .key("E"))
        #expect(try parse("#") == .key("#"))
        #expect(try parse("!") == .key("!"))
        #expect(try parse("?") == .key("?"))
        #expect(throws: KeyBindingParseError.shiftedSymbol("⇧1")) { try parse("⇧1") }
    }

    @Test func digitsInCommandChordsKeepShift() throws {
        let numbered = try parse("⇧⌘7")
        #expect(numbered == .chord("7", [.command, .shift]))
        #expect(numbered.chords[0].modifiers == [.command, .shift] && numbered.description == "⇧⌘7")
        #expect(numbered.grammar == "⇧⌘7")
        #expect(try parse(numbered.grammar) == numbered)
        #expect(try parse("cmd+shift+8") == .chord("8", [.command, .shift]))
        #expect(try parse("ctrl+shift+1").chords[0].modifiers == [.control, .shift])
        #expect(try parse("⌃1") == .chord("1", .control), "no ⇧, no change")
        #expect(KeyBinding.chord("#", [.command, .shift]).chords[0].modifiers == .command, "a symbol never keeps ⇧")
        #expect(KeyBinding.Chord(.character("7"), modifiers: .shift).modifiers.isEmpty, "a bare digit keeps no ⇧")
        #expect(throws: KeyBindingParseError.shiftedSymbol("⇧7")) { try parse("⇧7") }
        #expect(throws: KeyBindingParseError.shiftedSymbol("⇧⌥7")) { try parse("⇧⌥7") }
        #expect(KeyBinding.isDigit("7") && !KeyBinding.isDigit("a") && !KeyBinding.isDigit("77") && !KeyBinding.isDigit("٧"))
    }

    @Test func modifiersInBothSpellings() throws {
        #expect(try parse("⌘K") == .chord("K", .command))
        #expect(try parse("⌘k") == .chord("k", .command))
        #expect(try parse("cmd+k") == .chord("k", .command))
        #expect(try parse("⇧⌘Z") == .chord("Z", .command), "⇧⌘Z arrives as Z + ⌘")
        #expect(try parse("cmd+shift+z") == .chord("Z", .command))
        #expect(try parse("⌘⇧z") == .chord("Z", .command))
        #expect(try parse("⌃1") == .chord("1", .control))
        #expect(try parse("ctrl+cmd+s") == .chord("s", [.control, .command]))
        #expect(try parse("⌥⌘I") == .chord("I", [.option, .command]))
        #expect(try parse("cmd++") == .chord("+", .command))
    }

    @Test func namedKeysKeepShift() throws {
        #expect(try parse("↵") == .named(.enter))
        #expect(try parse("return") == .named(.enter))
        #expect(try parse("⇥") == .named(.tab))
        #expect(try parse("⇧⇥") == .named(.tab, .shift))
        #expect(try parse("shift+tab") == .named(.tab, .shift))
        #expect(try parse("esc") == .named(.escape))
        #expect(try parse("⌫") == .named(.delete))
        #expect(try parse("⌘⌫") == .named(.delete, .command))
        #expect(try parse("↓") == .named(.down))
        #expect(try parse("⌘↵") == .named(.enter, .command))
    }

    @Test func sequences() throws {
        #expect(try parse("g i") == .sequence("g", "i"))
        #expect(try parse("  g   i ") == .sequence("g", "i"))
        #expect(throws: KeyBindingParseError.tooManyChords("g i x")) { try parse("g i x") }
    }

    @Test func errorsNameTheText() {
        #expect(throws: KeyBindingParseError.empty) { try parse("  ") }
        #expect(throws: KeyBindingParseError.missingKey("⌘")) { try parse("⌘") }
        #expect(throws: KeyBindingParseError.missingKey("cmd+")) { try parse("cmd+") }
        #expect(throws: KeyBindingParseError.unknownKey("pageup")) { try parse("pageup") }
        #expect(throws: KeyBindingParseError.duplicateModifier("⌘⌘k")) { try parse("⌘⌘k") }
        #expect(KeyBindingParseError.shiftedSymbol("⇧1").description.contains("\"!\""))
    }

    @Test func everyCatalogBindingRoundTripsThroughTheGrammar() throws {
        for descriptor in ActionCatalog.all {
            for binding in descriptor.defaultBindings {
                let parsed = try KeyBinding(parsing: binding.grammar)
                #expect(parsed.chords == binding.chords, "\(descriptor.id): \(binding.grammar)")
            }
        }
    }

    @Test func displayUsesMacKeycaps() throws {
        #expect(try parse("⇧⌘z").description == "⇧⌘Z")
        #expect(try parse("ctrl+opt+cmd+k").description == "⌃⌥⌘K")
        #expect(try parse("g i").description == "G I")
        #expect(try parse("g i").keycaps == ["G", "I"])
        #expect(try parse("H").description == "⇧H")
        #expect(try parse("⇧⇥").description == "⇧⇥")
        #expect(try parse("⌫").description == "⌫")
        #expect(KeyBinding.key("E").grammar == "E")
        #expect(KeyBinding.chord("Z", .command).grammar == "⌘Z")
        #expect(KeyBinding.named(.tab, .shift).grammar == "⇧⇥")
    }
}

@Suite struct ConflictDetectorTests {
    @Test func theWholeCatalogHasNoConflicts() {
        let conflicts = KeyBindingConflicts.find(in: ActionCatalog.all)
        #expect(conflicts.isEmpty, "\(conflicts)")
    }

    @Test func sameKeysInOverlappingScopesAreFound() {
        let a = ActionDescriptor(ActionID("test.a"), "A", category: .thread, bindings: [.key("e")], scopes: [.list])
        let b = ActionDescriptor(ActionID("test.b"), "B", category: .thread, bindings: [.key("e")], scopes: [.reader])
        let c = ActionDescriptor(ActionID("test.c"), "C", category: .app, bindings: [.key("e")], scopes: [.global])
        #expect(KeyBindingConflicts.find(in: [a, b]).isEmpty, "list and reader never overlap")
        let found = KeyBindingConflicts.find(in: [a, b, c])
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.kind == .sameKeys && $0.second == c.id })
    }

    @Test func aSingleKeyMayNotShadowASequencePrefix() {
        let g = ActionDescriptor(ActionID("test.g"), "G", category: .thread, bindings: [.key("g")], scopes: [.list])
        let goInbox = ActionCatalog.descriptor(.goInbox)!
        let found = KeyBindingConflicts.find(in: [g, goInbox])
        #expect(found.map(\.kind) == [.prefixShadowsSequence])
        #expect(found.first?.first == g.id && found.first?.second == .goInbox)
    }

    @Test func designKeysThatMustStayDistinct() {
        let hints = [ActionID.goAllMail, .goReview, .goReminders, .goScheduled, .goMuted, .goDone].compactMap {
            ActionCatalog.descriptor($0)?.shortcutHint
        }
        #expect(hints == ["G A", "G R", "G H", "G Y", "G M", "G E"])
        #expect(ActionCatalog.descriptor(.remind)?.shortcutHint == (ActionCatalog.remindOnH ? "H" : "⇧H"))
        let singleM = ActionCatalog.all.filter { $0.defaultBindings.contains { $0.chords == [KeyBinding.Chord(.character("m"))] } }
            .filter { descriptor in descriptor.defaultBindings.contains { descriptor.scopes(of: $0) != [.calendar] } }
        #expect(singleM.map(\.id) == [.toggleMute] && singleM.first?.module == .mute, "`m` is Mute only")
    }

    @Test func theImportanceKeysAreFreeEverywhereElse() throws {
        for (key, id) in [("+", ActionID.alwaysImportantSender), ("-", ActionID.neverImportantDomain)] {
            let bound = ActionCatalog.all.filter { $0.defaultBindings.contains { $0.chords == [KeyBinding.Chord(.character(key))] } }
                .filter { descriptor in
                    descriptor.defaultBindings.contains {
                        $0.chords == [KeyBinding.Chord(.character(key))] && descriptor.scopes(of: $0) != [.calendar]
                    }
                }
            #expect(bound.map(\.id) == [id], "`\(key)` is \(id) only")
            let descriptor = try #require(bound.first)
            #expect(descriptor.scopes == [.list, .reader] && descriptor.module == .importance && descriptor.changesMail)
            #expect(try KeyBinding(parsing: key).chords == [KeyBinding.Chord(.character(key))], "the grammar reads it")
        }
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty)
    }
}

@Suite struct KeymapFixesConflictTests {
    static func action(_ name: String, _ binding: KeyBinding, _ scopes: Set<ActionScope>) -> ActionDescriptor {
        ActionDescriptor(ActionID("test.\(name)"), name, category: .thread, bindings: [binding], scopes: scopes)
    }

    @Test func theAddedKeysAreTakenWhereTheyWork() {
        let probes: [(KeyBinding, Set<ActionScope>, ActionID)] = [
            (.chord("u", .command), [.list], .unsubscribe), (.key("M"), [.reader], .toggleMute),
            (.sequence("g", "m"), [.global], .goMuted), (.sequence("g", "h"), [.global], .goReminders),
            (.sequence("g", "e"), [.global], .goDone), (.key("i"), [.list], .aiSummarize),
            (.key("0"), [.reader], .calendarToggleSidebar), (.key("b"), [.list], .calendarCreateEvent),
            (.named(.left), [.list], .focusLabelSidebar), (.chord("n", .command), [.list], .compose),
            (.chord("F", .command), [.composer], .chooseFrom), (.chord("U", .command), [.composer], .attachFiles),
            (.chord("T", .command), [.composer], .focusTo), (.chord("f", .command), [.reader], .findInConversation),
            (.named(.escape), [.review], .reviewLeave), (.chord("7", [.command, .shift]), [.composer], .formatNumberedList),
        ]
        for (binding, scopes, owner) in probes {
            let found = KeyBindingConflicts.find(in: ActionCatalog.all + [Self.action("probe", binding, scopes)])
            #expect(found.contains { $0.first == owner || $0.second == owner }, "\(binding) in \(scopes) is \(owner)'s")
        }
    }

    @Test func theSameKeyInDisjointPlacesIsFine() {
        let underline = ActionCatalog.descriptor(.formatUnderline)!
        let unsubscribe = ActionCatalog.descriptor(.unsubscribe)!
        #expect(KeyBindingConflicts.find(in: [underline, unsubscribe]).isEmpty)
        let zero = ActionCatalog.descriptor(.calendarToggleSidebar)!
        #expect(KeyBindingConflicts.find(in: [zero] + ActionCatalog.accounts).isEmpty)
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all + [Self.action("shiftB", .key("B"), [.list])]).isEmpty)
    }

    @Test func noComposerKeyIsATextSystemKey() {
        let conflicts = KeyBindingConflicts.textSystemConflicts(in: ActionCatalog.all)
        #expect(conflicts.isEmpty, "\(conflicts)")
        let discard = KeyBinding.Chord(.named(.delete), modifiers: .command)
        #expect(KeyBindingConflicts.reserved[discard] == "deleteToBeginningOfLine:")
        #expect(KeyBindingConflicts.reservedExceptions[discard] == .discardDraft)
        // ⌘⇧. reaches the composer as ⌘> (⇧. is >), which is no text system key, unlike ⌘. (cancelOperation:)
        #expect(ActionCatalog.descriptor(.discardDraft)?.defaultBindings.map(\.description) == ["⌘⌫", "⌘>"])
        #expect(KeyBindingConflicts.reserved[KeyBinding.Chord(.character(">"), modifiers: .command)] == nil)
    }

    @Test func aComposerKeyOnAnEditingKeyIsFound() {
        let emacs = Self.action("emacs", .chord("a", .control), [.composer])
        let cancel = Self.action("cancel", .chord(".", .command), [.composer])
        let words = Self.action("words", .named(.delete, .option), [.composer])
        let otherDelete = Self.action("otherDelete", .named(.delete, .command), [.composer])
        let found = KeyBindingConflicts.textSystemConflicts(in: [emacs, cancel, words, otherDelete])
        #expect(found.map(\.action.rawValue) == ["test.emacs", "test.cancel", "test.words", "test.otherDelete"])
        #expect(found.first?.textSystemUse == "Emacs-style editing")
        #expect(KeyBindingConflicts.textSystemConflicts(in: [Self.action("list", .chord("a", .control), [.list])]).isEmpty)
    }

    @Test func aUserKeymapCannotPutAComposerKeyOnAnEditingKey() throws {
        let keymap = Keymap.resolve(KeymapOverrides(bindings: ["format.bold": ["⌃b"], "format.italic": ["⌘Y"]]),
                                    descriptors: ActionCatalog.all)
        #expect(keymap.overrides[.formatBold] == nil, "⌃B is one of the text system's Emacs-style editing keys")
        #expect(keymap.issues.contains { if case .textSystem(let c) = $0 { c.action == .formatBold } else { false } })
        let bold = try #require(keymap.apply(to: ActionCatalog.all).first { $0.id == .formatBold })
        #expect(bold.defaultBindings.map(\.description) == ["⌘B"], "keeps its default")
        #expect(keymap.overrides[.formatItalic] == [.chord("Y", .command)], "a free composer key is accepted")
    }
}
