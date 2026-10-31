extension ActionCatalog {
    static let invites: [ActionDescriptor] = [
        ActionDescriptor(.inviteYes, "Invitation: Yes", shortTitle: "Yes", category: .thread, bindings: [.key("A")],
                         scopes: [.reader], effect: .external, target: .focusedThread,
                         keywords: ["accept", "rsvp", "yes", "going", "invitation", "invite", "attend"],
                         appearsInMenu: false),
        ActionDescriptor(.inviteMaybe, "Invitation: Maybe", shortTitle: "Maybe", category: .thread, bindings: [.key("T")],
                         scopes: [.reader], effect: .external, target: .focusedThread,
                         keywords: ["maybe", "tentative", "rsvp", "invitation", "invite"], appearsInMenu: false),
        ActionDescriptor(.inviteNo, "Invitation: No", shortTitle: "No", category: .thread, bindings: [.key("D")],
                         scopes: [.reader], effect: .external, target: .focusedThread,
                         keywords: ["decline", "rsvp", "no", "not going", "invitation", "invite"], appearsInMenu: false),
        ActionDescriptor(.inviteRemove, "Invitation: Remove from calendar…", shortTitle: "Remove", category: .thread,
                         bindings: [.key("X")], scopes: [.reader], effect: .external, target: .focusedThread,
                         isDestructive: true,
                         keywords: ["remove", "delete", "remove from calendar", "delete invitation", "junk invitation",
                                    "invitation", "invite", "calendar"],
                         appearsInMenu: false),
        ActionDescriptor(.inviteShowOriginal, "Invitation: Show original email", category: .view, scopes: [.reader],
                         target: .focusedThread, keywords: ["original", "invitation", "html", "show original"],
                         appearsInMenu: false),
    ]
}
