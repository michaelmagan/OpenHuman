import Testing
@testable import MailActions

@Suite struct SidebarFocusCatalogTests {
    func keys(_ id: ActionID) -> [String]? { ActionCatalog.descriptor(id)?.defaultBindings.map(\.description) }

    @Test func leftInTheListGoesToTheSidebar() throws {
        let focus = try #require(ActionCatalog.descriptor(.focusLabelSidebar))
        #expect(keys(.focusLabelSidebar) == ["←"] && focus.scopes == [.list])
        #expect(!focus.appearsInMenu, "a plain ← is no menu key")
        #expect(keys(.toggleLabelSidebar) == ["⌃⌘S"], "⌃⌘S still shows and hides the sidebar")
    }

    @Test func theSidebarHasItsOwnKeys() throws {
        #expect(keys(.sidebarOpen) == ["↵"])
        #expect(keys(.sidebarLeave) == ["Esc"], "→ unfolds a nested label")
        #expect(keys(.sidebarNext) == ["J"] && keys(.sidebarPrevious) == ["K"])
        for id in [ActionID.sidebarOpen, .sidebarLeave, .sidebarNext, .sidebarPrevious] {
            let descriptor = try #require(ActionCatalog.descriptor(id))
            #expect(descriptor.scopes == [.sidebar] && !descriptor.appearsInPalette && !descriptor.appearsInMenu, "\(id)")
        }
        let arrows: [[KeyBinding.Chord]] = [[.init(.named(.up))], [.init(.named(.down))], [.init(.named(.left))],
                                            [.init(.named(.right))]]
        let sidebarArrows = ActionCatalog.all.filter { descriptor in
            descriptor.defaultBindings.contains { descriptor.scopes(of: $0).contains(.sidebar) && arrows.contains($0.chords) }
        }
        #expect(sidebarArrows.isEmpty, "the arrows stay the sidebar list's own: VoiceOver follows its selection and ← → fold labels")
        #expect(KeyBindingConflicts.find(in: ActionCatalog.all).isEmpty)
    }

    @Test func theShortcutSheetNamesTheSidebar() throws {
        let lines = ShortcutSheet(descriptors: ActionCatalog.all).sections.flatMap(\.lines)
        let open = try #require(lines.first { $0.action == .sidebarOpen })
        #expect(open.places == ["Sidebar"])
        let focus = try #require(lines.first { $0.action == .focusLabelSidebar })
        #expect(focus.keys == ["←"] && focus.places == ["List"])
    }
}
