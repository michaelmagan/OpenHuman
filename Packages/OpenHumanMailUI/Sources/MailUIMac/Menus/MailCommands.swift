import AppKit
import MailActions
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

public struct MailCommands: Commands {
    let router: @MainActor () -> AppRouter?
    let themes: @MainActor () -> ThemeStore?

    public init(router: @escaping @MainActor () -> AppRouter?, themes: @escaping @MainActor () -> ThemeStore? = { nil }) {
        self.router = router
        self.themes = themes
    }

    public var body: some Commands {
        let router = router()
        CommandGroup(replacing: .newItem) {
            MenuItems(descriptors: Self.fileMenuIDs.compactMap(ActionCatalog.descriptor), router: router)
        }
        CommandMenu("Message") {
            MenuItems(descriptors: Self.messageMenuComposeDescriptors, router: router)
            Divider()
            MenuItems(descriptors: Self.menuDescriptors(.thread), router: router)
            Divider()
            MenuItems(descriptors: Self.menuDescriptors(.app), router: router)
        }
        CommandMenu("Go") {
            MenuItems(descriptors: Self.menuDescriptors(.navigation), router: router)
            if let router, router.showsAccountSwitcher {
                Divider()
                ForEach(Array(router.accounts.enumerated()), id: \.element.id) { position, state in
                    if position < 9, let descriptor = ActionCatalog.descriptor(.switchToAccount(position + 1)) {
                        MenuItem(descriptor: descriptor, router: router,
                                 title: state.account.alias ?? state.account.displayName ?? state.account.email)
                    }
                }
            }
        }
        CommandGroup(replacing: .printItem) {
            if let descriptor = ActionCatalog.descriptor(.printConversation) {
                MenuItem(descriptor: descriptor, router: router)
            }
        }
        CommandMenu("Format") {
            MenuItems(descriptors: Self.formatMenuDescriptors, router: router)
        }
        let themes = themes()
        CommandGroup(after: .sidebar) {
            MenuItems(descriptors: Self.menuDescriptors(.view).filter { !Self.isMessageItem($0) }, router: router)
            Divider()
            MenuItems(descriptors: Self.menuDescriptors(.view).filter(Self.isMessageItem), router: router)
            if let themes {
                Divider()
                AppearanceMenu(themes: themes, router: router)
                AccentMenu(themes: themes, router: router)
            }
        }
    }

    public static func menuDescriptors(_ category: ActionCategory) -> [ActionDescriptor] {
        ActionCatalog.descriptors(in: category).filter(\.appearsInMenu)
    }

    static let fileMenuIDs: [ActionID] = [.compose, .composeInWindow]

    static func isComposerItem(_ descriptor: ActionDescriptor) -> Bool { descriptor.scopes == [.composer] }

    static var messageMenuComposeDescriptors: [ActionDescriptor] {
        menuDescriptors(.compose).filter { !fileMenuIDs.contains($0.id) && !isComposerItem($0) }
    }

    static var formatMenuDescriptors: [ActionDescriptor] { menuDescriptors(.compose).filter(isComposerItem) }

    static func isMessageItem(_ descriptor: ActionDescriptor) -> Bool { descriptor.scopes == [.reader] }

    public static func keyboardShortcut(for descriptor: ActionDescriptor) -> KeyboardShortcut? {
        guard let binding = descriptor.menuKeyEquivalent, case .character = binding.chords[0].key else { return nil }
        return binding.keyboardShortcut
    }

    /// The symbol a menu item shows beside its title: the conversation's actions, where the toolbar shows the same
    /// symbol. Text only where menu images are not available.
    @MainActor
    static func menuSymbol(for id: ActionID, features: NativeFeatures = .current) -> String? {
        guard features.menuItemImages else { return nil }
        return ReaderActions.symbol(for: id)
    }

    public static func source(for event: NSEvent.EventType?) -> ActionSource {
        event == .keyDown ? .keyboard : .menu
    }
}

struct MenuItems: View {
    let descriptors: [ActionDescriptor]
    let router: AppRouter?

    var body: some View {
        ForEach(descriptors.filter { router?.environment.actions.contains($0.id) ?? true }) { descriptor in
            if descriptor.accountPosition == nil {
                MenuItem(descriptor: descriptor, router: router)
            }
        }
    }
}

struct MenuItem: View {
    let descriptor: ActionDescriptor
    let router: AppRouter?
    var title: String?

    var body: some View {
        let enabled = router?.isEnabled(descriptor.id) ?? false
        let shown = title ?? descriptor.title
        Button {
            router?.perform(descriptor.id, source: MailCommands.source(for: NSApp.currentEvent?.type))
        } label: {
            if let symbol = MailCommands.menuSymbol(for: descriptor.id) {
                Label(shown, systemImage: symbol)
            } else {
                Text(shown)
            }
        }
        .disabled(!enabled)
        .keyboardShortcut(MailCommands.keyboardShortcut(for: router?.environment.actions.descriptor(descriptor.id) ?? descriptor))
    }
}

struct AppearanceMenu: View {
    let themes: ThemeStore
    let router: AppRouter?

    var body: some View {
        let current = themes.preferences.mode
        Menu("Appearance") {
            ForEach([AppearanceMode.light, .dark, .system], id: \.self) { mode in
                let id = ThemeActionHandler.action(for: mode)
                Toggle(mode.menuTitle, isOn: Binding(get: { current == mode }, set: { _ in router?.perform(id, source: .menu) }))
                    .disabled(!(router?.isEnabled(id) ?? false))
            }
        }
    }
}

struct AccentMenu: View {
    let themes: ThemeStore
    let router: AppRouter?

    var body: some View {
        let current = themes.resolved.accentID
        Menu("Accent") {
            ForEach(themes.library.accentIDs, id: \.self) { name in
                let id = ActionID.themeAccent(name)
                Toggle(name.prefix(1).uppercased() + name.dropFirst(),
                       isOn: Binding(get: { current == name }, set: { _ in router?.perform(id, source: .menu) }))
                    .disabled(!(router?.isEnabled(id) ?? false))
            }
        }
    }
}

extension AppearanceMode {
    var menuTitle: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}

private extension ActionDescriptor {
    var accountPosition: Int? { id.accountPosition }
}
