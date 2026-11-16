extension ActionCatalog {
    /// ← in the list gives the sidebar the keys. There ↑ ↓ (the list's own keys) and J K move the highlight, Return
    /// opens the highlighted place, and Esc goes back to the list without opening anything. ← and → stay the list's
    /// own, so they still fold and unfold nested labels.
    static let sidebarFocus: [ActionDescriptor] = [
        ActionDescriptor(.focusLabelSidebar, "Go to Sidebar", category: .view, bindings: [.named(.left)],
                         scopes: [.list], appearsInPalette: false, appearsInMenu: false),
        ActionDescriptor(.sidebarOpen, "Open sidebar item", shortTitle: "Open", category: .navigation,
                         bindings: [.named(.enter)], scopes: [.sidebar], appearsInPalette: false, appearsInMenu: false),
        ActionDescriptor(.sidebarLeave, "Back to list", category: .navigation,
                         bindings: [.named(.escape)], scopes: [.sidebar],
                         appearsInPalette: false, appearsInMenu: false),
        ActionDescriptor(.sidebarNext, "Next sidebar item", category: .navigation, bindings: [.key("j")],
                         scopes: [.sidebar], appearsInPalette: false, appearsInMenu: false, allowsKeyRepeat: true),
        ActionDescriptor(.sidebarPrevious, "Previous sidebar item", category: .navigation, bindings: [.key("k")],
                         scopes: [.sidebar], appearsInPalette: false, appearsInMenu: false, allowsKeyRepeat: true),
    ]
}
